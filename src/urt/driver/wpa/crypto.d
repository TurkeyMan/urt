module urt.driver.wpa.crypto;

import urt.digest.hmac : HMACContext, hmac_init, hmac_update, hmac_finalise;
import urt.digest.sha : SHA1Context;
import urt.result : Result, InternalResult;

nothrow @nogc:


enum size_t wpa_pmk_len = 32;
enum size_t wpa_nonce_len = 32;
enum size_t wpa_ptk_len_ccmp = 48;

// IEEE 802.11i SHA1 PRF. The label is NUL-terminated in the MAC input, matching
// wpa_supplicant's sha1_prf() and the "Pairwise key expansion" PTK derivation.
Result sha1_prf(const(ubyte)[] key, const(char)[] label, const(ubyte)[] data, ubyte[] output)
{
    if (key.length == 0 || label.length == 0 || output.length == 0)
        return InternalResult.invalid_parameter;

    ubyte[SHA1Context.DigestLen] digest = void;
    ubyte zero = 0;
    ubyte counter = 0;
    size_t pos;

    while (pos < output.length)
    {
        HMACContext!SHA1Context h;
        hmac_init(h, key);
        hmac_update(h, cast(const(ubyte)[])label);
        hmac_update(h, (&zero)[0 .. 1]);
        hmac_update(h, data);
        hmac_update(h, (&counter)[0 .. 1]);
        digest = hmac_finalise(h);

        size_t n = output.length - pos;
        if (n > digest.length)
            n = digest.length;
        output[pos .. pos + n] = digest[0 .. n];
        pos += n;
        counter++;
    }

    return Result.success;
}

// Build B = min(AP, STA MAC) || max(AP, STA MAC) || min(ANonce, SNonce) ||
// max(ANonce, SNonce), then PRF(PMK, "Pairwise key expansion", B).
Result wpa2_pmk_to_ptk(const(ubyte)[wpa_pmk_len] pmk,
                       const(ubyte)[6] ap_mac,
                       const(ubyte)[6] sta_mac,
                       const(ubyte)[wpa_nonce_len] anonce,
                       const(ubyte)[wpa_nonce_len] snonce,
                       ubyte[] ptk)
{
    if (ptk.length == 0)
        return InternalResult.invalid_parameter;

    ubyte[6 + 6 + wpa_nonce_len + wpa_nonce_len] seed = void;
    size_t pos;

    if (lex_less(ap_mac[], sta_mac[]))
    {
        seed[pos .. pos + 6] = ap_mac[];
        pos += 6;
        seed[pos .. pos + 6] = sta_mac[];
        pos += 6;
    }
    else
    {
        seed[pos .. pos + 6] = sta_mac[];
        pos += 6;
        seed[pos .. pos + 6] = ap_mac[];
        pos += 6;
    }

    if (lex_less(anonce[], snonce[]))
    {
        seed[pos .. pos + wpa_nonce_len] = anonce[];
        pos += wpa_nonce_len;
        seed[pos .. pos + wpa_nonce_len] = snonce[];
    }
    else
    {
        seed[pos .. pos + wpa_nonce_len] = snonce[];
        pos += wpa_nonce_len;
        seed[pos .. pos + wpa_nonce_len] = anonce[];
    }

    return sha1_prf(pmk[], "Pairwise key expansion", seed[], ptk);
}

private bool lex_less(const(ubyte)[] a, const(ubyte)[] b)
{
    foreach (i; 0 .. a.length)
    {
        if (a[i] < b[i])
            return true;
        if (a[i] > b[i])
            return false;
    }
    return false;
}
