module urt.encoding;

nothrow @nogc:


enum Base64Decode(string str) = () { ubyte[base64_decode_length(str.length)] r; size_t len = base64_decode(str, r[]); assert(len == r.sizeof, "Not a base64 string: " ~ str);      return r; }();
enum HexDecode(string str) =    () { ubyte[hex_decode_length(str.length)] r;    size_t len = hex_decode(str, r[]);    assert(len == r.sizeof, "Not a hex string: " ~ str);         return r; }();
enum URLDecode(string str) =    () {  char[url_decode_length(str)] r;           size_t len = url_decode(str, r[]);    assert(len == r.sizeof, "Not a URL encoded string: " ~ str); return r; }();


size_t base64_encode_length(bool url = false)(size_t source_length) pure
{
    static if (url)
        return (source_length * 4 + 2) / 3; // no padding
    else
        return (source_length + 2) / 3 * 4;
}

size_t base64_encode_length(bool url = false)(const void[] data) pure
    => base64_encode_length!url(data.length);

ptrdiff_t base64_encode(bool url = false)(const void[] data, char[] result) pure
{
    immutable(char)* table = url ? &base64url[0] : &base64[0];
    auto src = cast(const(ubyte)[])data;
    size_t len = data.length;
    size_t out_len = base64_encode_length!url(len);

    if (result.length < out_len)
        return -1;

    size_t i = 0;
    size_t j = 0;
    while (i + 3 <= len)
    {
        ubyte b0 = src[i++];
        ubyte b1 = src[i++];
        ubyte b2 = src[i++];

        result[j++] = table[b0 >> 2];
        result[j++] = table[((b0 & 0x03) << 4) | (b1 >> 4)];
        result[j++] = table[((b1 & 0x0F) << 2) | (b2 >> 6)];
        result[j++] = table[b2 & 0x3F];
    }

    if (i < len)
    {
        ubyte b0 = src[i++];
        result[j++] = table[b0 >> 2];
        if (i < len)
        {
            ubyte b1 = src[i];
            result[j++] = table[((b0 & 0x03) << 4) | (b1 >> 4)];
            result[j++] = table[((b1 & 0x0F) << 2)];
        }
        else
        {
            result[j++] = table[((b0 & 0x03) << 4)];
            static if (!url)
                result[j++] = '=';
        }
        static if (!url)
            result[j] = '=';
    }

    return out_len;
}

size_t base64_decode_length(bool url = false)(size_t source_length) pure
{
    static if (url)
    {
        size_t remainder = source_length % 4;
        return source_length / 4 * 3 + (remainder > 0 ? remainder - 1 : 0);
    }
    else
        return source_length / 4 * 3;
}

size_t base64_decode_length(bool url = false)(const char[] data) pure
    => base64_decode_length!url(data.length);

ptrdiff_t base64_decode(bool url = false)(const char[] data, void[] result) pure
{
    static if (url)
    {
        enum uint offset = 45;
        enum uint map_size = 78;
        alias map = base64url_map;
    }
    else
    {
        enum uint offset = 43;
        enum uint map_size = 80;
        alias map = base64_map;
    }

    size_t len = data.length;
    auto dest = cast(ubyte[])result;
    size_t out_len;

    static if (url)
    {
        size_t remainder = len % 4;
        if (remainder == 1)
            return -1;
        out_len = len / 4 * 3 + (remainder > 0 ? remainder - 1 : 0);
    }
    else
    {
        out_len = len / 4 * 3;
        if (len >= 1 && data[len - 1] == '=')
            --out_len;
        if (len >= 2 && data[len - 2] == '=')
            --out_len;
    }

    if (result.length < out_len)
        return -1;

    static if (url)
        size_t full_len = len / 4 * 4;
    else
        size_t full_len = len;

    size_t i = 0;
    size_t j = 0;
    while (i < full_len)
    {
        if (i > full_len - 4)
            return -1;

        // TODO: this could be faster by using more memory, store a full 256-byte table and no comparisons...
        uint b0 = data[i++] - offset;
        uint b1 = data[i++] - offset;
        uint b2 = data[i++] - offset;
        uint b3 = data[i++] - offset;
        if (b0 >= map_size || b1 >= map_size || b2 >= map_size || b3 >= map_size)
            return -1;

        b0 = map[b0];
        b1 = map[b1];
        b2 = map[b2];
        b3 = map[b3];

        dest[j++] = cast(ubyte)((b0 << 2) | (b1 >> 4));
        if (b2 != 64)
            dest[j++] = cast(ubyte)((b1 << 4) | (b2 >> 2));
        if (b3 != 64)
            dest[j++] = cast(ubyte)((b2 << 6) | b3);
    }

    static if (url)
    {
        if (i < len)
        {
            uint b0 = data[i++] - offset;
            uint b1 = data[i++] - offset;
            if (b0 >= map_size || b1 >= map_size)
                return -1;
            b0 = map[b0];
            b1 = map[b1];
            dest[j++] = cast(ubyte)((b0 << 2) | (b1 >> 4));

            if (i < len)
            {
                uint b2 = data[i] - offset;
                if (b2 >= map_size)
                    return -1;
                b2 = map[b2];
                dest[j++] = cast(ubyte)((b1 << 4) | (b2 >> 2));
            }
        }
    }

    return out_len;
}

