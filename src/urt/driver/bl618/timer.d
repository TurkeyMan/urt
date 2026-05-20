// BL618 / BL808 M0 (E907) timer driver
//
// T-Head E907 (RV32IMAFC) has standard RISC-V mtime/mtimecmp exposed via the
// CORET block at 0xE0004000 (NOT the CLIC region at 0xE0800000 -- the two
// are separate peripherals on E907). MTIMECMP is at offset 0x000, MTIME at
// 0x7FFC. mtime runs at 1 MHz from the AON clock.
//
// Timer IRQ delivery is via CLIC line 7 (machine timer cause). The dispatch
// table in urt.driver.bl618.irq routes it here through _timer_irq_handler.
module urt.driver.bl618.timer;

import core.volatile;
import urt.driver.bl618.irq : IrqClass, IrqHandler,
                              irq_set_enable, irq_clear_enable,
                              irq_set_handler,
                              enable_interrupts, disable_interrupts,
                              irq_count, irq_histogram;

@nogc nothrow:

enum uint mtime_freq_hz = 1_000_000;
enum bool has_mtime = true;
enum bool has_rtc = false;
enum bool has_mcycle = false;
enum bool has_timer_stop = true;
enum bool has_oneshot_timer = true;

ulong mtime_read()
{
    uint hi1, lo, hi2;
    do
    {
        asm @nogc nothrow { "rdtimeh %0" : "=r" (hi1); }
        asm @nogc nothrow { "rdtime  %0" : "=r" (lo); }
        asm @nogc nothrow { "rdtimeh %0" : "=r" (hi2); }
    }
    while (hi1 != hi2);
    return (ulong(hi1) << 32) | lo;
}

alias TimerCallback = void function() @nogc nothrow;

void timer_set_periodic(uint period_us, TimerCallback cb)
{
    tick_interval = period_us;
    tick_callback = cb;

    irq_set_handler(IrqClass.timer, &_timer_irq_handler);
    irq_set_enable(IrqClass.timer);
    mtimecmp_write_oneshot(mtime_read() + period_us);
}

void timer_stop()
{
    irq_clear_enable(IrqClass.timer);
    irq_set_handler(IrqClass.timer, null);
    mtimecmp_write_oneshot(ulong.max);
    tick_callback = null;
    tick_interval = 0;
}

void _timer_irq_handler(uint /+irq+/)
{
    if (tick_interval > 0)
        mtimecmp_write_oneshot(mtime_read() + tick_interval);
    if (tick_callback !is null)
        tick_callback();
}

// Schedule a single mtime fire at the given absolute tick. Used by
// urt.system.sleep for WFI-based wakeup, and by the common oneshot tests.
// Pass ulong.max to park the comparator (cancel).
void mtimecmp_write_oneshot(ulong value)
{
    auto lo = cast(uint*)cast(size_t)MTIMECMP_LO;
    auto hi = cast(uint*)cast(size_t)MTIMECMP_HI;

    // Park high at 0xFFFFFFFF before touching low, so a stale low doesn't
    // briefly match an old high and fire a spurious IRQ.
    volatileStore(hi, 0xFFFF_FFFF);
    volatileStore(lo, cast(uint)(value & 0xFFFF_FFFF));
    volatileStore(hi, cast(uint)(value >> 32));
}


private:

// T-Head E907 CORET (mtime / mtimecmp). Separate peripheral from CLIC.
enum uint CORET_BASE  = 0xE000_4000;
enum uint MTIMECMP_LO = CORET_BASE + 0x0000;
enum uint MTIMECMP_HI = CORET_BASE + 0x0004;

__gshared TimerCallback tick_callback;
__gshared uint tick_interval;

ulong mtimecmp_read()
{
    auto lo = cast(uint*)cast(size_t)MTIMECMP_LO;
    auto hi = cast(uint*)cast(size_t)MTIMECMP_HI;

    uint h1 = volatileLoad(hi);
    uint l  = volatileLoad(lo);
    uint h2 = volatileLoad(hi);
    if (h1 != h2)
        l = volatileLoad(lo);
    return (ulong(h2) << 32) | l;
}


