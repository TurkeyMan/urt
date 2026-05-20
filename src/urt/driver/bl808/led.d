// M1s Dock onboard WS2812B LED (pin 8), bit-banged via GPIO.
//
// Timing is calibrated for D0 (C906) running at 480 MHz; the loop body
// (addi + bnez compressed) costs ~2 cycles, hence the loop counts below.
// Move to a portable baremetal/ws2812 driver once another SoC needs it.
module urt.driver.bl808.led;

import core.volatile : volatileStore;

@nogc nothrow:


void ws2812_send(uint pin, ubyte r, ubyte g, ubyte b)
{
    ws2812_raw_set(pin, false);
    ws2812_byte(pin, g);   // GRB order
    ws2812_byte(pin, r);
    ws2812_byte(pin, b);
    ws2812_raw_set(pin, false);
    delay_loops(WS_RESET_US * 200);
}

void led_set(ubyte r, ubyte g, ubyte b) => ws2812_send(WS2812_PIN, r, g, b);

void led_red()   { led_set(32, 0,  0);  }
void led_green() { led_set(0,  32, 0);  }
void led_blue()  { led_set(0,  0,  32); }
void led_white() { led_set(16, 16, 16); }
void led_off()   { led_set(0,  0,  0);  }


private:

// WS2812B spec: T0H=400ns, T0L=850ns, T1H=800ns, T1L=450ns (+/- 150ns).
// At 480MHz: 1 cycle ~= 2.08ns. Loop body ~= 2 cycles, so divide by 2.
enum uint WS2812_PIN   = 8;          // M1s Dock board
enum uint WS_T0H_LOOPS = 80;
enum uint WS_T0L_LOOPS = 170;
enum uint WS_T1H_LOOPS = 160;
enum uint WS_T1L_LOOPS = 90;
enum uint WS_RESET_US  = 60;         // >50us required by spec

pragma(inline, true)
void delay_loops(ulong n)
{
    import ldc.llvmasm;
    __asm!ulong(`
        1: addi $0, $0, -1
           bnez $0, 1b
    `, "=r,0", n);
}

enum uint GLB_BASE          = 0x2000_0000;
enum uint GPIO_CFG_BASE     = GLB_BASE + 0x8C4;
enum uint GPIO_FUN_SWGPIO   = 11;
enum uint GPIO_OUTPUT_EN    = 1u << 11;
enum uint GPIO_OUTPUT_HIGH  = 1u << 17;

pragma(inline, true)
void ws2812_raw_set(uint pin, bool high)
{
    // Direct cfg write -- the bit-bang is cycle-counted, so it skips the
    // read-modify-write and asserts that the public gpio_output_set/init use.
    uint cfg = GPIO_FUN_SWGPIO | GPIO_OUTPUT_EN;
    if (high)
        cfg |= GPIO_OUTPUT_HIGH;
    volatileStore(cast(uint*)(GPIO_CFG_BASE + pin * 4), cfg);
}

void ws2812_bit(uint pin, bool one)
{
    if (one)
    {
        ws2812_raw_set(pin, true);
        delay_loops(WS_T1H_LOOPS);
        ws2812_raw_set(pin, false);
        delay_loops(WS_T1L_LOOPS);
    }
    else
    {
        ws2812_raw_set(pin, true);
        delay_loops(WS_T0H_LOOPS);
        ws2812_raw_set(pin, false);
        delay_loops(WS_T0L_LOOPS);
    }
}

void ws2812_byte(uint pin, ubyte b)
{
    foreach (i; 0 .. 8)
        ws2812_bit(pin, (b & (0x80 >> i)) != 0);
}
