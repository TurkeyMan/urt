// BL618 interrupt controller driver (CLIC-style)
module urt.driver.bl618.irq;

@nogc nothrow:

enum bool has_plic = false;
enum bool has_nvic = false;
enum bool has_per_irq_control = false;
enum bool has_irq_priority = false;
enum bool has_wait_for_interrupt = false;
enum bool has_irq_diagnostics = false;
enum bool has_smp = false;
enum uint irq_max = 0;

// Globally disable interrupts
void irq_disable()
{
    asm @nogc nothrow
    {
        "csrc mstatus, 0x0008";  // Clear MIE
    }
}

/// Globally enable interrupts
void irq_enable()
{
    asm @nogc nothrow
    {
        "csrs mstatus, 0x0008";  // Set MIE
    }
}
