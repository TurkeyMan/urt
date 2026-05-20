/* BL808 M0 core (T-Head E907 RV32IMAFC) linker script
 *
 * Memory layout follows vendor M1s_BL808_SDK/components/platform/soc/bl808/
 *   bl808_e907_std/bl808_bsp_driver/startup/m0/bl808_flash.ld
 *
 * BootROM responsibilities (before M0 starts):
 *   - Configure XIP for flash @ 0x58000000
 *   - Initialise PSRAM (basic config; M0 calls bl_psram_init for full setup)
 *   - Set sp to _stack_top
 *   - Jump to _start
 *
 * Memory map (M0 view):
 *   FLASH   : 0x58000000  2MB    XIP -- .text, .rodata (matches M0 FW partition)
 *   ITCM    : 0x62028000  28KB   @critical code (.ramfunc), copied at boot
 *   DTCM    : 0x6202F000  4KB    fastest heap pool (uncached, single-cycle)
 *   HBNRAM  : 0x20010000  4KB    @persist data (.hbn_ram), survives hibernate
 *   XRAM    : 0x22020000  16KB   shared SRAM with D0 -- reserved for IPC rings
 *   OCRAM   : 0x22030000  160KB  .got + @fast_data (.sram_data) + stack + fast/DMA heap
 *   PSRAM   : 0x50000000  1MB    .data + @bulk_data + .bss + .tdata + .tbss + slow heap
 *
 * Notes:
 *   - OCRAM at 0x22030000 (not 0x22024000 -- that range is libwifi.a's
 *     private working RAM and cannot be used by the heap).
 *   - DTCM cannot be reached by peripheral DMA; the allocator routes
 *     MemFlags.dma to OCRAM only.
 *   - XRAM is declared but no sections are placed in it -- IPC code
 *     uses the _xram_start/_xram_end window directly.
 *   - HBNRAM survives deep-sleep / HBN if VBAT is maintained. NOLOAD --
 *     @persist data is not initialised at boot, that's the point.
 *   - ITCM stays empty unless the build has @critical functions; the
 *     copy loop in start.S is a no-op if .ramfunc is zero-length.
 *   - D0 uses PSRAM from 0x50100000 upward; the 1MB M0 slice (0x50000000
 *     .. 0x50100000) stays clear of that.
 */

ENTRY(_start)

EXTERN(_write _read _close _lseek _fstat _isatty _exit _kill _getpid)
EXTERN(_Dmodule_ref __errno_location stdout)

MEMORY
{
    FLASH  (rx)  : ORIGIN = 0x58000000, LENGTH = 2M
    ITCM   (rx)  : ORIGIN = 0x62028000, LENGTH = 28K
    DTCM   (rwx) : ORIGIN = 0x6202F000, LENGTH = 4K
    HBNRAM (rw)  : ORIGIN = 0x20010000, LENGTH = 4K
    XRAM   (rwx) : ORIGIN = 0x22020000, LENGTH = 16K
    OCRAM  (rwx) : ORIGIN = 0x22030000, LENGTH = 160K
    PSRAM  (rwx) : ORIGIN = 0x50000000, LENGTH = 1M
}

