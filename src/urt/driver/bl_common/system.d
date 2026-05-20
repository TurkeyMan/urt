// Bouffalo sys_init -- single canonical bring-up called from start.S after
// section init. Owns the order in which subsystems come up: exception
// unwinder, IRQ controller, TRNG, chip-specific extras, then global IRQ
// enable, then the platform tick.
//
// Driver bring-up bodies live in their owning modules (exception_init,
// irq_init, trng_init, ...) -- this file only sequences them.
module urt.driver.bl_common.system;

import urt.driver.uart;
import urt.driver.irq : irq_init, irq_global_enable;
import urt.driver.timer;
import urt.driver.bl_common.exception : exception_init;
import urt.driver.bl_common.trng;

@nogc nothrow:


version (BL808_M0)   private enum string chip_name = "BL808 M0";
else version (BL808) private enum string chip_name = "BL808 D0";
else version (BL618) private enum string chip_name = "BL618";
else static assert(false, "bl_common/system.d included on a non-Bouffalo target");


extern(C) void sys_init()
{
    exception_init();

    uart0_hw_puts(chip_name ~ ": sys_init\n");

    irq_init();

    // SEC_ENG hardware RNG. trng_init is idempotent and lazily retried on
    // first read, so a failure here only loses the eager bring-up -- mbedtls
    // entropy poll still works as long as the block is reachable.
    if (!trng_init())
        uart0_hw_puts(chip_name ~ ": TRNG init failed\n");

    chip_post_init();

    // mstatus.MIE on now that every controller is in a known state and
    // every default handler is wired (or null-and-silent). After this
    // point any irq_line_enable will actually deliver.
    irq_global_enable();

    // 50Hz tick for the diagnostic build -- if the hang is temporal at
    // the timer fire rate, halving the period should move it earlier.
    timer_set_periodic(50_000, &tick_stub);

    uart0_hw_puts(chip_name ~ ": ready\n");
}


private:

void tick_stub() @nogc nothrow
{
    // TODO: drive urt.time / Application frame tick
}

// Chip-specific bring-up that doesn't belong in the shared sequence.
// Order matters: BL808_M0 must precede BL808 because the M0 build sets both
// flags, and BL808 D0 wants XRAM-IPC rings that M0 hasn't grown yet.
void chip_post_init()
{
    version (BL808_M0)
    {
        // UART already up via m0_bringup before sys_init. Nothing else yet.
    }
    else version (BL808)
    {
        // XRAM ring buffers for IPC with M0.
        import urt.driver.bl808.ipc : ipc_init;
        ipc_init();
    }
    else version (BL618)
    {
        // Nothing chip-specific yet.
    }
}
