// BK7231 interrupt controller (shared by BK7231N and BK7231T)
//
// ARM968E-S uses a custom Beken interrupt controller (not ARM GIC/NVIC).
// The BK7231N ICU (Interrupt Control Unit) is at 0x0080_2000.
module urt.driver.bk7231.irq;

import core.volatile;

@nogc nothrow:

enum bool has_plic = false;
enum bool has_nvic = false;
enum bool has_per_irq_control = true;
enum bool has_irq_priority = false;
enum bool has_wait_for_interrupt = false;
enum bool has_irq_diagnostics = false;
enum bool has_smp = false;
enum uint irq_max = 32;

// Disable all IRQs (set CPSR I+F bits)
void irq_disable()
{
    uint cpsr;
    asm @nogc nothrow { "mrs %0, cpsr" : "=r" (cpsr); }
    cpsr |= 0xC0;
    asm @nogc nothrow { "msr cpsr_c, %0" :: "r" (cpsr); }
}

// Enable IRQs (clear CPSR I bit)
void irq_enable()
{
    uint cpsr;
    asm @nogc nothrow { "mrs %0, cpsr" : "=r" (cpsr); }
    cpsr &= ~0x80;
    asm @nogc nothrow { "msr cpsr_c, %0" :: "r" (cpsr); }
}

void irq_set_enable(uint irq_num)
{
    uint mask = volatileLoad(cast(uint*)(cast(size_t)(icu_base + icu_int_enable)));
    mask |= (1u << irq_num);
    volatileStore(cast(uint*)(cast(size_t)(icu_base + icu_int_enable)), mask);
}

void irq_clear_enable(uint irq_num)
{
    uint mask = volatileLoad(cast(uint*)(cast(size_t)(icu_base + icu_int_enable)));
    mask &= ~(1u << irq_num);
    volatileStore(cast(uint*)(cast(size_t)(icu_base + icu_int_enable)), mask);
}


private:

enum uint icu_base = 0x0080_2000;

// ICU register offsets (from SDK icu.h)
enum
{
    icu_peri_clk_pwd = 2 * 4,   // 0x08: peripheral clock power-down (1=off)
    icu_clk_gating   = 3 * 4,   // 0x0C: peripheral clock gating
    icu_int_enable   = 16 * 4,  // 0x40: interrupt enable mask (FIQ [31:16] | IRQ [15:0])
    icu_global_int   = 17 * 4,  // 0x44: global IRQ/FIQ enable
    icu_int_raw      = 18 * 4,  // 0x48: raw interrupt status
    icu_int_status   = 19 * 4,  // 0x4C: masked interrupt status
    icu_arm_wakeup   = 20 * 4,  // 0x50: ARM wakeup enable
}

// IRQ bit positions in icu_int_enable / icu_int_status
enum : uint
{
    IRQ_UART1 = 1 << 0,
    IRQ_UART2 = 1 << 1,
    IRQ_I2C1  = 1 << 2,
    IRQ_IRDA  = 1 << 3,
    IRQ_I2C2  = 1 << 5,
    IRQ_SPI   = 1 << 6,
    IRQ_GPIO  = 1 << 7,
    IRQ_TIMER = 1 << 8,
    IRQ_PWM   = 1 << 9,
    IRQ_ADC   = 1 << 11,
    IRQ_SDIO  = 1 << 12,
    IRQ_SEC   = 1 << 13,
    IRQ_LA    = 1 << 14,
    IRQ_DMA   = 1 << 15,
}
