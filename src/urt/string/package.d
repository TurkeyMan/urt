module urt.string;

import urt.string.uni;
import urt.traits : is_some_char;

public import urt.string.ascii;
public import urt.string.string;
public import urt.string.tailstring;

// seful string operations defined elsewhere
public import urt.array : empty, popFront, popBack, takeFront, takeBack;
public import urt.mem : strlen, wcslen;
public import urt.mem.temp : tstringz, twstringz;

nothrow @nogc:


inout(char)[] c_string(inout(char)* cstr) pure
    => cstr ? cstr[0 .. cstr.strlen] : null;

size_t strlen_s(const(char)[] s) pure
{
    size_t len = 0;
    while (len < s.length && s[len] != '\0')
        ++len;
    return len;
}

ptrdiff_t cmp(bool case_insensitive = false, T, U)(const(T)[] a, const(U)[] b) pure
{
    static if (case_insensitive)
        return uni_compare_i(a, b);
    else
    {
        static if (is(T == U))
        {
            if (a.length != b.length)
                return a.length - b.length;
        }
        return uni_compare(a, b);
    }
}

ptrdiff_t icmp(T, U)(const(T)[] a, const(U)[] b) pure
    => cmp!true(a, b);

bool eq(const(char)[] a, const(char)[] b) pure
    => cmp(a, b) == 0;

bool ieq(const(char)[] a, const(char)[] b) pure
    => cmp!true(a, b) == 0;

size_t findFirst(bool case_insensitive = false, T, U)(const(T)[] s, const U c)
    if (is_some_char!T && is_some_char!U)
{
    static if (is(U == char))
        assert(c <= 0x7F, "Invalid UTF character");
    else static if (is(U == wchar))
        assert(c < 0xD800 || c >= 0xE000, "Invalid UTF character");

    // TODO: what if `c` is 'ß'? do we find "ss" in case-insensitive mode?
    //       and if `c` is 's', do we match 'ß'?

    static if (case_insensitive)
        const U lc = cast(U)c.uni_case_fold();
    else
        alias lc = c;

    size_t i = 0;
    while (i < s.length)
    {
        static if (U.sizeof <= T.sizeof)
        {
            enum l = 1;
            dchar d = s[i];
        }
        else
        {
            size_t l;
            dchar d = next_dchar(s[i..$], l);
        }
        static if (case_insensitive)
        {
            static if (is(U == char))
            {
                // only fold the ascii characters, since lc is known to be ascii
                if (uint(d - 'A') < 26)
                    d |= 0x20;
            }
            else
                d = d.uni_case_fold();
        }
        if (d == lc)
            break;
        i += l;
    }
    return i;
}

size_t find_first_i(T, U)(const(T)[] s, U c)
    if (is_some_char!T && is_some_char!U)
    => findFirst!true(s, c);

size_t findLast(bool case_insensitive = false, T, U)(const(T)[] s, const U c)
    if (is_some_char!T && is_some_char!U)
{
    static assert(case_insensitive == false, "TODO");

    static if (is(U == char))
        assert(c <= 0x7F, "Invalid unicode character");
    else static if (is(U == wchar))
        assert(c >= 0xD800 && c < 0xE000, "Invalid unicode character");

    ptrdiff_t last = s.length-1;
    while (last >= 0)
    {
        static if (U.sizeof <= T.sizeof)
        {
            if (s[last] == c)
                return cast(size_t)last;
            --last;
        }
        else
        {
            // this is tricky, because we need to seek backwards to the start of surrogate sequences
            assert(false, "TODO");
        }
    }
    return s.length;
}

size_t find_last_i(T, U)(const(T)[] s, U c)
    if (is_some_char!T && is_some_char!U)
    => findLast!true(s, c);

