/// BL808 C906 timer support
///
/// Two time sources:
///
/// 1. mtime (RISC-V standard) - 1 MHz monotonic counter.
///    Read via rdtime. Survives WFI/clock scaling, resets on system reset.
///    Used for monotonic timekeeping (getTime / Duration / Timer).
///
/// 2. HBN RTC - 32,768 Hz counter in the Hibernate block.
///    40-bit, survives deep sleep (HBN) if VBAT is maintained.
///    Resets on full power cycle. Used with a stored UTC offset
///    for wall-clock time across sleep/wake cycles.
///
/// CLINT layout (T-Head C906):
///   CORET_BASE  = 0xE400_0000  (PLIC_BASE + 0x400_0000)
///   MTIMECMPL0  @ CORET_BASE + 0x4000
///   MTIMECMPH0  @ CORET_BASE + 0x4004
///
/// HBN layout:
///   HBN_BASE    = 0x2000_F000
///   HBN_CTL     @ +0x00   - bit 0: RTC enable
///   HBN_TIME_L  @ +0x04   - compare value low (alarm)
///   HBN_TIME_H  @ +0x08   - compare value high (alarm)
///   HBN_RTC_TIME_L @ +0x0C - latched counter low (read-only)
///   HBN_RTC_TIME_H @ +0x10 - latched counter high [7:0] + latch trigger [31]
module urt.driver.bl808.timer;

import core.volatile;

@nogc nothrow:

// ================================================================
// Hardware addresses
// ================================================================

private enum ulong CORET_BASE    = 0xE400_0000;
private enum ulong MTIMECMPL0    = CORET_BASE + 0x4000;
private enum ulong MTIMECMPH0    = CORET_BASE + 0x4004;

private enum ulong HBN_BASE      = 0x2000_F000;
private enum ulong HBN_CTL       = HBN_BASE + 0x00;
private enum ulong HBN_RTC_TIME_L = HBN_BASE + 0x0C;
private enum ulong HBN_RTC_TIME_H = HBN_BASE + 0x10;

// ================================================================
// mtime frequency
//
// The BL808 mtime counter runs at 1MHz (from the XTAL/PLL
// divided down). Confirm on hardware by measuring against
// a known delay or reading the clock tree registers.
// ================================================================

enum uint mtime_freq_hz = 1_000_000;
enum bool has_mtime = true;
enum bool has_rtc = true;
enum bool has_mcycle = true;
enum bool has_timer_stop = true;
enum bool has_oneshot_timer = true;

// ================================================================
// Time reading
// ================================================================

/// Read the monotonic mtime counter via rdtime.
/// Does not stop during WFI, unaffected by clock scaling.
ulong mtime_read()
{
    ulong t;
    asm @nogc nothrow { "rdtime %0" : "=r" (t); }
    return t;
}

/// Read CPU cycle counter (for profiling, NOT timekeeping).
/// Stops during WFI, rate changes with clock scaling.
ulong mcycle_read()
{
    ulong c;
    asm @nogc nothrow { "rdcycle %0" : "=r" (c); }
    return c;
}

// ================================================================
// Timer interrupt (periodic tick)
// ================================================================

private __gshared ulong tick_interval = 0;
private __gshared void function() @nogc nothrow tick_callback = null;

/// Set up a periodic timer interrupt.
/// interval_us: microseconds between ticks
/// callback: called from _timer_irq_handler (keep it short!)
void timer_set_periodic(ulong interval_us, void function() @nogc nothrow callback)
{
    import urt.driver.bl808.irq : IrqClass, enable_irq;

    tick_interval = interval_us;
    tick_callback = callback;

    ulong now = mtime_read();
    mtimecmp_write(now + tick_interval);
    enable_irq(IrqClass.timer);
}

/// Stop the periodic timer
void timer_stop()
{
    import urt.driver.bl808.irq : IrqClass, disable_irq;

    disable_irq(IrqClass.timer);
    mtimecmp_write(ulong.max);
    tick_callback = null;
}

