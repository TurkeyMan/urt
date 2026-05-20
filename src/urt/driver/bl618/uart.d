// BL618 / BL808-M0 UART driver
//
// Two UART peripherals share the same register-level IP block as BL808 D0:
//
//   UART0  0x2000_A000  MCU domain   default console (COM7 via BL702 bridge)
//   UART1  0x2000_A100  MCU domain   general purpose
//
// Used by both BL618 (single-core E907) and the BL808 M0 coprocessor. Both
// chips own the same UART0/1 instances in the MCU power domain. UART2/UART3
// exist on BL808 but live in the MM domain (D0's side); not exposed here.
//
// Polled only. Interrupts on the E907 go through the CLIC, and OpenWatt's
// shared CLIC IRQ dispatch isn't wired up yet, so uart_hw_poll() must be
// called from the main loop.
//
// Early-boot path: m0_bringup() (and equivalently the BL618 start) can call
// uart0_early_init(tx_pin, rx_pin, baud) before sys_init runs, then use
// uart0_putc / uart0_puts / uart0_hex to emit progress markers from raw
// register writes. The full uart_hw_open() comes later from serial.d and
// re-applies pin config harmlessly.
module urt.driver.bl618.uart;

import core.volatile;

import urt.attribute : fast_data;
import urt.driver.uart : Parity, StopBits, UartConfig;

nothrow @nogc:


// ----------------------------------------------------------------------------
// Register definitions
// ----------------------------------------------------------------------------

enum num_uarts = 2;
enum uint uart_clock_hz = 40_000_000;
enum bool has_irq_driven_uart = false;
enum bool has_dma_driven_uart = false;

private immutable uint[num_uarts] uart_base = [
    0x2000_A000, // UART0
    0x2000_A100, // UART1
];

private enum : uint
{
    UTX_CONFIG      = 0x00,
    URX_CONFIG      = 0x04,
    BIT_PRD         = 0x08,
    DATA_CONFIG     = 0x0C,
    URX_RTO_TIMER   = 0x18,
    SW_MODE         = 0x1C,
    INT_STS         = 0x20,
    INT_MASK        = 0x24,
    INT_CLEAR       = 0x28,
    INT_EN          = 0x2C,
    STATUS          = 0x30,
    FIFO_CONFIG_0   = 0x80,
    FIFO_CONFIG_1   = 0x84,
    FIFO_WDATA      = 0x88,
    FIFO_RDATA      = 0x8C,
}

// UTX_CONFIG (0x00)
private enum : uint
{
    CR_UTX_EN              = 1 << 0,
    CR_UTX_FRM_EN          = 1 << 2,
    CR_UTX_PRT_EN          = 1 << 4,
    CR_UTX_PRT_SEL         = 1 << 5,   // 0=even, 1=odd
    CR_UTX_BIT_CNT_D_SHIFT = 8,        // [10:8] data bits, field value = bits - 1
    CR_UTX_BIT_CNT_D_MASK  = 0x7 << 8,
    CR_UTX_BIT_CNT_P_SHIFT = 11,       // [12:11] stop bits (NOT [13:12] -- bit 13 is BIT_CNT_B/break)
    CR_UTX_BIT_CNT_P_MASK  = 0x3 << 11,
}

// URX_CONFIG (0x04)
private enum : uint
{
    CR_URX_EN              = 1 << 0,
    CR_URX_PRT_EN          = 1 << 4,
    CR_URX_PRT_SEL         = 1 << 5,
    CR_URX_BIT_CNT_D_SHIFT = 8,
    CR_URX_BIT_CNT_D_MASK  = 0x7 << 8,
}

// FIFO_CONFIG_0 (0x80)
private enum : uint
{
    TX_FIFO_CLR       = 1 << 2,
    RX_FIFO_CLR       = 1 << 3,
    TX_FIFO_OVERFLOW  = 1 << 4,
    TX_FIFO_UNDERFLOW = 1 << 5,
    RX_FIFO_OVERFLOW  = 1 << 6,
    RX_FIFO_UNDERFLOW = 1 << 7,
}

