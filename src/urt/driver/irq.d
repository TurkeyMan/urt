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
    enum bool has_clic = false;
    enum bool has_per_irq_control = false;
    enum bool has_irq_priority = false;
    enum bool has_wait_for_interrupt = false;
    enum bool has_irq_diagnostics = false;
    enum bool has_global_irq_state = false;
    enum bool has_smp = false;
    enum uint irq_max = 0;
}

nothrow @nogc:

alias IrqHandler = void function(uint irq) nothrow @nogc;


// ====================================================================
// Driver API
// ====================================================================

// `irq_init()` -- platform driver brings the interrupt controller to a known
// state. Re-exported from the platform module via the public import above
// (signature: extern(C) void irq_init()). sys_init in bl_common/system.d
// calls this before any irq_line_enable and before irq_global_enable.

// Global interrupt control

// Disable all interrupt delivery. Returns previous state where the platform
// can report it (has_global_irq_state). FreeRTOS-style critical-section
// platforms always report "true" so IrqGuard pairs enter/exit cleanly.
bool irq_global_disable()
{
    static if (has_plic || has_clic)
        return disable_interrupts();
    else static if (irq_max > 0)
        return irq_disable();
    else
        assert(false, "no IRQ controller");
}

// Enable all interrupt delivery. Returns previous state where the platform
// can report it; see irq_global_disable() for the FreeRTOS caveat.
bool irq_global_enable()
{
    static if (has_plic || has_clic)
        return enable_interrupts();
    else static if (irq_max > 0)
        return irq_enable();
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
            return irq_set_enable(irq);
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
            return irq_clear_enable(irq);
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
// PLIC delivers all external IRQs through a single line, so handlers are
// installed globally and the platform's claim/complete protocol routes to
// them.
static if (has_plic)
{
    IrqHandler irq_handler_set(IrqHandler handler)
    {
        return irq_set_handler(handler);
    }
}

// CLIC (and NVIC) maintains per-IRQ vectors. Each line gets its own handler;
// the dispatcher reads mcause / IPSR to pick which one to call.
static if (has_clic || has_nvic)
{
    IrqHandler irq_handler_set(uint irq, IrqHandler handler)
    {
        return irq_set_handler(irq, handler);
    }
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


// ====================================================================
// Tests
// ====================================================================
//
// The desktop unittest binary has irq_max == 0 so every body below stays
// behind `static if (irq_max > 0)` and is gated out -- only the capability
// cross-asserts run there. On embedded unittest builds (rare; embedded
// targets are CONFIG=release by policy) these exercise the live CSR / MMIO
// surface and the trap entry path.

unittest // capability cross-consistency
{
    static if (has_plic) static assert(has_per_irq_control);
    static if (has_nvic) static assert(has_per_irq_control);
    static if (has_clic) static assert(has_per_irq_control);
    static if (has_irq_diagnostics) static assert(irq_max > 0);
    // Diagnostics requires per-IRQ dispatch -- you can't increment a
    // histogram if there's no per-line tag at trap entry.
    static if (has_irq_diagnostics)
        static assert(has_plic || has_clic || has_nvic);
}

static if (irq_max > 0 && has_global_irq_state)
unittest // global enable/disable reports prior state symmetrically
{
    bool original = irq_global_disable();
    bool now = irq_global_disable();
    assert(!now, "second disable must observe MIE off");

    irq_global_enable();
    bool en = irq_global_enable();
    assert(en, "second enable must observe MIE on");

    irq_global_set(original);
}

static if (irq_max > 0 && has_global_irq_state)
unittest // IrqGuard restores prior state across both polarities
{
    irq_global_enable();
    {
        auto guard = irq_critical();
        bool inside = irq_global_disable();
        assert(!inside, "inside the guarded region, IRQs must remain off");
    }
    bool after_on = irq_global_disable();
    assert(after_on, "guard must re-enable when entered with IRQs on");

    irq_global_disable();
    {
        auto guard = irq_critical();
    }
    bool after_off = irq_global_disable();
    assert(!after_off, "guard must leave IRQs off when entered with IRQs off");
}

static if (irq_max > 0)
unittest // IrqGuard nests cleanly (covers FreeRTOS recursive-mux platforms too)
{
    auto outer = irq_critical();
    {
        auto inner = irq_critical();
        {
            auto innermost = irq_critical();
        }
    }
    // If destruction order or recursion accounting were wrong, a platform
    // using a counted spinlock (ESP32 portMUX) would assert internally.
}

static if (irq_max > 0 && has_per_irq_control)
unittest // per-IRQ enable / disable round-trip on an unwired slot
{
    enum uint slot = irq_max - 1;

    // Coerce to a known-off baseline first; some platform setters return
    // void rather than the previous state.
    irq_line_disable(slot);

    bool was = irq_line_enable(slot);
    assert(!was, "freshly cleared slot must report off");

    bool en = irq_line_enable(slot);
    assert(en, "re-enable must report on");

    bool dis = irq_line_disable(slot);
    assert(dis, "disable after enable must report on");

    bool again = irq_line_enable(slot);
    assert(!again, "re-enable after disable must report off");

    irq_line_disable(slot);
}

static if (irq_max > 0 && has_per_irq_control)
unittest // out-of-range per-IRQ calls must not crash or touch foreign memory
{
    enum uint bad = irq_max + 1024;
    bool e = irq_line_enable(bad);
    bool d = irq_line_disable(bad);
    assert(!e && !d, "out-of-range must be reported as 'was off'");
}

// Handler tables: only CLIC/NVIC expose per-line install. PLIC has a single
// global dispatcher so its irq_handler_set has a different signature.
static if (irq_max > 0 && (has_clic || has_nvic))
unittest // handler registration swap reports the just-installed handler
{
    static void a(uint) {}
    static void b(uint) {}

    enum uint slot = 7; // timer line on RISC-V; harmless on ARM unittest

    IrqHandler prior = irq_handler_set(slot, &a);
    scope (exit) irq_handler_set(slot, prior);

    IrqHandler swap1 = irq_handler_set(slot, &b);
    assert(swap1 is &a, "swap must surface the most recent install");

    IrqHandler swap2 = irq_handler_set(slot, null);
    assert(swap2 is &b);
}

static if (irq_max > 0 && has_irq_diagnostics)
unittest // diagnostics expose the expected geometry and read stably
{
    uint[] hist = irq_hit_histogram();
    assert(hist.length == irq_max,
           "histogram length must mirror irq_max");

    // The counter is __gshared and only mutated from _irq_dispatch; reading
    // it twice with IRQs off must yield identical values.
    auto guard = irq_critical();
    uint a = irq_total_count();
    uint b = irq_total_count();
    assert(a == b, "diagnostics counter wobbled with IRQs disabled");
}
