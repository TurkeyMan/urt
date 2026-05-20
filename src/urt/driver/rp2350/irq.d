// RP2350 interrupt controller driver
//
// Cortex-M33 uses the standard ARM NVIC (Nested Vectored Interrupt Controller).
// RP2350 has 52 peripheral interrupts (IRQ 0-51).
module urt.driver.rp2350.irq;

@nogc nothrow:

enum bool has_plic = false;
enum bool has_nvic = true;
enum bool has_clic = false;
enum bool has_per_irq_control = true;
enum bool has_irq_priority = true;
enum bool has_wait_for_interrupt = false;
enum bool has_irq_diagnostics = false;
enum bool has_global_irq_state = true;
enum bool has_smp = false;
enum uint irq_max = 52;

import core.volatile;

// NVIC registers (ARM standard)
private enum ulong NVIC_ISER0 = 0xE000E100;  // Interrupt Set Enable (2 words for 52 IRQs)
private enum ulong NVIC_ICER0 = 0xE000E180;  // Interrupt Clear Enable
private enum ulong NVIC_ISPR0 = 0xE000E200;  // Interrupt Set Pending
private enum ulong NVIC_ICPR0 = 0xE000E280;  // Interrupt Clear Pending
private enum ulong NVIC_IPR0  = 0xE000E400;  // Interrupt Priority (byte-accessible)

// Cortex-M33 PRIMASK: bit 0 set means interrupts masked. Read it before
// mutating so callers (IrqGuard) can restore prior state.
bool irq_disable()
{
    uint primask;
    asm @nogc nothrow
    {
        `
        mrs   %0, primask
        cpsid i
        `
        : "=r" (primask);
    }
    return (primask & 1) == 0;
}

bool irq_enable()
{
    uint primask;
    asm @nogc nothrow
    {
        `
        mrs   %0, primask
        cpsie i
        `
        : "=r" (primask);
    }
    return (primask & 1) == 0;
}

// Enable a specific peripheral IRQ (0-51). Returns previous state.
bool irq_set_enable(uint irq_num)
{
    immutable reg = irq_num / 32;
    immutable bit = irq_num % 32;
    auto iser = cast(uint*)(NVIC_ISER0 + reg * 4);
    bool prev = (volatileLoad(iser) & (1u << bit)) != 0;
    volatileStore(iser, 1u << bit);
    return prev;
}

// Disable a specific peripheral IRQ. Returns previous state.
bool irq_clear_enable(uint irq_num)
{
    immutable reg = irq_num / 32;
    immutable bit = irq_num % 32;
    auto iser = cast(uint*)(NVIC_ISER0 + reg * 4);
    bool prev = (volatileLoad(iser) & (1u << bit)) != 0;
    volatileStore(cast(uint*)(NVIC_ICER0 + reg * 4), 1u << bit);
    return prev;
}

// Set priority for a peripheral IRQ (0 = highest, 255 = lowest)
// Cortex-M33 on RP2350 implements 4 priority bits (top 4 of 8)
void irq_set_priority(uint irq_num, ubyte priority)
{
    volatileStore(cast(ubyte*)(NVIC_IPR0 + irq_num), priority);
}