// FIFO_CONFIG_1 (0x84)
private enum : uint
{
    TX_FIFO_CNT_MASK  = 0x3F,         // [5:0]
    RX_FIFO_CNT_SHIFT = 8,
    RX_FIFO_CNT_MASK  = 0x3F << 8,    // [13:8]
    TX_FIFO_TH_SHIFT  = 16,
    TX_FIFO_TH_MASK   = 0x1F << 16,
    RX_FIFO_TH_SHIFT  = 24,
    RX_FIFO_TH_MASK   = 0x1F << 24,
}

private enum uint INT_MASK_ALL = 0xFF;

private enum uint RX_FIFO_THRESHOLD = 16;
private enum uint TX_FIFO_THRESHOLD = 8;
private enum uint RX_TIMEOUT_BITS = 80;


import urt.mem.ring : RingBuffer;
private alias Ring = RingBuffer!512;


// ----------------------------------------------------------------------------
// Driver API
// ----------------------------------------------------------------------------

@fast_data private __gshared Ring[num_uarts] rx_ring;
@fast_data private __gshared Ring[num_uarts] tx_ring;
private __gshared bool[num_uarts] uart_open_flag;

bool uart_hw_open(uint id, UartConfig cfg)
{
    if (id >= num_uarts)
        return false;

    immutable base = uart_base[id];

    auto tx_cfg = reg_read(base, UTX_CONFIG);
    auto rx_cfg = reg_read(base, URX_CONFIG);
    tx_cfg &= ~CR_UTX_EN;
    rx_cfg &= ~CR_URX_EN;
    reg_write(base, UTX_CONFIG, tx_cfg);
    reg_write(base, URX_CONFIG, rx_cfg);

    immutable uint div = cast(uint)((cast(ulong)uart_clock_hz * 10 / cfg.baud_rate + 5) / 10);
    reg_write(base, BIT_PRD, ((div - 1) << 16) | (div - 1));

    tx_cfg &= ~(CR_UTX_BIT_CNT_D_MASK | CR_UTX_BIT_CNT_P_MASK | CR_UTX_PRT_EN | CR_UTX_PRT_SEL | CR_UTX_FRM_EN);
    tx_cfg |= uint(cfg.data_bits - 1) << CR_UTX_BIT_CNT_D_SHIFT;
    tx_cfg |= uint(cfg.stop_bits) << CR_UTX_BIT_CNT_P_SHIFT;
    tx_cfg |= CR_UTX_FRM_EN;
    if (cfg.parity != Parity.none)
    {
        tx_cfg |= CR_UTX_PRT_EN;
        if (cfg.parity == Parity.odd)
            tx_cfg |= CR_UTX_PRT_SEL;
    }

    rx_cfg &= ~(CR_URX_BIT_CNT_D_MASK | CR_URX_PRT_EN | CR_URX_PRT_SEL);
    rx_cfg |= uint(cfg.data_bits - 1) << CR_URX_BIT_CNT_D_SHIFT;
    if (cfg.parity != Parity.none)
    {
        rx_cfg |= CR_URX_PRT_EN;
        if (cfg.parity == Parity.odd)
            rx_cfg |= CR_URX_PRT_SEL;
    }

    rx_ring[id].purge();
    tx_ring[id].purge();

    reg_write(base, INT_MASK, INT_MASK_ALL);

    auto fifo0 = reg_read(base, FIFO_CONFIG_0);
    reg_write(base, FIFO_CONFIG_0, fifo0 | TX_FIFO_CLR | RX_FIFO_CLR);

    auto fifo1 = reg_read(base, FIFO_CONFIG_1);
    fifo1 &= ~(TX_FIFO_TH_MASK | RX_FIFO_TH_MASK);
    fifo1 |= TX_FIFO_THRESHOLD << TX_FIFO_TH_SHIFT;
    fifo1 |= RX_FIFO_THRESHOLD << RX_FIFO_TH_SHIFT;
    reg_write(base, FIFO_CONFIG_1, fifo1);

    reg_write(base, URX_RTO_TIMER, RX_TIMEOUT_BITS);

    tx_cfg |= CR_UTX_EN;
    rx_cfg |= CR_URX_EN;
    reg_write(base, UTX_CONFIG, tx_cfg);
    reg_write(base, URX_CONFIG, rx_cfg);

    uart_open_flag[id] = true;
    return true;
}

