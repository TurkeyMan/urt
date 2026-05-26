module urt.sync.mpsc;

import urt.atomic;
import urt.util : is_power_of_2;

nothrow @nogc:


// Lock-free bounded MPSC queue (Vyukov sequence-based algorithm).
//
// Many concurrent producers; ONE consumer.
//
// Producers:
//   - Thread-safe AND ISR-safe.
//   - Wait-free in the no-contention case; one CAS retry under contention.
//   - enqueue() returns false if the queue is full.
//
// Consumer:
//   - Single-threaded. Calling dequeue() from multiple threads, from an
//     ISR, or alongside a thread-context call is undefined behaviour.
//
// Capacity N must be a power of two >= 2. Effective capacity == N (all
// slots usable).
//
// Must call init() before first use -- slot sequences need to be primed
// to [0, 1, ..., N-1] so the first lap of producers see "empty" slots.
struct MpscQueue(T, uint N)
{
    static assert(N >= 2 && is_power_of_2(N), "N must be a power of two >= 2");

nothrow @nogc:

    void init()
    {
        foreach (uint i, ref slot; _slots)
            atomicStore!(MemoryOrder.relaxed)(slot.sequence, i);
        atomicStore!(MemoryOrder.relaxed)(_tail, cast(uint)0);
        _head = 0;
    }

    // Try to enqueue. Returns false if full.
    // Thread-safe and ISR-safe.
    bool enqueue(T item)
    {
        uint pos = atomicLoad!(MemoryOrder.relaxed)(_tail);
        for (;;)
        {
            Slot* slot = &_slots[pos & mask];
            uint seq = atomicLoad!(MemoryOrder.acquire)(slot.sequence);
            int diff = cast(int)(seq - pos);
            if (diff == 0)
            {
                // Slot is available at this lap; try to claim our position.
                if (cas(&_tail, pos, pos + 1))
                {
                    slot.data = item;
                    atomicStore!(MemoryOrder.release)(slot.sequence, pos + 1);
                    return true;
                }
                // Lost the race; reload and retry.
                pos = atomicLoad!(MemoryOrder.relaxed)(_tail);
            }
            else if (diff < 0)
            {
                // Slot is still occupied from a previous lap -- full.
                return false;
            }
            else
            {
                // Tail moved ahead between our load and the slot check; reload.
                pos = atomicLoad!(MemoryOrder.relaxed)(_tail);
            }
        }
    }

    // Try to dequeue. Returns false if empty.
    // Single-consumer ONLY.
    bool dequeue(out T item)
    {
        Slot* slot = &_slots[_head & mask];
        uint seq = atomicLoad!(MemoryOrder.acquire)(slot.sequence);
        if (cast(int)(seq - (_head + 1)) < 0)
            return false;
        item = slot.data;
        // Mark this slot ready for the next lap (head + N positions away).
        atomicStore!(MemoryOrder.release)(slot.sequence, _head + N);
        ++_head;
        return true;
    }

    // Approximate emptiness check. Safe from the consumer thread only.
    // A `false` return is authoritative ("not empty right now"); a `true`
    // return may race against a producer that's mid-enqueue.
    bool empty() const
    {
        const(Slot)* slot = &_slots[_head & mask];
        uint seq = atomicLoad!(MemoryOrder.acquire)(slot.sequence);
        return cast(int)(seq - (_head + 1)) < 0;
    }

private:
    enum uint mask = N - 1;

    struct Slot
    {
        T data;
        shared uint sequence;
    }

    Slot[N] _slots;
    shared uint _tail;     // producer claim cursor
    uint _head;            // consumer read cursor (single consumer; non-atomic)
}


unittest
{
    MpscQueue!(int, 4) q;
    q.init();

    int v;
    assert(q.empty);
    assert(!q.dequeue(v));

    // fill capacity
    assert(q.enqueue(10));
    assert(q.enqueue(20));
    assert(q.enqueue(30));
    assert(q.enqueue(40));
    assert(!q.enqueue(50));  // full

    assert(q.dequeue(v) && v == 10);
    assert(q.dequeue(v) && v == 20);
    assert(q.dequeue(v) && v == 30);
    assert(q.dequeue(v) && v == 40);
    assert(q.empty);
    assert(!q.dequeue(v));

    // wrap-around
    assert(q.enqueue(100));
    assert(q.enqueue(200));
    assert(q.dequeue(v) && v == 100);
    assert(q.dequeue(v) && v == 200);
    assert(q.empty);
}
