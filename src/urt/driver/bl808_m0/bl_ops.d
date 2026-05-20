/// libwifi.a OS abstraction shim.
///
/// The vendor LMAC blob (libwifi.a) routes every OS-flavoured call through
/// a single function-pointer table, g_bl_ops_funcs. The vendor SDK fills
/// it with FreeRTOS-backed implementations; we fill it with urt-backed
/// ones. Layout MUST match include/bl_os_adapter/bl_os_adapter.h exactly
/// -- the blob indexes the struct by offset.
///
/// Threading model: cooperative single-thread with wifi_main running as a
/// urt fibre. Blob sync primitives are represented as stateful objects; calls
/// that would block yield an AwakenEvent, and ISR/host-side signals mutate the
/// primitive state so the host can resume the fibre when the event is ready.
///
/// Anything not yet implemented returns conservative success/null where the
/// current open path requires it, and is hardened as more of the blob surface
/// is exercised.

module urt.driver.bl808_m0.bl_ops;

import urt.attribute : section;

version (BL808_M0):

import urt.mem.alloc : alloc, free, MemFlags;
import urt.mem       : memset;
import urt.driver.bl618.irq   : irq_disable, irq_enable, set_interrupts;
import urt.driver.bl618.timer : mtime_read, mtime_freq_hz;
import urt.fibre              : Fibre, AwakenEvent, FibreEntryFunc, ResumeHandler,
                                yield, isInFibre;
import urt.util               : InPlace;
import urt.lifetime           : emplace;

nothrow @nogc:


enum BL_OS_ADAPTER_VERSION = 0x00000001;

extern (C):

alias BL_TaskHandle_t   = void*;
alias BL_EventGroup_t   = void*;
alias BL_Timer_t        = void*;
alias BL_Sem_t          = void*;
alias BL_Mutex_t        = void*;
alias BL_MessageQueue_t = void*;
alias BL_TimeOut_t      = uint;
alias BL_TickType_t     = uint;

struct bl_ops_funcs_t
{
    int       _version;
    void   function(const(char)*, ...)                                            _printf;
    void   function(const(char)*)                                                 _puts;
    void   function(const(char)*, int, const(char)*, const(char)*)                _assert;
    int    function()                                                             _init;
    uint   function()                                                             _enter_critical;
    void   function(uint)                                                         _exit_critical;
    int    function(long)                                                         _msleep;
    int    function(uint)                                                         _sleep;
    BL_EventGroup_t function()                                                    _event_group_create;
    void   function(BL_EventGroup_t)                                              _event_group_delete;
    uint   function(BL_EventGroup_t, uint)                                        _event_group_send;
    uint   function(BL_EventGroup_t, uint, int, int, uint)                        _event_group_wait;
    int    function(int, void*, void*)                                            _event_register;
    int    function(int, int)                                                     _event_notify;
    int    function(const(char)*, void*, uint, void*, uint, BL_TaskHandle_t)      _task_create;
    void   function(BL_TaskHandle_t)                                              _task_delete;
    BL_TaskHandle_t function()                                                    _task_get_current_task;
    BL_TaskHandle_t function()                                                    _task_notify_create;
    void   function(BL_TaskHandle_t)                                              _task_notify;
    void   function(BL_TaskHandle_t, uint)                                        _task_wait;
    void   function()                                                             _lock_gaint;
    void   function()                                                             _unlock_gaint;
    void   function(int, void*, void*)                                            _irq_attach;
    void   function(int)                                                          _irq_enable;
    void   function(int)                                                          _irq_disable;
    void*  function()                                                             _workqueue_create;
    int    function(void*, void*, void*, long)                                    _workqueue_submit_hp;
    int    function(void*, void*, void*, long)                                    _workqueue_submit_lp;
    BL_Timer_t function(void*, void*)                                             _timer_create;
    int    function(BL_Timer_t, uint)                                             _timer_delete;
    int    function(BL_Timer_t, long, long)                                       _timer_start_once;
    int    function(BL_Timer_t, long, long)                                       _timer_start_periodic;
    BL_Sem_t function(uint)                                                       _sem_create;
    void   function(BL_Sem_t)                                                     _sem_delete;
    int    function(BL_Sem_t, uint)                                               _sem_take;
    int    function(BL_Sem_t)                                                     _sem_give;
    BL_Mutex_t function()                                                         _mutex_create;
    void   function(BL_Mutex_t)                                                   _mutex_delete;
    int    function(BL_Mutex_t)                                                   _mutex_lock;
    int    function(BL_Mutex_t)                                                   _mutex_unlock;
    BL_MessageQueue_t function(uint, uint)                                        _queue_create;
    void   function(BL_MessageQueue_t)                                            _queue_delete;
    int    function(BL_MessageQueue_t, void*, uint, uint, int)                    _queue_send_wait;
    int    function(BL_MessageQueue_t, void*, uint)                               _queue_send;
    int    function(BL_MessageQueue_t, void*, uint, uint)                         _queue_recv;
    void*  function(uint)                                                         _malloc;
    void   function(void*)                                                        _free;
    void*  function(uint)                                                         _zalloc;
    ulong  function()                                                             _get_time_ms;
    uint   function()                                                             _get_tick;
    void   function(uint, const(char)*, const(char)*, int, const(char)*, ...)     _log_write;
    int    function(BL_TaskHandle_t)                                              _task_notify_isr;
    void   function(int)                                                          _yield_from_isr;
    uint   function(uint)                                                         _ms_to_tick;
    BL_TimeOut_t function()                                                       _set_timeout;
    int    function(BL_TimeOut_t, BL_TickType_t*)                                 _check_timeout;
}


