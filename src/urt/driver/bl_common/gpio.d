// Bouffalo GPIO controller (BL618, BL808 D0, BL808 M0).
//
// Same register layout across all three; only the pin count differs.
//
// GPIO_CFG register at GLB_BASE + 0x8C4 + pin*4:
//   bits[4:0] = function (11 = SWGPIO)
//   bit[6]    = input enable
//   bit[11]   = output enable
//   bit[17]   = output value
//   bit[18]   = input value (read-only)
//   bit[24]   = pull-up enable
//   bit[25]   = pull-down enable
module urt.driver.bl_common.gpio;

import core.volatile : volatileLoad, volatileStore;

import urt.driver.gpio : Pull, DriveMode;

@nogc nothrow:


version (BL808_M0)    enum uint num_gpio = 35;  // shares the BL618 peripheral set
else version (BL618)  enum uint num_gpio = 35;
else version (BL808)  enum uint num_gpio = 47;  // D0 sees all 47 pads
else static assert(false, "bl_common/gpio.d included on a non-Bouffalo target");

enum bool has_pull_up = true;
enum bool has_pull_down = true;
enum bool has_open_drain = false;
enum bool has_pin_function_muxing = true;


uint gpio_count() => num_gpio;


void gpio_output_init(uint pin, bool initial = false, DriveMode mode = DriveMode.push_pull)
{
    assert(pin < num_gpio, "bouffalo gpio: pin out of range");
    assert(mode == DriveMode.push_pull, "bouffalo gpio: open-drain not supported");
    uint cfg = GPIO_FUN_SWGPIO | GPIO_OUTPUT_EN;
    if (initial)
        cfg |= GPIO_OUTPUT_HIGH;
    gpio_cfg_write(pin, cfg);
}

void gpio_input_init(uint pin, Pull pull = Pull.none)
{
    assert(pin < num_gpio, "bouffalo gpio: pin out of range");
    gpio_cfg_write(pin, GPIO_FUN_SWGPIO | GPIO_INPUT_EN | (uint(pull) << 24));
}

void gpio_output_set(uint pin, bool value)
{
    assert(pin < num_gpio, "bouffalo gpio: pin out of range");
    uint cfg = gpio_cfg_read(pin) & ~GPIO_OUTPUT_HIGH;
    if (value)
        cfg |= GPIO_OUTPUT_HIGH;
    gpio_cfg_write(pin, cfg);
}

void gpio_output_toggle(uint pin)
{
    assert(pin < num_gpio, "bouffalo gpio: pin out of range");
    gpio_cfg_write(pin, gpio_cfg_read(pin) ^ GPIO_OUTPUT_HIGH);
}

bool gpio_input_read(uint pin)
{
    assert(pin < num_gpio, "bouffalo gpio: pin out of range");
    return (gpio_cfg_read(pin) & GPIO_INPUT_VALUE) != 0;
}

void gpio_set_pull(uint pin, Pull pull)
{
    assert(pin < num_gpio, "bouffalo gpio: pin out of range");
    uint cfg = gpio_cfg_read(pin) & ~(GPIO_PULL_UP | GPIO_PULL_DOWN);
    gpio_cfg_write(pin, cfg | (uint(pull) << 24));
}

void gpio_release(uint pin)
{
    assert(pin < num_gpio, "bouffalo gpio: pin out of range");
    gpio_cfg_write(pin, GPIO_FUN_SWGPIO);
}

void gpio_set_function(uint pin, uint function_id, Pull pull = Pull.none, DriveMode mode = DriveMode.push_pull)
{
    assert(pin < num_gpio, "bouffalo gpio: pin out of range");
    assert(function_id <= GPIO_FUN_MASK, "bouffalo gpio: function_id out of range (5-bit field)");
    assert(mode == DriveMode.push_pull, "bouffalo gpio: open-drain not supported");
    uint cfg = (function_id & GPIO_FUN_MASK) | GPIO_INPUT_EN | (uint(pull) << 24);
    gpio_cfg_write(pin, cfg);
}


private:

enum uint GLB_BASE      = 0x2000_0000;
enum uint GPIO_CFG_BASE = GLB_BASE + 0x8C4;

enum uint GPIO_FUN_SWGPIO   = 11;
enum uint GPIO_FUN_MASK     = 0x1Fu;
enum uint GPIO_INPUT_EN     = 1u << 6;
enum uint GPIO_OUTPUT_EN    = 1u << 11;
enum uint GPIO_OUTPUT_HIGH  = 1u << 17;
enum uint GPIO_INPUT_VALUE  = 1u << 18;
enum uint GPIO_PULL_UP      = 1u << 24;
enum uint GPIO_PULL_DOWN    = 1u << 25;

// Pull values map directly to GPIO_CFG bits[25:24]: none=0, up=bit24, down=bit25.
static assert(Pull.none == 0 && Pull.up == 1 && Pull.down == 2);

pragma(inline, true)
uint gpio_cfg_read(uint pin)
{
    return volatileLoad(cast(uint*)(GPIO_CFG_BASE + pin * 4));
}

pragma(inline, true)
void gpio_cfg_write(uint pin, uint value)
{
    volatileStore(cast(uint*)(GPIO_CFG_BASE + pin * 4), value);
}
