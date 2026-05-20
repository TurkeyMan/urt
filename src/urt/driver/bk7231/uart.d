// BK7231 UART driver (shared by BK7231N and BK7231T)
//
// BK7231 has 2x UARTs:
//   UART1  0x0080_2100   Log/console (TX=GPIO11, RX=GPIO10)
//   UART2  0x0080_2200   Data/general purpose (TX=GPIO0, RX=GPIO1)
//
// Both have 128-byte TX/RX FIFOs.
//
// Register layout and init sequence verified against Beken SDK:
//   sdk/OpenBK7231N/platforms/bk7231n/bk7231n_os/beken378/driver/uart/uart.h
//   sdk/OpenBK7231N/platforms/bk7231n/bk7231n_os/beken378/driver/uart/uart_bk.c
module urt.driver.bk7231.uart;

import core.volatile;

import urt.driver.uart : FlowControl, Parity, StopBits, UartConfig;
import urt.driver.gpio : Pull, gpio_set_function;

nothrow @nogc:

enum num_uarts = 2;
enum uint uart_clock_hz = 26_000_000;
enum bool has_irq_driven_uart = false;
enum bool has_dma_driven_uart = false;


// --- Register offsets (from SDK uart.h) ------------------------------

private enum uint[2] uart_bases = [0x0080_2100, 0x0080_2200];

private enum : uint
{
    REG_CONFIG      = 0x00,  // Baud rate, data bits, parity, stop bits, TX/RX enable
    REG_FIFO_CONFIG = 0x04,  // FIFO thresholds, RX stop detect time
    REG_FIFO_STATUS = 0x08,  // FIFO counts and flags (read-only)
    REG_FIFO_PORT   = 0x0C,  // Data read/write port
    REG_INT_ENABLE  = 0x10,  // Interrupt enable
    REG_INT_STATUS  = 0x14,  // Interrupt status (write 1 to clear)
    REG_FLOW_CONFIG = 0x18,  // Flow control
    REG_WAKE_CONFIG = 0x1C,  // Wakeup configuration
}


// --- CONFIG register (0x00) ------------------------------------------

private enum : uint
{
    CFG_TX_ENABLE     = 1 << 0,
    CFG_RX_ENABLE     = 1 << 1,
    CFG_IRDA          = 1 << 2,
    CFG_DATA_LEN_POS  = 3,       // 2 bits: 0=5, 1=6, 2=7, 3=8
    CFG_DATA_LEN_MASK = 0x3 << 3,
    CFG_PARITY_EN     = 1 << 5,
    CFG_PARITY_ODD    = 1 << 6,  // 0=even, 1=odd
    CFG_STOP_LEN_2    = 1 << 7,  // 0=1 stop, 1=2 stop
    CFG_CLK_DIV_POS   = 8,       // 13-bit baud divisor
    CFG_CLK_DIV_MASK  = 0x1FFF << 8,
}


// --- FIFO_CONFIG register (0x04) -------------------------------------

private enum : uint
{
    FIFO_TX_THRESHOLD_POS  = 0,       // 8 bits
    FIFO_TX_THRESHOLD_MASK = 0xFF,
    FIFO_RX_THRESHOLD_POS  = 8,       // 8 bits
    FIFO_RX_THRESHOLD_MASK = 0xFF << 8,
    FIFO_RX_STOP_TIME_POS  = 16,      // 3 bits: 0=32, 1=64, 2=128, 3=256 clks
    FIFO_RX_STOP_TIME_MASK = 0x7 << 16,
}


// --- FIFO_STATUS register (0x08, read-only) --------------------------

private enum : uint
{
    STAT_TX_FIFO_COUNT_MASK  = 0xFF,        // bits [7:0]
    STAT_RX_FIFO_COUNT_POS   = 8,
    STAT_RX_FIFO_COUNT_MASK  = 0xFF << 8,   // bits [15:8]
    STAT_TX_FIFO_FULL        = 1 << 16,
    STAT_TX_FIFO_EMPTY       = 1 << 17,
    STAT_RX_FIFO_FULL        = 1 << 18,
    STAT_RX_FIFO_EMPTY       = 1 << 19,
    STAT_FIFO_WR_READY       = 1 << 20,
    STAT_FIFO_RD_READY       = 1 << 21,
}


// --- INT_ENABLE (0x10) / INT_STATUS (0x14) ---------------------------
// Same bit layout for both registers.

private enum : uint
{
    INT_TX_FIFO_NEED_WRITE = 1 << 0,
    INT_RX_FIFO_NEED_READ  = 1 << 1,
    INT_RX_FIFO_OVERFLOW   = 1 << 2,
    INT_RX_PARITY_ERR      = 1 << 3,
    INT_RX_STOP_ERR        = 1 << 4,
    INT_TX_STOP_END        = 1 << 5,
    INT_RX_STOP_END        = 1 << 6,
    INT_RXD_WAKEUP         = 1 << 7,