size_t findFirst(bool case_insensitive = false, T, U)(const(T)[] s, const(U)[] t)
    if (is_some_char!T && is_some_char!U)
{
    if (t.length == 0)
        return 0;

    // fast-path for one-length tokens
    size_t l = t.uni_seq_len();
    if (l == t.length)
    {
        dchar c = t.next_dchar(l);
        if (c < 0x80)
            return findFirst!case_insensitive(s, cast(char)c);
        if (c < 0x10000)
            return findFirst!case_insensitive(s, cast(wchar)c);
        return findFirst!case_insensitive(s, c);
    }

    size_t offset = 0;
    while (offset < s.length)
    {

        static if (case_insensitive)
            int c = uni_compare_i(s[offset .. $], t);
        else
            int c = uni_compare(s[offset .. $], t);
        if (c == int.max || c == 0)
            return offset;
        if (c == int.min)
            return s.length;
        offset += s[offset .. $].uni_seq_len();
    }
    return s.length;
}

size_t find_first_i(T, U)(const(T)[] s, const(U)[] t)
    if (is_some_char!T && is_some_char!U)
    => findFirst!true(s, t);

size_t findLast(bool case_insensitive = false, T, U)(const(T)[] s, const(U)[] t)
    if (is_some_char!T && is_some_char!U)
{
    // this is tricky, because we need to seek backwards to the start of surrogate sequences
    assert(false, "TODO");
}

size_t find_last_i(T, U)(const(T)[] s, const(U)[] t)
    if (is_some_char!T && is_some_char!U)
    => findLast!true(s, t);

bool contains(bool case_insensitive = false, T, U)(const(T)[] s, U c, size_t *offset = null)
    if (is_some_char!T && is_some_char!U)
{
    size_t i = findFirst!case_insensitive(s, c);
    if (i == s.length)
        return false;
    if (offset)
        *offset = i;
    return true;
}

bool contains(bool case_insensitive = false, T, U)(const(T)[] s, const(U)[] t, size_t *offset = null)
    if (is_some_char!T && is_some_char!U)
{
    size_t i = findFirst!case_insensitive(s, t);
    if (i == s.length)
        return false;
    if (offset)
        *offset = i;
    return true;
}

bool contains_i(T, U)(const(T)[] s, U c, size_t *offset = null)
    if (is_some_char!T && is_some_char!U)
    => contains!true(s, c, offset);

bool contains_i(T, U)(const(T)[] s, const(U)[] t, size_t *offset = null)
    if (is_some_char!T && is_some_char!U)
    => contains!true(s, t, offset);

bool startsWith(const(char)[] s, const(char)[] prefix) pure
{
    if (s.length < prefix.length)
        return false;
    return cmp(s[0 .. prefix.length], prefix) == 0;
}

bool endsWith(const(char)[] s, const(char)[] suffix) pure
{
    if (s.length < suffix.length)
        return false;
    return cmp(s[$ - suffix.length .. $], suffix) == 0;
}

inout(char)[] trim(alias pred = is_whitespace, bool Front = true, bool Back = true)(inout(char)[] s) pure
{
    size_t first = 0, last = s.length;
    static if (Front)
    {
        while (first < s.length && pred(s.ptr[first]))
            ++first;
    }
    static if (Back)
    {
        while (last > first && pred(s.ptr[last - 1]))
            --last;
    }
    return s.ptr[first .. last];
}

alias trimFront(alias pred = is_whitespace) = trim!(pred, true, false);

alias trimBack(alias pred = is_whitespace) = trim!(pred, false, true);

inout(char)[] takeLine(ref inout(char)[] s) pure
{
    for (size_t i = 0; i < s.length; ++i)
    {
        if (s[i] == '\n')
        {
            inout(char)[] t = s[0 .. i];
            s = s[i + 1 .. $];
            return t;
        }
        else if (s.length > i+1 && s[i] == '\r' && s[i+1] == '\n')
        {
            inout(char)[] t = s[0 .. i];
            s = s[i + 2 .. $];
            return t;
        }
    }
    inout(char)[] t = s;
    s = s[$ .. $];
    return t;
}

