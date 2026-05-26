module urt.sync.spsc;

import urt.atomic;
import urt.util : is_power_of_2;

nothrow @nogc:


// Lock-free single-producer single-consumer ring buffer.
//
// Producer side is staged: reserve() advances an internal uncommitted tail,
// but writes stay invisible to the consumer until commit().
//
// Consumer side is symmetrical: peek() returns pointers/slices into the
// committed region without advancing, pop(n) discards the oldest n slots
// and invalidates any outstanding peek() pointers.
struct SPSCRing(T, uint N)
{
nothrow @nogc:
    static assert(N >= 2 && is_power_of_2(N), "N must be a power of two >= 2");

    size_t pending() const
    {
        uint h = atomicLoad!(MemoryOrder.relaxed)(_head);
        uint t = atomicLoad!(MemoryOrder.acquire)(_tail);
        return (t - h) & (N - 1);
    }

    bool empty() const
    {
        uint h = atomicLoad!(MemoryOrder.relaxed)(_head);
        uint t = atomicLoad!(MemoryOrder.acquire)(_tail);
        return h == t;
    }

    size_t free_space() const
    {
        uint h = atomicLoad!(MemoryOrder.acquire)(_head);
        return (N - 1) - ((_pending_tail - h) & (N - 1));
    }

    // reserve up to `count` T's and return a contiguous writable slice
    // into the ring. may be shorter than count if ring boundary is hit
    // or if there isn't enough free space.
    T[] reserve(size_t count)
    {
        if (count == 0)
            return null;
        uint pt = _pending_tail;
        uint h  = atomicLoad!(MemoryOrder.acquire)(_head);
        size_t free = (N - 1) - ((pt - h) & (N - 1));
        size_t n = count < free ? count : free;
        size_t to_end = N - pt;
        if (n > to_end)
            n = to_end;
        if (n == 0)
            return null;
        T[] r = _buf[pt .. pt + n];
        _pending_tail = cast(uint)((pt + n) & (N - 1));
        return r;
    }

    T* reserve()
        => reserve(1).ptr;

    void commit()
    {
        atomicStore!(MemoryOrder.release)(_tail, _pending_tail);
    }

    void rollback()
    {
        _pending_tail = atomicLoad!(MemoryOrder.relaxed)(_tail);
    }

    size_t push(const(T)[] src, bool allow_partial = false)
    {
        if (src.length == 0)
            return 0;
        uint pt = _pending_tail;
        uint h  = atomicLoad!(MemoryOrder.acquire)(_head);
        size_t free = (N - 1) - ((pt - h) & (N - 1));
        if (!allow_partial && src.length > free)
            return 0;
        size_t n = src.length < free ? src.length : free;
        if (n == 0)
            return 0;
        size_t to_end = N - pt;
        if (n <= to_end)
            _buf[pt .. pt + n] = src[0 .. n];
        else
        {
            _buf[pt .. N]         = src[0 .. to_end];
            _buf[0 .. n - to_end] = src[to_end .. n];
        }
        _pending_tail = cast(uint)((pt + n) & (N - 1));
        atomicStore!(MemoryOrder.release)(_tail, _pending_tail);
        return n;
    }

    // peek up to `count` contiguous committed slots starting  at the oldest.
    // may be shorter than count when wrapping the ring boundary.
    // the returned slice is invalidated by the next pop().
    T[] peek(size_t count)
    {
        if (count == 0)
            return null;
        uint h = atomicLoad!(MemoryOrder.relaxed)(_head);
        uint t = atomicLoad!(MemoryOrder.acquire)(_tail);
        size_t filled = (t - h) & (N - 1);
        size_t n = count < filled ? count : filled;
        size_t to_end = N - h;
        if (n > to_end)
            n = to_end;
        if (n == 0)
            return null;
        return _buf[h .. h + n];
    }

    T* peek()
        => peek(1).ptr;

    // discard the oldest `count` committed slots.
    // invalidates pointers returned by prior peeks
    void pop(size_t count)
    {
        uint h = atomicLoad!(MemoryOrder.relaxed)(_head);
        atomicStore!(MemoryOrder.release)(_head, cast(uint)((h + count) & (N - 1)));
    }

    size_t pop(T[] dst)
    {
        if (dst.length == 0)
            return 0;
        uint h = atomicLoad!(MemoryOrder.relaxed)(_head);
        uint t = atomicLoad!(MemoryOrder.acquire)(_tail);
        size_t filled = (t - h) & (N - 1);
        size_t n = dst.length < filled ? dst.length : filled;
        if (n == 0)
            return 0;
        size_t to_end = N - h;
        if (n <= to_end)
            dst[0 .. n] = _buf[h .. h + n];
        else
        {
            dst[0 .. to_end] = _buf[h .. N];
            dst[to_end .. n] = _buf[0 .. n - to_end];
        }
        atomicStore!(MemoryOrder.release)(_head, cast(uint)((h + n) & (N - 1)));
        return n;
    }

private:
    T[N] _buf;
    shared uint _head;
    shared uint _tail;
    uint _pending_tail;     // producer-only; staging cursor for uncommitted writes
}
