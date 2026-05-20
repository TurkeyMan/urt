module urt.mem.temp;

import urt.attribute : fast_data;
import urt.mem;

version = DebugTempAlloc;

nothrow @nogc:

enum size_t TempMemSize = 4096;


void[] talloc(size_t size) pure
{
    debug version (DebugTempAlloc)
    {
        import urt.string.format : InFormatFunction;
        assert(InFormatFunction == false, "It is illegal to use the temp allocator inside string conversion functions. Consider using stack or scratchpad.");
    }

    assert(size <= TempMemSize / 2, "Requested temp memory size is too large");

    void[] mem = tmem_tail();
    if (mem.length < size)
        mem = tmem_reset();
    tmem_advance(size);
    return mem[0 .. size];
}

void[] talloc_aligned(size_t size, size_t alignment) pure
{
    import urt.util;

    debug assert(alignment != 0 && is_power_of_2(alignment), "alignment must be a power of two");
    assert(size <= TempMemSize / 2, "Requested temp memory size is too large");

    void[] mem = tmem_tail();
    auto ptr = align_up(mem.ptr, alignment);
    size_t adjust = ptr - mem.ptr;
    if (adjust + size > mem.length)
    {
        mem = tmem_reset();
        ptr = align_up(mem.ptr, alignment);
        adjust = ptr - mem.ptr;
    }
    tmem_advance(adjust + size);
    return ptr[0 .. size];
}

void[] trealloc(void[] mem, size_t newSize) pure
{
    if (newSize <= mem.length)
        return mem[0 .. newSize];
    void[] r = texpand(mem, newSize);
    if (!r)
    {
        r = talloc(newSize);
        if (r !is null)
            r[0 .. mem.length] = mem[];
    }
    return r;
}

void[] trealloc_aligned(void[] mem, size_t newSize, size_t alignment) pure
{
    assert(false);
}

void[] texpand(void[] mem, size_t newSize) pure
{
    void[] tmem = tmem_tail();
    if (mem.ptr + mem.length != tmem.ptr)
        return null;
    ptrdiff_t grow = newSize - mem.length;
    if (grow > tmem.length)
        return null;
    tmem_advance(grow);
    return mem.ptr[0 .. newSize];
}

void tfree(void[] mem) pure
{
    // maybe do some debug accounting...?
}

char* tstringz(const(char)[] str) pure
{
    char* r = cast(char*)talloc(str.length + 1).ptr;
    r[0 .. str.length] = str[];
    r[str.length] = '\0';
    return r;
}
char* tstringz(const(wchar)[] str) pure
{
    import urt.string.uni : uni_convert;
    char* r = cast(char*)talloc(str.length*3 + 1).ptr;
    size_t len = uni_convert(str, r[0 .. str.length*3]);
    r[len] = '\0';
    return r;
}

wchar* twstringz(const(char)[] str) pure
{
    import urt.string.uni : uni_convert;
    wchar* r = cast(wchar*)talloc(str.length*2 + 2).ptr;
    size_t len = uni_convert(str, r[0 .. str.length]);
    r[len] = '\0';
    return r;
}
wchar* twstringz(const(wchar)[] str) pure
{
    wchar* r = cast(wchar*)talloc(str.length*2 + 2).ptr;
    r[0 .. str.length] = str[];
    r[str.length] = '\0';
    return r;
}

const(char)[] tstring(T)(auto ref T value)
{
    import urt.string, urt.array;
    static if (is(T : const(char)[]) || is(T : const String) || is(T : const MutableString!N, size_t N) || is(T : const Array!char))
    {
        pragma(inline, true);
        return value[];
    }
    else
    {
        import urt.string.format : toString;
        char[] tmem = cast(char[])tmem_tail();
        ptrdiff_t r = toString(value, tmem);
        if (r < 0)
        {
            tmem = cast(char[])tmem_reset();
            r = toString(value, tmem);
            if (r < 0)
            {
//                assert(false, "Formatted string is too large for the temp buffer!");
                return null;
            }
        }
        const(char)[] result = tmem[0 .. r];
        tmem_advance(r);
        return result;
    }
}