inout(char)[] split(char[] separators, bool handle_quotes = true, bool do_trim = true)(ref inout(char)[] s, char* separator = null) pure
{
    static if (handle_quotes)
        int inQuotes = 0;
    else
        enum inQuotes = false;

    size_t i = 0;
    loop: for (; i < s.length; ++i)
    {
        static foreach (sep; separators)
        {
            if (s[i] == sep && !inQuotes)
            {
                if (separator)
                    *separator = s[i];
                break loop;
            }
        }
        static if (handle_quotes)
        {
            if (s[i] == '"' && !(inQuotes & 0x6))
                inQuotes = 1 - inQuotes;
            else if (s[i] == '\'' && !(inQuotes & 0x5))
                inQuotes = 2 - inQuotes;
            else if (s[i] == '`' && !(inQuotes & 0x3))
                inQuotes = 4 - inQuotes;
        }
    }
    static if (do_trim)
    {
        inout(char)[] t = s[0 .. i].trimBack;
        s = i < s.length ? s[i+1 .. $].trimFront : null;
    }
    else
    {
        inout(char)[] t = s[0 .. i];
        s = i < s.length ? s[i+1 .. $] : null;
    }
    return t;
}

alias split(char separator, bool handle_quotes = true, bool do_trim = true) = split!([separator], handle_quotes, do_trim);

// TODO: deprecate this one...
inout(char)[] split(separators...)(ref inout(char)[] s, out char sep) pure
{
    sep = '\0';
    return split!([separators], true, true)(s, &sep);
}

char[] unQuote(const(char)[] s, char[] buffer) pure
{
    // TODO: should this scan and match quotes rather than assuming there are no rogue closing quotes in the middle of the string?
    if (s.empty)
        return null;
    if (s[0] == '"' && s[$-1] == '"' || s[0] == '\'' && s[$-1] == '\'')
    {
        if (s is buffer)
            return buffer[1 .. $-1].unEscape;
        return s[1 .. $-1].unEscape(buffer);
    }
    bool quote = s[0] == '`' && s[$-1] == '`';
    if (s is buffer)
        return quote ? buffer[1 .. $-1] : buffer;
    s = quote ? s[1 .. $-1] : s;
    buffer[0 .. s.length] = s[];
    return buffer;
}

char[] unQuote(char[] s) pure
{
    return unQuote(s, s);
}

char[] unQuote(const(char)[] s)
{
    import urt.mem.temp : talloc;
    return unQuote(s, cast(char[])talloc(s.length));
}

char[] unEscape(inout(char)[] s, char[] buffer) pure
{
    if (s.empty)
        return null;

    bool same = s is buffer;

    size_t len = 0;
    for (size_t i = 0; i < s.length; ++i)
    {
        if (s[i] == '\\')
        {
            if (s.length > ++i)
            {
                switch (s[i])
                {
                    case '0':   buffer[len++] = '\0';   break;
                    case 'n':   buffer[len++] = '\n';   break;
                    case 'r':   buffer[len++] = '\r';   break;
                    case 't':   buffer[len++] = '\t';   break;
//                    case '\\':  buffer[len++] = '\\';   break;
//                    case '\'':  buffer[len++] = '\'';   break;
                    default:    buffer[len++] = s[i];
                }
            }
        }
        else if (!same || len < i)
            buffer[len++] = s[i];
    }
    return buffer[0..len];
}

char[] unEscape(char[] s) pure
{
    return unEscape(s, s);
}


char[] toHexString(const(void[]) data, char[] buffer, uint group = 0, uint secondaryGroup = 0, const(char)[] seps = " -") pure
{
    import urt.util : is_power_of_2;
    assert(group.is_power_of_2);
    assert(secondaryGroup.is_power_of_2);
    assert((secondaryGroup == 0 && seps.length > 0) || seps.length > 1, "Secondary grouping requires additional separator");

    if (data.length == 0)
        return buffer[0..0];

    size_t len = data.length*2;
    if (group)
        len += (data.length-1) / group;
    if (len > buffer.length)
        return null;

    auto src = cast(const(ubyte)[])data;

    size_t mask = group - 1;
    size_t secondMask = secondaryGroup - 1;

    size_t offset = 0;
    for (size_t i = 0; true; )
    {
        buffer[offset++] = hex_digits[src[i] >> 4];
        buffer[offset++] = hex_digits[src[i] & 0xF];

        bool sep = (i & mask) == mask;
        if (++i == data.length)
            return buffer[0 .. offset];
        if (sep)
            buffer[offset++] = ((i & secondMask) == 0 ? seps[1] : seps[0]);
    }
}