size_t base64url_encode_length(size_t source_length) pure
=> base64_encode_length!true(source_length);

size_t base64url_encode_length(const void[] data) pure
=> base64_encode_length!true(data);

alias base64url_encode = base64_encode!true;

size_t base64url_decode_length(size_t source_length) pure
    => base64_decode_length!true(source_length);

size_t base64url_decode_length(const char[] data) pure
    => base64_decode_length!true(data);

alias base64url_decode = base64_decode!true;

unittest
{
    immutable ubyte[12] data = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C];
    char[16] encoded = void;
    ubyte[12] decoded = void;

    static assert(Base64Decode!"AQIDBAUGBwgJCgsM" == data[]);

    size_t len = base64_encode(data, encoded);
    assert(len == 16);
    assert(encoded == "AQIDBAUGBwgJCgsM");
    len = base64_decode(encoded, decoded);
    assert(len == 12);
    assert(data == decoded);

    len = base64_encode(data[0..11], encoded);
    assert(len == 16);
    assert(encoded == "AQIDBAUGBwgJCgs=");
    len = base64_decode(encoded, decoded);
    assert(len == 11);
    assert(data[0..11] == decoded[0..11]);

    len = base64_encode(data[0..10], encoded);
    assert(len == 16);
    assert(encoded == "AQIDBAUGBwgJCg==");
    len = base64_decode(encoded, decoded);
    assert(len == 10);
    assert(data[0..10] == decoded[0..10]);

    // base64url: different alphabet (+/ → -_) and no padding
    // [0..3] all-62, [3..6] all-63, [6..9] mixed 62/63
    immutable ubyte[9] urldata = [0xFB, 0xEF, 0xBE, 0xFF, 0xFF, 0xFF, 0xFB, 0xFF, 0xBF];

    len = base64_encode(urldata[0..3], encoded[0..4]);
    assert(len == 4);
    assert(encoded[0..4] == "++++");
    len = base64url_encode(urldata[0..3], encoded[0..4]);
    assert(len == 4);
    assert(encoded[0..4] == "----");

    len = base64_encode(urldata[3..6], encoded[0..4]);
    assert(len == 4);
    assert(encoded[0..4] == "////");
    len = base64url_encode(urldata[3..6], encoded[0..4]);
    assert(len == 4);
    assert(encoded[0..4] == "____");

    len = base64_encode(urldata[6..9], encoded[0..4]);
    assert(len == 4);
    assert(encoded[0..4] == "+/+/");
    len = base64url_encode(urldata[6..9], encoded[0..4]);
    assert(len == 4);
    assert(encoded[0..4] == "-_-_");

    // decode roundtrips
    len = base64_decode("++++", decoded[0..3]);
    assert(len == 3);
    assert(decoded[0..3] == urldata[0..3]);
    len = base64url_decode("----", decoded[0..3]);
    assert(len == 3);
    assert(decoded[0..3] == urldata[0..3]);
    len = base64_decode("+/+/", decoded[0..3]);
    assert(len == 3);
    assert(decoded[0..3] == urldata[6..9]);
    len = base64url_decode("-_-_", decoded[0..3]);
    assert(len == 3);
    assert(decoded[0..3] == urldata[6..9]);

    // padding vs no-padding: 1 byte → /w== vs _w
    len = base64_encode(urldata[3..4], encoded[0..4]);
    assert(len == 4);
    assert(encoded[0..4] == "/w==");
    len = base64_decode(encoded[0..4], decoded[0..1]);
    assert(len == 1);
    assert(decoded[0] == 0xFF);

    len = base64url_encode(urldata[3..4], encoded[0..2]);
    assert(len == 2);
    assert(encoded[0..2] == "_w");
    len = base64url_decode(encoded[0..2], decoded[0..1]);
    assert(len == 1);
    assert(decoded[0] == 0xFF);

    // padding vs no-padding: 2 bytes → ++8= vs --8
    len = base64_encode(urldata[0..2], encoded[0..4]);
    assert(len == 4);
    assert(encoded[0..4] == "++8=");
    len = base64_decode(encoded[0..4], decoded[0..2]);
    assert(len == 2);
    assert(decoded[0..2] == urldata[0..2]);

    len = base64url_encode(urldata[0..2], encoded[0..3]);
    assert(len == 3);
    assert(encoded[0..3] == "--8");
    len = base64url_decode(encoded[0..3], decoded[0..2]);
    assert(len == 2);
    assert(decoded[0..2] == urldata[0..2]);
}

size_t hex_encode_length(size_t sourceLength) pure
    => sourceLength * 2;

size_t hex_encode_length(const void[] data) pure
    => data.length * 2;

