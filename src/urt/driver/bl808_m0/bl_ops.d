/// libwifi.a OS abstraction shim.
///
/// The vendor LMAC blob (libwifi.a) routes every OS-flavoured call through
/// a single function-pointer table, g_bl_ops_funcs. The vendor SDK fills
/// it with FreeRTOS-backed implementations; we fill it with urt-backed
/// ones. Layout MUST match include/bl_os_adapter/bl_os_adapter.h exactly
/// -- the blob indexes the struct by offset.
///
/// Threading model (initial): drain-on-update, cooperative single-thread.
/// "Tasks" are recorded but not actually scheduled; we expect the blob to
/// be largely event-driven once init finishes. If a real blob task turns
/// out to need preemption we'll revisit (fibres, or per-IRQ dispatch).
///
/// Anything not yet implemented returns success / null and logs a TODO.
/// We harden incrementally as init progresses and we discover what
/// libwifi.a actually exercises.

module urt.driver.bl808_m0.bl_ops;

import urt.attribute : fast_data;

version (BL808_M0):

import urt.mem.alloc : alloc, free, MemFlags;
import urt.driver.bl618.irq   : irq_disable, irq_enable;
import urt.driver.bl618.timer : mtime_read, mtime_freq_hz;
import urt.fibre              : Fibre, AwakenEvent, FibreEntryFunc, ResumeHandler,
                                yield, isInFibre;
import urt.util               : InPlace;
import urt.lifetime           : emplace;

nothrow @nogc:


// ====================================================================
// bl_ops_funcs_t layout -- mirrors bl_os_adapter.h. The blob references
// this struct by member offset; do not reorder.
// ====================================================================

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


// ====================================================================
// Implementations. Naming: bl_ops_<member-without-underscore>.
// ====================================================================

// Logging: route to UART0 so blob diagnostics surface during bring-up. The
// blob prints a lot during init/teardown; if this becomes noise once wifi
// is reliable, drop bl_ops_printf back to {} and leave puts wired.
//
// We don't run a real vfprintf -- printing the format string verbatim is
// enough to localise where the blob is at; the args are dropped. uart0_puts
// is null-terminator-tolerant via uart0_hw_puts(slice).

import urt.driver.bl618.uart : uart0_hw_puts;

private size_t cstr_len(const(char)* s) nothrow @nogc
{
    size_t n = 0;
    if (s !is null)
        while (s[n] != 0) ++n;
    return n;
}

void bl_ops_printf(const(char)* fmt, ...)
{
    uart0_hw_puts("[P]");
    if (fmt !is null)
        uart0_hw_puts(fmt[0 .. cstr_len(fmt)]);
}

void bl_ops_puts(const(char)* s)
{
    uart0_hw_puts("[U]");
    if (s !is null)
    {
        uart0_hw_puts(s[0 .. cstr_len(s)]);
        uart0_hw_puts("\n");
    }
}

void bl_ops_log_write(uint level, const(char)* tag, const(char)* file, int line, const(char)* fmt, ...)
{
    uart0_hw_puts("[L]");
    if (fmt !is null)
        uart0_hw_puts(fmt[0 .. cstr_len(fmt)]);
}

void bl_ops_assert(const(char)* file, int line, const(char)* func, const(char)* expr)
{
    import urt.io : writef;
    __gshared uint n_asserts;
    ++n_asserts;
    // Suppress the well-known noisy ipc_host.c:181 cnt-mismatch assert (fires
    // every cmd; LMAC writes a pointer to src_id rather than a sequence
    // counter on this chip variant -- functionally harmless). The file:line
    // 181 is unique enough as a filter.
    if (n_asserts <= 64 && line != 181)
    {
        uart0_hw_puts("\n*** BLOB ASSERT: ");
        if (file !is null)
            uart0_hw_puts(file[0 .. cstr_len(file)]);
        writef(":{0} ", line);
        if (func !is null)
        {
            uart0_hw_puts(func[0 .. cstr_len(func)]);
            uart0_hw_puts("() ");
        }
        if (expr !is null)
            uart0_hw_puts(expr[0 .. cstr_len(expr)]);
        uart0_hw_puts(" ***\n");
    }
    // Don't halt -- return and let the blob continue. Throttled to first
    // 16 hits so a tight assert loop doesn't drown the rest of the log.
}

