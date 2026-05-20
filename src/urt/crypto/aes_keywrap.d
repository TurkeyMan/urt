// RFC 3394 AES Key Wrap (NIST AES-WRAP). Used by the WPA2 4-way handshake to
// protect the GTK in EAPOL-Key msg 3/4: the AP wraps the GTK with the KEK
// (bytes 16..31 of the PTK) and we unwrap it on receipt.
//
// The algorithm operates on 64-bit blocks. The wrapped output is 8 bytes
// longer than the plaintext (one extra block holds the integrity check
// value, default A6A6A6A6A6A6A6A6).
module urt.crypto.aes_keywrap;

import urt.result : Result, InternalResult;

nothrow @nogc:


private enum ubyte[8] DEFAULT_IV = [0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6];


// RFC 3394 AES Key Wrap. On success, writes (plain.length + 8) bytes of
// wrapped key data to `cipher`.
Result aes_wrap(const(ubyte)[] kek,
                const(ubyte)[] plain,
                ubyte[] cipher)
{
    version (MbedTLS)
    {
        import urt.internal.mbedtls : urt_aes_ecb_encrypt;

        if (kek.length != 16 && kek.length != 24 && kek.length != 32)
            return InternalResult.invalid_parameter;
        if (plain.length < 16 || plain.length % 8 != 0)
            return InternalResult.invalid_parameter;
        if (cipher.length != plain.length + 8)
            return InternalResult.invalid_parameter;

        size_t n = plain.length / 8;
        ubyte[8] a = DEFAULT_IV;
        cipher[8 .. $] = plain[];

        ubyte[16] block = void;
        for (size_t j = 0; j < 6; ++j)
        {
            for (size_t i = 1; i <= n; ++i)
            {
                block[0 .. 8] = a[];
                block[8 .. 16] = cipher[i * 8 .. (i + 1) * 8];

                ubyte[16] enc = void;
                if (urt_aes_ecb_encrypt(kek.ptr, kek.length, block.ptr, enc.ptr) != 0)
                    return InternalResult.failed;

                a[] = enc[0 .. 8];
                size_t t = n * j + i;
                a[7] ^= cast(ubyte)(t);
                a[6] ^= cast(ubyte)(t >> 8);
                a[5] ^= cast(ubyte)(t >> 16);
                a[4] ^= cast(ubyte)(t >> 24);
                cipher[i * 8 .. (i + 1) * 8] = enc[8 .. 16];
            }
        }

        cipher[0 .. 8] = a[];
        return Result.success;
    }
    else
        return InternalResult.unsupported;
}

Result aes_unwrap(const(ubyte)[] kek,
                  const(ubyte)[] cipher,
                  ubyte[] plain)
{
    version (MbedTLS)
    {
        import urt.internal.mbedtls : urt_aes_ecb_decrypt;

        if (kek.length != 16 && kek.length != 24 && kek.length != 32)
            return InternalResult.invalid_parameter;
        if (cipher.length < 24 || cipher.length % 8 != 0)
            return InternalResult.invalid_parameter;
        if (plain.length + 8 != cipher.length)
            return InternalResult.invalid_parameter;

        size_t n = cipher.length / 8 - 1;  // number of 64-bit plaintext blocks

        ubyte[8] a = void;
        a[] = cipher[0 .. 8];
        plain[] = cipher[8 .. $];

        ubyte[16] block = void;
        for (int j = 5; j >= 0; --j)
        {
            for (size_t i = n; i >= 1; --i)
            {
                // A = MSB(64, AES-1(K, (A ^ t) | R[i]))  where t = n*j + i
                size_t t = n * cast(size_t)j + i;
                // XOR t (big-endian, lowest 4 bytes are sufficient for our sizes)
                a[7] ^= cast(ubyte)(t);
                a[6] ^= cast(ubyte)(t >> 8);
                a[5] ^= cast(ubyte)(t >> 16);
                a[4] ^= cast(ubyte)(t >> 24);

                block[0 .. 8] = a[];
                block[8 .. 16] = plain[(i - 1) * 8 .. i * 8];

                ubyte[16] dec = void;
                if (urt_aes_ecb_decrypt(kek.ptr, kek.length, block.ptr, dec.ptr) != 0)
                    return InternalResult.failed;

                a[] = dec[0 .. 8];
                plain[(i - 1) * 8 .. i * 8] = dec[8 .. 16];
            }
        }

        // A must equal the IV for an authentic unwrap. Mismatch means the
        // wrong KEK or a tampered ciphertext -- caller must discard plain.
        foreach (i; 0 .. 8)
        {
            if (a[i] != DEFAULT_IV[i])
                return InternalResult.data_error;
        }

        return Result.success;
    }
    else
        return InternalResult.unsupported;
}


unittest
{
    // RFC 3394 4.1: Wrap 128 bits of Key Data with a 128-bit KEK.
    import urt.encoding : HexDecode;

    static immutable ubyte[16] kek = HexDecode!"000102030405060708090A0B0C0D0E0F";
    static immutable ubyte[16] plain = HexDecode!"00112233445566778899AABBCCDDEEFF";
    static immutable ubyte[24] cipher = HexDecode!"1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5";

    ubyte[16] out_;
    auto r = aes_unwrap(kek[], cipher[], out_[]);
    assert(r.succeeded);
    assert(out_ == plain);
}
