// BL808 M0 chip init and D0 launch
//
// m0_bringup() runs from start.S before sys_init: chip-wide power, clocks,
// PSRAM, L2 partition, TZC, then D0 launch. D0's own start.S spins ~80ms
// waiting for M0 to finish clock setup, so launching it here (well before
// M0's main() loop comes up) is safe -- both cores run in parallel from
// that point, and M0's XRAM rings are ready by the time D0 needs IPC.
module urt.driver.bl808_m0.start;

import core.volatile;
import urt.zip : gzip_uncompress;
import urt.driver.bl618.uart : uart0_early_init, uart0_hw_puts;

@nogc nothrow:

// M1s Dock: UART0 -> BL702 USB-CDC bridge on GPIO14 (TX) / GPIO15 (RX).
// Confirmed from bl_iot_sdk/customer_app/bl808/bl808_demo_linux/main.c#L74.
private enum uint M0_CONSOLE_TX_PIN = 14;
private enum uint M0_CONSOLE_RX_PIN = 15;
private enum uint M0_CONSOLE_BAUD   = 2_000_000;

extern(C) void m0_bringup()
{
    mm_domain_power_on();
    mm_clk_config();
    mcu2ext_bus_threshold();
    uart_signal_mux();
    uart0_early_init(M0_CONSOLE_TX_PIN, M0_CONSOLE_RX_PIN, M0_CONSOLE_BAUD);
    uart0_hw_puts("\nBL808 M0: startup\n");
    wifi_em_carveout();
    psram_init();
    l2_sram_partition();
    tzc_config_for_d0();
    launch_d0();
}

private void launch_d0()
{
    d0_image_load();
    d0_mtimer_config();
    d0_halt();
    d0_set_boot_addr();
    d0_release();
}

private:

enum uint PDS_CTL2              = 0x2000_E010;
enum uint MM_CLK_CTRL_CPU       = 0x3000_7000;
enum uint MCU_MISC_MCU_BUS_CFG1 = 0x2000_9004;
enum uint GLB_PARM_CFG0         = 0x2000_0510;
enum uint MM_MISC_VRAM_CTRL     = 0x3000_0050;
enum uint TZC_MM_BMX_TZMID      = 0x2000_5300;
enum uint TZC_MM_BMX_TZMID_LOCK = 0x2000_5304;
enum uint TZC_PSRAMA_TZSRG_CTRL = 0x2000_5380;
enum uint TZC_PSRAMB_TZSRG_CTRL = 0x2000_53A0;
enum uint MM_MISC_CPU0_BOOT     = 0x3000_0000;
enum uint MM_GLB_SW_SYS_RESET   = 0x3000_7040;
enum uint MM_MISC_CPU_RTC       = 0x3000_0018;

enum uint D0_IMAGE_FLASH_ADDR   = 0x5821_0000;   // D0FW partition base (XIP-mapped)
enum uint D0_IMAGE_FLASH_SIZE   = 0x0040_0000;   // D0FW partition size
enum uint D0_PSRAM_LOAD_ADDR    = 0x5010_0000;
enum uint D0_PSRAM_LOAD_SIZE    = 0x0040_0000;   // D0 CODE region in d0 linker script

extern(C) void bl_psram_init();

pragma(inline, true) uint mmio_read(uint addr)
{
    return volatileLoad(cast(uint*)cast(size_t)addr);
}

pragma(inline, true) void mmio_write(uint addr, uint val)
{
    volatileStore(cast(uint*)cast(size_t)addr, val);
}

pragma(inline, true) void mmio_clear_bit(uint addr, uint bit)
{
    mmio_write(addr, mmio_read(addr) & ~(uint(1) << bit));
}

pragma(inline, true) void mmio_set_bit(uint addr, uint bit)
{
    mmio_write(addr, mmio_read(addr) | (uint(1) << bit));
}

pragma(inline, true) void mmio_set_field(uint addr, uint shift, uint mask, uint value)
{
    uint v = mmio_read(addr);
    v = (v & ~(mask << shift)) | ((value & mask) << shift);
    mmio_write(addr, v);
}

