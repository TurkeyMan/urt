module urt.driver.bl808.irq;

import core.volatile;

nothrow @nogc:

enum bool has_plic = true;
enum bool has_nvic = false;
enum bool has_clic = false;
enum bool has_per_irq_control = true;
enum bool has_irq_priority = false;
enum bool has_wait_for_interrupt = true;
enum bool has_irq_diagnostics = true;
enum bool has_global_irq_state = true;
enum bool has_smp = false;


// ================================================================
// CPU interrupt control
// ================================================================

// Enable interrupt delivery. Returns previous state.
bool enable_interrupts()
{
    ulong prev;
    asm nothrow @nogc { "csrrsi %0, mstatus, 0x8" : "=r" (prev); }
    return (prev & 0x8) != 0;
}

// Disable interrupt delivery. Returns previous state.
bool disable_interrupts()
{
    ulong prev;
    asm nothrow @nogc { "csrrci %0, mstatus, 0x8" : "=r" (prev); }
    return (prev & 0x8) != 0;
}

// Set interrupt delivery state. Returns previous state.
bool set_interrupts(bool state)
{
    return state ? enable_interrupts() : disable_interrupts();
}

// Halt CPU until an interrupt is pending. Near-zero power.
void wait_for_interrupt()
{
    asm nothrow @nogc { "wfi"; }
}

// ================================================================
// Interrupt source control
// ================================================================

// Interrupt classes (mie register bits)
enum IrqClass : uint { software = 3, timer = 7, external = 11 }

// Enable an interrupt class. Returns previous state.
bool enable_irq(IrqClass c)
{
    ulong prev;
    asm nothrow @nogc { "csrrs %0, mie, %1" : "=r" (prev) : "r" (1UL << c); }
    return (prev & (1UL << c)) != 0;
}

// Disable an interrupt class. Returns previous state.
bool disable_irq(IrqClass c)
{
    ulong prev;
    asm nothrow @nogc { "csrrc %0, mie, %1" : "=r" (prev) : "r" (1UL << c); }
    return (prev & (1UL << c)) != 0;
}

enum uint irq_max = 80;

alias IrqHandler = void function(uint irq) nothrow @nogc;

// Set the external interrupt handler. Receives the PLIC IRQ number.
// Returns the previous handler for chaining.
IrqHandler irq_set_handler(IrqHandler handler)
{
    auto prev = irq_handler;
    irq_handler = handler;
    return prev;
}

// Enable an individual PLIC IRQ (set priority > 0 and enable bit)
bool enable_irq(uint irq)
{
    if (irq >= irq_max)
        return false;
    auto prio = cast(uint*)(plic_base + irq * 4);
    volatileStore(prio, 1);
    auto en = cast(uint*)(plic_enable + (irq / 32) * 4);
    uint mask = 1U << (irq % 32);
    uint prev = volatileLoad(en);
    volatileStore(en, prev | mask);
    return (prev & mask) != 0;
}

// Disable an individual PLIC IRQ. Returns previous state.
bool disable_irq(uint irq)
{
    if (irq >= irq_max)
        return false;
    auto en = cast(uint*)(plic_enable + (irq / 32) * 4);
    uint mask = 1U << (irq % 32);
    uint prev = volatileLoad(en);
    volatileStore(en, prev & ~mask);
    return (prev & mask) != 0;
}

private:

enum ulong plic_base   = 0xE000_0000;
enum ulong plic_enable = 0xE000_2000;

__gshared IrqHandler irq_handler;

public:

// Diagnostic counters (temporary)
__gshared uint irq_count = 0;
__gshared uint[irq_max] irq_histogram;

// PLIC bring-up. C906/D0 boots with the PLIC already in a usable state from
// the boot ROM, so for now this is a stub that satisfies the sys_init
// contract. When we start exposing per-IRQ priorities we'll move that setup
// here (cleared priorities, enable mask zeroed) -- mirrors the CLIC's
// irq_init in bl618/irq.d.
extern(C) void irq_init() {}

package:

// Called from start.S _trap_mext
extern(C) void _irq_dispatch(uint irq)
{
    ++irq_count;
    if (irq < irq_max)
        ++irq_histogram[irq];
    if (irq_handler !is null)
        irq_handler(irq);
}

// Called from start.S _trap_mtimer
extern(C) void _timer_irq_handler()
{
    // TODO: hook up to urt.time tick
}
