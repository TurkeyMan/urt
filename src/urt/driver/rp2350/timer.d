// RP2350 timer driver
//
// Uses the ARM Cortex-M33 SysTick timer for the periodic main loop tick.
// SysTick is a 24-bit down-counter clocked from the processor clock.
//
// RP2350 also has a 64-bit microsecond timer at 0x400B_0000 (TIMER0)
// which can be used for wall-clock time -- not yet implemented here.
module urt.driver.rp2350.timer;

import core.volatile;

@nogc nothrow:

enum uint mtime_freq_hz = 1_000_000;  // TIMER0 runs at 1MHz (microsecond counter)
enum bool has_mtime = true;
enum bool has_rtc = false;
enum bool has_mcycle = false;
enum bool has_timer_stop = false;
enum bool has_oneshot_timer = false;

// RP2350 TIMER0: 64-bit free-running microsecond counter at 0x400B_0000
// Always enabled, always 1MHz. Read TIMELR first (latches TIMEHR).
private enum uint TIMER0_BASE = 0x400B_0000;
private enum uint TIMEHR      = TIMER0_BASE + 0x08;  // Time read high (latched on TIMELR read)
private enum uint TIMELR      = TIMER0_BASE + 0x0C;  // Time read low (triggers latch)

// SysTick registers (ARM standard, part of the System Control Block)
private enum uint SYST_CSR = 0xE000_E010;
private enum uint SYST_RVR = 0xE000_E014;
private enum uint SYST_CVR = 0xE000_E018;

private enum uint CSR_ENABLE    = 1 << 0;
private enum uint CSR_TICKINT   = 1 << 1;
private enum uint CSR_CLKSOURCE = 1 << 2;

alias TimerCallback = void function() @nogc nothrow;

private __gshared TimerCallback tick_callback;

void timer_init(uint reload_value)
{
    volatileStore(cast(uint*)(cast(size_t)SYST_RVR), reload_value & 0x00FFFFFF);
    volatileStore(cast(uint*)(cast(size_t)SYST_CVR), 0);
    volatileStore(cast(uint*)(cast(size_t)SYST_CSR), CSR_ENABLE | CSR_TICKINT | CSR_CLKSOURCE);
}

void timer_hw_init()
{
    // TIMER0 is always running at 1MHz on RP2350 -- nothing to init.
}

// Read 64-bit monotonic microsecond counter.
// Must read TIMELR first -- this latches TIMEHR atomically.
ulong mtime_read()
{
    uint lo = volatileLoad(cast(uint*)(cast(size_t)TIMELR));
    uint hi = volatileLoad(cast(uint*)(cast(size_t)TIMEHR));
    return (cast(ulong)hi << 32) | lo;
}

void timer_set_periodic(uint period_ticks, TimerCallback cb)
{
    tick_callback = cb;
    // Use SysTick for periodic interrupts.
    // period_ticks is in timer ticks (microseconds at 1MHz).
    // SysTick runs from processor clock -- assume 150MHz after PLL init.
    // Convert: systick_reload = period_us * 150
    uint reload = period_ticks * 150;
    if (reload > 0x00FF_FFFF)
        reload = 0x00FF_FFFF;  // SysTick is 24-bit
    volatileStore(cast(uint*)(cast(size_t)SYST_RVR), reload);
    volatileStore(cast(uint*)(cast(size_t)SYST_CVR), 0);
    volatileStore(cast(uint*)(cast(size_t)SYST_CSR), CSR_ENABLE | CSR_TICKINT | CSR_CLKSOURCE);
}

extern(C) void SysTick_Handler() @nogc nothrow
{
    if (tick_callback !is null)
        tick_callback();
}