pragma(inline, false) extern(C) void arch_delay_us(uint us)
{
    // E907 mtime runs at 1MHz so 1 tick == 1us. The low 32 bits roll over every
    // ~71 minutes; we only ever wait microseconds, so unsigned wrap is harmless.
    uint start, now;
    asm @nogc nothrow { "rdtime %0" : "=r" (start); }
    do
    {
        asm @nogc nothrow { "rdtime %0" : "=r" (now); }
    }
    while ((now - start) < us);
}

// Carve 64KB of WRAM as WiFi MAC "Embedded Memory" (EM). Vendor's libwifi.a
// was built expecting this split when BLE is compiled in, and at least one
// community Sipeed-fork SDK confirms WiFi-AP fails silently without it --
// beacons get queued into a buffer the RF DMA never reads. EM is LMAC's
// private DMA region; the CPU never touches it, so this does not collide
// with our linker layout. Done in m0_bringup before any other init so the
// SRAM controller settles before stack-heavy code runs.
//
// GLB_SRAM_CFG3 @ GLB_BASE + 0x60C, field GLB_EM_SEL [7:0]:
//   0x00 -> 160K WRAM + 0K EM (reset default; what crashed earlier was
//           NOT this; see below)
//   0xFF -> 96K WRAM + 64K EM (vendor wifi+ble default)
//
// Previously failed when written from chip_post_init -- by that point the
// stack is live and writing the register while CPU is mid-routine appears
// to glitch SRAM. Running here from m0_bringup, with only the early start.S
// stack in DTCM aliasing, is the same place vendor calls equivalent code
// from System_Init.
void wifi_em_carveout()
{
    enum uint GLB_SRAM_CFG3 = 0x2000_060C;
    mmio_set_field(GLB_SRAM_CFG3, 0, 0xFF, 0xFF);
}

void mcu2ext_bus_threshold()
{
    // Vendor bl_sys_reduce_mcu2ext(): MCU_MISC.MCU_BUS_CFG1
    // REG_X_WTHRE_MCU2EXT = 3.
    mmio_set_field(MCU_MISC_MCU_BUS_CFG1, 7, 0x3, 3);
}

void mm_domain_power_on()
{
    // PDS_CTL2: ordered de-isolation/power-up sequence; bit 1 first, settle, then 5/17/13/9
    mmio_clear_bit(PDS_CTL2, 1);
    arch_delay_us(45);
    mmio_clear_bit(PDS_CTL2, 5);
    mmio_clear_bit(PDS_CTL2, 17);
    mmio_clear_bit(PDS_CTL2, 13);
    mmio_clear_bit(PDS_CTL2, 9);
}

void mm_clk_config()
{
    mmio_set_field(MM_CLK_CTRL_CPU, 10, 0x1, 1);   // XCLK_CLK_SEL    = XTAL
    mmio_set_field(MM_CLK_CTRL_CPU, 13, 0x3, 2);   // BCLK1X_SEL      = 160MHz PLL
    mmio_set_field(MM_CLK_CTRL_CPU, 11, 0x1, 1);   // CPU_ROOT_CLK    = PLL
    mmio_set_field(MM_CLK_CTRL_CPU,  8, 0x3, 2);   // CPU_CLK_SEL     = 400MHz PLL
    mmio_set_field(MM_CLK_CTRL_CPU,  4, 0x3, 3);   // UART_CLK_SEL    = XCLK
    mmio_set_field(MM_CLK_CTRL_CPU,  6, 0x1, 1);   // I2C_CLK_SEL     = XCLK
}

void uart_signal_mux()
{
    // UART_SWAP_SET: bit 3 = GPIO12-23 group, bit 5 = GPIO36-45 group
    mmio_set_bit(GLB_PARM_CFG0, 3);
    mmio_set_bit(GLB_PARM_CFG0, 5);
}

void psram_init()
{
    bl_psram_init();
}

