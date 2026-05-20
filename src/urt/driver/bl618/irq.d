// BL618 / BL808 M0 interrupt controller (T-Head E907 CLIC).
//
// The E907 has a Core Local Interrupt Controller at 0xE080_0000. Each IRQ has
// four bytes at CLICINT_BASE + irq*4: { IP, IE, ATTR, CTL }. Trap entry is
// dispatched via mtvt (CSR 0x307, standard CLIC) as a flat .word table of handler addresses,
// with mtvec in CLIC mode (mode 11) pointing at the exception/sync-trap
// handler. The per-IRQ stub _clic_dispatch (in start.S) uses T-Head ipush /
// ipop to push mepc/mcause/caller-saved GPRs across the handler call, which
// is what makes nesting safe (without it, the inner IRQ's mret would clobber
// the outer's mepc CSR; that bug bit us before).
//
// This module is shared by BL618 and BL808 M0 builds. The two parts have the
// same CLIC layout; per-board carve-outs live behind version(BL618) /
// version(BL808_M0) gates.
module urt.driver.bl618.irq;

import core.volatile;

@nogc nothrow:


// ====================================================================
// Capability flags (read by urt.driver.irq facade)
// ====================================================================

enum bool has_plic               = false;
enum bool has_nvic               = false;
enum bool has_clic               = true;
enum bool has_per_irq_control    = true;
enum bool has_irq_priority       = true;
enum bool has_wait_for_interrupt = true;
enum bool has_irq_diagnostics    = true;
enum bool has_global_irq_state   = true;
enum bool has_smp                = false;

// E907 CLIC supports up to 4096 IRQ lines architecturally; both BL618 and
// BL808 M0 wire 16 standard + 64 peripheral = 80 sources. Sources above the
// SoC's wired count are valid CLIC registers but will never raise.
enum uint irq_max = 80;

// Standard RISC-V machine-mode interrupt cause indices.
enum IrqClass : uint
{
    software = 3,
    timer    = 7,
    external = 11,
}

alias IrqHandler = void function(uint irq) @nogc nothrow;


// ====================================================================
// Global IRQ delivery (mstatus.MIE)
// ====================================================================

bool disable_interrupts()
{
    uint prev;
    asm @nogc nothrow { "csrrci %0, mstatus, 0x8" : "=r" (prev); }
    return (prev & 0x8) != 0;
}

bool enable_interrupts()
{
    uint prev;
    asm @nogc nothrow { "csrrsi %0, mstatus, 0x8" : "=r" (prev); }
    return (prev & 0x8) != 0;
}

bool set_interrupts(bool state)
{
    return state ? enable_interrupts() : disable_interrupts();
}

// Legacy aliases used by urt.driver.bl618.start.S / urt.system.d.
alias irq_disable = disable_interrupts;
alias irq_enable  = enable_interrupts;

void wait_for_interrupt()
{
    asm @nogc nothrow { "wfi"; }
}


// ====================================================================
// Per-IRQ control
// ====================================================================

// Enable a single CLIC IRQ. Returns previous state.
//
// The T-Head CLIC will NOT deliver an IRQ whose CLICINTCTL byte (priority)
// is zero -- even with IE=1, SHV=1, IP=1, and mstatus.MIE set. Vendor's
// CPU_Interrupt_Enable in bl_iot_sdk's interrupt.c clamps the same way.
// We bump to the minimum-priority value (_clic_ctl_lsb), which on E907 is
// 0x10 because CLICINFO.CLICINTCTLBITS reports 4 (only the top 4 bits of
// CTL are RW; the bottom 4 are RAZ/WI). Writing 0x01 would store 0 and
// the line would still never deliver.
bool irq_set_enable(uint irq)
{
    if (irq >= irq_max)
        return false;
    ubyte* ctl = clicint_byte(irq, ctl_offset);
    if (volatileLoad(ctl) == 0)
        volatileStore(ctl, _clic_ctl_lsb);
    ubyte* ie = clicint_byte(irq, ie_offset);
    bool prev = (volatileLoad(ie) & 0x1) != 0;
    volatileStore(ie, ubyte(1));
    return prev;
}

bool irq_clear_enable(uint irq)
{
    if (irq >= irq_max)
        return false;
    ubyte* ie = clicint_byte(irq, ie_offset);
    bool prev = (volatileLoad(ie) & 0x1) != 0;
    volatileStore(ie, ubyte(0));
    return prev;
}

