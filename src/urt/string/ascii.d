module urt.string.ascii;



char[] to_lower(const(char)[] str) pure nothrow
{
    return to_lower(str, new char[str.length]);
}

char[] to_upper(const(char)[] str) pure nothrow
{
    return to_upper(str, new char[str.length]);
}


nothrow @nogc:

// some character category flags...
// 1 = alpha, 2 = numeric, 4 = white, 8 = newline, 10 = control, 20 = ???, 40 = url, 80 = hex
private __gshared immutable ubyte[128] char_details = [
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x14, 0x18, 0x10, 0x10, 0x18, 0x10, 0x10,
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x40, 0x00,
    0xC2, 0xC2, 0xC2, 0xC2, 0xC2, 0xC2, 0xC2, 0xC2, 0xC2, 0xC2, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0xC1, 0xC1, 0xC1, 0xC1, 0xC1, 0xC1, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
    0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x00, 0x00, 0x00, 0x00, 0x40,
    0x00, 0xC1, 0xC1, 0xC1, 0xC1, 0xC1, 0xC1, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
    0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x00, 0x00, 0x00, 0x40, 0x10
];

__gshared immutable char[16] hex_digits = "0123456789ABCDEF";


bool is_space(char c) pure          => c < 128 && (char_details[c] & 4);
bool is_newline(char c) pure        => c < 128 && (char_details[c] & 8);
bool is_whitespace(char c) pure     => c < 128 && (char_details[c] & 0xC);
bool is_alpha(char c) pure          => c < 128 && (char_details[c] & 1);
bool is_numeric(char c) pure        => cast(uint)(c - '0') <= 9;
bool is_alpha_numeric(char c) pure  => c < 128 && (char_details[c] & 3);
bool is_hex(char c) pure            => c < 128 && (char_details[c] & 0x80);
bool is_control_char(char c) pure   => c < 128 && (char_details[c] & 0x10);
bool is_url(char c) pure            => c < 128 && (char_details[c] & 0x40);

char to_lower(char c) pure
{
    // this is the typical way; which is faster on a weak arch?
//    if (c >= 'A' && c <= 'Z')
//        return c + 32;

    uint i = c - 'A';
    if (i < 26)
        return c | 0x20;
    return c;
}

char to_upper(char c) pure
{
    // this is the typical way; which is faster on a weak arch?
//    if (c >= 'a' && c <= 'z')
//        return c - 32;

    uint i = c - 'a';
    if (i < 26)
        return c ^ 0x20;
    return c;
}

char[] to_lower(const(char)[] str, char[] buffer) pure
{
    foreach (i; 0 .. str.length)
        buffer[i] = to_lower(str[i]);
    return buffer;
}

char[] to_upper(const(char)[] str, char[] buffer) pure
{
    foreach (i; 0 .. str.length)
        buffer[i] = to_upper(str[i]);
    return buffer;
}

char[] to_lower(char[] str) pure
{
    return to_lower(str, str);
}

char[] to_upper(char[] str) pure
{
    return to_upper(str, str);
}