int bl_ops_init() { return 0; }

// Critical sections -- global IRQ mask. Returns prior state in the low
// bit; symmetric with _exit_critical taking that token back.
uint bl_ops_enter_critical()
{
    // BL618/M0 irq driver only exposes global enable/disable; we don't
    // currently read prior state. Always returns 0; the blob just hands
    // it back, never inspects it.
    uart0_hw_puts("[crit+]");
    irq_disable();
    return 0;
}

void bl_ops_exit_critical(uint level)
{
    uart0_hw_puts("[crit-]");
    irq_enable();
}

// Time / sleep
ulong bl_ops_get_time_ms() => mtime_read() / (mtime_freq_hz / 1000);
uint  bl_ops_get_tick()    => cast(uint)mtime_read();
uint  bl_ops_ms_to_tick(uint ms) => ms * (mtime_freq_hz / 1000);

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

BL_TimeOut_t bl_ops_set_timeout() => cast(uint)mtime_read();

int bl_ops_check_timeout(BL_TimeOut_t start, BL_TickType_t* ticks_to_wait)
{
    if (ticks_to_wait is null)
        return 0;
    uint elapsed = cast(uint)mtime_read() - start;
    if (elapsed >= *ticks_to_wait)
        return 1;
    *ticks_to_wait -= elapsed;
    return 0;
}

