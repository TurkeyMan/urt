// =====================================================================
// Bouffalo unified multi-pool allocator (TLSF-backed)
//
// Shared across BL618, BL808 D0, and BL808 M0. Per-chip pool topology
// is selected by version branches inside; the public API and CRT
// overrides are identical across chips.
//
// Pool topologies (target end state):
//   BL618:        DTCM (64K, fastest) + OCRAM (480K, fast/slow/dma)
//   BL808 D0:     SRAM (64K, fastest/fast/dma) + PSRAM (61M, slow)
//   BL808 M0:     DTCM (4K, fastest) + OCRAM (160K, fast/dma)
//                                    + PSRAM (1M, slow)
//
// The whole file is gated by `version (BouffaloUnifiedAlloc)`. A chip
// opts in only when ALL prerequisites are in place:
//   1. Its linker script emits __<region>_heap_start/end symbols for
//      every pool in its topology.
//   2. Its Makefile compiles TLSF (tlsf.c + tlsf.h vendored).
//   3. Its per-chip pool topology block below is filled in.
//   4. urt.mem.alloc routes the chip's version branch to this module.
//   5. The chip's old urt.driver.<chip>.alloc stub is deleted.
//
// CRT override notes (critical for any chip that opts in):
//
// This module overrides extern(C) malloc/free/calloc/realloc so picolibc
// dlmalloc never gets pulled in -- vendor C (libwifi.a etc.) and picolibc
// internals (printf %f, strdup) all route through TLSF. Picolibc strong-
// aliases the public malloc/free onto __malloc_malloc/__malloc_free and
// its internals call the prefixed names directly, so we override BOTH
// public and prefixed forms to keep malloc.c.o out of the link.
//
// The override IS the whole point of this module being a unified
// allocator -- but it also means any build that compiles this file
// with BouffaloUnifiedAlloc set MUST be ready to route every libc-side
// malloc call through TLSF. Half-migrated builds will corrupt their
// own allocator routing. Hence the explicit per-chip opt-in below.
// =====================================================================
module urt.driver.bl_common.alloc;


// Per-chip activation. Every Bouffalo build with linker pool symbols
// and TLSF compiled is enabled here.
version (BL808_M0) version = BouffaloUnifiedAlloc;
version (BL808)    version = BouffaloUnifiedAlloc;
version (BL618)    version = BouffaloUnifiedAlloc;

version (BouffaloUnifiedAlloc):


import urt.attribute : fast_data;
import urt.mem.alloc : MemFlags;

@nogc nothrow:


enum has_realloc  = true;
enum has_expand   = false;
enum has_memsize  = true;
enum has_exec     = false;
enum has_retain   = false;
enum has_memflags = true;


void[] _alloc(size_t size, size_t alignment, MemFlags flags) pure
{
    alias Fn = void[] function(size_t, size_t, MemFlags) pure nothrow @nogc;
    return (cast(Fn) &alloc_impl)(size, alignment, flags);
}

void[] _realloc(void[] mem, size_t new_size, size_t alignment, MemFlags flags) pure
{
    alias Fn = void[] function(void[], size_t, size_t, MemFlags) pure nothrow @nogc;
    return (cast(Fn) &realloc_impl)(mem, new_size, alignment, flags);
}

void _free(void* ptr) pure
{
    alias Fn = void function(void*) pure nothrow @nogc;
    (cast(Fn) &free_impl)(ptr);
}

size_t _memsize(void* ptr) pure
{
    return tlsf_block_size(ptr);
}


// CRT overrides -- see header. Both public and __malloc_-prefixed forms
// are defined so picolibc's malloc.c.o stays out of the link.
extern(C) void* malloc(size_t size) nothrow @nogc
{
    void[] m = alloc_impl(size, size_t.sizeof, MemFlags.none);
    return m.ptr;
}

extern(C) void free(void* ptr) nothrow @nogc
{
    free_impl(ptr);
}

pragma(mangle, "__malloc_malloc")
extern(C) void* malloc_internal(size_t size) nothrow @nogc
{
    return malloc(size);
}

pragma(mangle, "__malloc_free")
extern(C) void free_internal(void* ptr) nothrow @nogc
{
    free(ptr);
}

extern(C) void* calloc(size_t nmemb, size_t size) nothrow @nogc
{
    size_t total = nmemb * size;
    void[] m = alloc_impl(total, size_t.sizeof, MemFlags.none);
    if (m.ptr !is null)
        (cast(ubyte*) m.ptr)[0 .. total] = 0;
    return m.ptr;
}

