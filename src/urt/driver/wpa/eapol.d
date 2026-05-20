// WPA/WPA2 EAPOL-Key frame codec.
//
// Wire format (802.1X EAPOL + IEEE 802.11i Key Descriptor v2):
//   4-byte IEEE 802.1X header:
//     ver (1), type (1), body_length (2 BE)
//     [type 3 = EAPOL-Key; ver 1 = 2001, ver 2 = 2004 (used today)]
//   95-byte fixed key-descriptor body:
//     descriptor_type (1)            -- 2 = RSN (WPA2)
//     key_info (2 BE)                -- version | flags | key index
//     key_length (2 BE)              -- 16 for CCMP pairwise; 0 for group msg
//     replay_counter (8 BE)          -- echo back AP's value
//     key_nonce (32)                 -- ANonce on msg 1, SNonce on msg 2
//     key_iv (16)                    -- zero in v2 (AES-CMAC/HMAC-SHA1)
//     key_rsc (8)                    -- group key seq, BE
//     key_id (8, reserved)           -- zero
//     key_mic (16)                   -- HMAC-SHA1(KCK, frame_with_zero_mic)
//     key_data_length (2 BE)
//   N-byte key_data:
//     msg 2: STA's RSN IE
//     msg 3: GTK KDE + group RSC + IGTK KDE if PMF, AES-key-wrapped with KEK
module urt.driver.wpa.eapol;

public import urt.driver.dot1x.eapol;

nothrow @nogc:


private ushort be_u16(const(ubyte)* p) pure
{
    return cast(ushort)((cast(ushort)p[0] << 8) | p[1]);
}


enum ubyte key_desc_type_rc4_hmac_md5 = 1; // WPA (no longer issued)
enum ubyte key_desc_type_rsn          = 2; // WPA2 / RSN

// key_info bitfield (host order):
enum ushort key_info_ver_hmac_md5_rc4   = 0x0001;
enum ushort key_info_ver_hmac_sha1_aes  = 0x0002;
enum ushort key_info_ver_aes_cmac       = 0x0003;
enum ushort key_info_ver_mask           = 0x0007;
enum ushort key_info_type_pairwise      = 0x0008;
enum ushort key_info_keyidx_shift       = 4;
enum ushort key_info_keyidx_mask        = 0x0030;
enum ushort key_info_install            = 0x0040;
enum ushort key_info_key_ack            = 0x0080;
enum ushort key_info_key_mic            = 0x0100;
enum ushort key_info_secure             = 0x0200;
enum ushort key_info_error              = 0x0400;
enum ushort key_info_request            = 0x0800;
enum ushort key_info_encr_key_data      = 0x1000;
enum ushort key_info_smk_message        = 0x2000;

enum size_t key_desc_fixed_len     = 95;  // descriptor body without key_data
enum size_t eapol_key_fixed_len    = eapol_hdr_len + key_desc_fixed_len; // 99
enum size_t eapol_key_nonce_len    = 32;
enum size_t eapol_key_mic_len      = 16;
enum size_t eapol_key_replay_len   = 8;
enum size_t eapol_key_rsc_len      = 8;
enum size_t eapol_key_iv_len       = 16;

// Offsets within an EAPOL-Key frame, measured from the start of the 802.1X
// header (so the byte that holds the version is at offset 0).
enum size_t off_version       = 0;
enum size_t off_type          = 1;
enum size_t off_body_len      = 2;  // BE u16
enum size_t off_desc_type     = 4;
enum size_t off_key_info      = 5;  // BE u16
enum size_t off_key_length    = 7;  // BE u16
enum size_t off_replay        = 9;
enum size_t off_nonce         = 17;
enum size_t off_iv            = 49;
enum size_t off_rsc           = 65;
enum size_t off_key_id        = 73;
enum size_t off_mic           = 81;
enum size_t off_key_data_len  = 97;  // BE u16
enum size_t off_key_data      = 99;


struct EapolKeyFrame
{
    ubyte version_;
    ubyte type;
    ushort body_length;     // bytes after the 4-byte 802.1X header
    ubyte descriptor_type;
    ushort key_info;
    ushort key_length;
    ubyte[eapol_key_replay_len] replay_counter;
    ubyte[eapol_key_nonce_len] key_nonce;
    ubyte[eapol_key_iv_len] key_iv;
    ubyte[eapol_key_rsc_len] key_rsc;
    ubyte[8] key_id;
    ubyte[eapol_key_mic_len] key_mic;
    ushort key_data_length;
    const(ubyte)[] key_data;    // borrowed slice into the source frame

nothrow @nogc:
    @property ushort version_bits() const => cast(ushort)(key_info & key_info_ver_mask);
    @property bool   pairwise()      const => (key_info & key_info_type_pairwise) != 0;
    @property ubyte  key_index()     const => cast(ubyte)((key_info & key_info_keyidx_mask) >> key_info_keyidx_shift);
    @property bool   install()       const => (key_info & key_info_install) != 0;
    @property bool   key_ack()       const => (key_info & key_info_key_ack) != 0;
    @property bool   key_mic_set()   const => (key_info & key_info_key_mic) != 0;
    @property bool   secure()        const => (key_info & key_info_secure) != 0;
    @property bool   error()         const => (key_info & key_info_error) != 0;
    @property bool   request()       const => (key_info & key_info_request) != 0;
    @property bool   encr_key_data() const => (key_info & key_info_encr_key_data) != 0;
}


