// IEEE 802.11i 4-way handshake (STA side). Drives the PMK-to-PTK derivation,
// MIC validation, GTK unwrap, and key install via host-provided hooks.
//
// Message flow (STA perspective):
//   1/4: receive ANonce from AP -> derive PTK, build msg 2/4 with SNonce + RSN
//        IE, MIC over frame using KCK
//   3/4: validate MIC, AES-unwrap encrypted key_data with KEK, parse GTK KDE,
//        install pairwise TK + group GTK via hooks, build msg 4/4 with MIC
//
// Key descriptor version 2 (HMAC-SHA1 MIC, AES key-wrap) handled here;
// version 3 (AES-CMAC, used for PMF) is planned but not yet implemented.
module urt.driver.wpa.fourway;

import urt.crypto.aes_keywrap : aes_unwrap;
import urt.crypto.random : crypto_random_bytes;
import urt.driver.wpa.crypto;
import urt.digest.hmac;
import urt.digest.sha;
import urt.result : Result, InternalResult;

import urt.driver.wpa.eapol;

nothrow @nogc:


enum size_t wpa_kck_len      = 16;
enum size_t wpa_kek_len      = 16;
enum size_t wpa_tk_len_ccmp  = 16;
enum size_t wpa_gtk_max_len  = 32;
enum size_t wpa_max_eapol_len = 256;     // typical handshake frame is ~120 bytes

enum FourwayState : ubyte
{
    idle,                // before assoc / after disconnect
    awaiting_msg1,       // assoc done, waiting for AP's first key frame
    awaiting_msg3,       // sent msg 2, waiting for AP's msg 3
    completed,           // sent msg 4, keys installed
    failed,
}

enum WpaHandshakeReason : ushort
{
    none,
    random_failed,
    ptk_failed,
    encode_failed,
    tx_failed,
    mic_failed,
    nonce_mismatch,
    malformed_key_data,
    gtk_unwrap_failed,
    gtk_missing,
    pairwise_install_failed,
    group_install_failed,
    pmf_required_unsupported,
}

struct FourwayHooks
{
    // Send a full EAPOL-Key 802.1X payload to the AP. The driver prepends
    // the Ethernet header and submits to libwifi's TX path. Returns true on
    // queued; false on error (handshake will fail).
    bool delegate(const(ubyte)[] eapol_payload) nothrow @nogc send_eapol;

    // Install the pairwise TK (16 bytes CCMP). Returns true on success.
    bool delegate(const(ubyte)[] tk) nothrow @nogc install_pairwise_key;

    // Install the group GTK. key_idx is 1..3, rsc is 6-byte sequence
    // counter (sometimes shorter, pad with zeros to 6).
    bool delegate(ubyte key_idx, const(ubyte)[] gtk, const(ubyte)[] rsc) nothrow @nogc install_group_key;

    // Notify the host that the handshake completed (success=true) or failed
    // (success=false, reason carries a wpa-spec reason code).
    void delegate(bool success, ushort reason) nothrow @nogc handshake_complete;
}


struct FourwayContext
{
    FourwayHooks hooks;

    // Long-lived material (set by configure / begin)
    ubyte[wpa_pmk_len] pmk;
    ubyte[6] own_mac;
    ubyte[6] bssid;
    // RSN IE we placed in the assoc request -- the AP echoes this in msg 3
    // key_data and uses it to MIC msg 2 from us. Live slice -- caller owns
    // backing storage and must keep it valid for the handshake duration.
    const(ubyte)[] sta_rsn_ie;

    // Per-handshake state
    ubyte[wpa_nonce_len] anonce;
    ubyte[wpa_nonce_len] snonce;
    ubyte[wpa_ptk_len_ccmp] ptk;
    ubyte[eapol_key_replay_len] last_replay;
    ubyte[wpa_max_eapol_len] last_msg4;
    size_t last_msg4_len;
    FourwayState state;

nothrow @nogc:

    void configure(const(ubyte)[wpa_pmk_len] pmk_,
                   const(ubyte)[6] own_mac_,
                   const(ubyte)[6] bssid_,
                   const(ubyte)[] sta_rsn_ie_)
    {
        pmk = pmk_;
        own_mac = own_mac_;
        bssid = bssid_;
        sta_rsn_ie = sta_rsn_ie_;
        state = FourwayState.idle;
    }

