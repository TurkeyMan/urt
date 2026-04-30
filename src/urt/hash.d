module urt.hash;

version = SmallSize;
version = BranchIsFasterThanMod;

nothrow @nogc:


alias fnv1a = fnv1!(uint, true);
alias fnv1a64 = fnv1!(ulong, true);

template fnv1_initial(T)
{
    static if (is(T == ushort))
        enum T fnv1_initial = 0x811C;
    else static if (is(T == uint))
        enum T fnv1_initial = 0x811C9DC5;
    else static if (is(T == ulong))
        enum T fnv1_initial = 0xCBF29CE484222325;
}

T fnv1(T, bool alternate)(const ubyte[] s, T hash = fnv1_initial!T) pure
    if (is(T == ushort) || is(T == uint) || is(T == ulong))
{
    static if (is(T == ushort))
        enum T prime = 0x0101;
    else static if (is(T == uint))
        enum T prime = 0x01000193;
    else static if (is(T == ulong))
        enum T prime = 0x100000001B3;

    const ubyte* p = s.ptr;
    for (size_t i = 0; i < s.length; ++i)
    {
        static if (alternate)
        {
            hash ^= p[i];
            hash *= prime;
        }
        else
        {
            hash *= prime;
            hash ^= p[i];
        }
    }
    return hash;
}

unittest
{
    enum hash = fnv1a(cast(ubyte[])"hello world");
    static assert(hash == 0xD58B3FA7);

    enum h1 = fnv1a(cast(ubyte[])"hello ");
    enum h2 = fnv1a(cast(ubyte[])"world", h1);
    static assert(h2 == hash);
}


version (Espressif)
{
    private extern(C) uint mz_adler32(uint adler, const ubyte* ptr, size_t buf_len) pure nothrow @nogc;

    uint adler32(const void[] data, uint init = 1) pure
    {
        return mz_adler32(init, cast(const ubyte*)data.ptr, data.length);
    }
}
else
{
    uint adler32(const void[] data, uint init = 1) pure
    {
        enum A32_BASE = 65521;

        assert(data.length <= int.max, "Data length must be less than or equal to int.max");

        uint s1 = init & 0xFFFF;
        uint s2 = (init >> 16) & 0xFFFF;

        version (SmallSize)
        {
            foreach (ubyte b; cast(ubyte[])data)
            {
                version (BranchIsFasterThanMod)
                {
                    s1 += b;
                    s2 += s1;
                    if (s1 >= A32_BASE)
                        s1 -= A32_BASE;
                    if (s2 >= A32_BASE)
                        s2 -= A32_BASE;
                }
                else
                {
                    s1 = (s1 + b) % A32_BASE;
                    s2 = (s2 + s1) % A32_BASE;
                }
            }
        }
        else
        {
            enum A32_NMAX = 5552;

            const(ubyte)* buf = cast(const ubyte*)data.ptr;
            int length = cast(int)data.length;

            while (length > 0)
            {
                int k = length < A32_NMAX ? length : A32_NMAX;
                int i;

                for (i = k / 16; i; --i, buf += 16)
                {
                    s1 += buf[0];
                    s2 += s1;
                    s1 += buf[1];
                    s2 += s1;
                    s1 += buf[2];
                    s2 += s1;
                    s1 += buf[3];
                    s2 += s1;
                    s1 += buf[4];
                    s2 += s1;
                    s1 += buf[5];
                    s2 += s1;
                    s1 += buf[6];
                    s2 += s1;
                    s1 += buf[7];
                    s2 += s1;

                    s1 += buf[8];
                    s2 += s1;
                    s1 += buf[9];
                    s2 += s1;
                    s1 += buf[10];
                    s2 += s1;
                    s1 += buf[11];
                    s2 += s1;
                    s1 += buf[12];
                    s2 += s1;
                    s1 += buf[13];
                    s2 += s1;
                    s1 += buf[14];
                    s2 += s1;
                    s1 += buf[15];
                    s2 += s1;
                }

                for (i = k & 0xF; i; --i)
                {
                    s1 += *buf++;
                    s2 += s1;
                }

                s1 %= A32_BASE;
                s2 %= A32_BASE;

                length -= k;
            }
        }

        return (s2 << 16) | s1;
    }
}