void uart_hw_close(uint id)
{
    if (id >= num_uarts)
        return;

    immutable base = uart_base[id];
    reg_write(base, INT_MASK, INT_MASK_ALL);

    auto tx_cfg = reg_read(base, UTX_CONFIG);
    auto rx_cfg = reg_read(base, URX_CONFIG);
    tx_cfg &= ~CR_UTX_EN;
    rx_cfg &= ~CR_URX_EN;
    reg_write(base, UTX_CONFIG, tx_cfg);
    reg_write(base, URX_CONFIG, rx_cfg);

    uart_open_flag[id] = false;
}

void uart_hw_poll(uint id)
{
    if (id >= num_uarts || !uart_open_flag[id])
        return;
    drain_rx_fifo(id);
    fill_tx_fifo(id);
}

ptrdiff_t uart_hw_read(uint id, void[] buffer)
{
    if (id >= num_uarts)
        return -1;
    return cast(ptrdiff_t)rx_ring[id].read(buffer);
}

ptrdiff_t uart_hw_write(uint id, const(void)[] data)
{
    if (id >= num_uarts)
        return -1;
    auto n = tx_ring[id].write(data);
    fill_tx_fifo(id);
    return cast(ptrdiff_t)n;
}

ptrdiff_t uart_hw_rx_pending(uint id)
{
    if (id >= num_uarts)
        return -1;
    return cast(ptrdiff_t)rx_ring[id].pending;
}

ptrdiff_t uart_hw_flush(uint id)
{
    if (id >= num_uarts)
        return -1;

    immutable p = rx_ring[id].pending;
    rx_ring[id].purge();

    immutable base = uart_base[id];
    auto fifo0 = reg_read(base, FIFO_CONFIG_0);
    reg_write(base, FIFO_CONFIG_0, fifo0 | RX_FIFO_CLR);

    return cast(ptrdiff_t)p;
}

bool uart_hw_check_errors(uint id)
{
    if (id >= num_uarts)
        return true;

    immutable base = uart_base[id];
    immutable fifo0 = reg_read(base, FIFO_CONFIG_0);
    immutable errors = fifo0 & (TX_FIFO_OVERFLOW | TX_FIFO_UNDERFLOW | RX_FIFO_OVERFLOW | RX_FIFO_UNDERFLOW);

    if (errors != 0)
    {
        reg_write(base, FIFO_CONFIG_0, fifo0);
        return true;
    }
    return false;
}


// ----------------------------------------------------------------------------
// FIFO transfer
// ----------------------------------------------------------------------------

private:

void drain_rx_fifo(uint id)
{
    immutable base = uart_base[id];
    ubyte[1] b = void;

    while (rx_ring[id].available > 0)
    {
        immutable avail = (reg_read(base, FIFO_CONFIG_1) & RX_FIFO_CNT_MASK) >> RX_FIFO_CNT_SHIFT;
        if (avail == 0)
            break;
        b[0] = cast(ubyte)reg_read(base, FIFO_RDATA);
        rx_ring[id].write(b);
    }
}

void fill_tx_fifo(uint id)
{
    immutable base = uart_base[id];
    ubyte[1] b = void;

    while (!tx_ring[id].empty)
    {
        immutable space = reg_read(base, FIFO_CONFIG_1) & TX_FIFO_CNT_MASK;
        if (space == 0)
            break;
        tx_ring[id].read(b);
        reg_write(base, FIFO_WDATA, cast(uint)b[0]);
    }
}


// ----------------------------------------------------------------------------
// Early-boot pin/signal/UART setup
// ----------------------------------------------------------------------------
//
// Pin-to-slot mapping with UART swap groups enabled (start.d sets GPIO12-23
// and GPIO36-45 swap bits in GLB_PARM_CFG0):
//
//   GPIO 12..23 -> slot = (pin + 6) % 12
//   GPIO 36..45 -> slot = (pin + 6) % 12
//   otherwise   -> slot = pin % 12
//
// Slot 0..7 live in GLB_UART_CFG1, slot 8..11 in GLB_UART_CFG2. Each slot has
// a 4-bit field selecting which UART signal (UART0_TXD=2, UART0_RXD=3, ...)
// drives that pin.