import urt.driver.bl618.uart : uart0_hw_puts;

void bl_ops_printf(const(char)* fmt, ...)
{
}

void bl_ops_puts(const(char)* s)
{
}

void bl_ops_log_write(uint level, const(char)* tag, const(char)* file, int line, const(char)* fmt, ...)
{
}

private size_t safe_cstr(const(char)* s) nothrow @nogc
{
    if (s is null)
        return 0;
    size_t addr = cast(size_t)s;
    // M0 valid: flash 0x58000000+, OCRAM 0x22000000+/0x40000000+, TCM 0x6202F000+
    bool in_range = (addr >= 0x22000000 && addr < 0x80000000);
    if (!in_range)
        return 0;
    ubyte first = cast(ubyte)s[0];
    if (first < 0x20 || first > 0x7E)
        return 0;
    size_t n = 0;
    while (n < 256 && s[n] != 0)
        ++n;
    return n;
}

void bl_ops_assert(const(char)* file, int line, const(char)* func, const(char)* expr)
{
    import urt.io : writef;
    uart0_hw_puts("\n*** BLOB ASSERT: ");
    print_strarg("file", file);
    writef(":{0} ", line);
    print_strarg("func", func);
    print_strarg("expr", expr);
    uart0_hw_puts(" ***\n");
    assert(false, "blob assert");
}

private void print_strarg(string label, const(char)* s) nothrow @nogc
{
    import urt.io : writef;
    size_t n = safe_cstr(s);
    if (n > 0)
        uart0_hw_puts(s[0 .. n]);
    else
        writef("<{0}={1,08X} bogus>", label, cast(uint)cast(size_t)s);
}

int bl_ops_init() { return 0; }

// Critical sections -- global IRQ mask. Returns prior state in the low
// bit; symmetric with _exit_critical taking that token back.
uint bl_ops_enter_critical()
{
    return irq_disable() ? 1 : 0;
}

void bl_ops_exit_critical(uint level)
{
    set_interrupts(level != 0);
}

// Time / sleep. The blob treats "tick" values like an RTOS tick counter,
// and AP station timeout code compares them against constants such as
// 30000. Use a 1 kHz tick base so those constants retain their SDK meaning.
ulong bl_ops_get_time_ms() => mtime_read() / (mtime_freq_hz / 1000);
uint  bl_ops_get_tick()    => cast(uint)bl_ops_get_time_ms();
uint  bl_ops_ms_to_tick(uint ms) => ms;

