// ESP32 interrupt controller driver
//
// ESP-IDF manages interrupts via esp_intr_alloc(). Direct vector table
// access is discouraged since FreeRTOS owns it. Global disable/enable
// uses the FreeRTOS portMUX-based critical section directly.
module urt.driver.esp32.irq;

import urt.internal.sys.freertos : portMUX_TYPE, portMUX_FREE_VAL, vPortEnterCritical, vPortExitCritical;

nothrow @nogc:


enum bool has_plic = false;
enum bool has_nvic = false;
enum bool has_clic = false;
enum bool has_per_irq_control = false; // TODO: wire up esp_intr_alloc
enum bool has_irq_priority = false;    // TODO: wire up esp_intr_alloc priority flags
enum bool has_wait_for_interrupt = true;
enum bool has_irq_diagnostics = false;

// FreeRTOS critical sections are recursive (portENTER nests with a per-mux
// counter), so the return value is not a meaningful "prior global IRQ" bit
// the way it is on bare-metal. Callers must pair enter/exit, and IrqGuard
// does -- we always claim "was enabled" so the guard unconditionally exits.
enum bool has_global_irq_state = false;
enum bool has_smp = false;
enum uint irq_max = 32;

bool irq_disable()
{
    vPortEnterCritical(&_irq_mux);
    return true;
}

bool irq_enable()
{
    vPortExitCritical(&_irq_mux);
    return true;
}

bool irq_set_enable(uint irq)
{
    assert(false, "TODO: use esp_intr_alloc");
}

bool irq_clear_enable(uint irq)
{
    assert(false, "TODO: use esp_intr_free");
}

void irq_set_priority(uint irq, ubyte priority)
{
    assert(false, "TODO: use esp_intr_set_in_iram / priority flags");
}

void wait_for_interrupt()
{
    ow_irq_wait();
}


private:

// Single global mux serves as the IRQ-disable lock. portENTER_CRITICAL
// is reentrant via the mux's internal count, so nested IrqGuards compose.
__gshared portMUX_TYPE _irq_mux = portMUX_TYPE(portMUX_FREE_VAL, 0);

// wait_for_interrupt remains a C shim -- it's per-arch inline asm
// (waiti on Xtensa, wfi on RISC-V) that doesn't fit cleanly in a D
// binding.
extern(C) void ow_irq_wait() nothrow @nogc;