extern(C) void* realloc(void* ptr, size_t size) nothrow @nogc
{
    if (ptr is null)
        return malloc(size);
    if (size == 0)
    {
        free_impl(ptr);
        return null;
    }
    // realloc_impl only reads mem.ptr; the slice length is irrelevant.
    void[] r = realloc_impl(ptr[0 .. 1], size, size_t.sizeof, MemFlags.none);
    return r.ptr;
}


// Pool count per chip (exposed so urt.system can size its loop).
version (BL808_M0) enum size_t num_pools = 3;
else version (BL808) enum size_t num_pools = 2;
else version (BL618) enum size_t num_pools = 2;
else static assert(false, "bl_common.alloc: unsupported chip");


// Per-pool runtime stats for sysinfo. `largest_free` walks the pool's
// free-list (O(blocks)) -- only call this from infrequent paths like the
// console sysinfo command, not from hot allocator code.
struct PoolStats
{
    immutable(char)* name;
    size_t total;
    size_t used;
    size_t peak_used;
    size_t largest_free;
}

void query_pool_stats(size_t idx, out PoolStats stats) nothrow @nogc
{
    init_pools();
    auto p = &_pools[idx];
    stats.name = p.name;
    stats.total = p.size;
    stats.used = p.used;
    stats.peak_used = p.peak_used;

    size_t largest = 0;
    tlsf_walk_pool(tlsf_get_pool(p.tlsf), &walker_max_free, &largest);
    stats.largest_free = largest;
}

private extern(C) void walker_max_free(void* ptr, size_t size, int used, void* user) nothrow @nogc
{
    if (used)
        return;
    auto lf = cast(size_t*)user;
    if (size > *lf)
        *lf = size;
}


private:


// =====================================================================
// Per-chip pool topology
//
// Each chip defines:
//   - pool index enum (DtcmIdx, OcramIdx, ...)
//   - num_pools
//   - linker boundary symbol externs
//   - pool_for(MemFlags) -> index of best-matching pool
//   - map_pools() -- populate _pools[] base/size/name from linker symbols
// =====================================================================