    INT_ALL_ERRORS = INT_RX_FIFO_OVERFLOW | INT_RX_PARITY_ERR | INT_RX_STOP_ERR,
}


// --- FLOW_CONFIG register (0x18) -------------------------------------

private enum : uint
{
    FLOW_LOW_CNT_POS    = 0,         // 8 bits: assert RTS below this count
    FLOW_LOW_CNT_MASK   = 0xFF,
    FLOW_HIGH_CNT_POS   = 8,         // 8 bits: de-assert RTS above this count
    FLOW_HIGH_CNT_MASK  = 0xFF << 8,
    FLOW_CTRL_EN        = 1 << 16,
    FLOW_RTS_POLARITY   = 1 << 17,
    FLOW_CTS_POLARITY   = 1 << 18,
}


// --- Hardware constants ----------------------------------------------

private enum uint FIFO_DEPTH = 128;

// SDK defaults (uart.h): TX_FIFO_THRD=0x40, RX_FIFO_THRD=0x30
private enum uint SDK_TX_FIFO_THRESHOLD = 0x40;
private enum uint SDK_RX_FIFO_THRESHOLD = 0x30;
private enum uint SDK_RX_STOP_DETECT    = 0;  // 32 clock cycles


// --- ICU registers for UART clock control ----------------------------
// From SDK icu.h: ICU_PERI_CLK_PWD = ICU_BASE + 2*4

private enum uint ICU_BASE         = 0x0080_2000;
private enum uint ICU_PERI_CLK_PWD = ICU_BASE + 2 * 4;  // 0x0080_2008

// Power-down bits (1=powered down, 0=running)
private enum uint PWD_UART1_CLK = 1 << 0;
private enum uint PWD_UART2_CLK = 1 << 1;


// UART pins are fixed by hardware; perial mode 0 is the only valid value.
private enum ubyte[2] default_tx_pins = [11, 0];   // UART1=GPIO11, UART2=GPIO0
private enum ubyte[2] default_rx_pins = [10, 1];   // UART1=GPIO10, UART2=GPIO1
private enum uint UART_PERIAL_MODE = 0;


// --- Register access helpers -----------------------------------------

private uint reg_read(uint addr)
{
    return volatileLoad(cast(uint*)(cast(size_t)addr));
}

private void reg_write(uint addr, uint val)
{
    volatileStore(cast(uint*)(cast(size_t)addr), val);
}


private bool gpio_setup_uart_pins(uint id, ref const UartConfig cfg)
{
    ubyte tx_pin = cfg.tx_gpio == ubyte.max ? default_tx_pins[id] : cfg.tx_gpio;
    ubyte rx_pin = cfg.rx_gpio == ubyte.max ? default_rx_pins[id] : cfg.rx_gpio;

    if (tx_pin != default_tx_pins[id] || rx_pin != default_rx_pins[id])
        return false;

    gpio_set_function(tx_pin, UART_PERIAL_MODE, Pull.up);
    gpio_set_function(rx_pin, UART_PERIAL_MODE, Pull.up);
    return true;
}


// --- ICU clock control -----------------------------------------------

private void icu_uart_clock_enable(uint id)
{
    // Clear power-down bit to enable clock
    uint pwd = reg_read(ICU_PERI_CLK_PWD);
    pwd &= ~((id == 0) ? PWD_UART1_CLK : PWD_UART2_CLK);
    reg_write(ICU_PERI_CLK_PWD, pwd);
}

private void icu_uart_clock_disable(uint id)
{
    uint pwd = reg_read(ICU_PERI_CLK_PWD);
    pwd |= (id == 0) ? PWD_UART1_CLK : PWD_UART2_CLK;
    reg_write(ICU_PERI_CLK_PWD, pwd);
}


// --- Public API ------------------------------------------------------

