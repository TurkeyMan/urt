// STM32 interrupt controller driver
//
// Cortex-M4/M7 use the standard ARM NVIC (Nested Vectored Interrupt Controller).
// STM32F4xx has up to 82 peripheral interrupts, STM32F7xx up to 98.
module urt.driver.stm32.irq;

@nogc nothrow:

enum bool has_plic = false;
enum bool has_nvic = true;
enum bool has_per_irq_control = true;
enum bool has_irq_priority = true;
enum bool has_wait_for_interrupt = false;
enum bool has_irq_diagnostics = false;
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

void irq_disable()
{
    asm @nogc nothrow { "cpsid i"; }
}

void irq_enable()
{
    asm @nogc nothrow { "cpsie i"; }
}

void irq_set_enable(uint irq_num)
{
    immutable reg = irq_num / 32;
    immutable bit = irq_num % 32;
    volatileStore(cast(uint*)(NVIC_ISER0 + reg * 4), 1u << bit);
}

void irq_clear_enable(uint irq_num)
{
    immutable reg = irq_num / 32;
    immutable bit = irq_num % 32;
    volatileStore(cast(uint*)(NVIC_ICER0 + reg * 4), 1u << bit);
}

// Set priority for a peripheral IRQ (0 = highest, 255 = lowest)
// STM32F4/F7 implement 4 priority bits (top 4 of 8)
void irq_set_priority(uint irq_num, ubyte priority)
{
    volatileStore(cast(ubyte*)(NVIC_IPR0 + irq_num), priority);
}