version (BL808_M0)
{
    enum size_t DtcmIdx  = 0;
    enum size_t OcramIdx = 1;
    enum size_t PsramIdx = 2;

    extern(C) extern __gshared
    {
        pragma(mangle, "__dtcm_heap_start")  void* _dtcm_heap_start;
        pragma(mangle, "__dtcm_heap_end")    void* _dtcm_heap_end;
        pragma(mangle, "__ocram_heap_start") void* _ocram_heap_start;
        pragma(mangle, "__ocram_heap_end")   void* _ocram_heap_end;
        pragma(mangle, "__psram_heap_start") void* _psram_heap_start;
        pragma(mangle, "__psram_heap_end")   void* _psram_heap_end;
    }

    size_t pool_for(MemFlags flags) nothrow @nogc
    {
        // DMA cannot reach DTCM (CPU-local bus) and PSRAM is not DMA-clean
        // on E907 -- so dma requests are pinned to OCRAM with no fallback.
        if (flags & MemFlags.dma)
            return OcramIdx;

        final switch (cast(MemFlags)(flags & 3))
        {
            case MemFlags.none:    return PsramIdx;
            case MemFlags.fast:    return OcramIdx;
            case MemFlags.slow:    return PsramIdx;
            case MemFlags.fastest: return DtcmIdx;
            case MemFlags.dma:     assert(false);
        }
    }

    void map_pools() nothrow @nogc
    {
        _pools[DtcmIdx].base  = cast(void*)&_dtcm_heap_start;
        _pools[DtcmIdx].size  = cast(size_t)&_dtcm_heap_end  - cast(size_t)&_dtcm_heap_start;
        _pools[DtcmIdx].name  = "TCM";
        _pools[OcramIdx].base = cast(void*)&_ocram_heap_start;
        _pools[OcramIdx].size = cast(size_t)&_ocram_heap_end - cast(size_t)&_ocram_heap_start;
        _pools[OcramIdx].name = "SRAM";
        _pools[PsramIdx].base = cast(void*)&_psram_heap_start;
        _pools[PsramIdx].size = cast(size_t)&_psram_heap_end - cast(size_t)&_psram_heap_start;
        _pools[PsramIdx].name = "PSRAM";
    }
}
else version (BL808)
{
    // BL808 D0 (C906) topology:
    //   SRAM  (64K)  fastest + fast + dma  (only fast on-chip SRAM, no DTCM)
    //   PSRAM (60M)  slow / default
    enum size_t SramIdx  = 0;
    enum size_t PsramIdx = 1;

    extern(C) extern __gshared
    {
        pragma(mangle, "__sram_heap_start")  void* _sram_heap_start;
        pragma(mangle, "__sram_heap_end")    void* _sram_heap_end;
        pragma(mangle, "__psram_heap_start") void* _psram_heap_start;
        pragma(mangle, "__psram_heap_end")   void* _psram_heap_end;
    }

    size_t pool_for(MemFlags flags) nothrow @nogc
    {
        // D0 has no DTCM; SRAM is the fastest available memory and is
        // also DMA-reachable from the D0-side bus matrix.
        if (flags & MemFlags.dma)
            return SramIdx;

        final switch (cast(MemFlags)(flags & 3))
        {
            case MemFlags.none:    return PsramIdx;
            case MemFlags.fast:    return SramIdx;
            case MemFlags.slow:    return PsramIdx;
            case MemFlags.fastest: return SramIdx;
            case MemFlags.dma:     assert(false);
        }
    }

    void map_pools() nothrow @nogc
    {
        _pools[SramIdx].base  = cast(void*)&_sram_heap_start;
        _pools[SramIdx].size  = cast(size_t)&_sram_heap_end  - cast(size_t)&_sram_heap_start;
        _pools[SramIdx].name  = "SRAM";
        _pools[PsramIdx].base = cast(void*)&_psram_heap_start;
        _pools[PsramIdx].size = cast(size_t)&_psram_heap_end - cast(size_t)&_psram_heap_start;
        _pools[PsramIdx].name = "PSRAM";
    }
}
else version (BL618)
{
    // BL618 topology:
    //   DTCM  (64K)  fastest
    //   OCRAM (480K) fast / slow / dma  (the only large pool)
    enum size_t DtcmIdx  = 0;
    enum size_t OcramIdx = 1;

    extern(C) extern __gshared
    {
        pragma(mangle, "__dtcm_heap_start")  void* _dtcm_heap_start;
        pragma(mangle, "__dtcm_heap_end")    void* _dtcm_heap_end;
        pragma(mangle, "__ocram_heap_start") void* _ocram_heap_start;
        pragma(mangle, "__ocram_heap_end")   void* _ocram_heap_end;
    }

    size_t pool_for(MemFlags flags) nothrow @nogc
    {
        // BL618 has no PSRAM; OCRAM is the only large pool and is
        // DMA-reachable. DTCM is reserved for the fastest pool (CPU-local,
        // not DMA-reachable).
        if (flags & MemFlags.dma)
            return OcramIdx;

        final switch (cast(MemFlags)(flags & 3))
        {
            case MemFlags.none:    return OcramIdx;
            case MemFlags.fast:    return OcramIdx;
            case MemFlags.slow:    return OcramIdx;
            case MemFlags.fastest: return DtcmIdx;
            case MemFlags.dma:     assert(false);
        }
    }

    void map_pools() nothrow @nogc
    {
        _pools[DtcmIdx].base  = cast(void*)&_dtcm_heap_start;
        _pools[DtcmIdx].size  = cast(size_t)&_dtcm_heap_end  - cast(size_t)&_dtcm_heap_start;
        _pools[DtcmIdx].name  = "TCM";
        _pools[OcramIdx].base = cast(void*)&_ocram_heap_start;
        _pools[OcramIdx].size = cast(size_t)&_ocram_heap_end - cast(size_t)&_ocram_heap_start;
        _pools[OcramIdx].name = "SRAM";
    }
}
else
{
    static assert(false, "bl_common.alloc: unsupported chip");
}


// =====================================================================
// Shared TLSF interface + impl (chip-independent)
// =====================================================================

alias tlsf_t = void*;
alias pool_t = void*;
alias tlsf_walker = extern(C) void function(void* ptr, size_t size, int used, void* user) nothrow @nogc;

extern(C) tlsf_t tlsf_create(void* mem) pure;
extern(C) pool_t tlsf_add_pool(tlsf_t tlsf, void* mem, size_t bytes) pure;
extern(C) pool_t tlsf_get_pool(tlsf_t tlsf) pure;
extern(C) size_t tlsf_size() pure;
extern(C) void*  tlsf_malloc(tlsf_t tlsf, size_t bytes) pure;
extern(C) void*  tlsf_memalign(tlsf_t tlsf, size_t alignment, size_t bytes) pure;
extern(C) void*  tlsf_realloc(tlsf_t tlsf, void* ptr, size_t size) pure;
extern(C) void   tlsf_free(tlsf_t tlsf, void* p) pure;
extern(C) size_t tlsf_block_size(void* p) pure;
extern(C) void   tlsf_walk_pool(pool_t pool, tlsf_walker walker, void* user) pure;