    // Call after layer-2 association completed; arms the state machine for
    // the AP's incoming msg 1.
    void begin_association()
    {
        state = FourwayState.awaiting_msg1;
        last_replay[] = 0;
        last_msg4_len = 0;
    }

    void reset(WpaHandshakeReason reason)
    {
        reset(cast(ushort)reason);
    }

    void reset(ushort reason)
    {
        last_msg4_len = 0;
        if (state != FourwayState.idle && state != FourwayState.failed)
        {
            state = FourwayState.failed;
            if (hooks.handshake_complete)
                hooks.handshake_complete(false, reason);
        }
        else
        {
            state = FourwayState.idle;
        }
    }

    @property const(ubyte)[] kck() const => ptk[0 .. wpa_kck_len];
    @property const(ubyte)[] kek() const => ptk[wpa_kck_len .. wpa_kck_len + wpa_kek_len];
    @property const(ubyte)[] tk()  const => ptk[wpa_kck_len + wpa_kek_len .. $];

    // Process an incoming EAPOL-Key frame. The frame is the 802.1X payload
    // (the driver has already stripped the Ethernet header). Returns true if
    // the frame was consumed by the handshake; false if not for us.
    bool handle_eapol(const(ubyte)[] frame)
    {
        EapolKeyFrame f;
        if (!decode_eapol_key(frame, f))
            return false;
        if (f.descriptor_type != key_desc_type_rsn)
            return false;
        if (f.version_bits != key_info_ver_hmac_sha1_aes)
            return false;
        if (!f.pairwise || !f.key_ack)
            return false;

        if (!f.key_mic_set)
            return handle_msg1(frame, f);
        else
            return handle_msg3(frame, f);
    }

private:

    bool handle_msg1(const(ubyte)[] /*frame*/, ref const EapolKeyFrame f)
    {
        if (state != FourwayState.awaiting_msg1 && state != FourwayState.awaiting_msg3)
            return false;

        // Stash ANonce, replay counter, generate SNonce, derive PTK.
        anonce = f.key_nonce;
        last_replay = f.replay_counter;

        if (!crypto_random_bytes(snonce[]).succeeded)
        {
            reset(WpaHandshakeReason.random_failed);
            return true;
        }

        auto r = wpa2_pmk_to_ptk(pmk, bssid, own_mac, anonce, snonce, ptk[]);
        if (!r.succeeded)
        {
            reset(WpaHandshakeReason.ptk_failed);
            return true;
        }

        // Build msg 2/4. key_info: pairwise, MIC, version 2.
        ushort key_info = key_info_type_pairwise | key_info_key_mic | key_info_ver_hmac_sha1_aes;
        ubyte[8] zero_rsc = 0;

        ubyte[wpa_max_eapol_len] out_buf = void;
        size_t out_len = encode_eapol_key(out_buf[],
            eapol_version_2004, key_desc_type_rsn,
            key_info, f.key_length,
            last_replay, snonce, zero_rsc,
            sta_rsn_ie);
        if (out_len == 0)
        {
            reset(WpaHandshakeReason.encode_failed);
            return true;
        }

        ubyte[eapol_key_mic_len] mic;
        compute_mic(kck, out_buf[0 .. out_len], mic);
        patch_mic(out_buf[0 .. out_len], mic);

        if (!hooks.send_eapol(out_buf[0 .. out_len]))
        {
            reset(WpaHandshakeReason.tx_failed);
            return true;
        }

        state = FourwayState.awaiting_msg3;
        return true;
    }

