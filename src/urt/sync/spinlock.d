module urt.sync.spinlock;

import urt.atomic;

nothrow @nogc:


// Mutual-exclusion via busy-wait CAS.
//
// Use when:
//   - The contended section is very short (a handful of instructions).
//   - The contender is another core, or another thread/task that can
//     make forward progress independently.
//
// Do NOT use:
//   - Between an ISR and same-core mainline -- spinning waiting for an
//     ISR-held lock deadlocks; spinning waiting for mainline from an
//     ISR deadlocks too. Use IrqGuard (urt.driver.irq) for that case.
//   - For long sections -- spinning is pure waste. Use Mutex.
//   - On single-core single-threaded targets -- nothing to contend with;
//     compiles to a real spinlock anyway since we don't have a reliable
//     compile-time "single core" flag yet, but you shouldn't reach for it.
struct Spinlock
{
nothrow @nogc:

    void lock()
    {
        while (!try_lock())
            pause();
    }

    bool try_lock()
        => cas(&_state, false, true);

    void unlock()
    {
        atomicStore!(MemoryOrder.release)(_state, false);
    }

    SpinlockGuard acquire() return
    {
        lock();
        return SpinlockGuard(&this);
    }

private:
    shared bool _state;
}


// RAII guard. Releases the held Spinlock on scope exit.
struct SpinlockGuard
{
nothrow @nogc:
    @disable this();
    @disable this(this);

    ~this()
    {
        if (_lock)
            _lock.unlock();
    }

private:
    Spinlock* _lock;

    this(Spinlock* lock)
    {
        _lock = lock;
    }
}


unittest
{
    Spinlock sl;

    assert(sl.try_lock());
    assert(!sl.try_lock());
    sl.unlock();
    assert(sl.try_lock());
    sl.unlock();

    sl.lock();
    assert(!sl.try_lock());
    sl.unlock();
    assert(sl.try_lock());
    sl.unlock();
}
