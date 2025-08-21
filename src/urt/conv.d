module urt.conv;

import urt.meta;
import urt.string;
public import urt.string.format : toString;

nothrow @nogc:


// on error or not-a-number cases, bytes_taken will contain 0
long parse_int(const(char)[] str, size_t* bytes_taken = null, int base = 10) pure
{
    size_t i = 0;
    bool neg = false;

    if (str.length > 0)
    {
        char c = str.ptr[0];
        neg = c == '-';
        if (neg || c == '+')
            i++;
    }

    ulong value = str.ptr[i .. str.length].parse_uint(bytes_taken, base);
    if (bytes_taken && *bytes_taken != 0)
        *bytes_taken += i;
    return neg ? -cast(long)value : cast(long)value;
}

long parse_int_with_decimal(const(char)[] str, out ulong fixed_point_divisor, size_t* bytes_taken = null, int base = 10) pure
{
    size_t i = 0;
    bool neg = false;

    if (str.length > 0)
    {
        char c = str.ptr[0];
        neg = c == '-';
        if (neg || c == '+')
            i++;
    }

    ulong value = str[i .. str.length].parse_uint_with_decimal(fixed_point_divisor, bytes_taken, base);
    if (bytes_taken && *bytes_taken != 0)
        *bytes_taken += i;
    return neg ? -cast(long)value : cast(long)value;
}

ulong parse_uint(const(char)[] str, size_t* bytes_taken = null, int base = 10) pure
{
    assert(base > 1 && base <= 36, "Invalid base");

    ulong value = 0;

    const(char)* s = str.ptr;
    const(char)* e = s + str.length;

    if (base <= 10)
    {
        for (; s < e; ++s)
        {
            uint digit = *s - '0';
            if (digit > 9)
                break;
            value = value*base + digit;
        }
    }
    else
    {
        for (; s < e; ++s)
        {
            uint digit = get_digit(*s);
            if (digit >= base)
                break;
            value = value*base + digit;
        }
    }

    if (bytes_taken)
        *bytes_taken = s - str.ptr;
    return value;
}

ulong parse_uint_with_decimal(const(char)[] str, out ulong fixed_point_divisor, size_t* bytes_taken = null, int base = 10) pure
{
    assert(base > 1 && base <= 36, "Invalid base");

    ulong value = 0;
    ulong divisor = 1;

    const(char)* s = str.ptr;
    const(char)* e = s + str.length;

    // TODO: we could optimise the common base <= 10 case...

    for (; s < e; ++s)
    {
        char c = *s;

        if (c == '.')
        {
            ++s;
            goto parse_decimal;
        }

        uint digit = get_digit(c);
        if (digit >= base)
            break;
        value = value*base + digit;
    }
    goto done;

parse_decimal:
    for (; s < e; ++s)
    {
        uint digit = get_digit(*s);
        if (digit >= base)
        {
            // if i == 1, then the first char was a '.' and the next was not numeric, so this is not a number!
            if (s == str.ptr + 1)
                s = str.ptr;
            break;
        }
        value = value*base + digit;
        divisor *= base;
    }

done:
    fixed_point_divisor = divisor;
    if (bytes_taken)
        *bytes_taken = s - str.ptr;
    return value;
}

ulong parse_uint_with_base(const(char)[] str, size_t* bytes_taken = null) pure
{
    const(char)* p = str.ptr;
    int base = parse_base_prefix(str);
    ulong i = parse_uint(str, bytes_taken, base);
    if (bytes_taken && *bytes_taken != 0)
        *bytes_taken += str.ptr - p;
    return i;
}


unittest
{
    size_t taken;
    ulong divisor;
    assert(parse_uint("123") == 123);
    assert(parse_int("+123.456") == 123);
    assert(parse_int("-123.456", null, 10) == -123);
    assert(parse_uint_with_decimal("123.456", divisor, null, 10) == 123456 && divisor == 1000);
    assert(parse_int_with_decimal("123.456.789", divisor, &taken, 16) == 1193046 && taken == 7 && divisor == 4096);
    assert(parse_int("11001", null, 2) == 25);
    assert(parse_int_with_decimal("-AbCdE.f", divisor, null, 16) == -11259375 && divisor == 16);
    assert(parse_int("123abc", &taken, 10) == 123 && taken == 3);
    assert(parse_int("!!!", &taken, 10) == 0 && taken == 0);
    assert(parse_int("-!!!", &taken, 10) == 0 && taken == 0);
    assert(parse_int("Wow", &taken, 36) == 42368 && taken == 3);
    assert(parse_uint_with_base("0x100", &taken) == 0x100 && taken == 5);
}