/// Called from start.S _trap_mtimer.
/// Sets next deadline and invokes the user callback.
extern(C) void _timer_irq_handler()
{
    if (tick_interval > 0)
    {
        // Advance deadline relative to current compare value
        // (not current time - avoids drift)
        ulong cmp = mtimecmp_read();
        mtimecmp_write(cmp + tick_interval);
    }

    if (tick_callback !is null)
        tick_callback();
}

// ================================================================
// MTIMECMP register access
//
// Split into two 32-bit writes. Write high word to max first
// to prevent a spurious interrupt when the low word is updated.
// ================================================================

/// Set mtimecmp for a one-shot wakeup (used by sleep).
/// The periodic timer handler will re-arm on the next tick if active.
void mtimecmp_write_oneshot(ulong value)
{
    mtimecmp_write(value);
}

private void mtimecmp_write(ulong value)
{
    auto lo = cast(uint*)MTIMECMPL0;
    auto hi = cast(uint*)MTIMECMPH0;

    // Write 0xFFFFFFFF to high first to prevent spurious fire
    volatileStore(hi, 0xFFFF_FFFF);
    volatileStore(lo, cast(uint)(value & 0xFFFF_FFFF));
    volatileStore(hi, cast(uint)(value >> 32));
}

private ulong mtimecmp_read()
{
    auto lo = cast(uint*)MTIMECMPL0;
    auto hi = cast(uint*)MTIMECMPH0;

    // Read high-low-high to handle rollover
    uint h1 = volatileLoad(hi);
    uint l  = volatileLoad(lo);
    uint h2 = volatileLoad(hi);
    if (h1 != h2)
        l = volatileLoad(lo);
    return (cast(ulong)h2 << 32) | l;
}

// ================================================================
// HBN RTC (32,768 Hz, 40-bit, survives hibernate)
// ================================================================

enum uint rtc_freq_hz = 32_768;

/// Enable the HBN RTC counter (bit 0 of HBN_CTL).
/// Does NOT reset the counter - call rtc_reset() first if needed.
/// Note: read-modify-write on HBN_CTL is not interrupt-safe.
/// If called after interrupts are enabled, wrap with mstatus.MIE guard.
void rtc_enable()
{
    auto ctl = cast(uint*)HBN_CTL;
    volatileStore(ctl, volatileLoad(ctl) | 0x01);
}

/// Disable and reset the HBN RTC counter to zero.
/// Note: same mstatus.MIE guard applies - see rtc_enable().
void rtc_reset()
{
    auto ctl = cast(uint*)HBN_CTL;
    volatileStore(ctl, volatileLoad(ctl) & ~uint(0x01));
}

/// Read the 40-bit HBN RTC counter.
/// Latches the value first (toggle bit 31 of RTC_TIME_H), then reads.
ulong rtc_read()
{
    auto lo = cast(uint*)HBN_RTC_TIME_L;
    auto hi = cast(uint*)HBN_RTC_TIME_H;

    // Latch: set bit 31, then clear it
    uint h = volatileLoad(hi);
    volatileStore(hi, h | (1u << 31));
    volatileStore(hi, h & ~(1u << 31));

    uint l = volatileLoad(lo);
    h = volatileLoad(hi);
    return (ulong(h & 0xFF) << 32) | l;
}

/// Convert RTC ticks (32,768 Hz) to seconds.
ulong rtc_ticks_to_sec(ulong ticks)
{
    return ticks / rtc_freq_hz;
}

/// Convert seconds to RTC ticks.
ulong rtc_sec_to_ticks(ulong sec)
{
    return sec * rtc_freq_hz;
}

// HBN persistence struct and accessor moved to urt.driver.bl_common.hbn so
// the M0 build can mirror D0's clock persistence without dragging in the
// rest of timer.d (which is D0-only).
public import urt.driver.bl_common.hbn : HbnPersist, hbn_persist;