// Overloads for IrqClass — matches urt.driver.bl808.irq's surface so
// urt.system.d (and other shared code) sees the same API on both cores.
bool enable_irq(IrqClass c)  { return irq_set_enable(cast(uint)c); }
bool disable_irq(IrqClass c) { return irq_clear_enable(cast(uint)c); }

bool irq_is_pending(uint irq)
{
    if (irq >= irq_max)
        return false;
    return (volatileLoad(clicint_byte(irq, ip_offset)) & 0x1) != 0;
}

void irq_clear_pending(uint irq)
{
    if (irq >= irq_max)
        return;
    volatileStore(clicint_byte(irq, ip_offset), ubyte(0));
}

// Priority is the top (8 - NLBIT) bits of CTL; with NLBIT=0 (one level, no
// preemption) all 8 bits of CTL are priority. Higher value = higher priority.
void irq_set_priority(uint irq, ubyte priority)
{
    if (irq >= irq_max)
        return;
    volatileStore(clicint_byte(irq, ctl_offset), priority);
}

// Set the trigger type for a peripheral IRQ. Default after clic_init is
// level-positive (0), which is what most peripherals need.
enum IrqTrigger : ubyte
{
    level_pos = 0b00,
    edge_pos  = 0b01,
    level_neg = 0b10,
    edge_neg  = 0b11,
}

void irq_set_trigger(uint irq, IrqTrigger trig)
{
    if (irq >= irq_max)
        return;
    ubyte* attr = clicint_byte(irq, attr_offset);
    ubyte v = volatileLoad(attr);
    v = cast(ubyte)((v & ~0b110) | ((cast(ubyte)trig & 0b11) << 1));
    volatileStore(attr, v);
}


// ====================================================================
// Handler registration
// ====================================================================

// Install a handler for IRQ id. Returns the previous handler.
IrqHandler irq_set_handler(uint irq, IrqHandler handler)
{
    if (irq >= irq_max)
        return null;
    IrqHandler prev = _handlers[irq];
    _handlers[irq] = handler;
    return prev;
}


// ====================================================================
// Initialization
// ====================================================================

// Bring the CLIC into a known state: one priority level, no preemption,
// every line disabled with level-positive trigger and SHV=1. Read CLICINFO
// to learn how many CLICINTCTL bits are implemented (E907 reports 4 -> only
// the top 4 bits of CTL are RW) and cache the minimum-priority value for
// irq_set_enable's auto-bump.
//
// Called from sys_init (bl_common/system.d) before mstatus.MIE is enabled.
// MUST run before any irq_set_enable / irq_set_priority on a fresh boot --
// otherwise stale CLIC state from a prior cycle could fire the moment MIE
// goes on, and the auto-bump would have no nlbits to shift against.
extern(C) void irq_init()
{
    // T-Head mexstatus.SPUSHEN | SPSWAPEN (bits 16-17 of CSR 0x7E1). Without
    // these, th.ipush / th.ipop in _clic_dispatch are a silent no-op and the
    // first IRQ wedges the chip. Vendor system_bl808.c sets the same bits.
    asm @nogc nothrow
    {
        `
        li      t0, 0x30000
        csrs    0x7E1, t0
        `
        : : : "t0";
    }

    // CLICCFG = 0: NLBIT=0 (single priority level, no preemption), NMBIT=0,
    // NVBIT=0. We want preemption off until callers explicitly opt in.
    volatileStore(cast(ubyte*)cast(size_t)clic_cfg, ubyte(0));

    // CLICINFO[24:21] = CLICINTCTLBITS = number of CTL bits implemented from
    // the top. E907 reports 4, so a CTL write of 1 (bit 0) stores 0 in the
    // RAZ/WI bottom bits -- the line would never deliver. Compute the
    // bottom-of-priority-field bit value so irq_set_enable can clamp to a
    // true nonzero priority. Mirrors vendor's csi_vic_set_prio() arithmetic.
    uint info = volatileLoad(cast(uint*)cast(size_t)clic_info);
    uint ctlbits = (info >> 21) & 0xF;
    if (ctlbits == 0 || ctlbits > 8)
        ctlbits = 4;  // E907 default; defensive fallback if CLICINFO is bogus
    _clic_ctl_lsb = cast(ubyte)(1u << (8 - ctlbits));

    foreach (uint i; 0 .. irq_max)
    {
        volatileStore(clicint_byte(i, ip_offset),   ubyte(0));
        volatileStore(clicint_byte(i, ie_offset),   ubyte(0));
        // SHV=1: hardware-vectored dispatch via mtvt[id] -> _clic_dispatch.
        // SHV=0 routes through mtvec.base, which is _trap_exception (wrong
        // path for interrupts -- it expects sync traps). TRIG=0 (level-pos)
        // matches the vendor default. Vendor system_bl808.c does the same.
        volatileStore(clicint_byte(i, attr_offset), ubyte(1));
        volatileStore(clicint_byte(i, ctl_offset),  ubyte(0));
    }
}