    bool handle_msg3(const(ubyte)[] frame, ref const EapolKeyFrame f)
    {
        if (state != FourwayState.awaiting_msg3)
        {
            if (state == FourwayState.completed)
            {
                if (last_msg4_len != 0 && hooks.send_eapol)
                    hooks.send_eapol(last_msg4[0 .. last_msg4_len]);
                return true;
            }
            else if (last_msg4_len != 0 && hooks.send_eapol)
            {
                hooks.send_eapol(last_msg4[0 .. last_msg4_len]);
                return true;
            }
            else
            {
                return false;
            }
        }

        // Replay: must be > last (we treat == as a retransmit and just
        // re-send the prior msg 2; not implemented yet, just drop).
        if (compare_replay(f.replay_counter, last_replay) <= 0)
            return true;

        // Verify MIC: compute over frame with the MIC field zeroed.
        if (!verify_mic(kck, frame, f.key_mic))
        {
            reset(WpaHandshakeReason.mic_failed);
            return true;
        }

        last_replay = f.replay_counter;

        // ANonce must match what AP sent in msg 1 (replay protection).
        foreach (i; 0 .. wpa_nonce_len)
        {
            if (f.key_nonce[i] != anonce[i])
            {
                reset(WpaHandshakeReason.nonce_mismatch);
                return true;
            }
        }

        // AES-unwrap encrypted key_data with KEK. key_data_length must be
        // a multiple of 8 and at least 24 (one wrapped block).
        if (!f.encr_key_data || f.key_data.length < 24 || (f.key_data.length % 8) != 0)
        {
            reset(WpaHandshakeReason.malformed_key_data);
            return true;
        }

        ubyte[256] unwrapped_buf = void;
        if (f.key_data.length < 24 || f.key_data.length > unwrapped_buf.length + 8)
        {
            reset(WpaHandshakeReason.malformed_key_data);
            return true;
        }
        size_t unwrap_len = f.key_data.length - 8; // checked above
        ubyte[] unwrapped = unwrapped_buf[0 .. unwrap_len];
        if (!aes_unwrap(kek, f.key_data, unwrapped).succeeded)
        {
            reset(WpaHandshakeReason.gtk_unwrap_failed);
            return true;
        }

        // Parse KDEs from the unwrapped key_data: walk the IE list, look
        // for the GTK KDE (id 0xDD, OUI 00:0F:AC, KDE type 0x01).
        ubyte[wpa_gtk_max_len] gtk = void;
        size_t gtk_len;
        ubyte gtk_key_id;
        ubyte[6] gtk_rsc;
        gtk_rsc[] = f.key_rsc[0 .. 6];
        bool gtk_found = parse_gtk_kde(unwrapped, gtk[], gtk_len, gtk_key_id);
        if (!gtk_found)
        {
            reset(WpaHandshakeReason.gtk_missing);
            return true;
        }

        // Build msg 4/4.
        ushort key_info = key_info_type_pairwise | key_info_key_mic | key_info_secure | key_info_ver_hmac_sha1_aes;
        ubyte[wpa_nonce_len] zero_nonce = 0;
        ubyte[8] zero_rsc = 0;

        ubyte[eapol_key_fixed_len] out_buf = void;
        size_t out_len = encode_eapol_key(out_buf[],
            eapol_version_2004, key_desc_type_rsn,
            key_info, 0,
            last_replay, zero_nonce, zero_rsc,
            null);
        if (out_len == 0)
        {
            reset(WpaHandshakeReason.encode_failed);
            return true;
        }

        ubyte[eapol_key_mic_len] mic;
        compute_mic(kck, out_buf[0 .. out_len], mic);
        patch_mic(out_buf[0 .. out_len], mic);
        last_msg4[0 .. out_len] = out_buf[0 .. out_len];
        last_msg4_len = out_len;

        if (!hooks.send_eapol(out_buf[0 .. out_len]))
        {
            reset(WpaHandshakeReason.tx_failed);
            return true;
        }
        // Install PTK/GTK after queueing msg 4. The BL808 firmware decides
        // encryption policy on queued TX descriptors, so installing first can
        // make the final control-port EAPOL disappear behind the new PTK.
        if (!hooks.install_pairwise_key(tk))
        {
            reset(WpaHandshakeReason.pairwise_install_failed);
            return true;
        }
        if (!hooks.install_group_key(gtk_key_id, gtk[0 .. gtk_len], gtk_rsc[]))
        {
            reset(WpaHandshakeReason.group_install_failed);
            return true;
        }

        state = FourwayState.completed;
        if (hooks.handshake_complete)
            hooks.handshake_complete(true, 0);
        return true;
    }
}