void l2_sram_partition()
{
    uint v = mmio_read(MM_MISC_VRAM_CTRL);
    v |= uint(1) << 4;             // L2_SRAM_REL = 1 (64KB L2, 0KB VRAM)
    v &= ~(uint(0x3) << 1);        // PF_SRAM_REL = 0 (192KB PFH)
    v &= ~(uint(1) << 7);          // APU_SRAM_REL = 0 (128KB APU)
    v &= ~(uint(1) << 6);          // DSP2_SRAM_REL = 0 (64KB DSP2)
    mmio_write(MM_MISC_VRAM_CTRL, v);

    // commit bit must be a separate write after the partition fields settle
    mmio_set_bit(MM_MISC_VRAM_CTRL, 0);
}

void tzc_config_for_d0()
{
    mmio_set_bit(TZC_MM_BMX_TZMID, 0);
    mmio_set_bit(TZC_MM_BMX_TZMID_LOCK, 0);

    uint a = mmio_read(TZC_PSRAMA_TZSRG_CTRL);
    a = (a & ~uint(0x3)) | 0x1;    // region 0 group = 1 (D0)
    a |= uint(1) << 16;            // region 0 enable
    mmio_write(TZC_PSRAMA_TZSRG_CTRL, a);

    uint b = mmio_read(TZC_PSRAMB_TZSRG_CTRL);
    b = (b & ~uint(0x3)) | 0x1;
    b |= uint(1) << 16;
    mmio_write(TZC_PSRAMB_TZSRG_CTRL, b);
}

void d0_image_load()
{
    // T-Head MHCR (CSR 0x7C1): bit 0 = I-cache enable, bit 1 = D-cache enable.
    // Disable D-cache around PSRAM writes so D0 sees fresh memory.
    asm @nogc nothrow { "csrc 0x7C1, 0x2"; }

    // Detect gzip: id1=0x1F, id2=0x8B, method=deflate(8). Anything else is
    // treated as a raw D0 image starting at offset 0.
    const(ubyte)* flash = cast(const(ubyte)*)cast(size_t)D0_IMAGE_FLASH_ADDR;
    if (flash[0] == 0x1F && flash[1] == 0x8B && flash[2] == 0x08)
        gunzip_d0(flash);
    else
        raw_copy_d0(flash);

    asm @nogc nothrow { "csrs 0x7C1, 0x2"; }
}

void raw_copy_d0(const(ubyte)* flash)
{
    uint* src = cast(uint*)flash;
    uint* dst = cast(uint*)cast(size_t)D0_PSRAM_LOAD_ADDR;
    uint words = D0_PSRAM_LOAD_SIZE / 4;
    for (uint i = 0; i < words; ++i)
        dst[i] = src[i];
}

void gunzip_d0(const(ubyte)* flash)
{
    // gzip_uncompress tolerates an oversized source slice -- it finds its own
    // footer via uncompress's srcConsumed output. Source bound is the whole
    // D0FW partition; anything past the actual gzip stream is junk and ignored.
    const(void)[] src = flash[0 .. D0_IMAGE_FLASH_SIZE];
    void[] dst = (cast(void*)cast(size_t)D0_PSRAM_LOAD_ADDR)[0 .. D0_PSRAM_LOAD_SIZE];
    size_t out_len;
    if (gzip_uncompress(src, dst, out_len).failed)
    {
        // No UART yet (sys_init runs after m0_bringup), nowhere to report.
        // Halt -- watchdog will reset the board if enabled.
        for (;;) {}
    }
}

void d0_mtimer_config()
{
    mmio_clear_bit(MM_MISC_CPU_RTC, 31);            // disable while changing divider
    mmio_set_field(MM_MISC_CPU_RTC, 0, 0x3FF, 39);  // DIV = 39 for 10MHz from 400MHz
    mmio_set_bit(MM_MISC_CPU_RTC, 31);              // re-enable
}

void d0_halt()
{
    mmio_set_bit(MM_GLB_SW_SYS_RESET, 8);
}

void d0_set_boot_addr()
{
    mmio_write(MM_MISC_CPU0_BOOT, D0_PSRAM_LOAD_ADDR);
}

void d0_release()
{
    mmio_clear_bit(MM_GLB_SW_SYS_RESET, 8);
}
