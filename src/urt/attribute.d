module urt.attribute;

version (GNU)
    public import gcc.attributes;
version (LDC)
    public import ldc.attributes;
version (DigitalMars)
{
    enum restrict;
    enum weak;
}

// The public imports above already provide the core compiler attributes:
//   @section("name")   explicit linker section placement
//   @weak              weak linkage
//   @restrict          pointer aliasing hint
//   @optStrategy(...)  optimization strategy override
//   @llvmAttr(...)     arbitrary LLVM function attribute (LDC)
//   @assumeUsed        prevent dead-stripping
//
// Aliases for commonly attributes:

version (LDC)
{
    enum noinline      = llvmAttr("noinline");
    enum always_inline = llvmAttr("alwaysinline");
    enum naked         = llvmAttr("naked");         // no prologue/epilogue
    enum cold          = llvmAttr("cold");          // optimizer: rarely executed (layout hint)
    enum hot           = llvmAttr("hot");           // optimizer: frequently executed (layout hint)
    enum used          = assumeUsed;                // prevent linker dead-stripping
}
else
{
    enum noinline;
    enum always_inline;
    enum naked;
    enum cold;
    enum hot;
    enum used;
}


// --- Memory placement -----------------------------------

// @critical - code that must execute from internal SRAM.
// Use for ISRs, code that runs during flash erase/write, and paths
// that need deterministic latency (no cache-miss jitter).
// Default (no attribute) = XIP from flash via instruction cache.
version (Espressif)     enum critical = section(".iram1");
else version (Bouffalo) enum critical = section(".ramfunc");
else version (STM32)    enum critical = section(".ramfunc");
else version (BK7231)   enum critical = section(".ramfunc");
else version (RP2350)   enum critical = section(".ramfunc");
else                    enum critical;

// @persist - data that survives deep sleep / hibernate.
// Not initialized at startup - the whole point is retaining prior values.
// Only available on platforms with RTC or hibernate-capable memory.
version (Espressif)     enum persist = section(".rtc_noinit");
else version (BL808)    enum persist = section(".hbn_ram");
else                    enum persist;

// @fast_data - data in the fastest available RAM (TCM/DTCM/SRAM).
// Use sparingly: these regions are small and shared with stack/GOT.
// Only meaningful on platforms with distinct fast/slow data regions.
version (STM32F7)       enum fast_data = section(".dtcm_data");
else version (Bouffalo) enum fast_data = section(".sram_data");
else                    enum fast_data;

// @bulk_data - large data in slow, abundant memory (PSRAM / ext RAM).
// Use for big buffers, caches, lookup tables where latency doesn't matter.
version (Espressif)     enum bulk_data = section(".ext_ram.bss");
else version (Bouffalo) enum bulk_data = section(".psram_data");
else                    enum bulk_data;