SECTIONS
{
    .text : ALIGN(4)
    {
        KEEP(*(.text.entry))
        . = ALIGN(4);
        *(.text .text.*)
    } > FLASH

    .rodata : ALIGN(8)
    {
        *(.rodata .rodata.*)

        /* Static WiFi cfg entry table -- the blob (libwifi.a) scans this
         * range at boot for static cfg registrations. We register none,
         * so start == end and the scan loop runs zero iterations. */
        . = ALIGN(4);
        _ld_bl_static_cfg_entry_start = .;
        KEEP(*(.wifi.cfg.entry))
        _ld_bl_static_cfg_entry_end = .;
    } > FLASH

    .eh_frame : ALIGN(8)
    {
        __eh_frame_start = .;
        KEEP(*(.eh_frame))
        KEEP(*(.eh_frame_hdr))
    } > FLASH

    .gcc_except_table : ALIGN(4)
    {
        *(.gcc_except_table .gcc_except_table.*)
    } > FLASH

    .init_array : ALIGN(4)
    {
        __init_array_start = .;
        KEEP(*(.init_array))
        __init_array_end = .;
    } > FLASH

    /* @critical -- code that must execute from internal SRAM. LMA in flash,
     * start.S copies to ITCM at boot. ISRs, flash-erase paths, low-latency
     * code paths land here. */
    .ramfunc : ALIGN(4)
    {
        *(.ramfunc .ramfunc.*)
    } > ITCM AT > FLASH

    _ramfunc_load  = LOADADDR(.ramfunc);
    _ramfunc_start = ADDR(.ramfunc);
    _ramfunc_end   = _ramfunc_start + SIZEOF(.ramfunc);

    /* GOT and small data in fast OCRAM. LMA in flash, start.S copies at boot.
     * Every indirect call/data load hits this region, so keeping it out of
     * PSRAM avoids a bus round-trip on the hot path. */
    .got : ALIGN(4)
    {
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.got .got.*)
        *(.got.plt)
        *(.sdata .sdata.*)
        *(.srodata .srodata.*)
    } > OCRAM AT > FLASH

    _got_load  = LOADADDR(.got);
    _got_start = ADDR(.got);
    _got_end   = _got_start + SIZEOF(.got);

    /* @fast_data -- frequently-accessed globals in fast OCRAM. Separate output
     * section so it has its own LMA/copy and doesn't tangle with .got's
     * gp-relative addressing. */
    .sram_data : ALIGN(4)
    {
        *(.sram_data .sram_data.*)
    } > OCRAM AT > FLASH

    _sram_data_load  = LOADADDR(.sram_data);
    _sram_data_start = ADDR(.sram_data);
    _sram_data_end   = _sram_data_start + SIZEOF(.sram_data);

    /* .data + @bulk_data both live in PSRAM with the same LMA copy
     * treatment; folding them keeps start.S simple. */
    .data : ALIGN(4)
    {
        *(.data .data.*)
        *(.psram_data .psram_data.*)
    } > PSRAM AT > FLASH

    _data_load = LOADADDR(.data);
    _data_start = ADDR(.data);
    _data_end = _data_start + SIZEOF(.data);
    __ram_load_addr = _data_load;
    __ram_data_start__ = _data_start;
    __ram_data_end__ = _data_end;

    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start__ = .;
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        _bss_end = .;
        __bss_end__ = .;
    } > PSRAM

    .tdata : ALIGN(4)
    {
        *(.tdata .tdata.*)
    } > PSRAM AT > FLASH

    _tdata_load  = LOADADDR(.tdata);
    _tdata_start = ADDR(.tdata);
    _tdata_end   = _tdata_start + SIZEOF(.tdata);

    .tbss (NOLOAD) : ALIGN(4)
    {
        _tbss_start = .;
        *(.tbss .tbss.*)
        _tbss_end = .;
    } > PSRAM

    /* @persist -- survives hibernate / deep sleep when VBAT is held up.
     * NOLOAD: not initialised at boot, prior contents are the point. */
    .hbn_ram (NOLOAD) : ALIGN(4)
    {
        *(.hbn_ram .hbn_ram.*)
    } > HBNRAM

    /* PSRAM heap pool: end of .tbss up to top of slice. Stack lives in OCRAM
     * (see below) so PSRAM is purely the slow/default heap pool. */
    __psram_heap_start = _tbss_end;
    __psram_heap_end   = ORIGIN(PSRAM) + LENGTH(PSRAM);

    /* Stack at top of OCRAM. Single-cycle SRAM keeps push/pop off PSRAM
     * for both performance and for surviving a PSRAM controller reconfig
     * (UHS upgrade) where PSRAM is briefly unreachable. _stack_low for the
     * fp walker is set to ORIGIN(OCRAM) -- permissive bound so the walker
     * accepts frames anywhere in OCRAM even if the stack temporarily grew
     * deeper than the 16K heap-end reservation (e.g. unittest call chains
     * with large transient buffers). Actual stack collision with the heap
     * is a separate concern handled by the heap allocator. */
    _stack_top = ORIGIN(OCRAM) + LENGTH(OCRAM);
    _stack_low = ORIGIN(OCRAM);
    __StackTop = _stack_top;

    /* OCRAM heap pool: end of .sram_data up to top of OCRAM minus the stack. */
    __ocram_heap_start = _sram_data_end;
    __ocram_heap_end   = ORIGIN(OCRAM) + LENGTH(OCRAM) - 16K;

    /* DTCM heap pool: full region (no sections placed here). */
    __dtcm_heap_start = ORIGIN(DTCM);
    __dtcm_heap_end   = ORIGIN(DTCM) + LENGTH(DTCM);

    /* Compatibility aliases: get_sysinfo and the (now dead) bl618 _sbrk
     * still reference __heap_start/__heap_end. Point them at the PSRAM
     * pool so heap-size reporting reflects the dominant pool. The TLSF
     * allocator owns the actual heap; _sbrk is dropped by --gc-sections
     * because malloc is satisfied by alloc.d before libc.a is consulted. */
    __heap_start = __psram_heap_start;
    __heap_end   = __psram_heap_end;

    /* XRAM reserved for D0/M0 IPC rings -- not in any heap pool. IPC code
     * places ring structures here directly via the _xram_start/_xram_end
     * window. */
    _xram_start = ORIGIN(XRAM);
    _xram_end   = ORIGIN(XRAM) + LENGTH(XRAM);

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.gnu.hash)
        *(.gnu.linkonce.*)
    }
}