unittest
{
    // empty data
    assert(adler32(null) == 1);

    // RFC 1950 test vectors
    assert(adler32("Wikipedia") == 0x11E6_0398);

    // single byte
    assert(adler32("a") == 0x0062_0062);

    // full string
    assert(adler32("Hello, World!") == 0x1F9E_046A);

    // progressive accumulation
    uint a1 = adler32("Hello, ");
    assert(a1 == 0x09EE_0241);
    assert(adler32("World!", a1) == 0x1F9E_046A);

    // all zeros
    ubyte[1024] zeros;
    assert(adler32(zeros[]) == 0x0400_0001);

    // known value: "123456789"
    assert(adler32("123456789") == 0x091E_01DE);
}


// NOTE: progressive accumulation via `initial` works only when prior chunks have even length!!!
// odd-length chunks misalign the 16-bit word pairing. fixing this requires carrying a pending byte between calls :/
// maybe there's some way to protect against misuse?
ushort internet_checksum(const void[] data, ushort initial = 0xFFFF) pure
{
    auto bytes = cast(const(const ubyte)[])data;

    uint sum = initial ^ 0xFFFF;
    while (bytes.length > 1)
    {
        sum += (bytes.ptr[0] << 8) | bytes.ptr[1];
        bytes = bytes[2 .. $];
    }
    if (bytes.length > 0)
        sum += bytes.ptr[0] << 8;

    while (sum >> 16)
        sum = (sum & 0xFFFF) + (sum >> 16);

    return cast(ushort)~sum;
}

unittest
{
    // Empty input: checksum of nothing is 0xFFFF (~0).
    assert(internet_checksum(null) == 0xFFFF);

    // RFC 1071 §B vector.
    static immutable ubyte[8] rfc1071 = [0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7];
    assert(internet_checksum(rfc1071[]) == 0x220D);

    // Real IPv4 header (checksum field zeroed).
    static immutable ubyte[20] ip_hdr = [
        0x45, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00,
        0x40, 0x06, 0x00, 0x00,
        0xC0, 0xA8, 0x00, 0xC8, 0xC0, 0xA8, 0x03, 0x0C,
    ];
    ushort cs = internet_checksum(ip_hdr[]);
    assert(cs == 0xF5A7);

    // Patching the computed checksum back in must verify to zero.
    ubyte[20] verified = ip_hdr;
    verified[10] = cast(ubyte)(cs >> 8);
    verified[11] = cast(ubyte)cs;
    assert(internet_checksum(verified[]) == 0);

    // Progressive accumulation across even-length chunks must match all-at-once.
    ushort first = internet_checksum(ip_hdr[0 .. 10]);
    ushort whole = internet_checksum(ip_hdr[10 .. $], first);
    assert(whole == cs);

    // Odd-length input: trailing byte is treated as the high byte of a 16-bit word.
    static immutable ubyte[3] odd = [0xAA, 0xBB, 0xCC];
    assert(internet_checksum(odd[]) == 0x8943);

    // Chained checksum across two buffers must equal the concatenated buffer's
    // checksum, when the prior result is passed directly as `initial`. (This
    // is the pseudo-header + segment pattern used by TCP/UDP.)
    static immutable ubyte[6] part_a = [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC];
    static immutable ubyte[6] part_b = [0xDE, 0xF0, 0x11, 0x22, 0x33, 0x44];
    ubyte[12] joined;
    joined[0 .. 6] = part_a;
    joined[6 .. 12] = part_b;
    ushort partial = internet_checksum(part_a[]);
    ushort chained = internet_checksum(part_b[], partial);
    assert(chained == internet_checksum(joined[]));
}