ptrdiff_t hex_encode(const void[] data, char[] result) pure
{
    import urt.string : toHexString;

    // reuse this since we already have it...
    return toHexString(data, result).length;
}

size_t hex_decode_length(size_t sourceLength) pure
    => sourceLength / 2;

size_t hex_decode_length(const char[] data) pure
    => data.length / 2;

ptrdiff_t hex_decode(const char[] data, void[] result) pure
{
    import urt.string.ascii : is_hex;

    if (data.length & 1)
        return -1;
    if (result.length < data.length / 2)
        return -1;

    auto dest = cast(ubyte[])result;

    for (size_t i = 0, j = 0; i < data.length; i += 2, ++j)
    {
        ubyte c0 = data[i];
        ubyte c1 = data[i + 1];
        if (!c0.is_hex || !c1.is_hex)
            return -1;

        if ((c0 | 0x20) >= 'a')
            c0 = cast(ubyte)((c0 | 0x20) - 'a' + 10);
        else
            c0 -= '0';
        if ((c1 | 0x20) >= 'a')
            c1 = cast(ubyte)((c1 | 0x20) - 'a' + 10);
        else
            c1 -= '0';
        dest[j] = cast(ubyte)(c0 << 4 | c1);
    }

    return data.length / 2;
}

unittest
{
    immutable ubyte[12] data = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C];
    char[24] encoded = void;
    ubyte[12] decoded = void;

    static assert(HexDecode!"0102030405060708090A0B0C" == data);

    size_t len = hex_encode(data, encoded);
    assert(len == 24);
    assert(encoded == "0102030405060708090A0B0C");
    len = hex_decode(encoded, decoded);
    assert(len == 12);
    assert(data == decoded);
}


size_t url_encode_length(const char[] data) pure
{
    import urt.string.ascii : is_url;

    size_t len = 0;
    foreach (c; data)
    {
        if (c.is_url || c == ' ')
            ++len;
        else
            len += 3;
    }
    return len;
}

ptrdiff_t url_encode(const char[] data, char[] result) pure
{
    import urt.string.ascii : is_url, hex_digits;

    size_t j = 0;

    for (size_t i = 0; i < data.length; ++i)
    {
        char c = data[i];
        if (c.is_url || c == ' ')
        {
            if (j == result.length)
                return -1;
            result[j++] = c == ' ' ? '+' : c;
        }
        else
        {
            if (j + 2 == result.length)
                return -1;
            result[j++] = '%';
            result[j++] = hex_digits[c >> 4];
            result[j++] = hex_digits[c & 0xF];
        }
    }

    return j;
}

size_t url_decode_length(const char[] data) pure
{
    size_t len = 0;
    for (size_t i = 0; i < data.length;)
    {
        if (data.ptr[i] == '%')
            i += 3;
        else
            ++i;
        ++len;
    }
    return len;
}

ptrdiff_t url_decode(const char[] data, char[] result) pure
{
    import urt.string.ascii : is_hex;

    size_t j = 0;
    for (size_t i = 0; i < data.length; ++i)
    {
        if (result.length == j)
            return -1;

        char c = data[i];
        if (c == '+')
            c = ' ';
        else if (c == '%')
        {
            if (i + 2 >= data.length)
                return -1;

            ubyte c0 = data[i + 1];
            ubyte c1 = data[i + 2];
            if (!c0.is_hex || !c1.is_hex)
                return -1;
            i += 2;

            if ((c0 | 0x20) >= 'a')
                c0 = cast(ubyte)((c0 | 0x20) - 'a' + 10);
            else
                c0 -= '0';
            if ((c1 | 0x20) >= 'a')
                c1 = cast(ubyte)((c1 | 0x20) - 'a' + 10);
            else
                c1 -= '0';
            c = cast(char)(c0 << 4 | c1);
        }
        result[j++] = c;
    }

    return j;
}

unittest
{
    static assert(URLDecode!"Hello%2C+World%21" == "Hello, World!");

    char[13] data = "Hello, World!";
    char[17] encoded = void;
    char[13] decoded = void;

    assert(url_encode_length(data) == 17);
    size_t len = url_encode(data, encoded);
    assert(len == 17);
    assert(encoded == "Hello%2C+World%21");
    assert(url_decode_length(encoded) == 13);
    len = url_decode(encoded, decoded);
    assert(len == 13);
    assert(data == decoded);
}


private:

__gshared immutable char[64] base64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
__gshared immutable ubyte[80] base64_map = [    62,  0,  0,  0, 63,
    52, 53, 54, 55, 56, 57, 58, 59, 60, 61,  0,  0,  0, 64,  0,  0,
     0,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14,
    15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,  0,  0,  0,  0,  0,
     0, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
    41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51
];

__gshared immutable char[64] base64url = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
__gshared immutable ubyte[78] base64url_map = [         62,  0,  0,
    52, 53, 54, 55, 56, 57, 58, 59, 60, 61,  0,  0,  0,  0,  0,  0,
     0,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14,
    15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,  0,  0,  0,  0, 63,
     0, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
    41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51
];
