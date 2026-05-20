module urt.crypto.pbkdf2;

import urt.digest.hmac : HMACContext, hmac_init, hmac_update, hmac_finalise;
import urt.digest.sha : SHA1Context;
import urt.result : Result, InternalResult;

nothrow @nogc:


// PBKDF2-HMAC-SHA1 as used by WPA/WPA2-PSK to derive the 32-byte PMK from
// passphrase + SSID. The interface is generic over output length so callers can
// also use the standard test vectors without heap allocation.
Result pbkdf2_hmac_sha1(const(ubyte)[] passphrase,
                        const(ubyte)[] salt,
                        uint iterations,
                        ubyte[] output)
{
    if (passphrase.length == 0 || salt.length == 0 || iterations == 0 || output.length == 0)
        return InternalResult.invalid_parameter;

    ubyte[SHA1Context.DigestLen] u = void;
    ubyte[SHA1Context.DigestLen] block = void;
    ubyte[4] counter_be = void;

    size_t pos;
    uint counter = 1;
    while (pos < output.length)
    {
        counter_be[0] = cast(ubyte)(counter >> 24);
        counter_be[1] = cast(ubyte)(counter >> 16);
        counter_be[2] = cast(ubyte)(counter >> 8);
        counter_be[3] = cast(ubyte)counter;

        HMACContext!SHA1Context h;
        hmac_init(h, passphrase);
        hmac_update(h, salt);
        hmac_update(h, counter_be[]);
        u = hmac_finalise(h);
        block[] = u[];

        foreach (_; 1 .. iterations)
        {
            hmac_init(h, passphrase);
            hmac_update(h, u[]);
            u = hmac_finalise(h);
            foreach (i; 0 .. block.length)
                block[i] ^= u[i];
        }

        size_t n = output.length - pos;
        if (n > block.length)
            n = block.length;
        output[pos .. pos + n] = block[0 .. n];
        pos += n;
        counter++;
    }

    return Result.success;
}

Result wpa2_psk_to_pmk(const(char)[] passphrase,
                       const(char)[] ssid,
                       ubyte[] pmk)
{
    if (passphrase.length < 8 || passphrase.length > 63 || ssid.length == 0 || ssid.length > 32 ||
        pmk.length != 32)
        return InternalResult.invalid_parameter;

    return pbkdf2_hmac_sha1(cast(const(ubyte)[])passphrase,
                            cast(const(ubyte)[])ssid,
                            4096,
                            pmk);
}


unittest
{
    ubyte[20] out1;
    assert(pbkdf2_hmac_sha1(cast(const(ubyte)[])"password",
                            cast(const(ubyte)[])"salt",
                            1,
                            out1[]));
    static immutable ubyte[20] expected1 = [
        0x0c, 0x60, 0xc8, 0x0f, 0x96, 0x1f, 0x0e, 0x71, 0xf3, 0xa9,
        0xb5, 0x24, 0xaf, 0x60, 0x12, 0x06, 0x2f, 0xe0, 0x37, 0xa6,
    ];
    assert(out1 == expected1);

    ubyte[20] out2;
    assert(pbkdf2_hmac_sha1(cast(const(ubyte)[])"password",
                            cast(const(ubyte)[])"salt",
                            2,
                            out2[]));
    static immutable ubyte[20] expected2 = [
        0xea, 0x6c, 0x01, 0x4d, 0xc7, 0x2d, 0x6f, 0x8c, 0xcd, 0x1e,
        0xd9, 0x2a, 0xce, 0x1d, 0x41, 0xf0, 0xd8, 0xde, 0x89, 0x57,
    ];
    assert(out2 == expected2);
}
