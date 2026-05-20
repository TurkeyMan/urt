module urt.mem.alloc;

import urt.mem;

nothrow @nogc:


enum MemFlags : ubyte
{
    none     = 0,

    // Speed bits are placement *preferences*
    fast     = 1,   // prefer internal SRAM
    slow     = 2,   // prefer external PSRAM
    fastest  = 3,   // prefer TCM (single-cycle), else internal SRAM

    dma      = 0x4, // DMA-accessible (hard requirement)
}

MemFlags mem_speed(MemFlags flags) pure => cast(MemFlags)(flags & 3);
bool mem_is_dma(MemFlags flags) pure => (flags & MemFlags.dma) != 0;


void[] alloc(size_t size, MemFlags flags = MemFlags.none) pure
    => alloc(size, size_t.sizeof, flags);

void[] alloc(size_t size, size_t alignment, MemFlags flags = MemFlags.none) pure
{
    import urt.util : is_power_of_2;

    assert(is_power_of_2(alignment), "Alignment must be a power of two!");

    void[] mem = _alloc(size, alignment, flags);
    version (AllocTracking)
    {
        import urt.mem.tracking : track_alloc;
        if (mem.ptr !is null)
        {
            alias TrackFn = void function(void*, size_t) pure nothrow @nogc;
            (cast(TrackFn) &track_alloc)(mem.ptr, mem.length);
        }
    }
    return mem;
}

void[] realloc(void[] mem, size_t new_size, size_t alignment = 8, MemFlags flags = MemFlags.none) pure
{
    import urt.util : min;

    if (new_size == 0)
    {
        free(mem);
        return null;
    }
    if (mem.ptr is null)
        return alloc(new_size, alignment, flags);

    static if (has_realloc)
    {
        void* old_ptr = mem.ptr;
        void[] new_mem = _realloc(mem, new_size, alignment, flags);
        version (AllocTracking)
        {
            import urt.mem.tracking : track_realloc;
            if (new_mem.ptr !is null)
            {
                alias TrackFn = void function(void*, void*, size_t) pure nothrow @nogc;
                (cast(TrackFn) &track_realloc)(old_ptr, new_mem.ptr, new_mem.length);
            }
        }
        return new_mem;
    }
    else
    {
        // Fallback path uses nested alloc/free, which are already hooked.
        void[] new_mem = alloc(new_size, alignment, flags);
        if (new_mem.ptr !is null)
        {
            size_t copy = min(mem.length, new_size);
            new_mem[0 .. copy] = mem[0 .. copy];
        }
        free(mem);
        return new_mem;
    }
}

void free(void[] mem) pure
{
    if (mem.ptr is null)
        return;
    version (AllocTracking)
    {
        import urt.mem.tracking : untrack_alloc;
        alias UntrackFn = void function(void*) pure nothrow @nogc;
        (cast(UntrackFn) &untrack_alloc)(mem.ptr);
    }
    _free(mem.ptr);
}

void[] expand(void[] mem, size_t new_size) pure
{
    if (mem.ptr is null)
        return null;
    static if (has_expand)
        return _expand(mem, new_size);
    else static if (has_memsize)
    {
        if (new_size <= _memsize(mem.ptr))
            return mem.ptr[0 .. new_size];
        return null;
    }
    else
        assert(false, "unsupported");
}

size_t memsize(void* ptr) pure
{
    if (ptr is null)
        return 0;
    static if (has_memsize)
        return _memsize(ptr);
    else
        assert(false, "unsupported");
}

void[] alloc_exec(size_t size) pure
{
    static if (has_exec)
        return _alloc_exec(size);
    else
        return null;
}

void free_exec(void[] mem) pure
{
    static if (has_exec)
    {
        if (mem.ptr !is null)
            _free_exec(mem);
    }
}

void[] alloc_retain(size_t size) pure
{
    static if (has_retain)
        return _alloc_retain(size);
    else
        return null;
}

void free_retain(void[] mem) pure
{
    static if (has_retain)
    {
        if (mem.ptr !is null)
            _free_retain(mem);
    }
}


// pointer tagging utilities -- for containers to store flags in low 3 bits
// of 8-byte aligned pointers. the allocator itself returns clean pointers.
T* tag(T)(T* ptr, MemFlags flags) pure
    => cast(T*)(cast(size_t)ptr | flags);

T* untag(T)(T* ptr) pure
    => cast(T*)(cast(size_t)ptr & ~cast(size_t)0x7);

MemFlags get_flags(void* ptr) pure
    => cast(MemFlags)(cast(size_t)ptr & 0x7);


version (Espressif)
    public import urt.driver.esp32.alloc;
else version (Bouffalo)
    public import urt.driver.bl_common.alloc;
else version (RP2350)
    public import urt.driver.rp2350.alloc;
else version (BK7231N)
    public import urt.driver.bk7231.alloc;
else version (BK7231T)
    public import urt.driver.bk7231.alloc;
else version (STM32F4)
    public import urt.driver.stm32.alloc;
else version (STM32F7)
    public import urt.driver.stm32.alloc;
else version (Windows)
    public import urt.driver.windows.alloc;
else version (Posix)
    public import urt.driver.posix.alloc;
else
    static assert(false, "No alloc driver for this platform");


unittest
{
    // basic alloc/free
    void[] mem = alloc(32, 8);
    assert(mem !is null);
    assert((cast(size_t)mem.ptr & 0x7) == 0); // 8-byte aligned
    assert(mem.length == 32);
    free(mem);

    // alloc with flags (on desktop, flags are ignored but API works)
    mem = alloc(64, 8, MemFlags.fast);
    assert(mem !is null);
    size_t s = memsize(mem.ptr);
    assert(s >= 64);
    free(mem);

    // realloc preserves data
    mem = alloc(16, 8);
    (cast(ubyte*)mem.ptr)[0 .. 16] = 0xAB;
    mem = realloc(mem, 64);
    assert(mem !is null);
    assert((cast(ubyte*)mem.ptr)[0] == 0xAB);
    free(mem);

    // expand
    mem = alloc(16, 8);
    void[] expanded = expand(mem, 8);
    if (expanded !is null)
        assert(expanded.ptr is mem.ptr);
    free(mem);

    // pointer tagging utilities
    void* p = mem.ptr;
    enum test_flags = cast(MemFlags)(MemFlags.fast | MemFlags.dma);
    void* tagged = tag(p, test_flags);
    assert(get_flags(tagged) == test_flags);
    assert(untag(tagged) is p);
}
