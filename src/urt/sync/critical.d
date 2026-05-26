module urt.sync.critical;

import urt.atomic;

nothrow @nogc:


// Scope-based "nothing else touches the protected state right now" guard.
// Critical sections are SHORT by contract - a handful of instructions.
// Long-held sections will starve other threads/cores; for long sections
// use a Mutex.
//
// Reentrant on every platform. Place a Critical as a field of the object
// it protects (or __gshared if it protects global state).

struct Critical
{
nothrow @nogc:
    @disable this(this);

    bool init()
    {
        version (Windows)
            InitializeCriticalSection(&_cs);
        // POSIX/FreeRTOS/bare-metal: zero-init is the valid initial state.
        return true;
    }

    void destroy()
    {
        version (Windows)
            DeleteCriticalSection(&_cs);
        // other platforms: nothing to release
    }

    CriticalGuard acquire() return
    {
        CriticalGuard g = void;
        version (Windows)
        {
            EnterCriticalSection(&_cs);
            g._critical = &this;
        }
        else version (Posix)
        {
            auto self = cast(size_t)pthread_self();
            if (atomicLoad(_owner) == self)
            {
                // already own it -- just bump the recursion count
                ++_count;
            }
            else
            {
                while (!cas(&_owner, cast(size_t)0, self))
                    pause();
                _count = 1;
            }
            g._critical = &this;
        }
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos : vPortEnterCritical;
            vPortEnterCritical(&_mux);
            g._critical = &this;
        }
        else
        {
            // bare-metal: always disable IRQs for same-core ISR protection.
            // On SMP targets, also acquire a per-instance owner-tracked
            // spinlock for cross-core protection.
            import urt.driver.irq : irq_global_disable, has_smp;
            g._prev = irq_global_disable();

            static if (has_smp)
            {
                import urt.driver.irq : cpu_id;
                uint self = cpu_id() + 1;   // +1 so 0 stays "unowned"
                if (atomicLoad(_owner) == self)
                {
                    ++_count;
                }
                else
                {
                    while (!cas(&_owner, cast(uint)0, self))
                        pause();
                    _count = 1;
                }
                g._critical = &this;
            }
        }
        return g;
    }

private:
    version (Windows)
    {
        CRITICAL_SECTION _cs;
    }
    else version (Posix)
    {
        shared size_t _owner;   // current thread id, or 0 when unowned
        int _count;             // recursion depth (touched only by owner)
    }
    else version (FreeRTOS)
    {
        import urt.internal.sys.freertos : portMUX_TYPE;
        portMUX_TYPE _mux;
    }
    else
    {
        // bare-metal: state only present on SMP targets.
        import urt.driver.irq : has_smp;
        static if (has_smp)
        {
            shared uint _owner;   // (cpu_id + 1) of owner, or 0 when unowned
            uint _count;          // recursion depth (touched only by owner)
        }
        // (single-core: nothing per-instance -- the IRQ-disable is global
        // on this core, and there are no other cores to spin against.)
    }

    void _leave()
    {
        version (Windows)
            LeaveCriticalSection(&_cs);
        else version (Posix)
        {
            if (--_count == 0)
                atomicStore!(MemoryOrder.release)(_owner, cast(size_t)0);
        }
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos : vPortExitCritical;
            vPortExitCritical(&_mux);
        }
        else
        {
            // bare-metal: drop the spinlock on SMP; the guard destructor
            // restores IRQs via _prev.
            import urt.driver.irq : has_smp;
            static if (has_smp)
            {
                if (--_count == 0)
                    atomicStore!(MemoryOrder.release)(_owner, cast(uint)0);
            }
        }
    }
}


struct CriticalGuard
{
nothrow @nogc:
    @disable this();
    @disable this(this);

    ~this()
    {
        version (Windows)       _critical._leave();
        else version (Posix)    _critical._leave();
        else version (FreeRTOS) _critical._leave();
        else
        {
            import urt.driver.irq : irq_global_set, has_smp;
            static if (has_smp)
                _critical._leave();
            irq_global_set(_prev);
        }
    }

private:
    version (Windows)       Critical* _critical;
    else version (Posix)    Critical* _critical;
    else version (FreeRTOS) Critical* _critical;
    else
    {
        import urt.driver.irq : has_smp;
        static if (has_smp)
            Critical* _critical;
        bool _prev;
    }
}


unittest
{
    Critical c;
    assert(c.init());

    // basic acquire/release
    int x;
    {
        auto g = c.acquire();
        x = 42;
    }
    assert(x == 42);

    // reentrant: nested acquire on the same thread/core
    {
        auto g1 = c.acquire();
        {
            auto g2 = c.acquire();
            x = 100;
        }
        // still held by g1 here
        x = 101;
    }
    assert(x == 101);

    // re-acquirable after release
    {
        auto g = c.acquire();
        x = 7;
    }
    assert(x == 7);

    c.destroy();
}


private:

version (Windows)
{
    import urt.internal.sys.windows.winbase : CRITICAL_SECTION;

    // Re-declare with the attribute set we need (winbase declares these
    // without nothrow @nogc). Linker resolves to the same Win32 symbols.
    extern(Windows) nothrow @nogc:
    void InitializeCriticalSection(CRITICAL_SECTION*);
    void DeleteCriticalSection(CRITICAL_SECTION*);
    void EnterCriticalSection(CRITICAL_SECTION*);
    void LeaveCriticalSection(CRITICAL_SECTION*);
}
else version (Posix)
{
    extern(C) nothrow @nogc:
    void* pthread_self();
}