int bl_ops_msleep(long ms)
{
    if (ms <= 0)
        return 0;
    if (isInFibre())
    {
        import urt.fibre : fibre_sleep = sleep;
        import urt.time : msecs;
        try
            fibre_sleep(ms.msecs);
        catch (Throwable)
            assert(false, "wifi fibre msleep yield threw unexpectedly");
        return 0;
    }
    // Host context: no fibre to yield to. Honour the duration with a spin.
    ulong target = mtime_read() + cast(ulong)ms * (mtime_freq_hz / 1000);
    while (mtime_read() < target) {}
    return 0;
}

int bl_ops_sleep(uint s) => bl_ops_msleep(s * 1000L);

BL_TimeOut_t bl_ops_set_timeout() => bl_ops_get_tick();

int bl_ops_check_timeout(BL_TimeOut_t start, BL_TickType_t* ticks_to_wait)
{
    if (ticks_to_wait is null)
        return 0;
    uint elapsed = bl_ops_get_tick() - start;
    if (elapsed >= *ticks_to_wait)
        return 1;
    *ticks_to_wait -= elapsed;
    return 0;
}

// Memory
void* bl_ops_malloc(uint size)
{
    return alloc(size, uint.sizeof, MemFlags.dma).ptr;
}

void bl_ops_free(void* p)
{
    if (p is null)
        return;
    // urt.mem.alloc.free only uses mem.ptr; length is irrelevant.
    free(p[0 .. 1]);
}

void* bl_ops_zalloc(uint size)
{
    void* p = alloc(size, uint.sizeof, MemFlags.dma).ptr;
    if (p !is null)
        memset(p, 0, size);
    return p;
}

// ---- Cooperative single-thread primitives ------------------------------
//
// In our drain-on-update model there is no real concurrency between blob
// "tasks". Mutexes/semaphores/events become trivial counters/flags. If we
// later run the blob on top of urt fibres these grow real bodies.

struct shim_mutex { uint locked; }
struct shim_sem   { int count; int max; }
struct shim_event { uint bits; }

BL_Mutex_t bl_ops_mutex_create()
{
    auto m = cast(shim_mutex*)bl_ops_zalloc(shim_mutex.sizeof);
    return m;
}
void bl_ops_mutex_delete(BL_Mutex_t h) { bl_ops_free(h); }
int  bl_ops_mutex_lock(BL_Mutex_t h)
{
    auto m = cast(shim_mutex*)h;
    if (m is null) return -1;
    m.locked = 1;
    return 0;
}
int bl_ops_mutex_unlock(BL_Mutex_t h)
{
    auto m = cast(shim_mutex*)h;
    if (m is null) return -1;
    m.locked = 0;
    return 0;
}

BL_Sem_t bl_ops_sem_create(uint init)
{
    auto s = cast(shim_sem*)bl_ops_zalloc(shim_sem.sizeof);
    if (s !is null)
        s.count = cast(int)init;
    return s;
}
void bl_ops_sem_delete(BL_Sem_t h) { bl_ops_free(h); }
int  bl_ops_sem_take(BL_Sem_t h, uint ticks)
{
    auto s = cast(shim_sem*)h;
    if (s is null) return -1;

    while (s.count == 0)
    {
        if (isInFibre())
        {
            auto ev = InPlace!SemAwaken(s);
            yield_nothrow(ev);
        }
        else if (!wifi_pump_one_for_host())
            return -1;
    }
    --s.count;
    return 0;
}
int bl_ops_sem_give(BL_Sem_t h)
{
    auto s = cast(shim_sem*)h;
    if (s is null) return -1;
    ++s.count;
    wifi_signal_ready();
    return 0;
}