struct Pool
{
    void* base;
    size_t size;
    tlsf_t tlsf;
    size_t used;
    size_t peak_used;
    immutable(char)* name;
}

// TLSF control_t for vendor config (FL_INDEX_MAX=30, SL_INDEX_COUNT_LOG2=5,
// rv32) sums to 3188 bytes; round to 3200. init_pools asserts the real
// tlsf_size() fits, so a vendor bump that grows control_t fails loudly.
enum TLSF_CONTROL_BYTES = 3200;

@fast_data align(16) __gshared ubyte[TLSF_CONTROL_BYTES][num_pools] _control;
@fast_data __gshared Pool[num_pools] _pools;
@fast_data __gshared bool _initialized;


void[] alloc_impl(size_t size, size_t alignment, MemFlags flags) nothrow @nogc
{
    init_pools();

    bool dma = (flags & MemFlags.dma) != 0;
    size_t primary = pool_for(flags);

    void* p = tlsf_memalign(_pools[primary].tlsf, alignment, size);
    size_t allocated_in = primary;
    if (p is null && !dma)
    {
        foreach (i, ref f; _pools)
        {
            if (i == primary)
                continue;
            p = tlsf_memalign(f.tlsf, alignment, size);
            if (p !is null)
            {
                allocated_in = i;
                log_failover(size, alignment, flags);
                break;
            }
        }
    }

    if (p !is null)
    {
        size_t block = tlsf_block_size(p);
        _pools[allocated_in].used += block;
        if (_pools[allocated_in].used > _pools[allocated_in].peak_used)
            _pools[allocated_in].peak_used = _pools[allocated_in].used;
    }
    else
        log_oom(size, alignment, flags);

    return p ? p[0 .. size] : null;
}

void[] realloc_impl(void[] mem, size_t new_size, size_t alignment, MemFlags flags) nothrow @nogc
{
    if (mem.ptr is null)
        return alloc_impl(new_size, alignment, flags);
    if (new_size == 0)
    {
        free_impl(mem.ptr);
        return null;
    }
    Pool* owner = pool_of(mem.ptr);
    if (owner is null)
        return null;
    size_t old_block = tlsf_block_size(mem.ptr);
    void* p = tlsf_realloc(owner.tlsf, mem.ptr, new_size);
    if (p is null)
        return null;
    size_t new_block = tlsf_block_size(p);
    owner.used = owner.used - old_block + new_block;
    if (owner.used > owner.peak_used)
        owner.peak_used = owner.used;
    return p[0 .. new_size];
}

void free_impl(void* ptr) nothrow @nogc
{
    Pool* owner = pool_of(ptr);
    if (owner is null)
        return;
    owner.used -= tlsf_block_size(ptr);
    tlsf_free(owner.tlsf, ptr);
}

void init_pools() nothrow @nogc
{
    if (_initialized)
        return;

    assert(tlsf_size() <= TLSF_CONTROL_BYTES, "TLSF control_t larger than reserved buffer");

    map_pools();

    foreach (i, ref p; _pools)
    {
        p.tlsf = tlsf_create(&_control[i][0]);
        tlsf_add_pool(p.tlsf, p.base, p.size);
    }

    _initialized = true;
}

Pool* pool_of(void* ptr) nothrow @nogc
{
    auto pi = cast(size_t)ptr;
    foreach (ref p; _pools)
    {
        auto bi = cast(size_t)p.base;
        if (pi >= bi && pi < bi + p.size)
            return &p;
    }
    return null;
}

void log_oom(size_t size, size_t alignment, MemFlags flags) nothrow @nogc
{
    __gshared bool reentrant;
    if (reentrant)
        return;
    reentrant = true;
    scope(exit) reentrant = false;

    import urt.log;
    log_error("heap.alloc", "OOM! - size=", size, " align=", alignment,
              " flags=", cast(int)flags);
}

void log_failover(size_t size, size_t alignment, MemFlags flags) nothrow @nogc
{
    __gshared bool reentrant;
    if (reentrant)
        return;
    reentrant = true;
    scope(exit) reentrant = false;

    import urt.log;
    log_debug("heap.alloc", "preferred pool full, fail to fallback - size=",
              size, " align=", alignment, " flags=", cast(int)flags);
}
