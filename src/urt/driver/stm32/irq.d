// STM32 interrupt controller driver
//
// Cortex-M4/M7 use the standard ARM NVIC (Nested Vectored Interrupt Controller).
// STM32F4xx has up to 82 peripheral interrupts, STM32F7xx up to 98.
module urt.driver.stm32.irq;

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

version (STM32F7)
    enum uint irq_max = 98;
else
    enum uint irq_max = 82;

import core.volatile;

// NVIC registers (ARM standard)
private enum ulong NVIC_ISER0 = 0xE000E100;
private enum ulong NVIC_ICER0 = 0xE000E180;
private enum ulong NVIC_ISPR0 = 0xE000E200;
private enum ulong NVIC_ICPR0 = 0xE000E280;
private enum ulong NVIC_IPR0  = 0xE000E400;

// Cortex-M PRIMASK: bit 0 set means interrupts masked. Read it before
// mutating so callers (including IrqGuard) can restore prior state.
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

bool irq_set_enable(uint irq_num)
{
    immutable reg = irq_num / 32;
    immutable bit = irq_num % 32;
    auto iser = cast(uint*)(NVIC_ISER0 + reg * 4);
    bool prev = (volatileLoad(iser) & (1u << bit)) != 0;
    volatileStore(iser, 1u << bit);
    return prev;
}

bool irq_clear_enable(uint irq_num)
{
    immutable reg = irq_num / 32;
    immutable bit = irq_num % 32;
    // NVIC mirrors enable state in ISER; reading ISER tells us prior bit
    // regardless of which window (ISER vs ICER) we use to mutate it.
    auto iser = cast(uint*)(NVIC_ISER0 + reg * 4);
    bool prev = (volatileLoad(iser) & (1u << bit)) != 0;
    volatileStore(cast(uint*)(NVIC_ICER0 + reg * 4), 1u << bit);
    return prev;
}

// Set priority for a peripheral IRQ (0 = highest, 255 = lowest)
// STM32F4/F7 implement 4 priority bits (top 4 of 8)
void irq_set_priority(uint irq_num, ubyte priority)
{
    volatileStore(cast(ubyte*)(NVIC_IPR0 + irq_num), priority);
}