// ====================================================================
// Diagnostics
// ====================================================================

__gshared uint irq_count;
__gshared uint[irq_max] irq_histogram;


// ====================================================================
// Dispatch (called from _clic_dispatch in start.S)
// ====================================================================

extern(C) void _irq_dispatch(uint cause) @nogc nothrow
{
    uint id = cause & 0x3FF;
    ++irq_count;
    if (id < irq_max)
    {
        ++irq_histogram[id];
        IrqHandler h = _handlers[id];
        if (h !is null)
            h(id);
    }
}


private:

enum uint clic_base    = 0xE080_0000;
enum uint clic_cfg     = clic_base + 0x0000;  // 1 byte
enum uint clic_info    = clic_base + 0x0004;  // 4 bytes
enum uint clic_mth     = clic_base + 0x0008;  // 4 bytes (MINTTHRESH)
enum uint clicint_base = clic_base + 0x1000;  // 4 bytes per IRQ thereafter

enum uint ip_offset   = 0;
enum uint ie_offset   = 1;
enum uint attr_offset = 2;
enum uint ctl_offset  = 3;

ubyte* clicint_byte(uint irq, uint field)
{
    return cast(ubyte*)cast(size_t)(clicint_base + irq * 4 + field);
}

__gshared IrqHandler[irq_max] _handlers;

// Minimum-nonzero CLICINTCTL value -- cached by irq_init() from CLICINFO.
// Pre-init fallback of 0x10 covers the E907 (4 implemented bits) so a stray
// irq_set_enable before irq_init still bumps to a valid priority.
__gshared ubyte _clic_ctl_lsb = 0x10;


// ====================================================================
// Tests
// ====================================================================
//
// Generic IRQ behaviour (global enable/disable round-trip, per-line
// enable/disable, handler table round-trip, diagnostics geometry,
// IrqGuard nesting) lives in urt.driver.irq's unittests and runs through
// this driver via the public-import facade.
//
// What lives here is everything that PROVES the CLIC trap path is wired
// correctly on real hardware:
//   1. CSR readback           -- mtvt / mtvec.MODE / mexstatus, plus the
//                                content of __clic_vectors. Catches the
//                                "csrw silently went nowhere" class of
//                                bug (mtvt=0x7D7 vs 0x307 cost us two
//                                days; this test would have ended the
//                                hunt in seconds).
//   2. Force-IP positive      -- vector 3 (MSWI) with IE=1, CTL>0, MIE=1
//                                hits the installed D handler.
//   3. Force-IP negatives x3  -- removing any one of IE / CTL / MIE
//                                MUST swallow the IRQ. A negative test
//                                that fires would tell us the gate we
//                                think we have isn't actually there.
//   4. Distinct-vector routing-- two handlers on two vectors, each fires
//                                its own. Catches table aliasing / a
//                                stuck single-slot dispatcher.
//   5. Live hardware trap     -- mtime/mtimecmp -> CLIC IRQ #7 -> the
//                                actual th.ipush / th.ipop trampoline,
//                                with a caller-saved register
//                                preservation check that no D-level test
//                                can mimic (the calling convention would
//                                hide the failure).

extern(C) extern __gshared uint[irq_max] __clic_vectors;
extern(C) extern void _clic_dispatch();

