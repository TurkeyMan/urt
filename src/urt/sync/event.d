module urt.sync.event;

import urt.atomic;
import urt.time;


// Manual-reset event ("latch"). Holds a single sticky bit:
//   - set()    flips the bit to true and wakes ALL current waiters.
//   - reset()  flips the bit back to false.
//   - wait()   returns immediately if set, otherwise blocks until set.
//              Does NOT clear the bit -- subsequent wait()s see it set
//              until reset() is called explicitly.

struct Event
{
nothrow @nogc:
    @disable this(this);

    bool init()
    {
        version (Windows)
        {
            _internal = CreateEventA(null, 1, 0, null);   // bManualReset=TRUE, initial=FALSE
            return _internal !is null;
        }
        else version (linux)
        {
            import urt.mem.allocator;
            auto p = cast(LinuxEvent*)defaultAllocator().alloc(LinuxEvent.sizeof, LinuxEvent.alignof);
            if (!p)
                return false;
            *p = LinuxEvent.init;
            if (pthread_mutex_init(&p.m, null) != 0)
            {
                defaultAllocator().free(p);
                return false;
            }
            if (pthread_cond_init(&p.c, null) != 0)
            {
                pthread_mutex_destroy(&p.m);
                defaultAllocator().free(p);
                return false;
            }
            _internal = p;
            return true;
        }
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            _internal = xEventGroupCreate();
            return _internal !is null;
        }
        else version (BareMetal)
        {
            atomicStore(*cast(shared(uint)*)&_internal, 0u);
            return true;
        }
        else
            static assert(false, "Event not implemented for this platform");
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
                auto p = cast(LinuxEvent*)_internal;
                pthread_cond_destroy(&p.c);
                pthread_mutex_destroy(&p.m);
                defaultAllocator().free(p);
                _internal = null;
            }
        }
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            if (_internal)
            {
                vEventGroupDelete(_internal);
                _internal = null;
            }
        }
        else version (BareMetal)
        {
            // nothing to free
        }
    }

    void set()
    {
        version (Windows)
            SetEvent(_internal);
        else version (linux)
        {
            auto p = cast(LinuxEvent*)_internal;
            pthread_mutex_lock(&p.m);
            p.flag = true;
            pthread_cond_broadcast(&p.c);
            pthread_mutex_unlock(&p.m);
        }
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            xEventGroupSetBits(_internal, 1);
        }
        else version (BareMetal)
            atomicStore!(MemoryOrder.release)(*cast(shared(uint)*)&_internal, 1u);
    }

    void reset()
    {
        version (Windows)
            ResetEvent(_internal);
        else version (linux)
        {
            auto p = cast(LinuxEvent*)_internal;
            pthread_mutex_lock(&p.m);
            p.flag = false;
            pthread_mutex_unlock(&p.m);
        }
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            xEventGroupClearBits(_internal, 1);
        }
        else version (BareMetal)
            atomicStore!(MemoryOrder.release)(*cast(shared(uint)*)&_internal, 0u);
    }

    void wait()
    {
        version (Windows)
        {
            import urt.internal.sys.windows.winbase : WaitForSingleObject, INFINITE;
            WaitForSingleObject(_internal, INFINITE);
        }
        else version (linux)
        {
            auto p = cast(LinuxEvent*)_internal;
            pthread_mutex_lock(&p.m);
            while (!p.flag)
                pthread_cond_wait(&p.c, &p.m);
            pthread_mutex_unlock(&p.m);
        }
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            xEventGroupWaitBits(_internal, 1, pdFALSE, pdFALSE, portMAX_DELAY);
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
            auto p = cast(LinuxEvent*)_internal;
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
            pthread_mutex_lock(&p.m);
            int rc = 0;
            while (!p.flag && rc == 0)
                rc = pthread_cond_timedwait(&p.c, &p.m, &ts);
            bool got = p.flag;
            pthread_mutex_unlock(&p.m);
            return got;
        }
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            long ms = timeout.as!"msecs";
            while (ms >= portMAX_DELAY)
            {
                if ((xEventGroupWaitBits(_internal, 1, pdFALSE, pdFALSE, portMAX_DELAY - 1) & 1) != 0)
                    return true;
                ms -= portMAX_DELAY - 1;
            }
            return (xEventGroupWaitBits(_internal, 1, pdFALSE, pdFALSE, cast(TickType_t)ms) & 1) != 0;
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
        {
            auto p = cast(LinuxEvent*)_internal;
            pthread_mutex_lock(&p.m);
            bool got = p.flag;
            pthread_mutex_unlock(&p.m);
            return got;
        }
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos;
            return (xEventGroupGetBits(_internal) & 1) != 0;
        }
        else version (BareMetal)
            return atomicLoad!(MemoryOrder.acquire)(*cast(shared(uint)*)&_internal) != 0;
    }

private:
    void* _internal;
}


unittest
{
    Event e;
    assert(e.init());

    assert(!e.try_wait());
    e.set();
    assert(e.try_wait());

    // sticky -- still set after wait()
    e.wait();
    assert(e.try_wait());

    e.reset();
    assert(!e.try_wait());

    // immediate timeout when unset
    assert(!e.wait(Duration.zero));

    // set + timed wait succeeds
    e.set();
    assert(e.wait(seconds(1)));
    assert(e.try_wait());   // still set

    e.destroy();
}


private:

version (Windows)
{
    extern(Windows) nothrow @nogc:
    void* CreateEventA(void* lpEventAttributes, int bManualReset, int bInitialState, const(char)* lpName);
    int   SetEvent(void* hEvent);
    int   ResetEvent(void* hEvent);
}
else version (linux)
{
    extern(C) nothrow @nogc:

    // pthread_mutex_t / pthread_cond_t -- opaque, platform-sized.
    // glibc <bits/pthreadtypes-arch.h>.
    static if (size_t.sizeof == 8)
    {
        struct pthread_mutex_t { align(8) ubyte[48] _; }   // ceiling; arches vary 40..48
        struct pthread_cond_t  { align(8) ubyte[48] _; }
    }
    else
    {
        struct pthread_mutex_t { align(4) ubyte[32] _; }
        struct pthread_cond_t  { align(4) ubyte[48] _; }
    }

    int pthread_mutex_init(pthread_mutex_t*, const(void)*);
    int pthread_mutex_destroy(pthread_mutex_t*);
    int pthread_mutex_lock(pthread_mutex_t*);
    int pthread_mutex_unlock(pthread_mutex_t*);

    int pthread_cond_init(pthread_cond_t*, const(void)*);
    int pthread_cond_destroy(pthread_cond_t*);
    int pthread_cond_wait(pthread_cond_t*, pthread_mutex_t*);
    int pthread_cond_timedwait(pthread_cond_t*, pthread_mutex_t*, const(timespec)*);
    int pthread_cond_broadcast(pthread_cond_t*);

    // Combined storage. Heap-allocated; pointer lives in Event._internal.
    struct LinuxEvent
    {
        pthread_mutex_t m;
        pthread_cond_t  c;
        bool flag;
    }

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