BL_EventGroup_t bl_ops_event_group_create()
{
    return cast(shim_event*)bl_ops_zalloc(shim_event.sizeof);
}
void bl_ops_event_group_delete(BL_EventGroup_t h) { bl_ops_free(h); }
uint bl_ops_event_group_send(BL_EventGroup_t h, uint bits)
{
    auto e = cast(shim_event*)h;
    if (e is null) return 0;
    e.bits |= bits;
    wifi_signal_ready();
    return e.bits;
}
uint bl_ops_event_group_wait(BL_EventGroup_t h, uint wait_bits, int clear_on_exit, int wait_all, uint block_ticks)
{
    auto e = cast(shim_event*)h;
    if (e is null) return 0;

    bool waitAll = wait_all != 0;
    while (true)
    {
        uint got = e.bits & wait_bits;
        if (waitAll ? (got == wait_bits) : (got != 0))
        {
            if (clear_on_exit)
                e.bits &= ~got;
            return got;
        }

        if (isInFibre())
        {
            auto ev = InPlace!EventGroupAwaken(e, wait_bits, waitAll);
            yield_nothrow(ev);
        }
        else if (!wifi_pump_one_for_host())
            return 0;
    }
}

int bl_ops_event_register(int type, void* cb, void* arg) { return 0; }
int bl_ops_event_notify(int evt, int val)                { return 0; }

// "Gaint" (giant) lock -- global serialising lock. Map to enter_critical.
void bl_ops_lock_gaint()
{
    irq_disable();
}
void bl_ops_unlock_gaint()
{
    irq_enable();
}


// ====================================================================
// Fibre infrastructure for the wifi_main task.
//
// libwifi.a's wifi_main is a long-lived event loop that processes LMAC
// messages -- vendor SDK runs it as a FreeRTOS task. We run it as a
// single urt fibre. Blocking primitives (sem_take/event_group_wait/
// queue_recv) yield to the main fibre when called from inside the
// wifi_main fibre, and pump the wifi fibre when called from host code
// (e.g. bl_send_reset waiting for MM_RESET_CFM).
//
// One fibre, one pending awaken event at a time. If we need more later
// (concurrent waiters) we extend; for now wifi_main is the only thing.
// ====================================================================

__gshared Fibre*       _wifi_fibre;
__gshared AwakenEvent  _wifi_pending_event;

extern(D)
{
    alias WifiWakeCallback = void function() nothrow @nogc;
    private __gshared WifiWakeCallback _wifi_wake_callback;

    public void wifi_set_wake_callback(WifiWakeCallback cb)
    {
        _wifi_wake_callback = cb;
    }

    public void wifi_signal_ready()
    {
        auto cb = _wifi_wake_callback;
        if (cb !is null)
            cb();
    }
}

private extern (D) ResumeHandler wifi_yield_handler(ref Fibre yielding, AwakenEvent ev) nothrow @nogc
{
    _wifi_pending_event = ev;
    return null;
}

/// nothrow wrapper around urt.fibre.yield. The only path yield() can
/// throw on is fibre-abort, which we never trigger.
private void yield_nothrow(AwakenEvent ev) nothrow @nogc
{
    try
        yield(ev);
    catch (Throwable)
        assert(false, "wifi fibre yield threw unexpectedly");
}

/// Set to true once wifi_main has reached its event-loop entry (first
/// call to bl_sleep_check). Used by wifi_hw_open to pump wifi_main
/// through its init *before* writing A2E_TRIGGER -- otherwise vendor's
/// Configure-IPC step inside wifi_main clobbers our trigger bit and
/// the host's bl_send_reset is never seen.
public __gshared bool wifi_main_in_main_loop;

/// Resume the wifi fibre if its awaken event is ready (or if it's just
/// been spawned and hasn't run yet). Safe to call repeatedly; a no-op
/// when the fibre is finished or blocked on an unsatisfied event.
public void wifi_fibre_pump()
{
    if (_wifi_fibre is null || _wifi_fibre.isFinished)
        return;
    if (_wifi_pending_event !is null && !_wifi_pending_event.ready())
        return;
    _wifi_pending_event = null;
    _wifi_fibre.resume();
}

/// Host-side pump step for sync waits (bl_ops_*_wait called from host
/// context, not from the fibre). Returns true if the fibre is still live;
/// false if dead and the wait must give up.
///
/// All wifi_main wakes come from real IRQs (vec 70 mac_irq, vec 79
/// bl_irq_handler) calling into the blob's natural shim chain
/// (sem_give/event_group_send/queue_send/task_notify), which makes the
/// appropriate AwakenEvent ready. No synthetic wakes, no manual A2E
/// dispatch -- if wifi_main doesn't progress, the real IRQ wiring is wrong
/// and that's the bug to fix.
private bool wifi_pump_one_for_host()
{
    if (_wifi_fibre is null || _wifi_fibre.isFinished)
        return false;
    wifi_fibre_pump();
    return true;
}