unittest // CSR + vector-table state proves the CLIC trap path is wired
{
    // mtvt (CSR 0x307) must point at __clic_vectors. If this fails, the
    // CSR number is wrong, the table moved, or start.S didn't reach the
    // csrw -- every IRQ would dispatch through whatever happens to be at
    // mtvt[id] (often address 0, which is what cost us two days).
    uint mtvt_csr;
    asm @nogc nothrow { "csrr %0, 0x307" : "=r" (mtvt_csr); }
    assert(mtvt_csr == cast(uint)cast(size_t)&__clic_vectors[0],
           "mtvt CSR does not point at __clic_vectors -- IRQs would vector through garbage");

    // mtvec.MODE = 0b11 = CLIC mode. MODE 01 (vectored) would route IRQs
    // through mtvec.base, where our _trap_exception sits -- it expects
    // sync traps, not IRQs, and would dump-and-spin on every fire.
    uint mtvec_csr;
    asm @nogc nothrow { "csrr %0, mtvec" : "=r" (mtvec_csr); }
    assert((mtvec_csr & 0x3) == 0x3, "mtvec MODE != 0b11 (CLIC)");

    // T-Head mexstatus.SPUSHEN | SPSWAPEN (bits 16/17 of CSR 0x7E1). Without
    // these, th.ipush / th.ipop are silent no-ops; the first nested IRQ
    // clobbers the outer's mepc and mret returns to the wrong PC.
    uint mexstatus;
    asm @nogc nothrow { "csrr %0, 0x7E1" : "=r" (mexstatus); }
    assert((mexstatus & 0x30000) == 0x30000,
           "mexstatus.SPUSHEN|SPSWAPEN not set -- nested IRQs will corrupt mepc");

    // Every live vector-table slot must dispatch through _clic_dispatch.
    // A wrong entry would mean that specific IRQ id silently jumps into
    // garbage or some unrelated handler.
    uint expected = cast(uint)cast(size_t)&_clic_dispatch;
    foreach (uint i; 0 .. irq_max)
        assert(__clic_vectors[i] == expected,
               "__clic_vectors entry doesn't point at _clic_dispatch");
}


// ====================================================================
// Force-IP CLIC plumbing (vector-agnostic; no peripheral needed)
// ====================================================================
//
// The positive and negative tests below all use vector 3 (MSWI). Software
// interrupts have no peripheral wiring of their own, so we drive IP=1
// manually and reason about what the CLIC must / must not do with it.

__gshared uint _clic_probe_calls;

void _clic_probe_handler(uint irq) @nogc nothrow
{
    ++_clic_probe_calls;
    // Clear IP so a level-triggered re-fire can't loop us; the test source
    // is just our IP=1 write, no peripheral to drain.
    volatileStore(clicint_byte(irq, ip_offset), ubyte(0));
}

// Hold mstatus.MIE off for the duration of the call so we can scribble on
// CLIC state without an in-flight IRQ landing mid-setup. Returns the prev
// state so the caller can restore it before testing delivery.
bool _quiesce_irq()
{
    return disable_interrupts();
}

void _spin_for_delivery()
{
    // ~50k nops at our running clock -- generous compared to the handful
    // of cycles between IP=1 and dispatch on real hardware.
    foreach (uint i; 0 .. 50_000)
        asm @nogc nothrow { "nop"; }
}

unittest // positive: IE=1, CTL>=lsb, MIE=1 -- handler runs, histogram increments
{
    enum uint test_vec = IrqClass.software;

    _clic_probe_calls = 0;
    uint hist_before = irq_histogram[test_vec];

    auto prev_handler = irq_set_handler(test_vec, &_clic_probe_handler);
    scope (exit) irq_set_handler(test_vec, prev_handler);

    bool was_globally_on = enable_interrupts();
    bool was_line_on     = irq_set_enable(test_vec);
    scope (exit)
    {
        irq_clear_enable(test_vec);
        if (!was_globally_on)
            disable_interrupts();
        if (was_line_on)
            irq_set_enable(test_vec);
    }

    // Confirm the auto-bump landed -- if CTL stayed 0, dispatch would never
    // happen (T-Head CLIC quirk) and we'd report a misleading delivery
    // failure instead of "CTL bump is broken".
    ubyte ctl_after = volatileLoad(clicint_byte(test_vec, ctl_offset));
    assert(ctl_after >= _clic_ctl_lsb,
           "irq_set_enable failed to bump CLICINTCTL above zero");

    volatileStore(clicint_byte(test_vec, ip_offset), ubyte(1));
    _spin_for_delivery();

    assert(_clic_probe_calls >= 1,
           "CLIC did not dispatch force-pended IRQ to handler");
    assert(irq_histogram[test_vec] > hist_before,
           "_irq_dispatch did not record the force-pended IRQ in irq_histogram");
}