int parse_int_fast(ref const(char)[] text, out bool success) pure
{
    if (!text.length)
        return 0;

    const(char)* s = text.ptr;
    const char* e = s + text.length;

    bool neg = false;
    if (*s == '-')
    {
        neg = true;
        goto skip;
    }
    if (*s == '+')
    {
    skip:
        if (text.length == 1)
            return 0;
        ++s;
    }
    uint i = *s - '0';
    if (i > 9)
        return 0;

    uint max = int.max + neg;

    while (true)
    {
        if (++s == e)
            break;
        uint c = *s - '0';
        if (c > 9)
            break;
        if (i > int.max / 10) // check for overflow
            return 0; // should we take the number from the text stream though?
        i = i*10 + c;
        if (i > max) // check for overflow
            return 0; // should we take the number from the text stream though?
    }
    text = s[0 .. e - s];
    success = true;
    return neg ? -cast(int)i : cast(int)i;
}

unittest
{
    bool success;
    const(char)[] text = "123";
    assert(parse_int_fast(text, success) == 123 && success == true && text.empty);
    text = "-2147483648abc";
    assert(parse_int_fast(text, success) == -2147483648 && success == true && text.length == 3);
    text = "2147483648";
    assert(parse_int_fast(text, success) == 0 && success == false);
    text = "-2147483649";
    assert(parse_int_fast(text, success) == 0 && success == false);
    text = "2147483650";
    assert(parse_int_fast(text, success) == 0 && success == false);
}


// on error or not-a-number, result will be nan and bytes_taken will contain 0
double parse_float(const(char)[] str, size_t* bytes_taken = null, int base = 10) pure
{
    // TODO: E-notation...
    size_t taken = void;
    ulong div = void;
    long value = str.parse_int_with_decimal(div, &taken, base);
    if (bytes_taken)
        *bytes_taken = taken;
    if (taken == 0)
        return double.nan;
    return cast(double)value / div;
}

unittest
{
    static bool fcmp(double a, double b) pure
    {
        import urt.math;
        return fabs(a - b) < 10e-23;
    }

    size_t taken;
    assert(fcmp(parse_float("123.456"), 123.456));
    assert(fcmp(parse_float("+123.456"), 123.456));
    assert(fcmp(parse_float("-123.456.789"), -123.456));
    assert(fcmp(parse_float("1101.11", &taken, 2), 13.75) && taken == 7);
    assert(parse_float("xyz", &taken) is double.nan && taken == 0);
}


ptrdiff_t format_int(long value, char[] buffer, uint base = 10, uint width = 0, char fill = ' ', bool show_sign = false) pure
{
    const bool neg = value < 0;
    show_sign |= neg;

    if (buffer.ptr && buffer.length < show_sign)
        return -1;

    ulong i = neg ? -value : value;

    ptrdiff_t r = format_uint(i, buffer.ptr ? buffer.ptr[(width == 0 ? show_sign : 0) .. buffer.length] : null, base, width, fill);
    if (r < 0 || !show_sign)
        return r;

    if (buffer.ptr)
    {
        char sgn = neg ? '-' : '+';

        if (width == 0)
        {
            buffer.ptr[0] = sgn;
            return r + 1;
        }
        if (buffer.ptr[0] == '0')
        {
            // this handles cases where the number was padded with leading zeroes
            // it should format as: "-000123" instead of "   -123"
            buffer.ptr[0] = sgn;
            return r;
        }
        if (buffer.ptr[0] == fill)
        {
            // we don't need to shift it left...
            size_t sgn_offset = 0;
            while (buffer.ptr[sgn_offset + 1] == fill)
                ++sgn_offset;
            buffer.ptr[sgn_offset] = sgn;
            return r;
        }

        // we need to shift the number right...
        // TODO: this is a bad case; maybe we should have reserved space in the first place?
        if (buffer.length < r + 1)
            return -1;
        for (size_t j = r; j > 0; --j)
            buffer.ptr[j] = buffer.ptr[j - 1];
        buffer.ptr[0] = sgn;
        return r + 1;
    }

    // determine if the formatted number would have padding, because the sign character will consume padding bytes
    if (r == width && i < base^^cast(uint)(width - 1))
        return r;
    return r + 1;
}

ptrdiff_t format_uint(ulong value, char[] buffer, uint base = 10, uint width = 0, char fill = ' ') pure
{
    import urt.util : max;

    assert(base >= 2 && base <= 36, "Invalid base");

    ulong i = value;
    uint num_len = 0;
    char[64] t = void;
    if (i == 0)
    {
        if (buffer.length > 0)
            t.ptr[0] = '0';
        num_len = 1;
    }
    else
    {
        // TODO: if this is a hot function, the if's could be hoisted outside the loop.
        //       there are 8 permutations...
        //       also, some platforms might prefer a lookup table than `d < 10 ? ... : ...`
        for (; i != 0; i /= base)
        {
            if (buffer.ptr)
            {
                int d = cast(int)(i % base);
                t.ptr[num_len] = cast(char)((d < 10 ? '0' : 'A' - 10) + d);
            }
            ++num_len;
        }
    }

    uint len = max(num_len, width);
    uint padding = width > num_len ? width - num_len : 0;

    if (buffer.ptr)
    {
        if (buffer.length < len)
            return -1;

        size_t offset = 0;
        while (padding--)
            buffer.ptr[offset++] = fill;
        for (uint j = num_len; j > 0; )
            buffer.ptr[offset++] = t[--j];
    }
    return len;
}