// AwakenEvent subclasses -- one per blocking primitive. AwakenEvent's
// methods are extern(D) (inside an extern(C++) class), so our overrides
// have to drop back to D linkage from the file-level extern(C).
extern (C++) class SemAwaken : AwakenEvent
{
extern(D) nothrow @nogc:
    shim_sem* sem;
    this(shim_sem* s) { sem = s; }
    override bool ready() { return sem.count > 0; }
}

extern (C++) class EventGroupAwaken : AwakenEvent
{
extern(D) nothrow @nogc:
    shim_event* ev;
    uint  mask;
    bool  wait_all;
    this(shim_event* e, uint m, bool all) { ev = e; mask = m; wait_all = all; }
    override bool ready()
    {
        uint got = ev.bits & mask;
        return wait_all ? (got == mask) : (got != 0);
    }
}

extern (C++) class QueueAwaken : AwakenEvent
{
extern(D) nothrow @nogc:
    shim_queue* q;
    this(shim_queue* x) { q = x; }
    override bool ready() { return q.count > 0; }
}

extern (C++) class TaskAwaken : AwakenEvent
{
extern(D) nothrow @nogc:
    shim_task* task;
    this(shim_task* t) { task = t; }
    override bool ready() { return task.notify_count > 0; }
}



// Tasks. First task_create spawns the wifi fibre; subsequent calls are
// recorded but ignored (we only run wifi_main on this platform).
//
// FreeRTOS task notifications are a per-task counter: notify() increments,
// wait() decrements (blocking until non-zero). Used by wifi_main as its
// idle/wake primitive when an ISR has data to hand off. We have one task,
// so one shim_task is enough; the handle the blob passes is its address.

struct shim_task
{
    uint notify_count;
}

__gshared shim_task _wifi_task;

int bl_ops_task_create(const(char)* name, void* entry, uint stack_depth, void* param, uint prio, BL_TaskHandle_t handle)
{
    if (_wifi_fibre !is null)
        return 0;  // already have one

    // FreeRTOS StackType_t is uint32_t -> stack_depth is words. Match
    // the vendor's 1536 words = 6KB if smaller is passed, otherwise
    // honour the caller's request.
    size_t stack_bytes = stack_depth * 4;
    if (stack_bytes < 6 * 1024)
        stack_bytes = 6 * 1024;

    void[] mem = alloc(Fibre.sizeof, Fibre.alignof);
    if (mem.ptr is null)
        return -1;
    _wifi_fibre = cast(Fibre*)mem.ptr;
    emplace!Fibre(_wifi_fibre, cast(FibreEntryFunc)entry, &wifi_yield_handler, param, stack_bytes);
    return 0;
}
void bl_ops_task_delete(BL_TaskHandle_t h)            {}
BL_TaskHandle_t bl_ops_task_get_current()    => cast(void*)&_wifi_task;
BL_TaskHandle_t bl_ops_task_notify_create()  => cast(void*)&_wifi_task;

void bl_ops_task_notify(BL_TaskHandle_t h)
{
    auto t = cast(shim_task*)h;
    if (t is null) return;
    ++t.notify_count;
    wifi_signal_ready();
}

void bl_ops_task_wait(BL_TaskHandle_t h, uint ticks)
{
    auto t = cast(shim_task*)h;
    if (t is null)
        return;
    while (t.notify_count == 0)
    {
        if (isInFibre())
        {
            auto ev = InPlace!TaskAwaken(t);
            yield_nothrow(ev);
        }
        else if (!wifi_pump_one_for_host())
            return;
    }
    --t.notify_count;
}

// ISR variant -- on this platform we don't have preemption, so an "ISR
// notify" is the same as a task notify. Return 1 to indicate "would
// cause a context switch" (vendor's flag is purely informational here).
int bl_ops_task_notify_isr(BL_TaskHandle_t h)
{
    bl_ops_task_notify(h);
    return 1;
}
void bl_ops_yield_from_isr(int yield)                 {}

