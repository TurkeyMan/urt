module urt.sync.semaphore;

import urt.atomic;
import urt.time;


// Counted signalling primitive.
//
// signal() is ISR-safe on bare-metal (single atomic add). On FreeRTOS,
// signal() is task-context only -- ISR producers need a separate ISR
// variant that calls xQueueGiveFromISR + portYIELD_FROM_ISR (TODO; will
// be added alongside the wake module that actually has ISR producers).
struct Semaphore
{
nothrow @nogc:
    @disable this(this);

    bool init(uint initial = 0)
    {
        version (Windows)
        {
            import urt.internal.sys.windows.winbase : CreateSemaphoreA;
            _internal = CreateSemaphoreA(null, initial, int.max, null);
            return _internal !is null;
        }
        else version (linux)
        {
            import urt.mem.allocator;
            auto p = cast(sem_t*)defaultAllocator().alloc(sem_t.sizeof, sem_t.alignof);
            if (!p)
                return false;
            if (sem_init(p, 0, initial) != 0)
            {
                defaultAllocator().free(p);
                return false;
            }
            _internal = p;
            return true;
        }
        else version (Darwin)
            static assert(false, "Semaphore on Darwin requires dispatch_semaphore_t -- TODO");
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            _internal = xQueueCreateCountingSemaphore(uint.max, initial);
            return _internal !is null;
        }
        else version (BareMetal)
        {
            atomicStore(*cast(shared(size_t)*)&_internal, cast(size_t)initial);
            return true;
        }
        else
            static assert(false, "Semaphore not implemented for this platform");
    }

    void destroy()
    {
        version (Windows)
        {
            import urt.internal.sys.windows.winbase : CloseHandle;
            if (_internal)
            {
                CloseHandle(_internal);
                _internal = null;
            }
        }
        else version (linux)
        {
            import urt.mem.allocator;
            if (_internal)
            {
                sem_destroy(cast(sem_t*)_internal);
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
            // counter lives in _internal; nothing to free
        }
    }

    void signal()
    {
        version (Windows)
        {
            import urt.internal.sys.windows.winbase : ReleaseSemaphore;
            ReleaseSemaphore(_internal, 1, null);
        }
        else version (linux)
            sem_post(cast(sem_t*)_internal);
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            xQueueGenericSend(_internal, null, semGIVE_BLOCK_TIME, queueSEND_TO_BACK);
        }
        else version (BareMetal)
            atomicFetchAdd(*cast(shared(size_t)*)&_internal, cast(size_t)1);
    }

    void wait()
    {
        version (Windows)
        {
            import urt.internal.sys.windows.winbase : WaitForSingleObject, INFINITE;
            WaitForSingleObject(_internal, INFINITE);
        }
        else version (linux)
            sem_wait(cast(sem_t*)_internal);
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            xQueueSemaphoreTake(_internal, portMAX_DELAY);
        }
        else version (BareMetal)
        {
            import urt.driver.irq;
            while (!try_wait())
            {
                static if (has_wait_for_interrupt)
                    irq_wait();
            }
        }
    }

    bool wait(Duration timeout)
    {
        if (timeout <= Duration.zero)
            return try_wait();

        version (Windows)
        {
            import urt.internal.sys.windows.winbase : WaitForSingleObject, WAIT_OBJECT_0, INFINITE;
            // INFINITE itself means "wait forever", so the largest finite
            // wait is INFINITE - 1 ms (~49 days). Chunk if longer.
            long ms = timeout.as!"msecs";
            while (ms >= INFINITE)
            {
                if (WaitForSingleObject(_internal, INFINITE - 1) == WAIT_OBJECT_0)
                    return true;
                ms -= INFINITE - 1;
            }
            return WaitForSingleObject(_internal, cast(uint)ms) == WAIT_OBJECT_0;
        }
        else version (linux)
        {
            timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            long add_ns = timeout.as!"nsecs";
            ts.tv_sec  += add_ns / 1_000_000_000;
            ts.tv_nsec += add_ns % 1_000_000_000;
            if (ts.tv_nsec >= 1_000_000_000)
            {
                ts.tv_sec  += 1;
                ts.tv_nsec -= 1_000_000_000;
            }
            return sem_timedwait(cast(sem_t*)_internal, &ts) == 0;
        }
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            // Assumes configTICK_RATE_HZ = 1000 (1ms tick); revisit if a
            // target uses a different tick rate.
            // portMAX_DELAY itself means "wait forever", so the largest
            // finite wait is portMAX_DELAY - 1 ticks. Chunk if longer.
            long ms = timeout.as!"msecs";
            while (ms >= portMAX_DELAY)
            {
                if (xQueueSemaphoreTake(_internal, portMAX_DELAY - 1) != 0)
                    return true;
                ms -= portMAX_DELAY - 1;
            }
            return xQueueSemaphoreTake(_internal, cast(uint)ms) != 0;
        }
        else version (BareMetal)
        {
            import urt.driver.timer;
            import urt.driver.irq;
            static if (has_mtime && has_wait_for_interrupt)
            {
                ulong deadline = mtime_read() + cast(ulong)timeout.as!"usecs";
                while (!try_wait())
                {
                    if (mtime_read() >= deadline)
                        return false;
                    mtimecmp_write_oneshot(deadline);
                    irq_wait();
                }
                return true;
            }
            else
            {
                // No timer + WFI? Busy-poll until deadline. Not ideal.
                MonoTime deadline = getTime() + timeout;
                while (!try_wait())
                {
                    if (getTime() >= deadline)
                        return false;
                }
                return true;
            }
        }
    }

    bool try_wait()
    {
        version (Windows)
        {
            import urt.internal.sys.windows.winbase : WaitForSingleObject, WAIT_OBJECT_0;
            return WaitForSingleObject(_internal, 0) == WAIT_OBJECT_0;
        }
        else version (linux)
            return sem_trywait(cast(sem_t*)_internal) == 0;
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            return xQueueSemaphoreTake(_internal, 0) != 0;
        }
        else version (BareMetal)
        {
            auto p = cast(shared(size_t)*)&_internal;
            size_t cur = atomicLoad(*p);
            for (;;)
            {
                if (cur == 0)
                    return false;
                if (cas(p, cur, cur - 1))
                    return true;
                cur = atomicLoad(*p);
            }
        }
    }

