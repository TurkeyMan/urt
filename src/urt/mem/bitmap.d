module urt.mem.bitmap;

import urt.util;

nothrow @nogc:


// Bitmap pool. The bitmap header sits at the head of the pool and holds two equal-size planes:
//   in-use  -> 1 = block is allocated
//   stop    -> 1 = last block of an allocation
// The header's blocks are pre-marked in-use so they can't be handed out. free() takes only the
// pointer; it scans the stop plane forward from the pointer's block to find the allocation's end.
//
// `_poolSize == 0` -> backing memory supplied at runtime via `init(mem)`.
// `_poolSize > 0`  -> storage lives inline; call `init()` after construction.
struct BitmapPool(size_t _poolSize = 0, size_t blockSize = size_t.sizeof)
{
    static assert(blockSize > 0, "blockSize must be > 0");
    static assert(IsPowerOf2!blockSize, "blockSize must be a power of 2");

    alias Word = size_t;
    enum size_t word_bits = Word.sizeof * 8;

    static if (_poolSize > 0)
    {
        static assert(_poolSize % blockSize == 0, "_poolSize must be a multiple of blockSize");

        enum size_t block_count = _poolSize / blockSize;
        enum size_t plane_words = align_up(block_count, word_bits) / word_bits;
        enum size_t bitmap_blocks = align_up(2 * plane_words * Word.sizeof, blockSize) / blockSize;
        enum size_t usable_blocks = block_count - bitmap_blocks;
        static assert(usable_blocks > 0, "pool too small: bitmap consumes the whole pool");

        void[] data() => cast(void[])_data[];

        void init()
        {
            init_planes(in_use_plane(), stop_plane(), block_count, bitmap_blocks);
        }
    }
    else
    {
        size_t block_count() const => _block_count;
        size_t plane_words() const => _plane_words;
        size_t bitmap_blocks() const => _bitmap_blocks;
        size_t usable_blocks() const => _block_count - _bitmap_blocks;

        void[] data() => _data;

        void init(void[] mem)
        {
            assert(mem.length >= blockSize, "pool too small");
            assert((cast(size_t)mem.ptr & (Word.alignof - 1)) == 0, "pool memory must be Word-aligned");

            size_t nblocks = mem.length / blockSize;
            size_t pwords = align_up(nblocks, word_bits) / word_bits;
            size_t bblocks = align_up(2 * pwords * Word.sizeof, blockSize) / blockSize;
            assert(nblocks > bblocks, "pool too small: bitmap consumes the whole pool");

            _data = mem.ptr[0 .. nblocks * blockSize];
            _block_count = cast(uint)nblocks;
            _plane_words = cast(uint)pwords;
            _bitmap_blocks = cast(uint)bblocks;

            init_planes(in_use_plane(), stop_plane(), _block_count, _bitmap_blocks);
        }
    }

    void[] alloc(size_t bytes)
    {
        if (bytes == 0)
            return null;
        size_t n = align_up(bytes, blockSize) / blockSize;
        size_t i = find_run(n);
        if (i == size_t.max)
            return null;
        mark_in_use(i, n, true);
        set_stop(i + n - 1);
        return (cast(ubyte*)_data.ptr + i * blockSize)[0 .. bytes];
    }

    void free(void* p)
    {
        if (p is null)
            return;
        size_t off = cast(ubyte*)p - cast(ubyte*)_data.ptr;
        debug
        {
            assert(off % blockSize == 0, "free pointer not aligned to a block");
            assert(off < _data.length, "free out of pool bounds");
        }
        size_t i = off / blockSize;
        size_t stop = find_stop(i);
        debug assert(stop != size_t.max, "free: no stop bit found (invalid pointer)");
        clear_stop(stop);
        mark_in_use(i, stop - i + 1, false);
    }

    void free(void[] mem)
    {
        free(mem.ptr);
    }

private:
    static if (_poolSize > 0)
        align(Word.alignof) ubyte[_poolSize] _data = void;
    else
    {
        void[] _data;
        uint _block_count;
        uint _plane_words;
        uint _bitmap_blocks;
    }

