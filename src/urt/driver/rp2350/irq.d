// RP2350 interrupt controller driver
//
// Cortex-M33 uses the standard ARM NVIC (Nested Vectored Interrupt Controller).
// RP2350 has 52 peripheral interrupts (IRQ 0-51).
module urt.driver.rp2350.irq;

@nogc nothrow:

enum bool has_plic = false;
enum bool has_nvic = true;
enum bool has_per_irq_control = true;
enum bool has_irq_priority = true;
enum bool has_wait_for_interrupt = false;
enum bool has_irq_diagnostics = false;
enum bool has_smp = false;
enum uint irq_max = 52;

import core.volatile;

// NVIC registers (ARM standard)
private enum ulong NVIC_ISER0 = 0xE000E100;  // Interrupt Set Enable (2 words for 52 IRQs)
private enum ulong NVIC_ICER0 = 0xE000E180;  // Interrupt Clear Enable
private enum ulong NVIC_ISPR0 = 0xE000E200;  // Interrupt Set Pending
private enum ulong NVIC_ICPR0 = 0xE000E280;  // Interrupt Clear Pending
private enum ulong NVIC_IPR0  = 0xE000E400;  // Interrupt Priority (byte-accessible)

// Globally disable interrupts (set PRIMASK)
void irq_disable()
{
    asm @nogc nothrow { "cpsid i"; }
}

// Globally enable interrupts (clear PRIMASK)
void irq_enable()
{
    asm @nogc nothrow { "cpsie i"; }
}

// Enable a specific peripheral IRQ (0-51)
void irq_set_enable(uint irq_num)
{
    immutable reg = irq_num / 32;
    immutable bit = irq_num % 32;
    volatileStore(cast(uint*)(NVIC_ISER0 + reg * 4), 1u << bit);
}

// Disable a specific peripheral IRQ
void irq_clear_enable(uint irq_num)
{
    immutable reg = irq_num / 32;
    immutable bit = irq_num % 32;
    volatileStore(cast(uint*)(NVIC_ICER0 + reg * 4), 1u << bit);
}

// Set priority for a peripheral IRQ (0 = highest, 255 = lowest)
// Cortex-M33 on RP2350 implements 4 priority bits (top 4 of 8)
void irq_set_priority(uint irq_num, ubyte priority)
{
    volatileStore(cast(ubyte*)(NVIC_IPR0 + irq_num), priority);
}