private:
    void* _internal;
}


unittest
{
    Semaphore s;
    assert(s.init(0));

    assert(!s.try_wait());
    s.signal();
    assert(s.try_wait());
    assert(!s.try_wait());

    s.signal();
    s.wait();
    assert(!s.try_wait());

    // immediate timeout
    assert(!s.wait(Duration.zero));

    // signal then timed wait -- should succeed immediately
    s.signal();
    assert(s.wait(seconds(1)));

    s.destroy();
}


private:

version (linux)
{
    extern(C) nothrow @nogc:

    // sem_t -- opaque, platform-sized.
    // glibc <bits/semaphore.h>: __SIZEOF_SEM_T = 32 on x86_64/aarch64/riscv64,
    //                                            16 on x86/arm/riscv32.
    static if (size_t.sizeof == 8)
        struct sem_t { align(8) ubyte[32] _; }
    else
        struct sem_t { align(4) ubyte[16] _; }

    int sem_init(sem_t*, int pshared, uint value);
    int sem_destroy(sem_t*);
    int sem_post(sem_t*);
    int sem_wait(sem_t*);
    int sem_trywait(sem_t*);
    int sem_timedwait(sem_t*, const(timespec)*);

    // timespec + clock_gettime live in <time.h>; duplicated here so this
    // module is self-contained. Promote to internal/sys/posix on second use.
    alias time_t = long;
    struct timespec
    {
        time_t tv_sec;
        long   tv_nsec;
    }

    alias clockid_t = int;
    enum CLOCK_REALTIME = 0;
    int clock_gettime(clockid_t, timespec*);
}