unittest // negative: IE=0 must swallow force-IP
{
    enum uint test_vec = IrqClass.software;

    _clic_probe_calls = 0;

    auto prev_handler = irq_set_handler(test_vec, &_clic_probe_handler);
    scope (exit) irq_set_handler(test_vec, prev_handler);

    // Quiesce, then manually stage CTL>=lsb + IE=0 + MIE=1. If the gate
    // is real, dispatch is impossible from here regardless of IP.
    bool was_globally_on = _quiesce_irq();
    volatileStore(clicint_byte(test_vec, ctl_offset), _clic_ctl_lsb);
    irq_clear_enable(test_vec);
    enable_interrupts();
    scope (exit)
    {
        volatileStore(clicint_byte(test_vec, ip_offset), ubyte(0));
        irq_clear_enable(test_vec);
        if (!was_globally_on)
            disable_interrupts();
    }

    volatileStore(clicint_byte(test_vec, ip_offset), ubyte(1));
    _spin_for_delivery();

    assert(_clic_probe_calls == 0,
           "IE=0 did not gate delivery -- per-line enable is broken");
}

unittest // negative: CTL=0 must swallow force-IP even with IE=1, MIE=1
{
    // This test directly exercises the T-Head "priority 0 = silently
    // dropped" behaviour. If it fails (handler fires), the auto-bump in
    // irq_set_enable is unnecessary -- but more likely, something below
    // us has rewritten CLICINTCTL[i] and broken the assumption.
    enum uint test_vec = IrqClass.software;

    _clic_probe_calls = 0;

    auto prev_handler = irq_set_handler(test_vec, &_clic_probe_handler);
    scope (exit) irq_set_handler(test_vec, prev_handler);

    bool was_globally_on = _quiesce_irq();
    volatileStore(clicint_byte(test_vec, ctl_offset), ubyte(0));
    volatileStore(clicint_byte(test_vec, ie_offset),  ubyte(1));
    enable_interrupts();
    scope (exit)
    {
        volatileStore(clicint_byte(test_vec, ip_offset), ubyte(0));
        irq_clear_enable(test_vec);
        if (!was_globally_on)
            disable_interrupts();
    }

    volatileStore(clicint_byte(test_vec, ip_offset), ubyte(1));
    _spin_for_delivery();

    assert(_clic_probe_calls == 0,
           "CTL=0 did not gate delivery -- T-Head priority-0 quirk no longer holds, or our model is wrong");
}

unittest // negative: MIE=0 must swallow force-IP even with IE=1, CTL>0
{
    enum uint test_vec = IrqClass.software;

    _clic_probe_calls = 0;

    auto prev_handler = irq_set_handler(test_vec, &_clic_probe_handler);
    scope (exit) irq_set_handler(test_vec, prev_handler);

    bool was_line_on     = irq_set_enable(test_vec);
    bool was_globally_on = disable_interrupts();
    scope (exit)
    {
        volatileStore(clicint_byte(test_vec, ip_offset), ubyte(0));
        irq_clear_enable(test_vec);
        if (was_line_on)
            irq_set_enable(test_vec);
        if (was_globally_on)
            enable_interrupts();
    }

    volatileStore(clicint_byte(test_vec, ip_offset), ubyte(1));
    _spin_for_delivery();

    assert(_clic_probe_calls == 0,
           "MIE=0 did not gate delivery -- mstatus.MIE handling is broken");
}


// ====================================================================
// Routing: two vectors, two handlers, each fires its own
// ====================================================================

__gshared uint _route_calls_a;
__gshared uint _route_calls_b;
__gshared uint _route_irq_seen_a;
__gshared uint _route_irq_seen_b;

void _route_handler_a(uint irq) @nogc nothrow
{
    ++_route_calls_a;
    _route_irq_seen_a = irq;
    volatileStore(clicint_byte(irq, ip_offset), ubyte(0));
}

void _route_handler_b(uint irq) @nogc nothrow
{
    ++_route_calls_b;
    _route_irq_seen_b = irq;
    volatileStore(clicint_byte(irq, ip_offset), ubyte(0));
}