// ====================================================================
// Tests
// ====================================================================

unittest // mtime register advances
{
    ulong t0 = mtime_read();
    foreach (uint i; 0 .. 10_000)
        asm @nogc nothrow { "nop"; }
    ulong t1 = mtime_read();
    assert(t1 > t0, "mtime did not advance across a nop spin");
}

__gshared uint _periodic_test_calls;

void _periodic_test_callback() @nogc nothrow
{
    ++_periodic_test_calls;
}

unittest // periodic timer fires its callback repeatedly via the real IRQ path
{
    // Snapshot the live periodic config (sys_init installed a 50ms tick) so
    // we can restore it after the test.
    TimerCallback prev_cb       = tick_callback;
    uint          prev_interval = tick_interval;

    timer_stop();

    _periodic_test_calls = 0;

    // Snapshot dispatch counters BEFORE arming the test timer. The pair
    // (irq_count, irq_histogram[7]) gives us proof that any callback
    // increments below actually came through _irq_dispatch -- a path
    // that bypassed dispatch (memory corruption, wrong handler table,
    // somebody else calling our callback) would advance _periodic_test_calls
    // without advancing these.
    uint irq_count_before = irq_count;
    uint hist7_before     = irq_histogram[IrqClass.timer];

    // 200us period -- short enough that ~2ms of waiting gets us a healthy
    // ten-ish fires (test stays imperceptible), still long enough that
    // handler entry/exit + re-arm don't pile up on themselves.
    timer_set_periodic(200, &_periodic_test_callback);
    scope (exit)
    {
        timer_stop();
        if (prev_cb !is null && prev_interval > 0)
            timer_set_periodic(prev_interval, prev_cb);
    }

    bool was_globally_on = enable_interrupts();
    scope (exit) if (!was_globally_on) disable_interrupts();

    // Wait ~2ms. At 200us period we expect ~10 callback invocations; allow
    // a floor of 5 to absorb IRQ latency / first-arm jitter.
    ulong start = mtime_read();
    while (mtime_read() - start < 2_000)
        asm @nogc nothrow { "nop"; }

    assert(_periodic_test_calls >= 5,
           "periodic timer callback fired too few times -- IRQ delivery or re-arm broken");
    assert(irq_count > irq_count_before,
           "_irq_dispatch never ran -- callback fired by some other path");
    assert(irq_histogram[IrqClass.timer] - hist7_before >= _periodic_test_calls,
           "timer-vector histogram didn't advance with callback count -- dispatch is routing wrong vector");
}

unittest // timer_stop disarms -- no further callbacks after stop
{
    TimerCallback prev_cb       = tick_callback;
    uint          prev_interval = tick_interval;

    timer_stop();

    _periodic_test_calls = 0;

    timer_set_periodic(200, &_periodic_test_callback);  // 200us
    scope (exit)
    {
        timer_stop();
        if (prev_cb !is null && prev_interval > 0)
            timer_set_periodic(prev_interval, prev_cb);
    }

    bool was_globally_on = enable_interrupts();
    scope (exit) if (!was_globally_on) disable_interrupts();

    // Let it tick a few times -- 1ms at 200us = ~5 fires
    ulong start = mtime_read();
    while (mtime_read() - start < 1_000)
        asm @nogc nothrow { "nop"; }
    assert(_periodic_test_calls > 0, "timer never fired before stop");

    timer_stop();
    uint after_stop = _periodic_test_calls;

    // Wait another 1ms -- count must NOT advance after stop
    ulong stop_t = mtime_read();
    while (mtime_read() - stop_t < 1_000)
        asm @nogc nothrow { "nop"; }

    assert(_periodic_test_calls == after_stop,
           "timer fired after timer_stop -- IRQ not actually disabled");
}