const(dchar)[] tdstring(T)(auto ref T value)
{
    static if (is(T : const(char)[]) || is(T : const(wchar)[]) || is(T : const(dchar)[]))
        alias s = value;
    else
        char[] s = tstring(value);
    import urt.string.uni : uni_convert;
    dchar* r = cast(dchar*)talloc(s[].length*4).ptr;
    size_t len = uni_convert(s[], r[0 .. s.length]);
    return r[0 .. len];
}

const(char)[] tconcat(Args...)(ref Args args)
{
    import urt.string, urt.array;
    static if (Args.length == 1 && (is(Args[0] : const(char)[]) || is(Args[0] : const String) || is(Args[0] : const MutableString!N, size_t N) || is(Args[0] : const Array!char)))
    {
        pragma(inline, true);
        return args[0][];
    }
    else
    {
        pragma(inline, true);
        import urt.string.format : normalise_args;
        return tconcat_impl(normalise_args(args));
    }
}

import urt.meta.tuple : Tuple;
const(char)[] tconcat_impl(Args...)(Tuple!Args args)
{
    import urt.string.format : concat_impl;
    const(char)[] r = concat_impl(cast(char[])tempMem[alloc_offset..$], args);
    if (!r)
    {
        alloc_offset = 0;
        r = concat_impl(cast(char[])tempMem[0..TempMemSize / 2], args);
    }
    alloc_offset += r.length;
    return r;
}


char[] tformat(Args...)(const(char)[] fmt, ref Args args)
{
    import urt.string.format : format;
    char[] r = format(cast(char[])tempMem[alloc_offset..$], fmt, args);
    if (!r)
    {
        alloc_offset = 0;
        r = format(cast(char[])tempMem[0..TempMemSize / 2], fmt, args);
    }
    alloc_offset += r.length;
    return r;
}


class TempAllocator : NoGCAllocator
{
    static import urt.mem.alloc;
nothrow @nogc:

    static TempAllocator instance() pure
    {
        alias PureHack = TempAllocator function() pure nothrow @nogc;
        static TempAllocator hack() nothrow @nogc => _instance;
        return (cast(PureHack)&hack)();
    }

    override void[] alloc(size_t bytes, size_t alignment = DefaultAlign) pure
    {
        return talloc_aligned(bytes, alignment);
    }

    override void[] realloc(void[] mem, size_t newSize, size_t alignment = DefaultAlign) pure
    {
        return trealloc(mem, newSize);
        // TODO...
//        return realloc(mem.ptr, newSize)[0..newSize];
        return null;
    }

    override void[] expand(void[] mem, size_t newSize) pure
    {
        return texpand(mem, newSize);
    }

    override void free(void[] mem) pure
    {
        tfree(mem);
    }

private:
    __gshared TempAllocator _instance = new TempAllocator;
}


private:

// TODO: we shpuld really have some indicator if the machine is multi-core or not...
//       this is doomed the moment we light up the esp32's second core!
version (BareMetal)
{
    @fast_data align(size_t.alignof) __gshared void[TempMemSize] tempMem;
    @fast_data __gshared ushort alloc_offset = 0;
}
else
{
    align(size_t.alignof) static void[TempMemSize] tempMem;
    static ushort alloc_offset = 0;
}

void[] tmem_tail() pure
{
    static void[] impl() nothrow @nogc
        => tempMem[alloc_offset..$];
    alias PureHack = void[] function() pure nothrow @nogc;
    return (cast(PureHack)&impl)();
}

void[] tmem_reset() pure
{
    static void[] impl() nothrow @nogc
    {
        alloc_offset = 0;
        return tempMem[0..TempMemSize / 2];
    }
    alias PureHack = void[] function() pure nothrow @nogc;
    return (cast(PureHack)&impl)();
}

void tmem_advance(size_t n) pure
{
    static void impl(ushort n) nothrow @nogc
    {
        alloc_offset += n;
    }
    alias PureHack = void function(ushort) pure nothrow @nogc;
    return (cast(PureHack)&impl)(cast(ushort)n);
}