char[] toHexString(const(ubyte[]) data, uint group = 0, uint secondaryGroup = 0, const(char)[] seps = " -")
{
    import urt.mem.temp;

    size_t len = data.length*2;
    if (group && len > 0)
        len += (data.length-1) / group;
    return data.toHexString(cast(char[])talloc(len), group, secondaryGroup, seps);
}

unittest
{
    ubyte[8] data = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF];
    assert(data.toHexString(0) == "0123456789ABCDEF");
    assert(data.toHexString(1) == "01 23 45 67 89 AB CD EF");
    assert(data.toHexString(2) == "0123 4567 89AB CDEF");
    assert(data.toHexString(4) == "01234567 89ABCDEF");
    assert(data.toHexString(8) == "0123456789ABCDEF");
    assert(data.toHexString(2, 4, "_ ") == "0123_4567 89AB_CDEF");
}


// Pattern grammar:
//   *     - Match zero or more characters
//   ?     - Match exactly one character
//   #     - Match exactly one digit (0-9)
//   ~T    - Token T is optional (matches with or without T)
//   \C    - Escape character C (literal match)
// Examples:
//   "h*o"    matches "hello", "ho"
//   "h?llo"  matches "hello", "hallo" but not "hllo"
//   "v#.#"   matches "v1.2", "v3.7" but not "va.b"
//   "~ab"    matches "ab", "b"
//   "h\*o"   matches "h*o" literally
bool wildcard_match(const(char)[] wildcard, const(char)[] value, bool value_wildcard = false, bool case_insensitive = false) pure
{
    const(char)* a = wildcard.ptr, ae = a + wildcard.length, b = value.ptr, be = b + value.length;

    static inout(char)* skip_wilds(inout(char)* p, const(char)* pe)
    {
        while (p < pe)
        {
            if (*p == '*')
                ++p;
            else if (*p == '~')
            {
            one_more:
                if (++p < pe)
                {
                    if (*p == '~')
                        goto one_more;
                    if (*p++ == '\\' && p < pe)
                        ++p;
                }
            }
            else break;
        }
        // HACK: skip trailing slash (handle a degenerate case)
        if (p == pe - 1 && *p == '\\')
            ++p;
        return p;
    }

    struct BacktrackState
    {
        const(char)* a, b;
    }
    BacktrackState[64] backtrack_stack = void;
    size_t backtrack_depth = 0;

    char ca_orig = void, cb_orig = void, ca = void, cb = void;

    while (a < ae && b < be)
    {
        ca_orig = *a, cb_orig = *b;

        // handle wildcards
        if (ca_orig == '*')
        {
            a = skip_wilds(++a, ae);
            if (a == ae) // tail star matches everything
                return true;

            const(char)[] a_remain = a[0 .. ae - a];
            for (; b <= be; ++b)
            {
                if (wildcard_match(a_remain, b[0 .. be - b], value_wildcard, case_insensitive))
                    return true;
            }
            return false;
        }

        // handle optionals
        if (ca_orig == '~')
        {
            while (++a < ae && *a == '~') {}
            if (a == ae)
                break;

            if (backtrack_depth < backtrack_stack.length)
            {
                backtrack_stack[backtrack_depth].a = a + (*a == '\\' ? 2 : 1);
                backtrack_stack[backtrack_depth].b = b;
                ++backtrack_depth;
            }
            continue;
        }

        // handle escape
        ca = ca_orig, cb = cb_orig;
        if (ca == '\\')
        {
            if (++a < ae)
                ca = *a;
            else
                break;
        }

        // handle value wildcards
        if (value_wildcard)
        {
            if (cb_orig == '*')
            {
                b = skip_wilds(++b, be);
                if (b == be) // tail star matches everything
                    return true;

                const(char)[] b_remain = b[0 .. be - b];
                for (; a <= ae; ++a)
                {
                    if (wildcard_match(a[0 .. ae - a], b_remain, true, case_insensitive))
                        return true;
                }
                return false;
            }
            if (cb_orig == '~')
            {
                while (++b < be && *b == '~') {}
                if (b == be)
                    break;

                if (backtrack_depth < backtrack_stack.length)
                {
                    backtrack_stack[backtrack_depth].a = a;
                    backtrack_stack[backtrack_depth].b = b + (*b == '\\' ? 2 : 1);
                    ++backtrack_depth;
                }
                continue;
            }
            if (cb == '\\')
            {
                if (++b < be)
                    cb = *b;
                else
                    break;
            }
            if (cb_orig == '#')
            {
                if (ca.is_numeric || ca_orig == '#')
                    goto advance;
            }
        }

        // compare next char
        if (ca_orig == '#')
        {
            if (cb.is_numeric)
                goto advance;
        }
        else if ((case_insensitive ? ca.to_lower == cb.to_lower : ca == cb) || (ca_orig == '?') || (value_wildcard && cb_orig == '?'))
            goto advance;

    try_backtrack:
        if (backtrack_depth == 0)
            return false;

        --backtrack_depth;
        a = backtrack_stack[backtrack_depth].a;
        b = backtrack_stack[backtrack_depth].b;
        continue;

    advance:
        ++a, ++b;
    }

    // check the strings are equal...
    if (a == ae)
    {
        if (value_wildcard)
            b = skip_wilds(b, be);
        if (b == be)
            return true;
    }
    else if (b == be && skip_wilds(a, ae) == ae)
        return true;

    goto try_backtrack;
}

