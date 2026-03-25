module urt.string.regex;

import urt.mem.allocator;

nothrow @nogc:


struct RegexMatch
{
    const(char)[] full;
    const(char)[][Regex.MaxGroups] captures;
    ubyte num_captures;
}

bool regex_match(const(char)[] text, const(char)[] pattern, ref RegexMatch result)
{
    Regex re = regex_compile(pattern, tempAllocator());
    if (!re.valid)
        return false;
    return re.exec(text, result);
}

// Compiled regex program. Single contiguous allocation for all instructions
// and character class data. Compile with regex_compile(), run with exec().
//
// Supported syntax:
//   .          any character
//   \d \D      digit / non-digit
//   \s \S      whitespace / non-whitespace
//   \w \W      word char [a-zA-Z0-9_] / non-word
//   \. \\ etc  literal escapes
//   [abc]      character class
//   [^abc]     negated character class
//   [a-z]      character range in class
//   *  +  ?    greedy quantifiers
//   *? +? ??   non-greedy (lazy) quantifiers
//   (...)      capture group (first group returned)
//   (a|b)      alternation
//   ^  $       anchors (start/end of text)
struct Regex
{
nothrow @nogc:

    enum MaxGroups = 8;

    bool valid() const
        => data.ptr !is null;

    // Execute against text. Unanchored unless pattern used ^.
    bool exec(const(char)[] text, ref RegexMatch result) const
    {
        if (!valid)
            return false;

        ref const Header hdr = *cast(const(Header)*)data.ptr;
        const(Inst)[] code = (cast(const(Inst)*)(data.ptr + Header.sizeof))[0 .. hdr.num_insts];
        const(ClassRange)[] ranges = (cast(const(ClassRange)*)(data.ptr + Header.sizeof + hdr.num_insts * Inst.sizeof))[0 .. hdr.num_ranges];
        const(ClassDef)[] classes = (cast(const(ClassDef)*)(data.ptr + Header.sizeof + hdr.num_insts * Inst.sizeof + hdr.num_ranges * ClassRange.sizeof))[0 .. hdr.num_classes];

        struct Thread
        {
            ushort ipc, pos;
            ushort[MaxGroups] gs, ge;
        }

        Thread[512] stack = void;
        ushort sp;

        foreach (start; 0 .. hdr.anchored ? 1 : text.length + 1)
        {
            sp = 0;
            Thread t;
            t.ipc = 0;
            t.pos = cast(ushort)start;
            t.gs[] = ushort.max;
            t.ge[] = ushort.max;

            bool matched = false;

            while (true)
            {
                if (t.ipc >= code.length)
                    break;

                Inst inst = code[t.ipc];

                final switch (inst.op) with (Op)
                {
                    case literal:
                        if (t.pos < text.length && text[t.pos] == inst.operand)
                            ++t.pos, ++t.ipc;
                        else
                            goto backtrack;
                        break;
                    case any:
                        if (t.pos < text.length)
                            ++t.pos, ++t.ipc;
                        else
                            goto backtrack;
                        break;
                    case digit:
                        if (t.pos < text.length && is_digit(text[t.pos]))
                            ++t.pos, ++t.ipc;
                        else
                            goto backtrack;
                        break;
                    case not_digit:
                        if (t.pos < text.length && !is_digit(text[t.pos]))
                            ++t.pos, ++t.ipc;
                        else
                            goto backtrack;
                        break;
                    case space:
                        if (t.pos < text.length && is_space(text[t.pos]))
                            ++t.pos, ++t.ipc;
                        else
                            goto backtrack;
                        break;
                    case not_space:
                        if (t.pos < text.length && !is_space(text[t.pos]))
                            ++t.pos, ++t.ipc;
                        else
                            goto backtrack;
                        break;
                    case word:
                        if (t.pos < text.length && is_word(text[t.pos]))
                            ++t.pos, ++t.ipc;
                        else
                            goto backtrack;
                        break;
                    case not_word:
                        if (t.pos < text.length && !is_word(text[t.pos]))
                            ++t.pos, ++t.ipc;
                        else
                            goto backtrack;
                        break;
                    case char_class:
                        if (t.pos < text.length && match_class(classes, ranges, inst.operand, text[t.pos]))
                            ++t.pos, ++t.ipc;
                        else
                            goto backtrack;
                        break;
                    case anchor_start:
                        if (t.pos == 0)
                            ++t.ipc;
                        else
                            goto backtrack;
                        break;
                    case anchor_end:
                        if (t.pos == text.length)
                            ++t.ipc;
                        else
                            goto backtrack;
                        break;
                    case group_open:
                        if (inst.operand < MaxGroups)
                            t.gs[inst.operand] = t.pos;
                        ++t.ipc;
                        break;
                    case group_close:
                        if (inst.operand < MaxGroups)
                            t.ge[inst.operand] = t.pos;
                        ++t.ipc;
                        break;
                    case split:
                        if (sp < stack.length)
                        {
                            stack[sp] = t;
                            if (inst.operand == 0)
                            {
                                stack[sp].ipc = inst.aux;
                                ++t.ipc;
                            }
                            else
                            {
                                stack[sp].ipc = cast(ushort)(t.ipc + 1);
                                t.ipc = inst.aux;
                            }
                            ++sp;
                        }
                        else
                            goto backtrack;
                        break;
                    case jump:
                        t.ipc = inst.aux;
                        break;
                    case Op.match:
                        matched = true;
                        break;
                }

                if (matched)
                    break;
                continue;

            backtrack:
                if (sp == 0)
                    break;
                t = stack[--sp];
            }

            if (matched)
            {
                result.full = text[start .. t.pos];
                result.num_captures = 0;
                foreach (g; 0 .. hdr.num_groups)
                {
                    if (g >= MaxGroups)
                        break;
                    if (t.gs[g] != ushort.max && t.ge[g] != ushort.max)
                    {
                        result.captures[g] = text[t.gs[g] .. t.ge[g]];
                        result.num_captures = cast(ubyte)(g + 1);
                    }
                    else
                        result.captures[g] = null;
                }
                return true;
            }
        }

        return false;
    }

private:
    const(ubyte)[] data; // Header ~ Inst[] ~ ClassRange[] ~ ClassDef[]