    Word[] in_use_plane()
    {
        return (cast(Word*)_data.ptr)[0 .. plane_words];
    }

    Word[] stop_plane()
    {
        return (cast(Word*)_data.ptr)[plane_words .. 2 * plane_words];
    }

    static void init_planes(Word[] in_use, Word[] stop, size_t blocks, size_t reserved)
    {
        in_use[] = 0;
        stop[] = 0;

        size_t i = 0;
        while (reserved >= word_bits)
        {
            in_use[i++] = ~Word(0);
            reserved -= word_bits;
        }
        if (reserved)
            in_use[i] = (Word(1) << reserved) - 1;

        // mark padding bits past `blocks` as in-use so the scanner won't pick them
        size_t tail = blocks & (word_bits - 1);
        if (tail)
            in_use[$ - 1] |= ~((Word(1) << tail) - 1);
    }

    // Find the lowest run of `n` free blocks. Strategy per word:
    //   - all-zero word: extend the pending cross-word run.
    //   - mixed word: combine pending + leading-free; then shift-OR within the word for an internal
    //     run; then record trailing-free for the next iteration.
    // Shift-OR: with `free = ~w`, `acc = free & (free>>1) & ... & (free>>(n-1))` has bit b set iff
    // bits b..b+n-1 of free are all 1, i.e. a run of n free blocks starts at b. ctz(acc) picks the
    // lowest such start. Only viable for n <= word_bits; longer runs come from cross-word combining.
    size_t find_run(size_t n)
    {
        Word[] bm = in_use_plane();

        if (n == 1)
        {
            foreach (wi; 0 .. bm.length)
            {
                Word w = bm[wi];
                if (w != ~Word(0))
                    return wi * word_bits + ctz!true(cast(Word)~w);
            }
            return size_t.max;
        }

        size_t pending = 0;
        size_t pending_start = 0;

        foreach (wi; 0 .. bm.length)
        {
            Word w = bm[wi];

            if (w == 0)
            {
                if (pending == 0)
                    pending_start = wi * word_bits;
                pending += word_bits;
                if (pending >= n)
                    return pending_start;
                continue;
            }

            size_t leading = ctz(w);
            if (pending + leading >= n)
                return pending > 0 ? pending_start : wi * word_bits;

            if (n <= word_bits)
            {
                Word free = ~w;
                Word acc = free;
                for (size_t k = 1; k < n; ++k)
                {
                    acc &= free >> k;
                    if (acc == 0)
                        break;
                }
                if (acc != 0)
                    return wi * word_bits + ctz!true(acc);
            }

            size_t trail = clz(w);
            if (trail > 0)
            {
                pending = trail;
                pending_start = (wi + 1) * word_bits - trail;
            }
            else
                pending = 0;
        }

        return size_t.max;
    }

    size_t find_stop(size_t start)
    {
        Word[] bm = stop_plane();
        size_t wi = start / word_bits;
        size_t bi = start & (word_bits - 1);

        Word w = bm[wi] >> bi;
        if (w != 0)
            return start + ctz!true(w);
        for (++wi; wi < bm.length; ++wi)
        {
            if (bm[wi] != 0)
                return wi * word_bits + ctz!true(bm[wi]);
        }
        return size_t.max;
    }

    void mark_in_use(size_t start, size_t n, bool set)
    {
        Word[] bm = in_use_plane();
        size_t end = start + n;
        size_t wi = start / word_bits;
        size_t bi = start & (word_bits - 1);
        while (start < end)
        {
            size_t span = min(word_bits - bi, end - start);
            Word mask = span == word_bits ? ~Word(0) : (((Word(1) << span) - 1) << bi);
            if (set)
            {
                debug assert((bm[wi] & mask) == 0, "double-alloc: bits already set");
                bm[wi] |= mask;
            }
            else
            {
                debug assert((bm[wi] & mask) == mask, "double-free: bits already clear");
                bm[wi] &= ~mask;
            }
            start += span;
            ++wi;
            bi = 0;
        }
    }

