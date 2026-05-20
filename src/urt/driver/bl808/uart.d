// BL808 UART driver
//
// Four UART peripherals sharing the same register-level IP block (BL6xx/BL8xx):
//
//   UART0  0x2000_A000  MCU domain   M0's console (COM7 on M1s Dock)
//   UART1  0x2000_A100  MCU domain   General purpose
//   UART2  0x2000_AA00  MCU domain   Shares address with ISO11898 CAN (mutually exclusive)
//   UART3  0x3000_2000  MM domain    D0's console (COM8 on M1s Dock)
//
// M0 initializes UART0 before releasing D0. M0 initializes UART3 clock
// ("UART CLK select MM XCLK") shortly after starting D0.
//
// GPIO pin muxing is handled by M0 at boot. UART0/3 are pre-configured.
// UART1/2 require M0 cooperation or future GPIO mux support from D0.
//
// Interrupt availability from D0:
//   UART3 - PLIC IRQ 20 (IRQ_NUM_BASE + 4), interrupt-driven
//   UART0/1/2 - IRQs are in M0's PLIC domain, must be polled from D0
//
// All UARTs use software ring buffers (512 bytes RX, 512 bytes TX).
// UART3 fills/drains them via ISR. UART0/1/2 require explicit uart_poll().
module urt.driver.bl808.uart;

import core.volatile;
import urt.driver.bl808.irq;

import urt.driver.uart : Parity, StopBits, UartConfig;

nothrow @nogc:


// ==============================================================================
// Register definitions
// ==============================================================================

enum num_uarts = 4;
enum uint uart_clock_hz = 40_000_000;
enum bool has_irq_driven_uart = true;
enum bool has_dma_driven_uart = false;

private immutable uint[num_uarts] uart_base = [
    0x2000_A000, // UART0
    0x2000_A100, // UART1
    0x2000_AA00, // UART2 (shared with ISO11898 CAN)
    0x3000_2000, // UART3
];

// D0 PLIC IRQ numbers (IRQ_NUM_BASE = 16 for D0)
private enum uint UART3_PLIC_IRQ = 20; // IRQ_NUM_BASE + 4