    struct Header
    {
        ushort num_insts;
        ubyte num_classes;
        ubyte num_ranges;
        ubyte num_groups;
        bool anchored;
    }

    enum Op : ubyte
    {
        literal, any, digit, not_digit, space, not_space, word, not_word,
        char_class, anchor_start, anchor_end, group_open, group_close,
        split, jump, match,
    }

    struct Inst
    {
        Op op;
        ubyte operand;
        ushort aux;
    }

    struct ClassRange
    {
        char lo, hi;
    }

    struct ClassDef
    {
        ubyte start, count;
        bool negated;
    }

    static bool is_digit(char ch) { return ch >= '0' && ch <= '9'; }
    static bool is_space(char ch) { return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'; }
    static bool is_word(char ch) { return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || is_digit(ch) || ch == '_'; }

    static bool match_class(const(ClassDef)[] classes, const(ClassRange)[] ranges, ubyte idx, char ch)
    {
        if (idx >= classes.length)
            return false;
        ref const ClassDef cd = classes[idx];
        bool found = false;
        foreach (i; cd.start .. cd.start + cd.count)
        {
            if (ch >= ranges[i].lo && ch <= ranges[i].hi)
            {
                found = true;
                break;
            }
        }
        return cd.negated ? !found : found;
    }
}


Regex regex_compile(const(char)[] pattern, NoGCAllocator allocator = defaultAllocator())
{
    import urt.mem : memcpy;

    alias Op = Regex.Op;
    alias Inst = Regex.Inst;
    alias ClassRange = Regex.ClassRange;
    alias ClassDef = Regex.ClassDef;

    // TODO: replace these stack buffers with Array!N when it works...
    Inst[256] code = void;
    ClassRange[128] class_ranges = void;
    ClassDef[32] class_defs = void;
    ubyte num_classes, total_ranges, num_groups;
    ushort pc;
    bool anchored;

    bool emit(Op op, ubyte operand = 0, ushort aux = 0)
    {
        if (pc >= code.length - 1)
            return false;
        code[pc++] = Inst(op, operand, aux);
        return true;
    }

    bool shift_code(ushort start, ushort end, ushort n)
    {
        if (end + n >= code.length)
            return false;
        for (ushort i = cast(ushort)(end + n - 1); i >= start + n; --i)
            code[i] = code[cast(ushort)(i - n)];
        for (ushort i = 0; i < end + n; ++i)
        {
            if (code[i].op == Op.split || code[i].op == Op.jump)
            {
                if (code[i].aux >= start && code[i].aux < end)
                    code[i].aux += n;
            }
        }
        pc += n;
        return true;
    }

    struct GroupFrame
    {
        ushort group_pc;
        ubyte group_id;
        ubyte num_jumps;
        ushort[8] jump_pcs;
        ushort last_split;
        bool has_alt;
    }
    GroupFrame[16] gframes = void;
    ubyte gdepth;

    Regex fail;

    size_t pi = 0;
    while (pi < pattern.length)
    {
        ushort atom_start = pc;
        char c = pattern[pi++];

        switch (c)
        {
            case '^':
                if (!emit(Op.anchor_start))
                    return fail;
                continue;
            case '$':
                if (!emit(Op.anchor_end))
                    return fail;
                continue;

            case '|':
            {
                // Alternation: a|b|c compiles as cascading splits:
                //   split(alt1, L1) → alt1 → jump(end) → L1: split(alt2, L2) → alt2 → jump(end) → L2: alt3 → end
                // First | inserts a split before alt1. Subsequent | patch the previous split's aux.
                if (gdepth == 0)
                    return fail;
                ref GroupFrame gf = gframes[gdepth - 1];

                // Emit jump to skip over remaining alternatives (patched at ')')
                if (!emit(Op.jump))
                    return fail;
                if (gf.num_jumps < gf.jump_pcs.length)
                    gf.jump_pcs[gf.num_jumps++] = cast(ushort)(pc - 1);

                // Insert a split before the current alternative.
                // For a|b: split(a, b). For a|b|c: split(a, split(b, c)).
                // Each | inserts a split before its preceding alternative that
                // points forward to the next one.
                {
                    // Find where the current alternative started — it's right after
                    // the previous split (or after group_open for the first alt).
                    ushort split_pos;
                    if (!gf.has_alt)
                        split_pos = cast(ushort)(gf.group_pc + 1); // after group_open
                    else
                        split_pos = cast(ushort)(gf.last_split + 1); // after previous split

                    if (!shift_code(split_pos, pc, 1))
                        return fail;
                    code[split_pos] = Inst(Op.split, 0, pc); // aux = start of next alt
                    gf.last_split = split_pos;

                    // Fix jump_pcs that shifted
                    foreach (ref jp; gf.jump_pcs[0 .. gf.num_jumps])
                    {
                        if (jp >= split_pos)
                            ++jp;
                    }
                }
                gf.has_alt = true;
                continue;
            }

            case '.':
                if (!emit(Op.any))
                    return fail;
                break;

            case '\\':
                if (pi >= pattern.length)
                    return fail;
                switch (pattern[pi++])
                {
                    case 'd':
                        if (!emit(Op.digit))
                            return fail;
                        break;
                    case 'D':
                        if (!emit(Op.not_digit))
                            return fail;
                        break;
                    case 's':
                        if (!emit(Op.space))
                            return fail;
                        break;
                    case 'S':
                        if (!emit(Op.not_space))
                            return fail;
                        break;
                    case 'w':
                        if (!emit(Op.word))
                            return fail;
                        break;
                    case 'W':
                        if (!emit(Op.not_word))
                            return fail;
                        break;
                    default:
                        if (!emit(Op.literal, cast(ubyte)pattern[pi-1]))
                            return fail;
                        break;
                }
                break;

            case '[':
            {
                if (num_classes >= class_defs.length)
                    return fail;
                bool negated = pi < pattern.length && pattern[pi] == '^';
                if (negated)
                    ++pi;
                ubyte rs = total_ranges;
                while (pi < pattern.length && pattern[pi] != ']')
                {
                    if (total_ranges >= class_ranges.length)
                        return fail;
                    char lo = pattern[pi++];
                    if (lo == '\\' && pi < pattern.length)
                        lo = pattern[pi++];
                    if (pi + 1 < pattern.length && pattern[pi] == '-' && pattern[pi+1] != ']')
                    {
                        ++pi;
                        char hi = pattern[pi++];
                        if (hi == '\\' && pi < pattern.length)
                            hi = pattern[pi++];
                        class_ranges[total_ranges++] = ClassRange(lo, hi);
                    }
                    else
                        class_ranges[total_ranges++] = ClassRange(lo, lo);
                }
                if (pi < pattern.length)
                    ++pi;
                class_defs[num_classes] = ClassDef(rs, cast(ubyte)(total_ranges - rs), negated);
                if (!emit(Op.char_class, num_classes++))
                    return fail;
                break;
            }

            case '(':
            {
                if (gdepth >= gframes.length)
                    return fail;
                ubyte gid = num_groups++;
                gframes[gdepth] = GroupFrame.init;
                gframes[gdepth].group_id = gid;
                gframes[gdepth].group_pc = pc;
                ++gdepth;
                if (!emit(Op.group_open, gid))
                    return fail;
                continue;
            }

            case ')':
            {
                if (gdepth == 0)
                    return fail;
                --gdepth;
                ref GroupFrame gf = gframes[gdepth];

                // Patch all | jumps to land on the group_close (not past it)
                foreach (ref jp; gf.jump_pcs[0 .. gf.num_jumps])
                    code[jp].aux = pc;

                if (!emit(Op.group_close, gf.group_id))
                    return fail;

                atom_start = gf.group_pc;
                break;
            }

            default:
                if (!emit(Op.literal, cast(ubyte)c))
                    return fail;
                break;
        }

        // Quantifier
        if (pi < pattern.length && (pattern[pi] == '*' || pattern[pi] == '+' || pattern[pi] == '?'))
        {
            char q = pattern[pi++];
            bool is_lazy = pi < pattern.length && pattern[pi] == '?';
            if (is_lazy)
                ++pi;

            ushort body_start = atom_start;
            ushort body_end = pc;
            ubyte lazy_flag = is_lazy ? 1 : 0;

            if (q == '*')
            {
                if (!shift_code(body_start, body_end, 1))
                    return fail;
                ushort after = cast(ushort)(pc + 1);
                code[body_start] = Inst(Op.split, lazy_flag, after);
                if (!emit(Op.jump, 0, body_start))
                    return fail;
            }
            else if (q == '+')
            {
                if (!emit(Op.split, lazy_flag, cast(ushort)(pc + 1)))
                    return fail;
                code[pc - 1] = Inst(Op.split, lazy_flag, cast(ushort)(pc + 1));
                if (!emit(Op.jump, 0, body_start))
                    return fail;
            }
            else // '?'
            {
                if (!shift_code(body_start, body_end, 1))
                    return fail;
                code[body_start] = Inst(Op.split, lazy_flag, pc);
            }
        }
    }

    if (gdepth != 0)
        return fail; // unclosed group

    if (!emit(Op.match))
        return fail;

    anchored = pattern.length > 0 && pattern[0] == '^';

    // Pack into single allocation: Header ~ Inst[pc] ~ ClassRange[total_ranges] ~ ClassDef[num_classes]
    size_t size = Regex.Header.sizeof + pc * Inst.sizeof + total_ranges * ClassRange.sizeof + num_classes * ClassDef.sizeof;
    ubyte[] buf = cast(ubyte[])allocator.alloc(size);
    if (!buf)
        return fail;

    Regex.Header* hdr = cast(Regex.Header*)buf.ptr;
    hdr.num_insts = pc;
    hdr.num_classes = num_classes;
    hdr.num_ranges = total_ranges;
    hdr.num_groups = num_groups;
    hdr.anchored = anchored;

    size_t off = Regex.Header.sizeof;
    memcpy(buf.ptr + off, code.ptr, pc * Inst.sizeof);
    off += pc * Inst.sizeof;
    memcpy(buf.ptr + off, class_ranges.ptr, total_ranges * ClassRange.sizeof);
    off += total_ranges * ClassRange.sizeof;
    memcpy(buf.ptr + off, class_defs.ptr, num_classes * ClassDef.sizeof);

    Regex result;
    result.data = cast(const(ubyte)[])buf;
    return result;
}


unittest
{
    RegexMatch m;

    // -- Literals --

    assert(regex_match("hello world", "world", m));
    assert(m.full == "world");
    assert(m.num_captures == 0);

    assert(regex_match("abc", "abc", m));
    assert(m.full == "abc");

    assert(!regex_match("hello world", "xyz", m));

    // match at start, middle, end
    assert(regex_match("abc", "a", m));
    assert(m.full == "a");
    assert(regex_match("abc", "b", m));
    assert(m.full == "b");
    assert(regex_match("abc", "c", m));
    assert(m.full == "c");

    // -- Dot (any char) --

    assert(regex_match("abc", "a.c", m));
    assert(m.full == "abc");

    assert(!regex_match("ac", "a.c", m)); // dot requires exactly one char

    assert(regex_match("a\tc", "a.c", m)); // dot matches tab
    assert(m.full == "a\tc");

    // -- Character classes --

    assert(regex_match("test123", "[0-9]+", m));
    assert(m.full == "123");

    assert(regex_match("abc123", "[^a-z]+", m)); // negated
    assert(m.full == "123");

    assert(regex_match("x", "[xyz]", m));
    assert(m.full == "x");

    assert(!regex_match("a", "[xyz]", m));

    assert(regex_match("B", "[A-Za-z]", m)); // multiple ranges
    assert(m.full == "B");

    assert(regex_match("-", "[a\\-z]", m)); // escaped - in class
    assert(m.full == "-");

    // -- Escape sequences --

    assert(regex_match("foo 42 bar", `\d+`, m));
    assert(m.full == "42");

    assert(regex_match("hello world", `\w+`, m));
    assert(m.full == "hello");

    assert(regex_match("key: value", `\s+`, m));
    assert(m.full == " ");

    // negated escapes
    assert(regex_match("abc 123", `\D+`, m));
    assert(m.full == "abc ");

    assert(regex_match("abc 123", `\S+`, m));
    assert(m.full == "abc");

    assert(regex_match(" abc", `\W+`, m));
    assert(m.full == " ");

    // escaped special characters
    assert(regex_match("a.b", `a\.b`, m));
    assert(m.full == "a.b");

    assert(!regex_match("axb", `a\.b`, m));

    assert(regex_match("(hi)", `\(hi\)`, m));
    assert(m.full == "(hi)");

    assert(regex_match("a*b", `a\*b`, m));
    assert(m.full == "a*b");

    assert(regex_match("a|b", `a\|b`, m));
    assert(m.full == "a|b");

    assert(regex_match("a\\b", `a\\b`, m));
    assert(m.full == "a\\b");

    assert(regex_match("[x]", `\[x\]`, m));
    assert(m.full == "[x]");

    // -- Anchors --

    assert(regex_match("hello", "^hello$", m));
    assert(m.full == "hello");

    assert(!regex_match("say hello", "^hello", m));
    assert(regex_match("say hello", "hello$", m));
    assert(m.full == "hello");

    assert(!regex_match("hello!", "^hello$", m));

    // ^ on empty string
    assert(regex_match("", "^$", m));
    assert(m.full == "");

    // -- Simple groups (no alternation) --

    assert(regex_match("abc", "(abc)", m));
    assert(m.full == "abc");
    assert(m.num_captures == 1);
    assert(m.captures[0] == "abc");

    assert(regex_match("abc", "a(b)c", m));
    assert(m.full == "abc");
    assert(m.captures[0] == "b");

    // -- Alternation --

    // two branches
    assert(regex_match("true", "(true|false)", m));
    assert(m.captures[0] == "true");

    assert(regex_match("false", "(true|false)", m));
    assert(m.captures[0] == "false");

    assert(!regex_match("maybe", "^(true|false)$", m));

    // three branches
    assert(regex_match("red", "(red|green|blue)", m));
    assert(m.captures[0] == "red");

    assert(regex_match("green", "(red|green|blue)", m));
    assert(m.captures[0] == "green");

    assert(regex_match("blue", "(red|green|blue)", m));
    assert(m.captures[0] == "blue");

    assert(!regex_match("yellow", "^(red|green|blue)$", m));

    // alternation with shared prefix/suffix
    assert(regex_match("foobar", "(foo|foobar)", m));
    // greedy: tries foo first, succeeds — but we're not anchored, so full match is "foo"
    assert(m.captures[0] == "foo");

    // alternation with surrounding literal
    assert(regex_match("catdog", "cat(and|or)?dog", m)); // no "and"/"or", ? makes it optional
    assert(m.full == "catdog");

    assert(regex_match("catanddog", "cat(and|or)dog", m));
    assert(m.captures[0] == "and");

    assert(regex_match("catordog", "cat(and|or)dog", m));
    assert(m.captures[0] == "or");

    // -- Greedy quantifiers: *, +, ? --

    // * — zero or more
    assert(regex_match("aaa", "a*", m));
    assert(m.full == "aaa");

    assert(regex_match("bbb", "a*", m)); // zero-length match at start
    assert(m.full == "");

    assert(regex_match("", "a*", m)); // empty string, zero-length match
    assert(m.full == "");

    // + — one or more
    assert(regex_match("aaa", "a+", m));
    assert(m.full == "aaa");

    assert(!regex_match("bbb", "a+", m));

    assert(regex_match("baaab", "a+", m));
    assert(m.full == "aaa");

    // ? — zero or one
    assert(regex_match("colour", "colou?r", m));
    assert(m.full == "colour");

    assert(regex_match("color", "colou?r", m));
    assert(m.full == "color");

    // greedy * consumes as much as possible
    assert(regex_match("<b>bold</b>", "<.*>", m));
    assert(m.full == "<b>bold</b>");

    // -- Lazy quantifiers: *?, +?, ?? --

    // lazy * — shortest match
    assert(regex_match("<b>bold</b>", "<.*?>", m));
    assert(m.full == "<b>");

    // lazy + — at least one, but shortest
    assert(regex_match("aaa", "a+?", m));
    assert(m.full == "a");

    // lazy ? — prefer zero
    assert(regex_match("ab", "a??b", m));
    assert(m.full == "ab"); // a?? tries empty first but needs 'b', backtracks to 'a'

    // -- Quantifier on groups --

    // group with +
    assert(regex_match("ababab", "(ab)+", m));
    assert(m.full == "ababab");
    // last capture of the repeated group
    assert(m.captures[0] == "ab");

    // group with *
    assert(regex_match("xyzxyz", "(xyz)*", m));
    assert(m.full == "xyzxyz");

    // group with ?
    assert(regex_match("foobar", "(foo)?bar", m));
    assert(m.full == "foobar");
    assert(m.captures[0] == "foo");

    assert(regex_match("bar", "(foo)?bar", m));
    assert(m.full == "bar");

    // alternation group with quantifier
    assert(regex_match("abcabc", "(abc|def)+", m));
    assert(m.full == "abcabc");

    assert(regex_match("abcdef", "(abc|def)+", m));
    assert(m.full == "abcdef");

    // -- Nested groups --

    assert(regex_match("abc", "((a)(b)(c))", m));
    assert(m.num_captures == 4);
    assert(m.captures[0] == "abc"); // outer group
    assert(m.captures[1] == "a");
    assert(m.captures[2] == "b");
    assert(m.captures[3] == "c");

    // nested with alternation
    assert(regex_match("ab", "((a|x)(b|y))", m));
    assert(m.captures[0] == "ab");
    assert(m.captures[1] == "a");
    assert(m.captures[2] == "b");

    // -- Quantifier + class interactions --

    assert(regex_match("abc123def", "[a-z]+", m));
    assert(m.full == "abc");

    assert(regex_match("abc123def", "[a-z]+?", m)); // lazy
    assert(m.full == "a");

    assert(regex_match("123", "[0-9]?", m));
    assert(m.full == "1");

    assert(regex_match("abc", "[0-9]?", m)); // zero-length match
    assert(m.full == "");

    // -- Quantifier + escape interactions --

    assert(regex_match("  \t  ", `\s+`, m));
    assert(m.full == "  \t  ");

    assert(regex_match("hello123world", `\w+\d+\w+`, m));
    assert(m.full == "hello123world");

    // -- Complex scraping patterns --

    assert(regex_match("voltage: 52.3V", `voltage:\s*(\d+\.\d+)`, m));
    assert(m.captures[0] == "52.3");

    assert(regex_match("<td>active</td>", `<td>(\w+)</td>`, m));
    assert(m.captures[0] == "active");

    assert(regex_match("power: 1500W", `power:\s*(\d+)`, m));
    assert(m.captures[0] == "1500");

    assert(regex_match("temp=25.6C", `temp=(\d+\.?\d*)`, m));
    assert(m.captures[0] == "25.6");

    // multiple captures in a real pattern
    assert(regex_match("error 404: not found", `(\w+)\s+(\d+):\s+(.+)`, m));
    assert(m.num_captures == 3);
    assert(m.captures[0] == "error");
    assert(m.captures[1] == "404");
    assert(m.captures[2] == "not found");

    // key=value extraction
    assert(regex_match("host=192.168.1.1 port=502", `(\w+)=(\S+)`, m));
    assert(m.captures[0] == "host");
    assert(m.captures[1] == "192.168.1.1");

    // CSV-like: extract fields
    assert(regex_match("42,hello,true", `^(\d+),(\w+),(true|false)`, m));
    assert(m.captures[0] == "42");
    assert(m.captures[1] == "hello");
    assert(m.captures[2] == "true");

    // -- Compile once, match many --

    Regex re = regex_compile(`(\d+)\s*([A-Z]+)`);
    assert(re.valid);

    assert(re.exec("reading: 42 V", m));
    assert(m.num_captures == 2);
    assert(m.captures[0] == "42");
    assert(m.captures[1] == "V");

    assert(re.exec("other: 100 MW", m));
    assert(m.captures[0] == "100");
    assert(m.captures[1] == "MW");

    assert(!re.exec("no numbers here", m));

    // -- Edge cases --

    // empty text, empty pattern
    assert(regex_match("", "", m));
    assert(m.full == "");

    // empty pattern matches empty at start of any text
    assert(regex_match("abc", "", m));
    assert(m.full == "");

    // no captures
    assert(regex_match("abc", `\w+`, m));
    assert(m.num_captures == 0);

    // unmatched parens should fail to compile
    assert(!regex_compile("abc)").valid);
    assert(!regex_compile("(abc").valid);

    // pattern with only anchors
    assert(regex_match("", "^$", m));
    assert(!regex_match("x", "^$", m));

    // .* at start — heavy backtracking but should work
    assert(regex_match("the end", ".*end", m));
    assert(m.full == "the end");

    // .* with capture
    assert(regex_match("key: value here", `(\w+):\s*(.*)$`, m));
    assert(m.captures[0] == "key");
    assert(m.captures[1] == "value here");

    // single char edge
    assert(regex_match("x", "x", m));
    assert(m.full == "x");

    assert(!regex_match("", "x", m));

    // quantifier on dot
    assert(regex_match("abc", ".+", m));
    assert(m.full == "abc");

    assert(regex_match("a", ".+", m));
    assert(m.full == "a");

    assert(!regex_match("", ".+", m));

    assert(regex_match("", ".*", m));
    assert(m.full == "");
}