public:

private enum uint GLB_BASE              = 0x2000_0000;
private enum uint GLB_GPIO_CFG0_OFFSET  = 0x8C4;
private enum uint GLB_UART_CFG1_OFFSET  = 0x154;
private enum uint GLB_UART_CFG2_OFFSET  = 0x158;
private enum uint HBN_GLB_ADDR          = 0x2000_F030;

// UART signal function codes (matches vendor GLB_UART_SIG_FUN_Type enum order)
enum uint UART0_TXD = 2;
enum uint UART0_RXD = 3;
enum uint UART1_TXD = 6;
enum uint UART1_RXD = 7;

// Configure GPIO pad for UART alt-function, signal-route the slot to the
// requested UART signal, then bring UART0 up at the given baud, 8N1.
// Idempotent: safe to call again from uart_hw_open() once the driver proper
// is online.
void uart0_early_init(uint tx_pin, uint rx_pin, uint baud)
{
    // HBN UART_CLK_SEL = XCLK (enum 2 -> SEL2=1 at bit 15, SEL=0 at bit 2).
    // XCLK is deterministically 40 MHz (XTAL) regardless of MCU_PBCLK state;
    // see bouffalo-m0-clock-sources-at-boot.
    uint h = mmio_read(HBN_GLB_ADDR);
    h &= ~((uint(1) << 2) | (uint(1) << 15));
    h |= uint(1) << 15;
    mmio_write(HBN_GLB_ADDR, h);

    gpio_config_uart_af(tx_pin, false);     // TX: output via AF
    gpio_config_uart_af(rx_pin, true);      // RX: input via AF
    uart_route_signal(pin_to_slot(tx_pin), UART0_TXD);
    uart_route_signal(pin_to_slot(rx_pin), UART0_RXD);
    uart0_regs_init(baud);
}

private uint pin_to_slot(uint pin)
{
    if ((pin >= 12 && pin <= 23) || (pin >= 36 && pin <= 45))
        return (pin + 6) % 12;
    return pin % 12;
}

private void gpio_config_uart_af(uint pin, bool is_input)
{
    immutable addr = GLB_BASE + GLB_GPIO_CFG0_OFFSET + (pin << 2);
    uint v = mmio_read(addr);

    // Disable output first (vendor order).
    v &= ~(uint(1) << 6);              // OE = 0
    mmio_write(addr, v);

    v = mmio_read(addr);
    if (is_input)
    {
        v |= uint(1) << 0;             // IE = 1
        v &= ~(uint(1) << 6);          // OE = 0 (AF drives)
    }
    else
    {
        v &= ~uint(1);                 // IE = 0
        v &= ~(uint(1) << 6);          // OE = 0 (AF drives)
    }

    v |= uint(1) << 4;                 // PU = 1
    v &= ~(uint(1) << 5);              // PD = 0
    v |= uint(1) << 1;                 // SMT = 1
    v = (v & ~(uint(0x3) << 2)) | (uint(1) << 2);             // DRV = 1
    v = (v & ~(uint(0x1F) << 8)) | (uint(7) << 8);            // FUNC_SEL = GPIO_FUN_UART
    v = (v & ~(uint(0x3) << 30)) | (uint(0) << 30);           // output value mode

    mmio_write(addr, v);
}

private void uart_route_signal(uint slot, uint sig_fun)
{
    uint reg_off;
    uint bit_off;
    if (slot < 8)
    {
        reg_off = GLB_UART_CFG1_OFFSET;
        bit_off = slot * 4;
    }
    else
    {
        reg_off = GLB_UART_CFG2_OFFSET;
        bit_off = (slot - 8) * 4;
    }
    immutable addr = GLB_BASE + reg_off;
    uint v = mmio_read(addr);
    v = (v & ~(uint(0xF) << bit_off)) | ((sig_fun & 0xF) << bit_off);
    mmio_write(addr, v);
}