    void set_stop(size_t i)
    {
        Word[] bm = stop_plane();
        bm[i / word_bits] |= Word(1) << (i & (word_bits - 1));
    }

    void clear_stop(size_t i)
    {
        Word[] bm = stop_plane();
        bm[i / word_bits] &= ~(Word(1) << (i & (word_bits - 1)));
    }
}


unittest
{
    // 4 KiB / 8 B -> 512 blocks, 2 x 64-byte planes = 16 reserved blocks, 496 usable.
    BitmapPool!(4096, 8) p;
    p.init();

    assert(p.block_count == 512);
    assert(p.bitmap_blocks == 16);
    assert(p.usable_blocks == 496);

    ubyte* base = cast(ubyte*)p.data.ptr;
    ubyte* first = base + p.bitmap_blocks * 8;

    void[] a = p.alloc(8);
    assert(a !is null && a.length == 8);
    assert(cast(ubyte*)a.ptr == first);

    void[] b = p.alloc(8);
    assert(cast(ubyte*)b.ptr == first + 8);

    p.free(a.ptr);
    void[] c = p.alloc(8);
    assert(c.ptr is a.ptr);

    void[] big = p.alloc(40);
    assert(big !is null && big.length == 40);
    p.free(big.ptr);

    p.free(b.ptr);
    p.free(c.ptr);

    void[][496] all;
    foreach (i; 0 .. 496)
    {
        all[i] = p.alloc(8);
        assert(all[i] !is null);
    }
    assert(p.alloc(8) is null);
    foreach (s; all)
        p.free(s.ptr);
    assert(p.alloc(8) !is null);
}

unittest
{
    align(size_t.alignof) ubyte[1024] storage;
    BitmapPool!(0, 16) p;
    p.init(storage[]);

    assert(p.block_count == 64);
    assert(p.usable_blocks > 0);

    void[] a = p.alloc(16);
    void[] b = p.alloc(48);
    assert(a !is null && b !is null);
    p.free(a.ptr);
    p.free(b.ptr);
}

unittest
{
    // multi-block run that straddles a word boundary, then length-less free
    BitmapPool!(2048, 4) p;
    p.init();

    void[][70] filler;
    foreach (i; 0 .. 70)
        filler[i] = p.alloc(4);

    void[] run = p.alloc(20);
    assert(run !is null && run.length == 20);

    foreach (s; filler)
        p.free(s.ptr);
    p.free(run.ptr);

    // pool should be back to full availability
    void[] big = p.alloc(256);
    assert(big !is null);
    p.free(big.ptr);
}

unittest
{
    // Exercise the optimised find_run paths: long runs across many words and within-word runs
    // hidden behind a dense alternating-bit pattern.
    enum bs = 8;
    BitmapPool!(8192, bs) p;
    p.init();

    // Long run spanning many words.
    void[] big = p.alloc(bs * 200);
    assert(big !is null && big.length == bs * 200);
    p.free(big.ptr);

    // Biggest possible run.
    void[] huge = p.alloc(bs * p.usable_blocks);
    assert(huge !is null);
    p.free(huge.ptr);

    // Fragment with alternating singles, then place a 2-block run somewhere valid.
    void[][50] singles;
    foreach (i; 0 .. 50)
        singles[i] = p.alloc(bs);
    foreach (i; 0 .. 50)
    {
        if (i & 1)
            p.free(singles[i].ptr);
    }
    void[] two = p.alloc(bs * 2);
    assert(two !is null);
    p.free(two.ptr);
    foreach (i; 0 .. 50)
    {
        if (!(i & 1))
            p.free(singles[i].ptr);
    }

    // Run that requires combining trailing zeros of one word with leading zeros of the next.
    void[][62] fill;
    foreach (i; 0 .. 62)
        fill[i] = p.alloc(bs);
    void[] cross = p.alloc(bs * 4);
    assert(cross !is null);
    p.free(cross.ptr);
    foreach (s; fill)
        p.free(s.ptr);
}