bool uart_hw_init(uint id, UartConfig cfg)
{
    if (id >= num_uarts)
        return false;

    immutable uint base = uart_bases[id];

    // Step 1: Enable peripheral clock (SDK: CMD_CLK_PWR_UP)
    icu_uart_clock_enable(id);

    // Step 2: Configure GPIO pins for UART function (SDK: CMD_GPIO_ENABLE_SECOND)
    const pins_ok = gpio_setup_uart_pins(id, cfg);
    if (!pins_ok)
        return false;

    // Step 3: Disable TX/RX during configuration
    reg_write(base + REG_CONFIG, 0);

    // Step 4: Configure FIFO thresholds and RX stop detect time
    // SDK defaults: TX_FIFO_THRD=0x40, RX_FIFO_THRD=0x30, RX_STOP_DETECT=0 (32 clks)
    reg_write(base + REG_FIFO_CONFIG,
        (SDK_TX_FIFO_THRESHOLD << FIFO_TX_THRESHOLD_POS)
      | (SDK_RX_FIFO_THRESHOLD << FIFO_RX_THRESHOLD_POS)
      | (SDK_RX_STOP_DETECT    << FIFO_RX_STOP_TIME_POS));

    // Step 5: Disable flow control (enable only if requested)
    uint flow = 0;
    if (cfg.flow_control == FlowControl.hardware)
    {
        // Assert RTS when RX FIFO < 32, de-assert when > 96
        flow = FLOW_CTRL_EN
             | (0x20 << FLOW_LOW_CNT_POS)
             | (0x60 << FLOW_HIGH_CNT_POS);
    }
    reg_write(base + REG_FLOW_CONFIG, flow);

    // Step 6: Disable wakeup
    reg_write(base + REG_WAKE_CONFIG, 0);

    // Step 7: Disable all interrupts (polled mode)
    reg_write(base + REG_INT_ENABLE, 0);

    // Step 8: Clear any pending interrupt status
    uint pending = reg_read(base + REG_INT_STATUS);
    reg_write(base + REG_INT_STATUS, pending);

    // Step 9: Build CONFIG register and enable
    // Baud divisor: clock / baud - 1 (SDK: uart_hw_init)
    uint divisor = uart_clock_hz / cfg.baud_rate - 1;

    uint config = CFG_TX_ENABLE | CFG_RX_ENABLE;

    // Data length: 5=0, 6=1, 7=2, 8=3
    config |= ((cfg.data_bits - 5) & 0x3) << CFG_DATA_LEN_POS;

    if (cfg.parity != Parity.none)
    {
        config |= CFG_PARITY_EN;
        if (cfg.parity == Parity.odd)
            config |= CFG_PARITY_ODD;
    }

    if (cfg.stop_bits == StopBits.two)
        config |= CFG_STOP_LEN_2;

    config |= (divisor & 0x1FFF) << CFG_CLK_DIV_POS;

    reg_write(base + REG_CONFIG, config);

    return true;
}

bool uart_hw_open(uint id, UartConfig cfg)
{
    return uart_hw_init(id, cfg);
}

void uart_hw_close(uint id)
{
    if (id >= num_uarts)
        return;

    immutable uint base = uart_bases[id];

    // Disable all interrupts
    reg_write(base + REG_INT_ENABLE, 0);

    // Disable TX and RX
    uint config = reg_read(base + REG_CONFIG);
    config &= ~(CFG_TX_ENABLE | CFG_RX_ENABLE);
    reg_write(base + REG_CONFIG, config);
}

ptrdiff_t uart_hw_read(uint id, void[] buffer)
{
    immutable uint base = uart_bases[id];
    auto buf = cast(ubyte[])buffer;
    ptrdiff_t n = 0;

    while (n < buf.length)
    {
        if (reg_read(base + REG_FIFO_STATUS) & STAT_RX_FIFO_EMPTY)
            break;
        buf[n] = cast(ubyte)(reg_read(base + REG_FIFO_PORT) & 0xFF);
        ++n;
    }
    return n;
}

ptrdiff_t uart_hw_write(uint id, const(void)[] data)
{
    immutable uint base = uart_bases[id];
    auto buf = cast(const(ubyte)[])data;
    ptrdiff_t n = 0;

    while (n < buf.length)
    {
        if (reg_read(base + REG_FIFO_STATUS) & STAT_TX_FIFO_FULL)
            break;
        reg_write(base + REG_FIFO_PORT, buf[n]);
        ++n;
    }
    return n;
}

void uart_hw_poll(uint id)
{
    // Polled FIFO mode: clear any accumulated error/status interrupts
    // so they don't pile up even though we're not using interrupt mode.
    immutable uint base = uart_bases[id];
    uint status = reg_read(base + REG_INT_STATUS);
    if (status)
        reg_write(base + REG_INT_STATUS, status);
}

bool uart_hw_check_errors(uint id)
{
    immutable uint base = uart_bases[id];
    uint status = reg_read(base + REG_INT_STATUS);
    uint errors = status & INT_ALL_ERRORS;

    if (errors)
    {
        // Clear the error flags by writing 1
        reg_write(base + REG_INT_STATUS, errors);
        return true;
    }
    return false;
}

ptrdiff_t uart_hw_rx_pending(uint id)
{
    uint status = reg_read(uart_bases[id] + REG_FIFO_STATUS);
    return (status & STAT_RX_FIFO_COUNT_MASK) >> STAT_RX_FIFO_COUNT_POS;
}

ptrdiff_t uart_hw_flush(uint id)
{
    immutable uint base = uart_bases[id];
    while (!(reg_read(base + REG_FIFO_STATUS) & STAT_TX_FIFO_EMPTY))
    {}
    return 0;
}

// Blocking puts for early boot (before the serial stream is up).
// Uses UART1 (the log/console UART) at 0x0080_2100.
void uart0_hw_puts(const(char)[] s)
{
    enum uint base = 0x0080_2100;
    foreach (c; s)
    {
        while (reg_read(base + REG_FIFO_STATUS) & STAT_TX_FIFO_FULL)
        {}
        reg_write(base + REG_FIFO_PORT, cast(uint)c);
    }
}