unittest
{
    char[64] buffer;
    assert(format_int(0, null) == 1);
    assert(format_int(14, null) == 2);
    assert(format_int(14, null, 16) == 1);
    assert(format_int(-14, null) == 3);
    assert(format_int(-14, null, 16) == 2);
    assert(format_int(-14, null, 16, 3, '0') == 3);
    assert(format_int(-123, null, 10, 6) == 6);
    assert(format_int(-123, null, 10, 3) == 4);
    assert(format_int(-123, null, 10, 2) == 4);

    size_t len = format_int(0, buffer);
    assert(buffer[0 .. len] == "0");
    len = format_int(14, buffer);
    assert(buffer[0 .. len] == "14");
    len = format_int(14, buffer, 2);
    assert(buffer[0 .. len] == "1110");
    len = format_int(14, buffer, 8, 3);
    assert(buffer[0 .. len] == " 16");
    len = format_int(14, buffer, 16, 4, '0');
    assert(buffer[0 .. len] == "000E");
    len = format_int(-14, buffer, 16, 3, '0');
    assert(buffer[0 .. len] == "-0E");
    len = format_int(12345, buffer, 10, 3);
    assert(buffer[0 .. len] == "12345");
    len = format_int(-123, buffer, 10, 6);
    assert(buffer[0 .. len] == "  -123");
}


ptrdiff_t format_float(double value, char[] buffer, const(char)[] format = null) // pure
{
    // TODO: this function should be oblitereated and implemented natively...
    //       CRT call can't CTFE, which is a shame

    import core.stdc.stdio;
    import urt.string.format : concat;

    char[16] fmt = void;
    char[64] result = void;
    assert(format.length <= fmt.sizeof - 3, "Format string buffer overflow");

    concat(fmt, "%", format, "g\0");
    int len = snprintf(result.ptr, result.length, fmt.ptr, value);
    if (len < 0)
        return -2;
    if (buffer.ptr)
    {
        if (len > buffer.length)
            return -1;
        buffer[0 .. len] = result[0 .. len];
    }
    return len;
}



template to(T)
{
    import urt.traits;

    static if (is(T == long))
    {
        long to(const(char)[] str)
        {
            int base = parse_base_prefix(str);
            size_t taken;
            long r = parse_int(str, &taken, base);
            assert(taken == str.length, "String is not numeric");
            return r;
        }
    }
    else static if (is(T == double))
    {
        double to(const(char)[] str)
        {
            int base = parse_base_prefix(str);
            size_t taken;
            double r = parse_float(str, &taken, base);
            assert(taken == str.length, "String is not numeric");
            return r;
        }
    }
    else static if (is_some_int!T) // call-through for other int types; reduce instantiation bloat
    {
        T to(const(char)[] str)
            => cast(T)to!long(str);
    }
    else static if (is_some_float!T) // call-through for other float types; reduce instantiation bloat
    {
        T to(const(char)[] str)
            => cast(T)to!double(str);
    }
    else static if (is(T == struct) || is(T == class))
    {
        // if aggregates have a fromString() function, we can use it to parse the string...
        static assert(is(typeof(&(T.init).fromString) == bool delegate(const(char)[], ulong*) nothrow @nogc), "Aggregate requires 'fromString' member");

        T to(const(char)[] str)
        {
            T r;
            ptrdiff_t taken = r.fromString(str);
            assert(taken == str.length, "Failed to parse string as " ~ T.stringof);
            return r;
        }
    }
    else static if (is(T : const(char)[]))
    {
        import urt.mem.allocator;

        const(char)[] to(ref T, NoGCAllocator allocator = tempAllocator())
        {
            static assert(false, "TODO");
        }
    }
}


private:

uint get_digit(char c) pure
{
    uint zero_base = c - '0';
    if (zero_base < 10)
        return zero_base;
    uint A_base = c - 'A';
    if (A_base < 26)
        return A_base + 10;
    uint a_base = c - 'a';
    if (a_base < 26)
        return a_base + 10;
    return -1;
}

int parse_base_prefix(ref const(char)[] str) pure
{
    int base = 10;
    if (str.length >= 2)
    {
        if (str[0..2] == "0x")
            base = 16, str = str[2..$];
        else if (str[0..2] == "0b")
            base = 2, str = str[2..$];
        else if (str[0..2] == "0o")
            base = 8, str = str[2..$];
    }
    return base;
}


/+
size_t format_struct(T)(ref T value, char[] buffer) nothrow @nogc
{
    import urt.string.format;

    static assert(is(T == struct), "T must be some struct");

    alias args = value.tupleof;
//    alias args = AliasSeq!(value.tupleof);
//    alias args = INTERLEAVE_SEPARATOR!(", ", value.tupleof);
//    pragma(msg, args);
    return concat(buffer, args).length;
}

unittest
{
    import router.iface;

    Packet p;

    char[1024] buffer;
    size_t len = format_struct(p, buffer);
    assert(buffer[0 .. len] == "Packet()");

}
+/
