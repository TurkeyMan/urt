// STM32 timer driver
//
// Monotonic time via SysTick interpolation: the SysTick handler increments
// a tick counter, and mtime_read() combines the tick count with the current
// SysTick value for full 16 MHz resolution.
//
// SysTick keeps running during WFI (SLEEP mode) since AHB stays active,
// unlike DWT CYCCNT which stops on sleep.
module urt.driver.stm32.timer;

import core.volatile;

@nogc nothrow:

enum uint mtime_freq_hz = 16_000_000;
enum bool has_mtime = true;
enum bool has_rtc = false;
enum bool has_mcycle = false;
enum bool has_timer_stop = false;
enum bool has_oneshot_timer = false;

// SysTick registers (ARM standard)
private enum ulong SYST_CSR = 0xE000E010;
private enum ulong SYST_RVR = 0xE000E014;
private enum ulong SYST_CVR = 0xE000E018;

private enum uint CSR_ENABLE    = 1 << 0;
private enum uint CSR_TICKINT   = 1 << 1;
private enum uint CSR_CLKSOURCE = 1 << 2;

// 20 Hz tick: reload = 16_000_000 / 20 - 1 = 799_999
private enum uint SYSTICK_RELOAD = 799_999;

alias TimerCallback = void function() @nogc nothrow;

private __gshared TimerCallback tick_callback;
private __gshared uint tick_count;

void timer_init(uint reload_value)
{
    volatileStore(cast(uint*)SYST_RVR, reload_value & 0x00FFFFFF);
    volatileStore(cast(uint*)SYST_CVR, 0);
    volatileStore(cast(uint*)SYST_CSR, CSR_ENABLE | CSR_TICKINT | CSR_CLKSOURCE);
}

void timer_set_periodic(uint period_us, TimerCallback cb)
{
    tick_callback = cb;
    timer_init(period_us * 16);
}

// Full-resolution monotonic time by combining SysTick overflow count with
// the current down-counter value. Retry loop handles the race where
// SysTick fires between reading tick_count and CVR.
ulong mtime_read()
{
    uint t1, cvr, t2;
    do
    {
        t1 = volatileLoad(&tick_count);
        cvr = volatileLoad(cast(uint*)SYST_CVR);
        t2 = volatileLoad(&tick_count);
    }
    while (t1 != t2);
    return cast(ulong)t1 * (SYSTICK_RELOAD + 1) + (SYSTICK_RELOAD - cvr);
}

extern(C) void SysTick_Handler() @nogc nothrow
{
    volatileStore(&tick_count, volatileLoad(&tick_count) + 1);
    if (tick_callback !is null)
        tick_callback();
}