// Queues -- simple heap-allocated ring. SPSC is enough since we're
// cooperative. Capacity = queue_len * item_size bytes; head/tail are
// indices in items, not bytes.
struct shim_queue
{
    ubyte* buf;
    uint   item_size;
    uint   capacity;     // number of items
    uint   head;         // next write
    uint   tail;         // next read
    uint   count;
}

BL_MessageQueue_t bl_ops_queue_create(uint queue_len, uint item_size)
{
    auto q = cast(shim_queue*)bl_ops_zalloc(shim_queue.sizeof);
    if (q is null) return null;
    q.buf = cast(ubyte*)bl_ops_malloc(queue_len * item_size);
    if (q.buf is null) { bl_ops_free(q); return null; }
    q.item_size = item_size;
    q.capacity  = queue_len;
    return q;
}
void bl_ops_queue_delete(BL_MessageQueue_t h)
{
    auto q = cast(shim_queue*)h;
    if (q is null) return;
    bl_ops_free(q.buf);
    bl_ops_free(q);
}
int bl_ops_queue_send(BL_MessageQueue_t h, void* item, uint len)
{
    auto q = cast(shim_queue*)h;
    if (q is null || q.count == q.capacity) return -1;
    auto slot = q.buf + q.head * q.item_size;
    slot[0 .. q.item_size] = (cast(ubyte*)item)[0 .. q.item_size];
    q.head = (q.head + 1) % q.capacity;
    ++q.count;
    wifi_signal_ready();
    return 0;
}
int bl_ops_queue_send_wait(BL_MessageQueue_t h, void* item, uint len, uint ticks, int prio)
    => bl_ops_queue_send(h, item, len);
int bl_ops_queue_recv(BL_MessageQueue_t h, void* item, uint len, uint ticks)
{
    auto q = cast(shim_queue*)h;
    if (q is null) return -1;

    while (q.count == 0)
    {
        if (isInFibre())
        {
            auto ev = InPlace!QueueAwaken(q);
            yield_nothrow(ev);
        }
        else if (!wifi_pump_one_for_host())
            return -1;
    }
    auto slot = q.buf + q.tail * q.item_size;
    (cast(ubyte*)item)[0 .. q.item_size] = slot[0 .. q.item_size];
    q.tail = (q.tail + 1) % q.capacity;
    --q.count;
    return 0;
}

// Timers -- record callback + period; we'll drive the firing logic from
// our update loop once that's wired. For now, creation succeeds but the
// timer never fires.
struct shim_timer
{
    extern(C) void function() nothrow @nogc cb;
    void*  arg;
    ulong  fire_at_us;
    ulong  period_us;
    ubyte  active;
}

BL_Timer_t bl_ops_timer_create(void* func, void* arg)
{
    auto t = cast(shim_timer*)bl_ops_zalloc(shim_timer.sizeof);
    if (t !is null)
    {
        t.cb  = cast(typeof(shim_timer.cb))func;
        t.arg = arg;
    }
    return t;
}
int bl_ops_timer_delete(BL_Timer_t h, uint ticks)
{
    bl_ops_free(h);
    return 0;
}
int bl_ops_timer_start_once(BL_Timer_t h, long t_sec, long t_nsec)
{
    auto t = cast(shim_timer*)h;
    if (t is null) return -1;
    ulong us = cast(ulong)t_sec * 1_000_000UL + cast(ulong)t_nsec / 1000;
    t.fire_at_us = mtime_read() + us;
    t.period_us  = 0;
    t.active     = 1;
    return 0;
}
int bl_ops_timer_start_periodic(BL_Timer_t h, long t_sec, long t_nsec)
{
    auto t = cast(shim_timer*)h;
    if (t is null) return -1;
    ulong us = cast(ulong)t_sec * 1_000_000UL + cast(ulong)t_nsec / 1000;
    t.fire_at_us = mtime_read() + us;
    t.period_us  = us;
    t.active     = 1;
    return 0;
}

