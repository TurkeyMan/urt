module urt.driver.timer;

import urt.time : Duration, dur;
import urt.driver.irq : has_clic, has_per_irq_control;

version (BL808_M0)
    public import urt.driver.bl618.timer;
else version (BL808)
    public import urt.driver.bl808.timer;
else version (BL618)
    public import urt.driver.bl618.timer;
else version (Beken)
    public import urt.driver.bk7231.timer;
else version (RP2350)
    public import urt.driver.rp2350.timer;
else version (STM32)
    public import urt.driver.stm32.timer;
else version (Espressif)
    public import urt.driver.esp32.timer;
else
{
    enum uint mtime_freq_hz = 0;
    enum bool has_mtime = false;
    enum bool has_rtc = false;
    enum bool has_mcycle = false;
    enum bool has_timer_stop = false;
    enum bool has_oneshot_timer = false;
}

nothrow @nogc:


alias TimerCallback = void function() nothrow @nogc;

// ====================================================================
// Driver API
// ====================================================================

// Lifecycle

void timer_init()
{
    if (_init_refcount++ == 0)
    {
        version (Beken)
            timer_hw_init();
    }
}

void timer_deinit()
{
    assert(_init_refcount > 0);
    if (--_init_refcount == 0)
    {
        static if (has_timer_stop)
            periodic_stop();
        static if (has_rtc)
            rtc_stop();
        // TODO: disable timer IRQs at the interrupt controller level
    }
}

// Monotonic clock

// Read the monotonic tick counter. Units are platform-specific;
// use mtime_freq_hz to convert to real time.
static if (has_mtime)
    alias monotonic_read = mtime_read;
else
{
    ulong monotonic_read()
    {
        assert(false, "monotonic_read not available");
    }
}

// Read CPU cycle counter (for profiling, NOT timekeeping).
// Stops during WFI, rate changes with clock scaling.
static if (has_mcycle)
    alias cycle_read = mcycle_read;
else
{
    ulong cycle_read()
    {
        assert(false, "cycle_read not available");
    }
}

// Periodic tick

// Set up a periodic timer interrupt at the given interval.
void periodic_set(Duration interval, TimerCallback cb)
{
    static if (has_mtime)
    {
        ulong ticks = interval.as!"nsecs" * mtime_freq_hz / 1_000_000_000;
        timer_set_periodic(cast(uint)ticks, cb);
    }
    else
        assert(false, "TODO: periodic_set not available");
}

// Stop the periodic timer.
void periodic_stop()
{
    static if (has_timer_stop)
        timer_stop();
    else
        assert(false, "TODO: periodic_stop not available");
}

// One-shot wakeup

// Schedule a one-shot interrupt at the given absolute tick value.
// Used by sleep() to wake from WFI.
void oneshot_set(ulong tick_value)
{
    static if (has_oneshot_timer)
        mtimecmp_write_oneshot(tick_value);
    else
        assert(false, "TODO: oneshot_set not available");
}

// RTC (battery-backed real-time counter)

// Enable the RTC counter. Does not reset it.
void rtc_start()
{
    static if (has_rtc)
        rtc_enable();
    else
        assert(false, "TODO: rtc_start not available");
}

// Disable and reset the RTC counter to zero.
void rtc_stop()
{
    static if (has_rtc)
        rtc_reset();
    else
        assert(false, "TODO: rtc_stop not available");
}

// Read the RTC tick counter.
static if (has_rtc)
    alias rtc_now = rtc_read;
else
{
    ulong rtc_now()
    {
        assert(false, "TODO: rtc_now not available");
    }
}

// Access persistent state in battery-retained RAM.
static if (has_rtc)
{
    HbnPersist* persistent_state()
    {
        return hbn_persist();
    }
}


// ====================================================================
// Tests
// ====================================================================
//
// Most of these are gated by capability flags so they collapse to no-ops
// on platforms that don't support the underlying surface (desktop, in
// particular, runs only the cross-asserts and the refcount test).

unittest // capability cross-consistency
{
    static assert(mtime_freq_hz > 0 || !has_mtime,
                  "has_mtime requires a known mtime frequency");
    static assert(!has_mcycle || has_mtime,
                  "mcycle without mtime makes no sense in this codebase");
    static assert(!has_timer_stop || has_mtime,
                  "stoppable periodic implies an mtime source");
}

unittest // timer_init / timer_deinit refcount balances
{
    timer_init();
    timer_init();
    timer_deinit();
    timer_deinit();
    // If the refcount underflowed, the next timer_init would re-init the
    // hardware redundantly; if it leaked, the matching deinit above would
    // assert(_init_refcount > 0). Reaching this line means neither happened.
}

static if (has_mtime)
unittest // monotonic_read is non-decreasing and actually advances
{
    timer_init();
    scope (exit) timer_deinit();

    ulong t1 = monotonic_read();
    ulong t2 = monotonic_read();
    assert(t2 >= t1, "monotonic_read went backwards");

    // Spin until the clock advances or we exhaust the budget. A clock that
    // never advances is a more useful failure mode than a flake.
    ulong start = monotonic_read();
    ulong observed = start;
    foreach (_; 0 .. 1_000_000)
    {
        observed = monotonic_read();
        if (observed > start)
            break;
    }
    assert(observed > start, "monotonic_read did not advance within 1M reads");
}

