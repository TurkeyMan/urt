// Unified baremetal interrupt controller driver
//
// Normalizes the IRQ API across RISC-V PLIC, ARM NVIC, Beken ICU, etc.
// Platform drivers export capabilities; the baremetal layer re-exports
// them and provides a uniform function surface.
module urt.driver.irq;

version (BL808_M0)
    public import urt.driver.bl618.irq;
else version (BL808)
    public import urt.driver.bl808.irq;
else version (BL618)
    public import urt.driver.bl618.irq;
else version (Beken)
    public import urt.driver.bk7231.irq;
else version (RP2350)
    public import urt.driver.rp2350.irq;
else version (STM32)
    public import urt.driver.stm32.irq;
else version (Espressif)
    public import urt.driver.esp32.irq;
else
{
    enum bool has_plic = false;
    enum bool has_nvic = false;
    enum bool has_per_irq_control = false;
    enum bool has_irq_priority = false;
    enum bool has_wait_for_interrupt = false;
    enum bool has_irq_diagnostics = false;
    enum bool has_smp = false;
    enum uint irq_max = 0;
}

nothrow @nogc:

alias IrqHandler = void function(uint irq) nothrow @nogc;


// ════════════════════════════════════════════════════════════════════
// Driver API
// ════════════════════════════════════════════════════════════════════

// Global interrupt control

// Disable all interrupt delivery. Returns previous state.
bool irq_global_disable()
{
    static if (has_plic)
        return disable_interrupts();
    else static if (irq_max > 0)
    {
        irq_disable();
        return true;
    }
    else
        assert(false, "no IRQ controller");
}

// Enable all interrupt delivery. Returns previous state.
bool irq_global_enable()
{
    static if (has_plic)
        return enable_interrupts();
    else static if (irq_max > 0)
    {
        irq_enable();
        return true;
    }
    else
        assert(false, "no IRQ controller");
}

// Set global interrupt state. Returns previous state.
bool irq_global_set(bool enabled)
{
    return enabled ? irq_global_enable() : irq_global_disable();
}

// RAII-style critical section guard.
// Usage: auto guard = irq_critical();
struct IrqGuard
{
    private bool _prev;
    @disable this();
    @disable this(this);

    ~this() nothrow @nogc
    {
        irq_global_set(_prev);
    }
}

IrqGuard irq_critical()
{
    IrqGuard g = void;
    g._prev = irq_global_disable();
    return g;
}

// Per-IRQ control

// Enable a specific peripheral interrupt. Returns previous state.
bool irq_line_enable(uint irq)
{
    static if (has_per_irq_control)
    {
        static if (has_plic)
            return enable_irq(irq);
        else
        {
            irq_set_enable(irq);
            return false;
        }
    }
    else
        assert(false, "no per-IRQ control");
}

// Disable a specific peripheral interrupt. Returns previous state.
bool irq_line_disable(uint irq)
{
    static if (has_per_irq_control)
    {
        static if (has_plic)
            return disable_irq(irq);
        else
        {
            irq_clear_enable(irq);
            return false;
        }
    }
    else
        assert(false, "no per-IRQ control");
}

// Set priority for a peripheral interrupt (0 = highest).
void irq_line_set_priority(uint irq, ubyte priority)
{
    static if (has_irq_priority)
        irq_set_priority(irq, priority);
    else
        assert(false, "no IRQ priority support");
}

// Handler registration

// Install an interrupt handler. Returns the previous handler for chaining.
IrqHandler irq_handler_set(IrqHandler handler)
{
    static if (has_plic)
        return irq_set_handler(handler);
    else
        assert(false, "TODO: irq_handler_set for this platform");
}

// Power management

// Halt CPU until an interrupt fires. Near-zero power draw.
void irq_wait()
{
    static if (has_wait_for_interrupt)
        wait_for_interrupt();
    else
        assert(false, "WFI not available");
}

// Diagnostics

static if (has_irq_diagnostics)
{
    ref uint irq_total_count()
    {
        return irq_count;
    }

    uint[] irq_hit_histogram()
    {
        return irq_histogram[];
    }
}


// ════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════

unittest
{
    static if (has_plic) static assert(has_per_irq_control);
    static if (has_nvic) static assert(has_per_irq_control);

    static if (irq_max > 0)
    {
        // Global disable/enable round-trip
        bool prev = irq_global_disable();
        irq_global_enable();

        // Critical section guard
        {
            auto guard = irq_critical();
        }

        static if (has_per_irq_control)
        {
            irq_line_disable(0);
            irq_line_enable(0);
        }

        static if (has_irq_diagnostics)
        {
            uint total = irq_total_count();
            uint[] hist = irq_hit_histogram();
            assert(hist.length == irq_max);
        }
    }
}