// Register offsets
private enum : uint
{
    UTX_CONFIG      = 0x00,
    URX_CONFIG      = 0x04,
    BIT_PRD         = 0x08,
    DATA_CONFIG     = 0x0C,
    UTX_IR_POSITION = 0x10,
    URX_IR_POSITION = 0x14,
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

// UTX_CONFIG (0x00) bits
private enum : uint
{
    CR_UTX_EN          = 1 << 0,
    CR_UTX_CTS_EN      = 1 << 1,
    CR_UTX_FRM_EN      = 1 << 2,
    CR_UTX_LIN_EN      = 1 << 3,
    CR_UTX_PRT_EN      = 1 << 4,
    CR_UTX_PRT_SEL     = 1 << 5,   // 0 = even, 1 = odd
    CR_UTX_BIT_CNT_D_SHIFT = 8,    // [10:8] data bits, field value = data_bits - 1
    CR_UTX_BIT_CNT_D_MASK  = 0x7 << 8,
    CR_UTX_BIT_CNT_P_SHIFT = 11,   // [12:11] stop bits (NOT [13:12] -- bit 13 is BIT_CNT_B/break)
    CR_UTX_BIT_CNT_P_MASK  = 0x3 << 11,
}

// URX_CONFIG (0x04) bits
private enum : uint
{
    CR_URX_EN          = 1 << 0,
    CR_URX_PRT_EN      = 1 << 4,
    CR_URX_PRT_SEL     = 1 << 5,
    CR_URX_BIT_CNT_D_SHIFT = 8,
    CR_URX_BIT_CNT_D_MASK  = 0x7 << 8,
}

// FIFO_CONFIG_0 (0x80) bits
private enum : uint
{
    DMA_TX_EN           = 1 << 0,
    DMA_RX_EN           = 1 << 1,
    TX_FIFO_CLR         = 1 << 2,
    RX_FIFO_CLR         = 1 << 3,
    TX_FIFO_OVERFLOW    = 1 << 4,
    TX_FIFO_UNDERFLOW   = 1 << 5,
    RX_FIFO_OVERFLOW    = 1 << 6,
    RX_FIFO_UNDERFLOW   = 1 << 7,
}

// FIFO_CONFIG_1 (0x84) bits
private enum : uint
{
    TX_FIFO_CNT_MASK  = 0x3F,        // [5:0]  available TX slots
    RX_FIFO_CNT_SHIFT = 8,
    RX_FIFO_CNT_MASK  = 0x3F << 8,   // [13:8] available RX bytes
    TX_FIFO_TH_SHIFT  = 16,
    TX_FIFO_TH_MASK   = 0x1F << 16,  // [20:16]
    RX_FIFO_TH_SHIFT  = 24,
    RX_FIFO_TH_MASK   = 0x1F << 24,  // [28:24]
}

// INT_STS / INT_MASK / INT_CLEAR / INT_EN bit positions
private enum : uint
{
    INT_UTX_END   = 1 << 0,
    INT_URX_END   = 1 << 1,
    INT_UTX_FIFO  = 1 << 2,
    INT_URX_FIFO  = 1 << 3,
    INT_URX_RTO   = 1 << 4,
    INT_URX_PCE   = 1 << 5,
    INT_UTX_FER   = 1 << 6,
    INT_URX_FER   = 1 << 7,
    INT_MASK_ALL  = 0xFF,
}

// FIFO depth
private enum UART_FIFO_MAX = 32;

// RX FIFO threshold - interrupt fires when RX FIFO count >= this value.
// Set to 16 so we drain before the 32-byte FIFO overflows.
private enum RX_FIFO_THRESHOLD = 16;

// TX FIFO threshold - interrupt fires when TX FIFO count >= this value
// (i.e., space is available). Set low so we refill aggressively.
private enum TX_FIFO_THRESHOLD = 8;

// RX timeout - number of bit periods of silence before RX timeout interrupt.
// Catches partial frames shorter than RX_FIFO_THRESHOLD.
private enum RX_TIMEOUT_BITS = 80; // ~10 byte times at any baud rate

// UART clock frequency - M0 sets all UARTs to XCLK = 40 MHz.
// TODO: read GLB_UART_CFG0 (GLB_BASE + 0x150) to determine actual clock
// source. Bits: [2:0] = divider, [4] = clock enable, [7] = clk_sel,
// [22] = clk_sel2. The 2-bit selector chooses between MCU PBCLK (0),
// 160 MHz PLL mux (1), or XCLK (2). Actual uart_clk = source / (div + 1).
private enum uint UART_CLK_HZ = 40_000_000;


// Software ring buffer - reuse urt.mem.ring with fixed 512-byte capacity.
import urt.mem.ring : RingBuffer;
private alias Ring = RingBuffer!512;


// ==============================================================================
// Driver API
// ==============================================================================

// Per-UART state
private __gshared Ring[num_uarts] rx_ring;
private __gshared Ring[num_uarts] tx_ring;
private __gshared bool[num_uarts] uart_open_flag;
private __gshared IrqHandler prev_irq_handler;
private __gshared bool irq_handler_installed;

// Open a UART: configure baud rate, frame format, clear FIFOs, enable TX+RX.
// UART3 gets interrupt-driven I/O. UART0/1/2 require uart_poll().
// Returns false if id is out of range.
bool uart_hw_open(uint id, UartConfig cfg)
{
    if (id >= num_uarts)
        return false;

    immutable base = uart_base[id];

    // Disable TX and RX while reconfiguring
    auto tx_cfg = reg_read(base, UTX_CONFIG);
    auto rx_cfg = reg_read(base, URX_CONFIG);
    tx_cfg &= ~CR_UTX_EN;
    rx_cfg &= ~CR_URX_EN;
    reg_write(base, UTX_CONFIG, tx_cfg);
    reg_write(base, URX_CONFIG, rx_cfg);

    // Baud rate divisor
    immutable uint div = cast(uint)((cast(ulong)UART_CLK_HZ * 10 / cfg.baud_rate + 5) / 10);
    reg_write(base, BIT_PRD, ((div - 1) << 16) | (div - 1));

    // TX config: data bits, stop bits, parity
    tx_cfg &= ~(CR_UTX_BIT_CNT_D_MASK | CR_UTX_BIT_CNT_P_MASK | CR_UTX_PRT_EN | CR_UTX_PRT_SEL | CR_UTX_FRM_EN);
    tx_cfg |= cast(uint)(cfg.data_bits - 1) << CR_UTX_BIT_CNT_D_SHIFT;
    tx_cfg |= cast(uint)cfg.stop_bits << CR_UTX_BIT_CNT_P_SHIFT;
    tx_cfg |= CR_UTX_FRM_EN;
    if (cfg.parity != Parity.none)
    {
        tx_cfg |= CR_UTX_PRT_EN;
        if (cfg.parity == Parity.odd)
            tx_cfg |= CR_UTX_PRT_SEL;
    }

    // RX config: data bits, parity (stop bits are TX-only in hardware)
    rx_cfg &= ~(CR_URX_BIT_CNT_D_MASK | CR_URX_PRT_EN | CR_URX_PRT_SEL);
    rx_cfg |= cast(uint)(cfg.data_bits - 1) << CR_URX_BIT_CNT_D_SHIFT;
    if (cfg.parity != Parity.none)
    {
        rx_cfg |= CR_URX_PRT_EN;
        if (cfg.parity == Parity.odd)
            rx_cfg |= CR_URX_PRT_SEL;
    }

    // Clear software ring buffers
    rx_ring[id].purge();
    tx_ring[id].purge();

    // Mask all interrupts initially
    reg_write(base, INT_MASK, INT_MASK_ALL);

    // Clear FIFOs
    auto fifo0 = reg_read(base, FIFO_CONFIG_0);
    reg_write(base, FIFO_CONFIG_0, fifo0 | TX_FIFO_CLR | RX_FIFO_CLR);

    // Set FIFO thresholds
    auto fifo1 = reg_read(base, FIFO_CONFIG_1);
    fifo1 &= ~(TX_FIFO_TH_MASK | RX_FIFO_TH_MASK);
    fifo1 |= TX_FIFO_THRESHOLD << TX_FIFO_TH_SHIFT;
    fifo1 |= RX_FIFO_THRESHOLD << RX_FIFO_TH_SHIFT;
    reg_write(base, FIFO_CONFIG_1, fifo1);

    // Set RX timeout
    reg_write(base, URX_RTO_TIMER, RX_TIMEOUT_BITS);

    // Enable TX + RX
    tx_cfg |= CR_UTX_EN;
    rx_cfg |= CR_URX_EN;
    reg_write(base, UTX_CONFIG, tx_cfg);
    reg_write(base, URX_CONFIG, rx_cfg);

    uart_open_flag[id] = true;

    // UART3: set up interrupt-driven I/O
    if (id == 3)
    {
        // Install our IRQ handler (chain with previous)
        if (!irq_handler_installed)
        {
            prev_irq_handler = irq_set_handler(&uart_irq_handler);
            irq_handler_installed = true;
        }

        // Enable UART3 PLIC IRQ
        enable_irq(UART3_PLIC_IRQ);

        // Unmask RX FIFO threshold + RX timeout interrupts
        // TX FIFO interrupt is unmasked on demand when tx_ring has data
        auto mask = reg_read(base, INT_MASK);
        mask &= ~(INT_URX_FIFO | INT_URX_RTO);
        reg_write(base, INT_MASK, mask);

        // Enable interrupt generation
        reg_write(base, INT_EN, INT_URX_FIFO | INT_URX_RTO | INT_UTX_FIFO);
    }

    return true;
}

// Disable TX and RX, mask interrupts.
void uart_hw_close(uint id)
{
    assert(id < num_uarts);

    immutable base = uart_base[id];

    // Mask all interrupts
    reg_write(base, INT_MASK, INT_MASK_ALL);

    if (id == 3)
        disable_irq(UART3_PLIC_IRQ);

    auto tx_cfg = reg_read(base, UTX_CONFIG);
    auto rx_cfg = reg_read(base, URX_CONFIG);
    tx_cfg &= ~CR_UTX_EN;
    rx_cfg &= ~CR_URX_EN;
    reg_write(base, UTX_CONFIG, tx_cfg);
    reg_write(base, URX_CONFIG, rx_cfg);

    uart_open_flag[id] = false;
}

// Poll hardware FIFOs and transfer to/from ring buffers.
// Required for UART0/1/2 (no D0 interrupt). Harmless for UART3.
void uart_hw_poll(uint id)
{
    if (id >= num_uarts || !uart_open_flag[id])
        return;
    drain_rx_fifo(id);
    fill_tx_fifo(id);
}

// Non-blocking read: pull from RX ring buffer, return bytes read.
ptrdiff_t uart_hw_read(uint id, void[] buffer)
{
    if (id >= num_uarts)
        return -1;

    immutable prev = disable_interrupts();
    auto n = rx_ring[id].read(buffer);
    set_interrupts(prev);
    return cast(ptrdiff_t)n;
}

// Non-blocking write: push into TX ring buffer, kick TX if needed.
// Returns bytes accepted (may be less than data.length if ring is full).
ptrdiff_t uart_hw_write(uint id, const(void)[] data)
{
    if (id >= num_uarts)
        return -1;

    immutable prev = disable_interrupts();

    auto n = tx_ring[id].write(data);

    // Kick: fill hardware FIFO from ring
    fill_tx_fifo(id);

    // For UART3, unmask TX FIFO interrupt so ISR continues draining
    if (id == 3 && !tx_ring[id].empty)
    {
        auto mask = reg_read(uart_base[id], INT_MASK);
        mask &= ~INT_UTX_FIFO;
        reg_write(uart_base[id], INT_MASK, mask);
    }

    set_interrupts(prev);
    return cast(ptrdiff_t)n;
}

// Return number of bytes available to read from RX ring.
ptrdiff_t uart_hw_rx_pending(uint id)
{
    if (id >= num_uarts)
        return -1;

    immutable prev = disable_interrupts();
    auto p = rx_ring[id].pending;
    set_interrupts(prev);
    return cast(ptrdiff_t)p;
}

// Clear RX ring buffer and hardware FIFO. Returns bytes discarded.
ptrdiff_t uart_hw_flush(uint id)
{
    if (id >= num_uarts)
        return -1;

    immutable prev = disable_interrupts();

    immutable p = rx_ring[id].pending;
    rx_ring[id].purge();

    // Also clear hardware RX FIFO
    immutable base = uart_base[id];
    auto fifo0 = reg_read(base, FIFO_CONFIG_0);
    reg_write(base, FIFO_CONFIG_0, fifo0 | RX_FIFO_CLR);

    set_interrupts(prev);
    return cast(ptrdiff_t)p;
}

// Check and clear FIFO error flags (overflow/underflow).
// Returns true if any error was detected.
bool uart_hw_check_errors(uint id)
{
    if (id >= num_uarts)
        return true;

    immutable base = uart_base[id];
    immutable fifo0 = reg_read(base, FIFO_CONFIG_0);
    immutable errors = fifo0 & (TX_FIFO_OVERFLOW | TX_FIFO_UNDERFLOW | RX_FIFO_OVERFLOW | RX_FIFO_UNDERFLOW);

    if (errors != 0)
    {
        // Clear error flags by writing them back
        reg_write(base, FIFO_CONFIG_0, fifo0);
        return true;
    }

    return false;
}


// ==============================================================================
// Interrupt handler and FIFO transfer
// ==============================================================================

private:

// Drain hardware RX FIFO into software ring buffer.
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

// Fill hardware TX FIFO from software ring buffer.
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

// PLIC IRQ handler - services UART3 interrupts.
// Chains to previous handler for non-UART IRQs.
void uart_irq_handler(uint irq)
{
    if (irq == UART3_PLIC_IRQ)
    {
        immutable base = uart_base[3];
        immutable sts = reg_read(base, INT_STS);
        immutable mask = reg_read(base, INT_MASK);
        immutable active = sts & ~mask;

        // RX FIFO threshold or RX timeout - drain into ring
        if (active & (INT_URX_FIFO | INT_URX_RTO))
        {
            drain_rx_fifo(3);
            if (active & INT_URX_RTO)
                reg_write(base, INT_CLEAR, INT_URX_RTO);
        }

        // TX FIFO has space - refill from ring
        if (active & INT_UTX_FIFO)
        {
            fill_tx_fifo(3);
            // If ring is drained, mask TX interrupt until more data arrives
            if (tx_ring[3].empty)
            {
                auto m = reg_read(base, INT_MASK);
                m |= INT_UTX_FIFO;
                reg_write(base, INT_MASK, m);
            }
        }
    }
    else if (prev_irq_handler !is null)
        prev_irq_handler(irq);
}


// ==============================================================================
// Early-boot debug output (used before driver is initialized)
// ==============================================================================

public:

private auto u0_cfg() { return cast(uint*)cast(ulong)(uart_base[0] + FIFO_CONFIG_1); }
private auto u0_wr()  { return cast(uint*)cast(ulong)(uart_base[0] + FIFO_WDATA); }
private auto u3_cfg() { return cast(uint*)cast(ulong)(uart_base[3] + FIFO_CONFIG_1); }
private auto u3_wr()  { return cast(uint*)cast(ulong)(uart_base[3] + FIFO_WDATA); }

// -- UART0 (COM7, MCU domain) ------------------------------------------------

void uart0_putc(char c)
{
    while ((volatileLoad(u0_cfg) & 0x3F) == 0) {}
    volatileStore(u0_wr, cast(uint)c);
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

void uart0_hex(ulong val)
{
    uart0_putc('0');
    uart0_putc('x');
    int start = 60;
    while (start > 0 && ((val >> start) & 0xF) == 0)
        start -= 4;
    for (int i = start; i >= 0; i -= 4)
    {
        uint nibble = cast(uint)((val >> i) & 0xF);
        uart0_putc(nibble < 10 ? cast(char)('0' + nibble) : cast(char)('a' + nibble - 10));
    }
}

// -- UART3 (COM8, MM domain - D0's console) ----------------------------------

void uart3_putc(char c)
{
    while ((volatileLoad(u3_cfg) & 0x3F) == 0) {}
    volatileStore(u3_wr, cast(uint)c);
}

void uart3_puts(const(char)[] s)
{
    foreach (c; s)
    {
        if (c == '\n')
            uart3_putc('\r');
        uart3_putc(c);
    }
}

void uart3_print(const(char)* s)
{
    while (*s != 0)
    {
        if (*s == '\n')
            uart3_putc('\r');
        uart3_putc(*s);
        ++s;
    }
}

void uart3_hex(ulong val)
{
    uart3_putc('0');
    uart3_putc('x');
    int start = 60;
    while (start > 0 && ((val >> start) & 0xF) == 0)
        start -= 4;
    for (int i = start; i >= 0; i -= 4)
    {
        uint nibble = cast(uint)((val >> i) & 0xF);
        uart3_putc(nibble < 10 ? cast(char)('0' + nibble) : cast(char)('a' + nibble - 10));
    }
}


// ==============================================================================
// Register access helpers
// ==============================================================================

private:

uint reg_read(uint base, uint offset)
{
    return volatileLoad(cast(uint*)cast(ulong)(base + offset));
}

void reg_write(uint base, uint offset, uint value)
{
    volatileStore(cast(uint*)cast(ulong)(base + offset), value);
}