static if (has_mcycle)
unittest // cycle_read advances within a busy spin
{
    ulong c1 = cycle_read();
    ulong c2 = cycle_read();
    assert(c2 >= c1);

    ulong start = cycle_read();
    ulong observed = start;
    foreach (_; 0 .. 10_000)
    {
        observed = cycle_read();
        if (observed > start)
            break;
    }
    assert(observed > start, "cycle counter is stuck");
}

static if (has_oneshot_timer)
unittest // oneshot_set arm and cancel don't crash
{
    timer_init();
    scope (exit) timer_deinit();

    ulong now = monotonic_read();
    // Arm well in the future so the fire-and-handler path is exercised by
    // the periodic test below, not here.
    oneshot_set(now + cast(ulong)mtime_freq_hz * 60);
    oneshot_set(ulong.max);
}

// Light-weight sanity check that periodic_set / periodic_stop don't crash.
// We can't easily assert delivery here because periodic_set is a platform-
// specific helper -- some platforms (BL618 during M0 bring-up) leave the
// IRQ enable commented out so the callback won't fire. The oneshot-based
// trap-entry test below covers delivery via the common API.
static if (has_mtime && has_timer_stop)
unittest // periodic_set / periodic_stop are safe to call back-to-back
{
    timer_init();
    scope (exit) timer_deinit();

    periodic_set(dur!"msecs"(50), () @nogc nothrow {});
    periodic_stop();
}

// The big integration test: arm a oneshot, install a handler at the timer
// line, spin until it fires, verify the trap path doesn't corrupt the
// stack frame and the diagnostics counter increments. Built entirely on
// the common irq+timer API surface -- no platform helpers.
//
// Gated on has_clic because on CLIC the machine-timer cause arrives as
// ordinary IRQ line 7 through the per-line dispatch table, which is what
// irq_handler_set targets. PLIC routes the timer trap through its own
// path (start.S _trap_mtimer), so installing a handler at line 7 wouldn't
// reach it. NVIC's SysTick is a system exception, not a peripheral IRQ.
static if (has_mtime && has_oneshot_timer && has_clic && has_per_irq_control)
unittest // oneshot_set fires an IRQ, handler runs, trap doesn't trash stack
{
    import urt.driver.irq : irq_handler_set, irq_line_enable, irq_line_disable,
                            irq_global_enable, irq_global_set,
                            has_global_irq_state, has_irq_diagnostics,
                            IrqHandler;
    import core.volatile : volatileLoad;
    static if (has_irq_diagnostics)
        import urt.driver.irq : irq_total_count;

    timer_init();
    scope (exit) timer_deinit();

    // RISC-V machine-timer cause; standard across every CLIC platform.
    enum uint timer_line = 7;

    __gshared uint fire_count;
    fire_count = 0;

    static void handler(uint) @nogc nothrow
    {
        ++fire_count;
        oneshot_set(ulong.max); // disarm so the trap doesn't keep re-firing
    }

    IrqHandler prior_handler = irq_handler_set(timer_line, &handler);
    scope (exit) irq_handler_set(timer_line, prior_handler);

    // Canary in the test's stack frame. If trap entry writes outside the
    // saved frame (mis-aligned SP, wrong push count) this gets clobbered.
    enum size_t canary_len = 256;
    ubyte[canary_len] canary;
    foreach (i, ref b; canary)
        b = cast(ubyte)((i * 0x9Eu) ^ 0xA5u);

    static if (has_irq_diagnostics)
        uint prior_total = irq_total_count();

    bool prior_line = irq_line_enable(timer_line);
    scope (exit)
    {
        if (!prior_line)
            irq_line_disable(timer_line);
    }

    static if (has_global_irq_state)
        bool prior_global = irq_global_enable();
    else
        irq_global_enable();

    // Arm 10 ms in the future (10_000 ticks at 1 MHz mtime).
    oneshot_set(monotonic_read() + 10_000);

    // Bounded busy wait -- 200 ms of mtime is generous slack for a 10 ms timer.
    // volatileLoad keeps the optimizer from caching fire_count in a register;
    // monotonic_read's inline-asm rdtime doesn't carry a memory clobber, so an
    // ordinary __gshared load can otherwise be hoisted out of the loop.
    ulong start_mt = monotonic_read();
    ulong budget = 200u * (cast(ulong)mtime_freq_hz / 1000u);
    while (volatileLoad(&fire_count) == 0 && (monotonic_read() - start_mt) < budget)
    {}

    static if (has_global_irq_state)
        irq_global_set(prior_global);

    assert(volatileLoad(&fire_count) == 1, "oneshot_set did not deliver an IRQ");

    foreach (i, b; canary)
        assert(b == cast(ubyte)((i * 0x9Eu) ^ 0xA5u),
               "stack canary clobbered across IRQ trap");

    static if (has_irq_diagnostics)
        assert(irq_total_count() > prior_total,
               "diagnostics counter did not track delivered IRQ");
}

static if (has_rtc)
unittest // RTC counter non-decreasing; persistence struct accessible
{
    timer_init();
    scope (exit) timer_deinit();

    rtc_start();

    ulong r1 = rtc_now();
    ulong r2 = rtc_now();
    assert(r2 >= r1);

    auto p = persistent_state();
    assert(p !is null,
           "persistent_state must return a valid pointer when RTC is up");
}


private:

__gshared ubyte _init_refcount;