unittest // mtvt[a] and mtvt[b] independently route to their own handler
{
    enum uint vec_a = IrqClass.software;  // 3
    enum uint vec_b = 16;                 // first peripheral slot -- no real wire on this build

    _route_calls_a = 0;
    _route_calls_b = 0;
    _route_irq_seen_a = ~0u;
    _route_irq_seen_b = ~0u;

    auto prev_a = irq_set_handler(vec_a, &_route_handler_a);
    auto prev_b = irq_set_handler(vec_b, &_route_handler_b);
    scope (exit)
    {
        irq_set_handler(vec_a, prev_a);
        irq_set_handler(vec_b, prev_b);
    }

    bool was_globally_on = enable_interrupts();
    bool was_a_on = irq_set_enable(vec_a);
    bool was_b_on = irq_set_enable(vec_b);
    scope (exit)
    {
        irq_clear_enable(vec_a);
        irq_clear_enable(vec_b);
        if (!was_globally_on)
            disable_interrupts();
        if (was_a_on) irq_set_enable(vec_a);
        if (was_b_on) irq_set_enable(vec_b);
    }

    volatileStore(clicint_byte(vec_a, ip_offset), ubyte(1));
    _spin_for_delivery();
    volatileStore(clicint_byte(vec_b, ip_offset), ubyte(1));
    _spin_for_delivery();

    assert(_route_calls_a == 1,        "handler A fired wrong number of times");
    assert(_route_calls_b == 1,        "handler B fired wrong number of times");
    assert(_route_irq_seen_a == vec_a, "handler A dispatched with wrong vector id");
    assert(_route_irq_seen_b == vec_b, "handler B dispatched with wrong vector id");
}


// ====================================================================
// Live hardware trap (mtime -> CLIC IRQ #7 -> th.ipush trampoline)
// ====================================================================
//
// Force-IP exercises the CLIC, but not the timer hardware and not the
// nested-IRQ safety property of th.ipush / th.ipop. This test arms a
// real mtimecmp fire and asserts both that the handler ran AND that a
// caller-saved register survived the trap. A bare sw/lw trampoline (no
// ipush) would silently corrupt t0 here and the test would fail with a
// clearly-attributed message.

__gshared uint _timer_magic;

void _timer_trap_probe_handler(uint /+irq+/) @nogc nothrow
{
    _timer_magic = 0xCAFE_F00D;
    auto mtimecmp = cast(ulong*)cast(size_t)0xE000_4000;
    volatileStore(mtimecmp, ulong.max);  // disarm so we don't re-fire mid-cleanup
}

unittest // mtime fires IRQ #7, _clic_dispatch preserves caller-saved t0
{
    import urt.driver.bl618.timer : mtime_read;

    _timer_magic = 0;
    uint hist_before = irq_histogram[IrqClass.timer];

    auto prev_handler = irq_set_handler(IrqClass.timer, &_timer_trap_probe_handler);
    scope (exit) irq_set_handler(IrqClass.timer, prev_handler);

    auto mtimecmp = cast(ulong*)cast(size_t)0xE000_4000;
    volatileStore(mtimecmp, mtime_read() + 1_000);  // 1ms at 1MHz mtime

    bool was_globally_on = enable_interrupts();
    bool was_irq7_on     = irq_set_enable(IrqClass.timer);
    scope (exit)
    {
        irq_clear_enable(IrqClass.timer);
        if (!was_globally_on)
            disable_interrupts();
        if (was_irq7_on)
            irq_set_enable(IrqClass.timer);
    }

    // Hold a known pattern in t0 across the spin. If th.ipush / th.ipop
    // drops t0 (the most likely failure for caller-saved restore), the
    // post-loop read shows the wrong value. Inline asm because nothing at
    // D level can keep a value in a specific GPR across a function call.
    // 1M iterations is plenty of grace past the 1ms mtime fire.
    uint t0_after;
    asm @nogc nothrow
    {
        `
        li      t0, 0x12345678
        li      t4, 1000000
    1:
        lw      t1, %1
        li      t2, 0xCAFEF00D
        beq     t1, t2, 2f
        addi    t4, t4, -1
        bnez    t4, 1b
    2:
        mv      %0, t0
        `
        : "=r" (t0_after)
        : "m" (_timer_magic)
        : "t0", "t1", "t2", "t4", "memory";
    }

    assert(_timer_magic == 0xCAFE_F00D, "machine timer IRQ did not fire -- mtime/mtimecmp path broken");
    assert(t0_after == 0x12345678,
           "caller-saved t0 clobbered across IRQ trap -- th.ipush/ipop not preserving GPRs");
    assert(irq_histogram[IrqClass.timer] > hist_before,
           "_irq_dispatch did not record the timer trap in irq_histogram");
}
