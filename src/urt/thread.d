module urt.sync.thread;

import urt.mem.allocator : defaultAllocator;

nothrow @nogc:


version (Windows)       enum ThreadsSupported = true;
else version (Posix)    enum ThreadsSupported = true;
else version (FreeRTOS) enum ThreadsSupported = true;
else                    enum ThreadsSupported = false;


alias Thread      = void*;
alias ThreadEntry = void delegate() nothrow @nogc;


// Spawn an OS thread. Returns null on failure.
// stack_size = 0: platform default (Windows: 1MB; POSIX: ~8MB; FreeRTOS: 4096 bytes).
Thread thread_spawn(ThreadEntry entry, size_t stack_size = 0)
{
    auto entry_ptr = defaultAllocator().allocT!ThreadEntry();
    if (!entry_ptr)
        return null;
    *entry_ptr = entry;

    Thread handle;
    version (Windows)
    {
        import urt.internal.sys.windows.winbase : CreateThread;
        handle = CreateThread(null, stack_size, &_win_entry, entry_ptr, 0, null);
    }
    else version (Posix)
    {
        pthread_t tid;
        int err;
        if (stack_size == 0)
        {
            err = pthread_create(&tid, null, &_posix_entry, entry_ptr);
        }
        else
        {
            pthread_attr_t attr;
            pthread_attr_init(&attr);
            pthread_attr_setstacksize(&attr, stack_size);
            err = pthread_create(&tid, &attr, &_posix_entry, entry_ptr);
            pthread_attr_destroy(&attr);
        }
        handle = (err == 0) ? cast(Thread)tid : null;
    }
    else version (FreeRTOS)
    {
        import urt.internal.sys.freertos;
        UBaseType_t prio = uxTaskPriorityGet(null);   // inherit current task's priority
        uint stack = stack_size ? cast(uint)stack_size : 4096;
        TaskHandle_t h;
        if (xTaskCreate(&_freertos_entry, null, stack, entry_ptr, prio, &h) != pdPASS)
            h = null;
        handle = h;
    }
    else
        assert(false, "thread_spawn not supported on this target");

    if (!handle)
    {
        defaultAllocator().freeT(entry_ptr);
        return null;
    }
    return handle;
}

void thread_join(Thread t)
{
    if (!t)
        return;
    version (Windows)
    {
        import urt.internal.sys.windows.winbase : WaitForSingleObject, CloseHandle, INFINITE;
        WaitForSingleObject(t, INFINITE);
        CloseHandle(t);
    }
    else version (Posix)
        pthread_join(cast(pthread_t)t, null);
    else version (FreeRTOS)
        assert(false, "thread_join is not yet implemented on FreeRTOS");
    else
        return;
}


private:

version (Windows)
{
    extern(Windows) uint _win_entry(void* arg) nothrow @nogc
    {
        auto entry_ptr = cast(ThreadEntry*)arg;
        ThreadEntry entry = *entry_ptr;
        defaultAllocator().freeT(entry_ptr);
        entry();
        return 0;
    }
}
else version (Posix)
{
    extern(C) void* _posix_entry(void* arg) nothrow @nogc
    {
        auto entry_ptr = cast(ThreadEntry*)arg;
        ThreadEntry entry = *entry_ptr;
        defaultAllocator().freeT(entry_ptr);
        entry();
        return null;
    }
}
else version (FreeRTOS)
{
    extern(C) void _freertos_entry(void* arg) nothrow @nogc
    {
        import urt.internal.sys.freertos : vTaskDelete;
        auto entry_ptr = cast(ThreadEntry*)arg;
        ThreadEntry entry = *entry_ptr;
        defaultAllocator().freeT(entry_ptr);
        entry();
        vTaskDelete(null);
    }
}


// --- Platform bindings --------------------------------------------------

version (Posix)
{
    extern(C) nothrow @nogc:

    // pthread_t -- typedef varies by impl. Linux glibc: unsigned long.
    // Darwin: _opaque_pthread_t*.
    alias pthread_t = void*;

    // pthread_attr_t -- opaque, platform-sized.
    // Linux: 56 bytes (x86_64), 36 (x86). Darwin: 56 (64-bit), 36 (32-bit).
    // Conservative ceilings below.
    version (linux)
    {
        static if (size_t.sizeof == 8)
            struct pthread_attr_t { align(8) ubyte[64] _; }
        else
            struct pthread_attr_t { align(4) ubyte[36] _; }
    }
    else version (Darwin)
    {
        static if (size_t.sizeof == 8)
            struct pthread_attr_t { align(8) ubyte[64] _; }
        else
            struct pthread_attr_t { align(4) ubyte[40] _; }
    }
    else
        static assert(false, "pthread_attr_t size not configured for this POSIX target");

    alias PthreadStart = extern(C) void* function(void*) nothrow @nogc;
    int pthread_create(pthread_t*, const(pthread_attr_t)*, PthreadStart, void*);
    int pthread_join(pthread_t, void**);
    int pthread_attr_init(pthread_attr_t*);
    int pthread_attr_destroy(pthread_attr_t*);
    int pthread_attr_setstacksize(pthread_attr_t*, size_t);
}


version (Windows)    enum _has_smoke = true;
else version (Posix) enum _has_smoke = true;
else                 enum _has_smoke = false;

static if (_has_smoke)
{
    import urt.atomic;

    unittest
    {
        static shared int _smoke_counter;

        atomicStore(_smoke_counter, 0);
        Thread t = thread_spawn(() nothrow @nogc { atomicFetchAdd(_smoke_counter, 1); });
        assert(t !is null);
        thread_join(t);
        assert(atomicLoad(_smoke_counter) == 1);
    }
}