private void uart0_regs_init(uint baud)
{
    immutable base = uart_base[0];

    // TX/RX off while reconfiguring
    reg_write(base, UTX_CONFIG, reg_read(base, UTX_CONFIG) & ~CR_UTX_EN);
    reg_write(base, URX_CONFIG, reg_read(base, URX_CONFIG) & ~CR_URX_EN);

    // Mask all IRQs
    reg_write(base, INT_MASK, INT_MASK_ALL);

    // Baud divisor: round-to-nearest on a x10 scaled fraction
    immutable uint div = cast(uint)((cast(ulong)uart_clock_hz * 10 / baud + 5) / 10);
    reg_write(base, BIT_PRD, ((div - 1) << 16) | (div - 1));

    // 8N1, framing on
    uint tx = CR_UTX_FRM_EN | (uint(7) << CR_UTX_BIT_CNT_D_SHIFT) | (uint(1) << CR_UTX_BIT_CNT_P_SHIFT);
    uint rx = uint(7) << CR_URX_BIT_CNT_D_SHIFT;
    reg_write(base, UTX_CONFIG, tx);
    reg_write(base, URX_CONFIG, rx);

    // Clear FIFOs
    reg_write(base, FIFO_CONFIG_0, reg_read(base, FIFO_CONFIG_0) | TX_FIFO_CLR | RX_FIFO_CLR);

    // FIFO thresholds
    uint f1 = reg_read(base, FIFO_CONFIG_1);
    f1 &= ~(TX_FIFO_TH_MASK | RX_FIFO_TH_MASK);
    f1 |= TX_FIFO_THRESHOLD << TX_FIFO_TH_SHIFT;
    f1 |= RX_FIFO_THRESHOLD << RX_FIFO_TH_SHIFT;
    reg_write(base, FIFO_CONFIG_1, f1);

    reg_write(base, URX_RTO_TIMER, RX_TIMEOUT_BITS);

    // Enable TX + RX
    reg_write(base, UTX_CONFIG, reg_read(base, UTX_CONFIG) | CR_UTX_EN);
    reg_write(base, URX_CONFIG, reg_read(base, URX_CONFIG) | CR_URX_EN);
}


// ----------------------------------------------------------------------------
// Early-boot blocking putc/puts: usable from start.d before sys_init
// ----------------------------------------------------------------------------

void uart0_putc(char c)
{
    immutable base = uart_base[0];
    while ((reg_read(base, FIFO_CONFIG_1) & TX_FIFO_CNT_MASK) == 0) {}
    reg_write(base, FIFO_WDATA, cast(uint)c);
}

void uart0_hw_puts(const(char)[] s)
{
    foreach (c; s)
    {
        if (c == '\n')
            uart0_putc('\r');
        uart0_putc(c);
    }
}

void uart0_print(const(char)* s)
{
    while (*s != 0)
    {
        if (*s == '\n')
            uart0_putc('\r');
        uart0_putc(*s);
        ++s;
    }
}

void uart0_hex(uint val)
{
    uart0_putc('0');
    uart0_putc('x');
    int start = 28;
    while (start > 0 && ((val >> start) & 0xF) == 0)
        start -= 4;
    for (int i = start; i >= 0; i -= 4)
    {
        uint nibble = (val >> i) & 0xF;
        uart0_putc(nibble < 10 ? cast(char)('0' + nibble) : cast(char)('a' + nibble - 10));
    }
}


// ----------------------------------------------------------------------------
// Register access helpers
// ----------------------------------------------------------------------------

private:

uint reg_read(uint base, uint offset)
{
    return volatileLoad(cast(uint*)cast(size_t)(base + offset));
}

void reg_write(uint base, uint offset, uint value)
{
    volatileStore(cast(uint*)cast(size_t)(base + offset), value);
}

uint mmio_read(uint addr)
{
    return volatileLoad(cast(uint*)cast(size_t)addr);
}

void mmio_write(uint addr, uint value)
{
    volatileStore(cast(uint*)cast(size_t)addr, value);
}