void bl_ops_irq_attach(int n, void* f, void* arg) {}
void bl_ops_irq_enable(int n)  {}
void bl_ops_irq_disable(int n) {}

// Workqueues -- run submitted work synchronously for now. Two priority
// levels collapse to one.
void* bl_ops_workqueue_create() => cast(void*)1;  // non-null sentinel
int bl_ops_workqueue_submit_hp(void* work, void* worker, void* argv, long tick)
{
    if (worker !is null)
    {
        alias work_fn = extern(C) void function(void*) nothrow @nogc;
        (cast(work_fn)worker)(argv);
    }
    return 0;
}
int bl_ops_workqueue_submit_lp(void* work, void* worker, void* argv, long tick)
    => bl_ops_workqueue_submit_hp(work, worker, argv, tick);


@section(".sram_data.wifi") __gshared bl_ops_funcs_t g_bl_ops_funcs = {
    _version:                BL_OS_ADAPTER_VERSION,
    _printf:                 &bl_ops_printf,
    _puts:                   &bl_ops_puts,
    _assert:                 &bl_ops_assert,
    _init:                   &bl_ops_init,
    _enter_critical:         &bl_ops_enter_critical,
    _exit_critical:          &bl_ops_exit_critical,
    _msleep:                 &bl_ops_msleep,
    _sleep:                  &bl_ops_sleep,
    _event_group_create:     &bl_ops_event_group_create,
    _event_group_delete:     &bl_ops_event_group_delete,
    _event_group_send:       &bl_ops_event_group_send,
    _event_group_wait:       &bl_ops_event_group_wait,
    _event_register:         &bl_ops_event_register,
    _event_notify:           &bl_ops_event_notify,
    _task_create:            &bl_ops_task_create,
    _task_delete:            &bl_ops_task_delete,
    _task_get_current_task:  &bl_ops_task_get_current,
    _task_notify_create:     &bl_ops_task_notify_create,
    _task_notify:            &bl_ops_task_notify,
    _task_wait:              &bl_ops_task_wait,
    _lock_gaint:             &bl_ops_lock_gaint,
    _unlock_gaint:           &bl_ops_unlock_gaint,
    _irq_attach:             &bl_ops_irq_attach,
    _irq_enable:             &bl_ops_irq_enable,
    _irq_disable:            &bl_ops_irq_disable,
    _workqueue_create:       &bl_ops_workqueue_create,
    _workqueue_submit_hp:    &bl_ops_workqueue_submit_hp,
    _workqueue_submit_lp:    &bl_ops_workqueue_submit_lp,
    _timer_create:           &bl_ops_timer_create,
    _timer_delete:           &bl_ops_timer_delete,
    _timer_start_once:       &bl_ops_timer_start_once,
    _timer_start_periodic:   &bl_ops_timer_start_periodic,
    _sem_create:             &bl_ops_sem_create,
    _sem_delete:             &bl_ops_sem_delete,
    _sem_take:               &bl_ops_sem_take,
    _sem_give:               &bl_ops_sem_give,
    _mutex_create:           &bl_ops_mutex_create,
    _mutex_delete:           &bl_ops_mutex_delete,
    _mutex_lock:             &bl_ops_mutex_lock,
    _mutex_unlock:           &bl_ops_mutex_unlock,
    _queue_create:           &bl_ops_queue_create,
    _queue_delete:           &bl_ops_queue_delete,
    _queue_send_wait:        &bl_ops_queue_send_wait,
    _queue_send:             &bl_ops_queue_send,
    _queue_recv:             &bl_ops_queue_recv,
    _malloc:                 &bl_ops_malloc,
    _free:                   &bl_ops_free,
    _zalloc:                 &bl_ops_zalloc,
    _get_time_ms:            &bl_ops_get_time_ms,
    _get_tick:               &bl_ops_get_tick,
    _log_write:              &bl_ops_log_write,
    _task_notify_isr:        &bl_ops_task_notify_isr,
    _yield_from_isr:         &bl_ops_yield_from_isr,
    _ms_to_tick:             &bl_ops_ms_to_tick,
    _set_timeout:            &bl_ops_set_timeout,
    _check_timeout:          &bl_ops_check_timeout,
};