const(char)[] wpa_handshake_reason_message(ushort reason) pure nothrow @nogc
{
    switch (cast(WpaHandshakeReason)reason)
    {
        case WpaHandshakeReason.none:                    return null;
        case WpaHandshakeReason.random_failed:           return "WPA handshake failed: random nonce generation failed";
        case WpaHandshakeReason.ptk_failed:              return "WPA handshake failed: PTK derivation failed";
        case WpaHandshakeReason.encode_failed:           return "WPA handshake failed: EAPOL frame encode failed";
        case WpaHandshakeReason.tx_failed:               return "WPA handshake failed: EAPOL transmit failed";
        case WpaHandshakeReason.mic_failed:              return "WPA handshake failed: key MIC verification failed";
        case WpaHandshakeReason.nonce_mismatch:          return "WPA handshake failed: AP nonce changed during handshake";
        case WpaHandshakeReason.malformed_key_data:      return "WPA handshake failed: malformed AP key data";
        case WpaHandshakeReason.gtk_unwrap_failed:       return "WPA handshake failed: GTK unwrap failed";
        case WpaHandshakeReason.gtk_missing:             return "WPA handshake failed: AP did not provide GTK";
        case WpaHandshakeReason.pairwise_install_failed: return "WPA handshake failed: pairwise key install failed";
        case WpaHandshakeReason.group_install_failed:    return "WPA handshake failed: group key install failed";
        case WpaHandshakeReason.pmf_required_unsupported:return "WPA PMF-required networks are not supported yet";
        default:                                        return "WPA handshake failed";
    }
}


private void compute_mic(const(ubyte)[] kck,
                         const(ubyte)[] frame,
                         ref ubyte[eapol_key_mic_len] out_mic)
{
    // HMAC-SHA1(KCK, frame_with_zero_mic). We feed the bytes around the MIC
    // field; the caller passes a frame already zero-filled at off_mic..+16.
    HMACContext!SHA1Context h;
    hmac_init(h, kck);
    hmac_update(h, frame);
    ubyte[SHA1Context.DigestLen] digest = hmac_finalise(h);
    out_mic[] = digest[0 .. eapol_key_mic_len];
}


private bool verify_mic(const(ubyte)[] kck,
                        const(ubyte)[] frame,
                        const(ubyte)[eapol_key_mic_len] expected_mic)
{
    if (frame.length < off_mic + eapol_key_mic_len)
        return false;

    // HMAC over frame with the MIC field zeroed. Copy frame into a scratch
    // buffer so we don't mutate the caller's slice.
    ubyte[wpa_max_eapol_len] scratch = void;
    if (frame.length > scratch.length)
        return false;
    scratch[0 .. frame.length] = frame[];
    scratch[off_mic .. off_mic + eapol_key_mic_len] = 0;

    ubyte[eapol_key_mic_len] computed;
    compute_mic(kck, scratch[0 .. frame.length], computed);

    // Constant-time compare to avoid leaking timing info on the MIC.
    ubyte diff = 0;
    foreach (i; 0 .. eapol_key_mic_len)
        diff |= computed[i] ^ expected_mic[i];
    return diff == 0;
}


// Compare two 8-byte replay counters (big-endian). Returns -1 / 0 / 1.
private int compare_replay(const(ubyte)[eapol_key_replay_len] a,
                           const(ubyte)[eapol_key_replay_len] b)
{
    foreach (i; 0 .. eapol_key_replay_len)
    {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    return 0;
}


// Walk a buffer of EAPOL key-data IEs looking for the GTK KDE
// (id=0xDD, OUI=00:0F:AC, kde_type=0x01). Returns true on success and
// fills out_gtk + out_len + out_key_id.
private bool parse_gtk_kde(const(ubyte)[] data,
                           ubyte[] out_gtk,
                           ref size_t out_len,
                           ref ubyte out_key_id)
{
    size_t off = 0;
    while (off + 2 <= data.length)
    {
        ubyte id  = data[off];
        ubyte len = data[off + 1];
        if (off + 2 + len > data.length)
            return false;

        if (id == 0xDD && len >= 6)
        {
            // Vendor-specific IE: OUI(3) + KDE type(1) + payload
            if (data[off + 2] == 0x00 && data[off + 3] == 0x0F && data[off + 4] == 0xAC
                && data[off + 5] == 0x01)
            {
                // GTK KDE payload: key_id/tx/reserved(1), reserved(1), GTK(N).
                size_t body_off = off + 6;
                size_t body_end = off + 2 + len;
                if (body_end - body_off < 2)
                    return false;
                out_key_id = data[body_off] & 0x03;
                size_t gtk_len = body_end - body_off - 2;
                if (gtk_len > out_gtk.length)
                    return false;
                out_gtk[0 .. gtk_len] = data[body_off + 2 .. body_end];
                out_len = gtk_len;
                return true;
            }
        }

        off += 2 + len;
        if (id == 0xDD)
            continue;
    }
    return false;
}
