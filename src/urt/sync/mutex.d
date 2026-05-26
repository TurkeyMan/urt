module urt.sync.mutex;

import urt.atomic;


// Blocking ownership lock. Excludes other threads/tasks from a critical
// section. Has an owner; non-recursive (locking from the holding thread
// is undefined behaviour).
//
// Do NOT use:
//   - Between an ISR and same-core mainline - use IrqGuard
//     (urt.driver.irq) for that case.
//   - For sections that may yield (cooperative-fibre code). A held Mutex
//     must be released before yielding; otherwise behaviour is target-
//     dependent (block-forever on desktop, race-or-spin on bare-metal).

struct Mutex
{
nothrow @nogc:
    @disable this(this);

    bool init()
    {
        version (Windows)
        {
            InitializeSRWLock(cast(SRWLOCK*)&_internal);
            return true;
        }
        else version (Posix)
        {
            import urt.mem.allocator;
            auto p = cast(pthread_mutex_t*)defaultAllocator().alloc(pthread_mutex_t.sizeof, pthread_mutex_t.alignof);
            if (!p)
                return false;
            if (pthread_mutex_init(p, null) != 0)
            {
                defaultAllocator().free(p);
                return false;
            }
            _internal = p;
            return true;
        }
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            _internal = xQueueCreateMutex(queueQUEUE_TYPE_MUTEX);
            return _internal !is null;
        }
        else version (BareMetal)
        {
            atomicStore(*cast(shared(size_t)*)&_internal, cast(size_t)0);
            return true;
        }
        else
            static assert(false, "Mutex not implemented for this platform");
    }

    void destroy()
    {
        version (Windows)
        {
            // SRWLOCK has no destroy
        }
        else version (Posix)
        {
            import urt.mem.allocator;
            if (_internal)
            {
                pthread_mutex_destroy(cast(pthread_mutex_t*)_internal);
                defaultAllocator().free(_internal);
                _internal = null;
            }
        }
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            if (_internal)
            {
                vQueueDelete(_internal);
                _internal = null;
            }
        }
        else version (BareMetal)
        {
            // nothing to free
        }
    }

    void lock()
    {
        version (Windows)
            AcquireSRWLockExclusive(cast(SRWLOCK*)&_internal);
        else version (Posix)
            pthread_mutex_lock(cast(pthread_mutex_t*)_internal);
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            xQueueSemaphoreTake(_internal, portMAX_DELAY);
        }
        else version (BareMetal)
        {
            while (!cas(cast(shared(size_t)*)&_internal, cast(size_t)0, cast(size_t)1))
                pause();
        }
    }

    bool try_lock()
    {
        version (Windows)
            return TryAcquireSRWLockExclusive(cast(SRWLOCK*)&_internal) != 0;
        else version (Posix)
            return pthread_mutex_trylock(cast(pthread_mutex_t*)_internal) == 0;
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            return xQueueSemaphoreTake(_internal, 0) != 0;
        }
        else version (BareMetal)
            return cas(cast(shared(size_t)*)&_internal, cast(size_t)0, cast(size_t)1);
    }

    void unlock()
    {
        version (Windows)
            ReleaseSRWLockExclusive(cast(SRWLOCK*)&_internal);
        else version (Posix)
            pthread_mutex_unlock(cast(pthread_mutex_t*)_internal);
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            xQueueGenericSend(_internal, null, semGIVE_BLOCK_TIME, queueSEND_TO_BACK);
        }
        else version (BareMetal)
            atomicStore!(MemoryOrder.release)(*cast(shared(size_t)*)&_internal, cast(size_t)0);
    }

    MutexGuard acquire() return
    {
        lock();
        return MutexGuard(&this);
    }

private:
    void* _internal;
}


struct MutexGuard
{
nothrow @nogc:
    @disable this();
    @disable this(this);

    ~this()
    {
        assert (_mutex);
        _mutex.unlock();
    }

private:
    Mutex* _mutex;

    this(Mutex* mutex)
    {
        _mutex = mutex;
    }
}


unittest
{
    Mutex m;
    assert(m.init());

    assert(m.try_lock());
    assert(!m.try_lock());
    m.unlock();

    m.lock();
    assert(!m.try_lock());
    m.unlock();
    assert(m.try_lock());
    m.unlock();

    m.destroy();
}


private:

version (Windows)
{
    extern(Windows) nothrow @nogc:

    // SRWLOCK is a single pointer-sized opaque value; zero-init is valid.
    struct SRWLOCK { void* Ptr; }

    void InitializeSRWLock(SRWLOCK*);
    void AcquireSRWLockExclusive(SRWLOCK*);
    ubyte TryAcquireSRWLockExclusive(SRWLOCK*);   // returns BOOLEAN
    void ReleaseSRWLockExclusive(SRWLOCK*);
}
else version (Posix)
{
    extern(C) nothrow @nogc:

    // pthread_mutex_t -- opaque, platform-sized.
    // Sizes from glibc <bits/pthreadtypes-arch.h> / Darwin <sys/_pthread/_pthread_types.h>.
    // Conservative ceilings used where 32-bit/64-bit variants differ between archs.
    version (linux)
    {
        static if (size_t.sizeof == 8)
            struct pthread_mutex_t { align(8) ubyte[48] _; }   // x86_64=40, aarch64=48, riscv64=40
        else
            struct pthread_mutex_t { align(4) ubyte[32] _; }   // x86=24, arm=24, riscv32=32
    }
    else version (Darwin)
    {
        static if (size_t.sizeof == 8)
            struct pthread_mutex_t { align(8) ubyte[64] _; }   // _PTHREAD_MUTEX_SIZE__ + sig
        else
            struct pthread_mutex_t { align(4) ubyte[44] _; }
    }
    else
        static assert(false, "pthread_mutex_t size not configured for this POSIX target");

    int pthread_mutex_init(pthread_mutex_t*, const(void)*);
    int pthread_mutex_destroy(pthread_mutex_t*);
    int pthread_mutex_lock(pthread_mutex_t*);
    int pthread_mutex_trylock(pthread_mutex_t*);
    int pthread_mutex_unlock(pthread_mutex_t*);
}
