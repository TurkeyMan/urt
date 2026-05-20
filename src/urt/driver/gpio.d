// GPIO driver. Software-GPIO primitives plus per-pin function muxing
// for SoCs that support it (BL6xx, BL8xx, BK7231, RP2350, STM32). On
// targets that route via signal matrix (ESP32) or have no pin concept
// (Windows/POSIX without sysfs), has_pin_function_muxing is false and
// gpio_set_function is not declared.
//
// Pin numbering is a flat uint per SoC. STM32 packs port and pin as
// (port * 16 + pin_in_port) so PA9 = 9, PB3 = 19, PE15 = 79. Other
// SoCs use linear pin numbers from 0.
//
// num_gpio is a compile-time upper bound (exact on SoCs with fixed
// pin counts; on hosted targets like Linux SBC it is a static cap and
// gpio_count() returns the actual runtime number).
//
// Function bodies live in <soc>/gpio.d, pulled in by the version
// dispatch below. Each backend exports:
//   uint gpio_count();
//   void gpio_output_init(uint pin, bool initial = false, DriveMode = push_pull);
//   void gpio_input_init(uint pin, Pull = none);
//   void gpio_output_set(uint pin, bool value);
//   void gpio_output_toggle(uint pin);
//   bool gpio_input_read(uint pin);
//   void gpio_set_pull(uint pin, Pull);
//   void gpio_release(uint pin);
//   void gpio_set_function(uint pin, uint function_id, Pull = none, DriveMode = push_pull);
//
// function_id is opaque per chip; peripheral drivers know the right
// value. The peripheral owns I/O direction once muxed.
module urt.driver.gpio;

version (Bouffalo)
    public import urt.driver.bl_common.gpio;
else version (Beken)
    public import urt.driver.bk7231.gpio;
else version (Espressif)
    public import urt.driver.esp32.gpio;
else version (linux)
    public import urt.driver.posix.gpio;
else
{
    enum uint num_gpio = 0;
    enum bool has_pull_up = false;
    enum bool has_pull_down = false;
    enum bool has_open_drain = false;
    enum bool has_pin_function_muxing = false;

    uint gpio_count() nothrow @nogc => 0;
}

nothrow @nogc:

enum Pull : ubyte
{
    none,
    up,
    down,
}

enum DriveMode : ubyte
{
    push_pull,
    open_drain,
}


unittest
{
    static assert(is(typeof(num_gpio) == uint));
    static assert(is(typeof(has_pull_up) == bool));
    static assert(is(typeof(has_pull_down) == bool));
    static assert(is(typeof(has_open_drain) == bool));
    static assert(is(typeof(has_pin_function_muxing) == bool));

    // Pull encoding is load-bearing: bl808/bl618 backends shift the
    // ordinal directly into GPIO_CFG bits[25:24].
    static assert(Pull.none == 0);
    static assert(Pull.up   == 1);
    static assert(Pull.down == 2);

    static assert(DriveMode.push_pull  == 0);
    static assert(DriveMode.open_drain == 1);

    // gpio_count() is callable on every backend (returns 0 on fallback).
    gpio_count();
}