// Parse an EAPOL-Key frame from the wire. `frame` is the full 802.1X payload
// (starting at the version byte; the ethernet header has already been
// consumed by the driver). Returns false on malformed input.
bool decode_eapol_key(const(ubyte)[] frame, ref EapolKeyFrame out_)
{
    if (frame.length < eapol_key_fixed_len)
        return false;

    if (frame[off_type] != eapol_type_key)
        return false;

    ushort body_len = be_u16(frame.ptr +off_body_len);
    // body_len counts the bytes after the 802.1X header (descriptor + data).
    if (cast(size_t)body_len + eapol_hdr_len > frame.length)
        return false;

    out_.version_        = frame[off_version];
    out_.type            = frame[off_type];
    out_.body_length     = body_len;
    out_.descriptor_type = frame[off_desc_type];
    out_.key_info        = be_u16(frame.ptr +off_key_info);
    out_.key_length      = be_u16(frame.ptr +off_key_length);
    out_.replay_counter[] = frame[off_replay .. off_replay + eapol_key_replay_len];
    out_.key_nonce[]      = frame[off_nonce  .. off_nonce  + eapol_key_nonce_len];
    out_.key_iv[]         = frame[off_iv     .. off_iv     + eapol_key_iv_len];
    out_.key_rsc[]        = frame[off_rsc    .. off_rsc    + eapol_key_rsc_len];
    out_.key_id[]         = frame[off_key_id .. off_key_id + 8];
    out_.key_mic[]        = frame[off_mic    .. off_mic    + eapol_key_mic_len];

    ushort kd_len = be_u16(frame.ptr +off_key_data_len);
    out_.key_data_length = kd_len;
    if (off_key_data + cast(size_t)kd_len > frame.length)
        return false;
    out_.key_data = frame[off_key_data .. off_key_data + kd_len];

    return true;
}


// Build an EAPOL-Key frame into `dst`. Returns the number of bytes written,
// or 0 if the buffer is too small. MIC field is zero-filled; the caller is
// expected to compute the MIC over the written buffer and patch it in via
// the patch_mic() helper.
size_t encode_eapol_key(ubyte[] dst,
                        ubyte eapol_version,
                        ubyte descriptor_type,
                        ushort key_info,
                        ushort key_length,
                        const(ubyte)[eapol_key_replay_len] replay,
                        const(ubyte)[eapol_key_nonce_len] nonce,
                        const(ubyte)[eapol_key_rsc_len] rsc,
                        const(ubyte)[] key_data)
{
    size_t total = eapol_key_fixed_len + key_data.length;
    if (dst.length < total)
        return 0;

    dst[off_version] = eapol_version;
    dst[off_type]    = eapol_type_key;

    // body_length excludes the 4-byte 802.1X header.
    ushort body_len = cast(ushort)(key_desc_fixed_len + key_data.length);
    dst[off_body_len]     = cast(ubyte)(body_len >> 8);
    dst[off_body_len + 1] = cast(ubyte)(body_len & 0xff);

    dst[off_desc_type] = descriptor_type;
    dst[off_key_info]     = cast(ubyte)(key_info >> 8);
    dst[off_key_info + 1] = cast(ubyte)(key_info & 0xff);
    dst[off_key_length]     = cast(ubyte)(key_length >> 8);
    dst[off_key_length + 1] = cast(ubyte)(key_length & 0xff);

    dst[off_replay .. off_replay + eapol_key_replay_len] = replay[];
    dst[off_nonce  .. off_nonce  + eapol_key_nonce_len]  = nonce[];
    dst[off_iv     .. off_iv     + eapol_key_iv_len]     = 0;
    dst[off_rsc    .. off_rsc    + eapol_key_rsc_len]    = rsc[];
    dst[off_key_id .. off_key_id + 8] = 0;
    dst[off_mic    .. off_mic    + eapol_key_mic_len]    = 0;

    dst[off_key_data_len]     = cast(ubyte)(key_data.length >> 8);
    dst[off_key_data_len + 1] = cast(ubyte)(key_data.length & 0xff);

    if (key_data.length > 0)
        dst[off_key_data .. off_key_data + key_data.length] = key_data[];

    return total;
}


// Patch the MIC field into an already-encoded EAPOL-Key frame.
void patch_mic(ubyte[] frame, const(ubyte)[eapol_key_mic_len] mic)
{
    if (frame.length < off_mic + eapol_key_mic_len)
        return;
    frame[off_mic .. off_mic + eapol_key_mic_len] = mic[];
}