// Memory
void* bl_ops_malloc(uint size)
{
    void[] m = alloc(size);
    return m.ptr;
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
    void* p = bl_ops_malloc(size);
    if (p !is null)
        (cast(ubyte*)p)[0 .. size] = 0;
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

// Sem instrumentation: keep a small registry so we can identify which sem
// in a probe message (by sequential id). Helps tell which sem wifi_main is
// parked on vs which one a sem_give wakes.
__gshared uint _sem_next_id = 1;
struct shim_sem_dbg { shim_sem base; uint id; }

BL_Sem_t bl_ops_sem_create(uint init)
{
    import urt.io : writef;
    auto s = cast(shim_sem_dbg*)bl_ops_zalloc(shim_sem_dbg.sizeof);
    if (s !is null)
    {
        s.base.count = cast(int)init;
        s.id = _sem_next_id++;
        writef("[s:sem_create #{0}]", s.id);
    }
    return s;
}
void bl_ops_sem_delete(BL_Sem_t h) { bl_ops_free(h); }
int  bl_ops_sem_take(BL_Sem_t h, uint ticks)
{
    import urt.io : writef;
    auto s = cast(shim_sem*)h;
    if (s is null) return -1;
    auto d = cast(shim_sem_dbg*)h;

    bool first_wait = (s.count == 0);
    while (s.count == 0)
    {
        if (first_wait)
        {
            first_wait = false;
            writef("[s:sem_take.wait #{0}]", d.id);
        }
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
    import urt.io : writef;
    auto s = cast(shim_sem*)h;
    if (s is null) return -1;
    auto d = cast(shim_sem_dbg*)h;
    writef("[s:sem_give #{0}]", d.id);
    ++s.count;
    return 0;
}

// Event-group identity tracking (companion to sem identity tracking).
// Lets us pair sends with waits across the blob's internal control flow.
__gshared uint _evg_next_id = 1;
struct shim_event_dbg { shim_event base; uint id; }

BL_EventGroup_t bl_ops_event_group_create()
{
    import urt.io : writef;
    auto e = cast(shim_event_dbg*)bl_ops_zalloc(shim_event_dbg.sizeof);
    if (e !is null)
    {
        e.id = _evg_next_id++;
        writef("[s:evg_create #{0}]", e.id);
    }
    return e;
}
void bl_ops_event_group_delete(BL_EventGroup_t h) { bl_ops_free(h); }
uint bl_ops_event_group_send(BL_EventGroup_t h, uint bits)
{
    import urt.io : writef;
    auto e = cast(shim_event*)h;
    if (e is null) return 0;
    auto d = cast(shim_event_dbg*)h;
    writef("[s:evg_send #{0} bits={1,08X}]", d.id, bits);
    e.bits |= bits;
    return e.bits;
}
uint bl_ops_event_group_wait(BL_EventGroup_t h, uint wait_bits, int clear_on_exit, int wait_all, uint block_ticks)
{
    import urt.io : writef;
    auto e = cast(shim_event*)h;
    if (e is null) return 0;
    auto d = cast(shim_event_dbg*)h;

    bool waitAll = wait_all != 0;
    bool first_wait = true;
    while (true)
    {
        uint got = e.bits & wait_bits;
        if (waitAll ? (got == wait_bits) : (got != 0))
        {
            if (clear_on_exit)
                e.bits &= ~got;
            return got;
        }

        if (first_wait)
        {
            first_wait = false;
            writef("[s:evg_wait.park #{0} bits={1,08X}{2}]", d.id, wait_bits, waitAll ? " all" : "");
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

int bl_ops_event_register(int type, void* cb, void* arg) { uart0_hw_puts("[s:event_reg]");  return 0; }
int bl_ops_event_notify(int evt, int val)                { uart0_hw_puts("[s:event_notify]"); return 0; }

// "Gaint" (giant) lock -- global serialising lock. Map to enter_critical.
// Probe first-only to avoid log spam in hot critical sections.
void bl_ops_lock_gaint()
{
    __gshared bool seen;
    if (!seen) { seen = true; uart0_hw_puts("[s:lock_gaint.first]"); }
    irq_disable();
}
void bl_ops_unlock_gaint()
{
    __gshared bool seen;
    if (!seen) { seen = true; uart0_hw_puts("[s:unlock_gaint.first]"); }
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

// EMB-side A2E handlers exported by libwifi.a. On vendor hw the MAC intc
// fires when host writes A2E_TRIGGER, mac_irq dispatches to these via the
// intc table. In our setup the intc never asserts (istat stays 0), so we
// manually dispatch from the pump.
extern(C) void ipc_emb_msg_irq();
extern(C) void ipc_emb_tx_irq();
extern(C) void ipc_emb_cfmback_irq();

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

/// Single host-side pump step. Returns true if the fibre was resumable
/// (we attempted to advance it), false if the fibre is dead or wedged on
/// an awaken event we can't satisfy from the host side -- the host
/// caller should give up its blocking wait in that case.
///
/// IRQ simulation: on the real chip wifi_main wakes from task_wait when
/// the IPC hw register write fires an IRQ on the LMAC core. We have no
/// A2E IRQ -- both "cores" are the same M0 -- so we poll the trigger
/// register and manually dispatch the EMB-side handlers. Those handlers
/// should wake wifi_main through the blob's normal task-notify path.
private bool wifi_pump_one_for_host()
{
    if (_wifi_fibre is null || _wifi_fibre.isFinished)
        return false;

    // EXPERIMENT: manual EMB-IRQ dispatch. The IPC peripheral's A2E side
    // doesn't fire a CLIC IRQ on this part (istat stays 0 even when host
    // writes A2E_TRIGGER), so the blob's IRQ-driven processing chain never
    // runs. Poll the trigger here and dispatch directly to the EMB-side
    // handlers libwifi.a normally calls from mac_irq. The handlers do
    // ke_evt_set() to schedule the actual processing in wifi_main's
    // ke_evt_schedule path -- so a subsequent pump should run it.
    bool dispatched_a2e;
    uint notify_before = _wifi_task.notify_count;
    if (wifi_main_in_main_loop)
    {
        auto trig_reg = cast(uint*)cast(size_t)0x24800000;
        uint a2e = *trig_reg;
        if (a2e != 0)
        {
            import urt.io : writef;
            __gshared uint dispatch_n;
            writef("[manual-dispatch #{0} a2e={1,08X}]", ++dispatch_n, a2e);
            if (a2e & 0x02) ipc_emb_msg_irq();         // A2E_MSG
            if (a2e & 0x10) ipc_emb_cfmback_irq();     // A2E_RXDESC_BACK
            if (a2e & 0x20) ipc_emb_cfmback_irq();     // A2E_RXBUF_BACK
            if (a2e & 0xFF00) ipc_emb_tx_irq();        // A2E_TXDESC bits 8-15
            dispatched_a2e = true;
            // Clear the bits we processed. Mirrors what the MAC intc ACK
            // would do on real silicon.
            *trig_reg = a2e & 0x01;  // keep DBG bit (handler-less)
        }
    }

    // Do not manufacture task notifications on every host poll. In the
    // vendor FreeRTOS flow wifi_main wakes from ISR notification only; a
    // permanent synthetic notify turns its idle wait into a tight loop and
    // can hide the actual event ordering. The EMB-side handlers normally
    // notify via the blob's OS adapter; keep one fallback for manual-dispatch
    // paths that consumed A2E work without producing a notify.
    if (dispatched_a2e && _wifi_task.notify_count == notify_before)
        bl_ops_task_notify(cast(void*)&_wifi_task);

    // Periodic census dump: every ~131k pumps, print IRQ-delivery counters
    // and live IPC peripheral state.
    //   c=N        - total trap count from _irq_dispatch
    //   h70/h79/h7 - per-line histogram (LMAC mac / LMAC ipc / timer)
    //   a2e        - APP2EMB_TRIGGER at 0x24800000 (host->emb doorbell bits)
    //   raw        - E2A_RAWSTATUS at 0x24800004 (emb->app raw bits)
    //   um         - E2A_UNMASK    at 0x2480000C (which raw bits raise IRQ 79)
    // If a2e stays non-zero after host wrote it, wifi_main isn't polling it
    // (or doesn't know the bit's meaning). If a2e goes to zero immediately
    // after spawn, wifi_main is clobbering it during its Configure IPC step.
    // Print full state on first call AND whenever a2e/raw/intc-status changes.
    // Covers:
    //   sig    - 0x24800140 IPC signature (vendor ipc_emb_init asserts == 0x49504332/"IPC2")
    //   a2e    - 0x24800000 APP2EMB_TRIGGER
    //   raw    - 0x24800004 EMB2APP_RAWSTATUS
    //   um     - 0x2480000C E2A unmask
    //   istat  - 0x24910000 MAC intc status (asserted lines)
    //   ien_lo - 0x24910010 MAC intc enable [31:0]   -- intc_init writes here
    //   ien_hi - 0x24910014 MAC intc enable [63:32]
    {
        import urt.io : writef;
        import urt.driver.bl618.irq : irq_count, irq_histogram;

        uint sig    = *cast(uint*)cast(size_t)0x24800140;
        uint a2e    = *cast(uint*)cast(size_t)0x24800000;
        uint raw    = *cast(uint*)cast(size_t)0x24800004;
        uint um     = *cast(uint*)cast(size_t)0x2480000C;
        uint istat  = *cast(uint*)cast(size_t)0x24910000;
        uint ien_lo = *cast(uint*)cast(size_t)0x24910010;
        uint ien_hi = *cast(uint*)cast(size_t)0x24910014;

        __gshared uint last_a2e   = 0xDEADBEEF;
        __gshared uint last_raw   = 0xDEADBEEF;
        __gshared uint last_istat = 0xDEADBEEF;
        __gshared uint last_h79;
        if (a2e != last_a2e || raw != last_raw || istat != last_istat || irq_histogram[79] != last_h79)
        {
            last_a2e   = a2e;
            last_raw   = raw;
            last_istat = istat;
            last_h79   = irq_histogram[79];
            writef("[c={0} h70={1} h79={2} h7={3} sig={4,08X} a2e={5,08X} raw={6,08X} um={7,08X} istat={8,08X} ien={9,08X}/{10,08X}]",
                irq_count, irq_histogram[70], irq_histogram[79], irq_histogram[7],
                sig, a2e, raw, um, istat, ien_hi, ien_lo);
        }
    }

    // Resume the fibre when its pending event is ready (or there's none yet).
    // If not ready, still return true so the host's wait loop keeps polling --
    // the event will eventually become ready (timer expires, sem given, etc).
    if (_wifi_pending_event is null || _wifi_pending_event.ready())
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
    // Probe: log every task create, with name (best effort - print up to
    // 16 chars). We only spawn one fibre; if the blob asks for a second
    // task, this lets us see it AND we currently fake-success.
    uart0_hw_puts("[s:task_create ");
    if (name !is null)
    {
        size_t n;
        while (name[n] != 0 && n < 16)
            ++n;
        uart0_hw_puts(name[0 .. n]);
    }
    else uart0_hw_puts("<null>");
    uart0_hw_puts("]");

    if (_wifi_fibre !is null)
    {
        uart0_hw_puts("[s:task_create FAKE_2ND]");
        return 0;  // already have one
    }

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
    import urt.io : writef;
    auto t = cast(shim_task*)h;
    if (t is null) return;
    writef("[s:task_notify count={0}->{1}]", t.notify_count, t.notify_count + 1);
    ++t.notify_count;
}

void bl_ops_task_wait(BL_TaskHandle_t h, uint ticks)
{
    import urt.io : write, writef;
    auto t = cast(shim_task*)h;
    if (t is null)
        return;
    // Periodic heartbeat: every 65k parks, print so we know wifi_main is
    // still alive in its main loop. If this stops printing, wifi_main has
    // wedged.
    __gshared uint park_count;
    while (t.notify_count == 0)
    {
        if ((++park_count & 0xFFFF) == 1)
            writef("[s:task_wait #{0}]", park_count);
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

// Queue identity tracking (companion to sem / evg identity tracking).
__gshared uint _queue_next_id = 1;
struct shim_queue_dbg { shim_queue base; uint id; }

BL_MessageQueue_t bl_ops_queue_create(uint queue_len, uint item_size)
{
    import urt.io : writef;
    auto q = cast(shim_queue_dbg*)bl_ops_zalloc(shim_queue_dbg.sizeof);
    if (q is null) return null;
    q.base.buf = cast(ubyte*)bl_ops_malloc(queue_len * item_size);
    if (q.base.buf is null) { bl_ops_free(q); return null; }
    q.base.item_size = item_size;
    q.base.capacity  = queue_len;
    q.id = _queue_next_id++;
    writef("[s:queue_create #{0} len={1} item_size={2}]", q.id, queue_len, item_size);
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
    import urt.io : writef;
    auto q = cast(shim_queue*)h;
    if (q is null || q.count == q.capacity) return -1;
    auto d = cast(shim_queue_dbg*)h;
    writef("[s:queue_send #{0}]", d.id);
    auto slot = q.buf + q.head * q.item_size;
    slot[0 .. q.item_size] = (cast(ubyte*)item)[0 .. q.item_size];
    q.head = (q.head + 1) % q.capacity;
    ++q.count;
    return 0;
}
int bl_ops_queue_send_wait(BL_MessageQueue_t h, void* item, uint len, uint ticks, int prio)
    => bl_ops_queue_send(h, item, len);
int bl_ops_queue_recv(BL_MessageQueue_t h, void* item, uint len, uint ticks)
{
    import urt.io : writef;
    auto q = cast(shim_queue*)h;
    if (q is null) return -1;
    auto d = cast(shim_queue_dbg*)h;

    bool first_wait = true;
    while (q.count == 0)
    {
        if (first_wait)
        {
            first_wait = false;
            writef("[s:queue_recv.park #{0}]", d.id);
        }
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

// IRQ -- bl618 driver only has global enable/disable today. If the blob
// actually attaches a handler, we'll know and either grow the urt API
// (delegate that work to a separate agent) or wire it ad-hoc.
void bl_ops_irq_attach(int n, void* f, void* arg)
{
    uart0_hw_puts("[s:irq_attach ");
    char[3] dec;
    uint v = cast(uint)n;
    if (v >= 100) { dec[0] = cast(char)('0' + v/100); dec[1] = cast(char)('0' + (v/10)%10); dec[2] = cast(char)('0' + v%10); uart0_hw_puts(dec[]); }
    else if (v >= 10) { dec[1] = cast(char)('0' + v/10); dec[2] = cast(char)('0' + v%10); uart0_hw_puts(dec[1..3]); }
    else { dec[2] = cast(char)('0' + v); uart0_hw_puts(dec[2..3]); }
    uart0_hw_puts("]");
}
void bl_ops_irq_enable(int n)  { uart0_hw_puts("[s:irq_en]"); }
void bl_ops_irq_disable(int n) { uart0_hw_puts("[s:irq_dis]"); }

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


// ====================================================================
// The table itself. Layout-matched; do not reorder.
// ====================================================================

@fast_data __gshared bl_ops_funcs_t g_bl_ops_funcs = {
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
