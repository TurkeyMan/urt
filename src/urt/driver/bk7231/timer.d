// BK7231 timer driver (shared by BK7231N and BK7231T)
//
// The BK7231 timer/PWM block lives at PWM_NEW_BASE = 0x0080_2A00.
// Timers 0-2 run from 26MHz, timers 3-5 from 32kHz.
//
// We use Timer0 as a freerunning monotonic clock source at 26MHz.
// The counter counts up from 0 to the period register value, then wraps.
// With period = 0xFFFF_FFFF, it wraps every ~165s at 26MHz.
//
// Reading the current count is a two-step process:
//   1. Write (timer_index << 2) | 1 to READ_CTL
//   2. Poll READ_CTL until bit 0 clears
//   3. Read current count from READ_VALUE
//
// Register layout verified against Beken SDK:
//   sdk/OpenBK7231N/platforms/bk7231n/bk7231n_os/beken378/driver/pwm/bk_timer.h
//   sdk/OpenBK7231N/platforms/bk7231n/bk7231n_os/beken378/driver/pwm/bk_timer.c
module urt.driver.bk7231.timer;

import core.volatile;

@nogc nothrow:


// --- Timer/PWM base (from SDK pwm.h) --------------------------------

private enum uint PWM_NEW_BASE = 0x0080_2A00;


// --- Timer0-2 registers (26MHz group) --------------------------------

private enum : uint
{
    // Period/end-value registers (one per timer, writable)
    TIMER0_PERIOD = PWM_NEW_BASE + 0 * 4,  // 0x0080_2A00
    TIMER1_PERIOD = PWM_NEW_BASE + 1 * 4,  // 0x0080_2A04
    TIMER2_PERIOD = PWM_NEW_BASE + 2 * 4,  // 0x0080_2A08

    // Shared control register for Timer0-2
    TIMER0_2_CTL  = PWM_NEW_BASE + 3 * 4,  // 0x0080_2A0C

    // Counter read-back registers (BK7231N/U; BK7231T has them in practice)
    TIMER0_2_READ_CTL   = PWM_NEW_BASE + 4 * 4,  // 0x0080_2A10
    TIMER0_2_READ_VALUE = PWM_NEW_BASE + 5 * 4,  // 0x0080_2A14
}


// --- Timer0-2 control register bits ----------------------------------

private enum : uint
{
    TIMER0_EN     = 1 << 0,
    TIMER1_EN     = 1 << 1,
    TIMER2_EN     = 1 << 2,
    CLK_DIV_POS   = 3,         // 3-bit divider: actual_div = reg_val + 1
    CLK_DIV_MASK  = 0x7 << 3,
    TIMER0_INT    = 1 << 7,    // Timer0 interrupt flag (write 1 to clear)
    TIMER1_INT    = 1 << 8,
    TIMER2_INT    = 1 << 9,
    INT_FLAG_MASK = 0x7 << 7,
}


// --- ICU clock power for timers --------------------------------------
// From SDK icu.h: ICU_PERI_CLK_PWD = ICU_BASE + 2*4 = 0x0080_2008

private enum uint ICU_PERI_CLK_PWD    = 0x0080_2008;
private enum uint PWD_TIMER_26M_CLK   = 1 << 20;


// --- Public interface ------------------------------------------------

enum uint mtime_freq_hz = 26_000_000;
enum bool has_mtime = true;
enum bool has_rtc = false;
enum bool has_mcycle = false;
enum bool has_timer_stop = false;
enum bool has_oneshot_timer = false;

private enum uint timer_freq_hz = mtime_freq_hz;

private __gshared uint timer_high;
private __gshared uint timer_last;

void timer_hw_init()
{
    // Enable 26MHz timer clock (clear power-down bit)
    uint pwd = volatileLoad(cast(uint*)(cast(size_t)ICU_PERI_CLK_PWD));
    pwd &= ~PWD_TIMER_26M_CLK;
    volatileStore(cast(uint*)(cast(size_t)ICU_PERI_CLK_PWD), pwd);

    // Set Timer0 period to maximum (freerunning)
    volatileStore(cast(uint*)(cast(size_t)TIMER0_PERIOD), 0xFFFF_FFFF);

    // Configure control: enable Timer0, div=1 (CLK_DIV=0), clear interrupt flags
    uint ctl = volatileLoad(cast(uint*)(cast(size_t)TIMER0_2_CTL));
    ctl &= ~(CLK_DIV_MASK | INT_FLAG_MASK);  // div=0 means /1, clear int flags
    ctl |= TIMER0_EN;
    volatileStore(cast(uint*)(cast(size_t)TIMER0_2_CTL), ctl);

    timer_high = 0;
    timer_last = 0;
}

// Read the current Timer0 count via the READ_CTL/READ_VALUE mechanism.
// Hardware clears READ_CTL bit 0 when the snapshot is ready.
private uint timer0_read_count()
{
    enum uint read_ctl_addr  = TIMER0_2_READ_CTL;
    enum uint read_val_addr  = TIMER0_2_READ_VALUE;

    // Trigger read for timer index 0: (index << 2) | 1
    volatileStore(cast(uint*)(cast(size_t)read_ctl_addr), (0 << 2) | 1);

    // Poll until hardware clears bit 0 (should be near-instant at 26MHz)
    while (volatileLoad(cast(uint*)(cast(size_t)read_ctl_addr)) & 1)
    {}

    return volatileLoad(cast(uint*)(cast(size_t)read_val_addr));
}

// Read monotonic 64-bit tick count.
// Must be called at least once per ~165 seconds (2^32 / 26MHz) to catch
// rollovers. The main loop at 20Hz guarantees this.
ulong mtime_read()
{
    uint now = timer0_read_count();
    if (now < timer_last)
        ++timer_high;
    timer_last = now;
    return (cast(ulong)timer_high << 32) | now;
}

alias TimerCallback = void function() @nogc nothrow;

private __gshared TimerCallback tick_callback;

void timer_set_periodic(uint period_us, TimerCallback cb)
{
    tick_callback = cb;
    // TODO: configure Timer1 for periodic interrupt at period_us
    // Requires IRQ vector dispatch in start.S (not yet implemented)
}