bool wildcard_match_i(const(char)[] wildcard, const(char)[] value, bool value_wildcard = false) pure
    => wildcard_match(wildcard, value, value_wildcard, true);


unittest
{
    // test findFirst
    assert("hello".findFirst('e') == 1);
    assert("hello".findFirst('a') == 5);
    assert("hello".findFirst("e") == 1);
    assert("hello".findFirst("ll") == 2);
    assert("hello".findFirst("lo") == 3);
    assert("hello".findFirst("la") == 5);
    assert("hello".findFirst("low") == 5);
    assert("héllo".findFirst('é') == 1);
    assert("héllo"w.findFirst('é') == 1);
    assert("héllo".findFirst("éll") == 1);
    assert("héllo".findFirst('a') == 6);
    assert("héllo".findFirst("la") == 6);
    assert("hello".find_first_i('E') == 1);
    assert("HELLO".find_first_i("e") == 1);
    assert("hello".find_first_i("LL") == 2);
    assert("héllo".find_first_i('É') == 1);
    assert("HÉLLO".find_first_i("é") == 1);
    assert("HÉLLO".find_first_i("éll") == 1);

    assert("HÉLLO".contains('É'));
    assert(!"HÉLLO".contains('A'));
    assert("HÉLLO".contains_i("éll"));

    // test wildcard_match
    assert(wildcard_match("hello", "hello"));
    assert(!wildcard_match("hello", "world"));
    assert(wildcard_match("h*o", "hello"));
    assert(wildcard_match("h*", "hello"));
    assert(wildcard_match("*o", "hello"));
    assert(wildcard_match("*", "hello"));
    assert(wildcard_match("h?llo", "hello"));
    assert(!wildcard_match("h?llo", "hllo"));
    assert(wildcard_match("h??lo", "hello"));
    assert(!wildcard_match("a*b", "axxxc"));

    // test optional - basic cases
    assert(wildcard_match("~ab", "b"));
    assert(wildcard_match("~ab", "ab"));
    assert(wildcard_match("a~b", "a"));
    assert(wildcard_match("a~b", "ab"));
    assert(!wildcard_match("~ab", "a"));
    assert(!wildcard_match("a~b", "b"));
    assert(!wildcard_match("a~b", "ac"));

    // optional - multiple optionals
    assert(wildcard_match("~a~b", ""));
    assert(wildcard_match("~a~b", "a"));
    assert(wildcard_match("~a~b", "b"));
    assert(wildcard_match("~a~b", "ab"));
    assert(!wildcard_match("~a~b", "ba"));
    assert(wildcard_match("~a~b~c", ""));
    assert(wildcard_match("~a~b~c", "ac"));
    assert(wildcard_match("~a~b~c", "abc"));

    // optional with wildcards
    assert(wildcard_match("~a*", ""));
    assert(wildcard_match("~a*", "a"));
    assert(wildcard_match("~a*", "abc"));
    assert(wildcard_match("*~a", ""));
    assert(wildcard_match("*~a", "a"));
    assert(wildcard_match("*~a", "xya"));
    assert(wildcard_match("a~b*c", "ac"));
    assert(wildcard_match("a~b*c", "abc"));
    assert(wildcard_match("a~b*c", "abxc"));
    assert(wildcard_match("a~b*c", "axbc"));
    assert(!wildcard_match("a*~bc", "a"));
    assert(wildcard_match("a*~bc", "ac"));
    assert(wildcard_match("a*~bc", "abc"));
    assert(wildcard_match("a*~bc", "axbc"));

    // optional with ?
    assert(wildcard_match("~a?", "a"));
    assert(wildcard_match("~a?", "x"));
    assert(wildcard_match("~a?", "ax"));
    assert(wildcard_match("?~a", "x"));
    assert(wildcard_match("?~a", "xa"));
    assert(wildcard_match("?~a", "a"));
    assert(wildcard_match("?~a", "aa"));

    // optional with #
    assert(wildcard_match("~a#", "5"));
    assert(wildcard_match("~a#", "a5"));
    assert(!wildcard_match("~a#", "a"));
    assert(!wildcard_match("~a#", "ax"));
    assert(wildcard_match("v~#.#", "v.5"));
    assert(wildcard_match("v~#.#", "v1.5"));

    // optional with escape
    assert(wildcard_match("~\\*", ""));
    assert(wildcard_match("~\\*", "*"));
    assert(!wildcard_match("~\\*", "x"));
    assert(wildcard_match("a~\\*b", "ab"));
    assert(wildcard_match("a~\\*b", "a*b"));
    assert(!wildcard_match("a~\\*b", "axb"));

    // double optional ~~
    assert(wildcard_match("~~a", ""));
    assert(wildcard_match("~~a", "a"));
    assert(!wildcard_match("~~a", "aa"));

    // degenerates
    assert(wildcard_match("a\\", "a"));
    assert(!wildcard_match("a\\", ""));
    assert(!wildcard_match("a\\", "x"));
    assert(wildcard_match("a~", "a"));
    assert(!wildcard_match("a~", ""));
    assert(!wildcard_match("a~", "x"));
    assert(wildcard_match("a~\\", "a"));
    assert(!wildcard_match("a~\\", ""));
    assert(!wildcard_match("a~\\", "x"));

    // optional with value_wildcard - basic
    assert(wildcard_match("~b", "", true));
    assert(wildcard_match("~b", "b", true));
    assert(wildcard_match("", "~b", true));
    assert(wildcard_match("b", "~b", true));
    assert(wildcard_match("ab", "~ab", true));
    assert(wildcard_match("ab", "~a~b", true));
    assert(wildcard_match("~ab", "ab", true));
    assert(wildcard_match("~ab", "~ab", true));
    assert(wildcard_match("~ab", "~a~b", true));
    assert(wildcard_match("a~b", "~ab", true));
    assert(wildcard_match("a~b", "~a~b", true));
    assert(wildcard_match("~a~b", "~ab", true));
    assert(wildcard_match("~a~b", "~a~b", true));

    // optional with value_wildcard - with wildcards on rhs
    assert(wildcard_match("~a", "*", true));
    assert(wildcard_match("~ab", "*", true));
    assert(wildcard_match("~a~b", "*", true));
    assert(wildcard_match("*", "~a", true));
    assert(wildcard_match("*", "~ab", true));
    assert(wildcard_match("*", "~a~b", true));
    assert(wildcard_match("~a", "?", true));
    assert(wildcard_match("?", "~a", true));
    assert(wildcard_match("~ab", "?", true));
    assert(wildcard_match("~ab", "?b", true));
    assert(wildcard_match("~ab", "a?", true));
    assert(wildcard_match("~ab", "??", true));
    assert(wildcard_match("?", "~ab", true));
    assert(wildcard_match("?b", "~ab", true));
    assert(wildcard_match("a?", "~ab", true));
    assert(wildcard_match("??", "~ab", true));
    assert(wildcard_match("~ab", "?b", true));
    assert(wildcard_match("~abc", "?c", true));
    assert(wildcard_match("~a*", "*", true));
    assert(wildcard_match("*~a", "*", true));
    assert(wildcard_match("*", "~a*", true));
    assert(wildcard_match("*", "*~a", true));
    assert(wildcard_match("ab", "*~c", true));
    assert(wildcard_match("abc", "a?~c", true));

    // optional on both sides with wildcards
    assert(wildcard_match("~a*", "*~b", true));
    assert(wildcard_match("a~b*", "*~cd", true));
    assert(wildcard_match("~ab", "*b", true));
    assert(wildcard_match("~ab", "*ab", true));
    assert(wildcard_match("x~ab", "*ab", true));
    assert(wildcard_match("*b", "~ab", true));
    assert(wildcard_match("*ab", "~ab", true));
    assert(wildcard_match("*ab", "x~ab", true));
    assert(wildcard_match("~a~b", "~c~d", true));
    assert(wildcard_match("~a~b", "~c~da", true));
    assert(wildcard_match("~a~b", "~c~db", true));
    assert(wildcard_match("~a~b", "~c~dab", true));
    assert(wildcard_match("~a~bc", "~c~d", true));
    assert(wildcard_match("~a~bd", "~c~d", true));
    assert(wildcard_match("~a~bcd", "~c~d", true));
    assert(wildcard_match("*a~bc*d", "xxacxxd", true));
    assert(!wildcard_match("*a~bc*de", "xxabcxxd", true));
    assert(!wildcard_match("*a~bc*d", "xxabcxxde", true));
    assert(wildcard_match("*a~bc*d", "~x~x~a~c~x~x~d", true));

    // case insensitive with optional
    assert(wildcard_match_i("~a", "A"));
    assert(wildcard_match_i("~aB", "Ab"));
    assert(wildcard_match_i("A~b", "aB"));

    // multiple wildcards
    assert(wildcard_match("*l*o", "hello"));
    assert(wildcard_match("h*l*o", "hello"));
    assert(wildcard_match("h*l*", "hello"));
    assert(wildcard_match("*e*l*", "hello"));
    assert(wildcard_match("*h*e*l*l*o*", "hello"));

    // wildcards with sequences in between
    assert(wildcard_match("h*ll*", "hello"));
    assert(wildcard_match("*el*", "hello"));
    assert(wildcard_match("h*el*o", "hello"));
    assert(!wildcard_match("h*el*x", "hello"));
    assert(wildcard_match("*lo", "hello"));
    assert(!wildcard_match("*lx", "hello"));

    // mixed wildcards and single matches
    assert(wildcard_match("h?*o", "hello"));
    assert(wildcard_match("h*?o", "hello"));
    assert(wildcard_match("?e*o", "hello"));
    assert(wildcard_match("h?ll?", "hello"));
    assert(!wildcard_match("h?ll?", "hllo"));

    // overlapping wildcards
    assert(wildcard_match("**hello", "hello"));
    assert(wildcard_match("hello**", "hello"));
    assert(wildcard_match("h**o", "hello"));
    assert(wildcard_match("*?*", "hello"));
    assert(wildcard_match("?*?", "hello"));
    assert(!wildcard_match("?*?", "x"));
    assert(wildcard_match("?*?", "xx"));

    // escape sequences
    assert(wildcard_match("\\*", "*"));
    assert(wildcard_match("\\?", "?"));
    assert(wildcard_match("\\#", "#"));
    assert(wildcard_match("\\\\", "\\"));
    assert(!wildcard_match("\\*", "a"));
    assert(!wildcard_match("\\?", "a"));
    assert(!wildcard_match("\\#", "5"));
    assert(wildcard_match("h\\*o", "h*o"));
    assert(!wildcard_match("h\\*o", "hello"));
    assert(wildcard_match("\\*\\?\\\\", "*?\\"));
    assert(wildcard_match("a\\*b*c", "a*bxyzc"));
    assert(wildcard_match("*\\**", "hello*world"));

    // edge cases
    assert(wildcard_match("", ""));
    assert(!wildcard_match("", "a"));
    assert(wildcard_match("*", ""));
    assert(wildcard_match("**", ""));
    assert(!wildcard_match("?", ""));
    assert(wildcard_match("a*b*c", "abc"));
    assert(wildcard_match("a*b*c", "aXbYc"));
    assert(wildcard_match("a*b*c", "aXXbYYc"));

    // value_wildcard tests - bidirectional matching
    assert(wildcard_match("hello", "h*o", true));
    assert(wildcard_match("h*o", "hello", true));
    assert(wildcard_match("h?llo", "he?lo", true));
    assert(wildcard_match("h\\*o", "h\\*o", true));
    assert(wildcard_match("test*", "*test", true));

    // both sides have wildcards
    assert(wildcard_match("h*o", "h*o", true));
    assert(wildcard_match("*hello*", "*world*", true));
    assert(wildcard_match("a*b*c", "a*b*c", true));
    assert(wildcard_match("*", "*", true));
    assert(wildcard_match("?", "?", true));

    // complex interplay - wildcards matching wildcards
    assert(wildcard_match("a*c", "a?c", true));
    assert(wildcard_match("a?c", "a*c", true));
    assert(wildcard_match("*abc", "?abc", true));
    assert(wildcard_match("abc*", "abc?", true));

    // multiple wildcards on both sides
    assert(wildcard_match("a*b*c", "a?b?c", true));
    assert(wildcard_match("*a*b*", "?a?b?", true));
    assert(wildcard_match("a**b", "a*b", true));
    assert(wildcard_match("a*b", "a**b", true));

    // wildcards at different positions
    assert(wildcard_match("*test", "test*", true));
    assert(wildcard_match("test*end", "*end", true));
    assert(wildcard_match("*middle*", "start*", true));

    // edge cases with value_wildcard
    assert(wildcard_match("", "", true));
    assert(wildcard_match("*", "", true));
    assert(wildcard_match("", "*", true));
    assert(wildcard_match("**", "*", true));
    assert(wildcard_match("*", "**", true));

    // digit wildcard tests
    assert(wildcard_match("#", "0"));
    assert(wildcard_match("#", "5"));
    assert(wildcard_match("#", "9"));
    assert(!wildcard_match("#", "a"));
    assert(!wildcard_match("#", "A"));
    assert(!wildcard_match("#", ""));
    assert(!wildcard_match("#", "12"));
    assert(!wildcard_match("#", "#"));
    assert(wildcard_match("#", "#", true));
    assert(!wildcard_match("#", "\\#", true));
    assert(wildcard_match("v#.#", "v1.2"));
    assert(!wildcard_match("v#.#", "va.b"));
    assert(!wildcard_match("v#.#", "v1."));
    assert(wildcard_match("port-##", "port-42"));
    assert(wildcard_match("#*#", "123"));
    assert(!wildcard_match("#*#", "abc"));
}
