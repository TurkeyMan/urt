/* BL808 D0 core (T-Head C906 RV64GC) linker script
 *
 * M0 copies D0 firmware from Flash (0x58100000, D0FW partition) to PSRAM and
 * starts D0 executing from PSRAM at 0x50100000. This is NOT XIP -- code runs
 * from RAM.
 *
 * Memory layout (must stay in sync with D0_PSRAM_LOAD_SIZE / D0_IMAGE_FLASH_SIZE
 * in driver/bl808_m0/start.d, and with partition.toml D0FW size):
 *   PSRAM:   0x50100000, 60MB  (D0 firmware image + .data + .bss + heap, contiguous)
 *   SRAM:    0x3eff8000, 64KB  (.got + .sram_data fast globals + .tdata/.tbss + stack)
 *   HBNRAM:  0x20010000, 4KB   (survives hibernate if VBAT maintained)
 *
 * @fast_data globals land in SRAM (fast on-chip, single-cycle); everything
 * else lives in PSRAM.
 *
 * Image layout in PSRAM (file offset order, LMA-tail discipline):
 *   .text / .rodata / .eh_frame / .gcc_except_table / .init_array  (in-place)
 *   .data                                                          (in-place, VMA = LMA)
 *   .bss range                                                     (NOLOAD; objcopy zero-fills the gap)
 *   .got / .sram_data / .tdata LMAs                                (copied to SRAM at boot)
 *
 * After start.S has copied the LMA tail to SRAM, those PSRAM bytes are dead;
 * the heap starts at _bss_end and grows over them. start.S finishes all
 * section init before any allocator call, so the overlap is safe.
 */

ENTRY(_start)

/* Force-link newlib syscall stubs and D runtime symbols
 * (otherwise --gc-sections strips them before newlib resolves) */
EXTERN(_write _read _close _lseek _fstat _isatty _sbrk _exit _kill _getpid)
EXTERN(_Dmodule_ref __errno_location stdout)
EXTERN(socket close poll _accept _recv _recvfrom _sendmsg)
EXTERN(_shutdown _bind _listen _connect setsockopt getsockname getpeername)
EXTERN(getaddrinfo freeaddrinfo)

MEMORY
{
    PSRAM  (rwx) : ORIGIN = 0x50100000, LENGTH = 60M
    SRAM   (rwx) : ORIGIN = 0x3eff8000, LENGTH = 64K
    HBNRAM (rw)  : ORIGIN = 0x20010000, LENGTH = 4K
}

SECTIONS
{
    .text : ALIGN(4)
    {
        KEEP(*(.text.entry))
        . = ALIGN(4);
        *(.text.psram_early)
        *(.text .text.*)
    } > PSRAM

    .rodata : ALIGN(8)
    {
        *(.rodata .rodata.*)
    } > PSRAM

    /* DWARF exception handling -- required for D throw/catch (fibre abort, etc.). */
    .eh_frame : ALIGN(8)
    {
        __eh_frame_start = .;
        KEEP(*(.eh_frame))
        KEEP(*(.eh_frame_hdr))
    } > PSRAM

    .gcc_except_table : ALIGN(4)
    {
        *(.gcc_except_table .gcc_except_table.*)
    } > PSRAM

    /* Init array -- LDC module info registration functions. Called from start.S before main(). */
    .init_array : ALIGN(8)
    {
        __init_array_start = .;
        KEEP(*(.init_array))
        __init_array_end = .;
    } > PSRAM

    /* .data: VMA = LMA in PSRAM. M0 places initialised data via the image load,
     * so start.S's .data copy loop becomes a no-op. */
    .data : ALIGN(8)
    {
        *(.data .data.*)
    } > PSRAM

    _data_load = LOADADDR(.data);
    _data_start = ADDR(.data);
    _data_end = _data_start + SIZEOF(.data);
    __ram_load_addr = _data_load;
    __ram_data_start__ = _data_start;
    __ram_data_end__ = _data_end;

    /* .bss: VMA in PSRAM right after .data. NOLOAD -- no LMA bytes, but the
     * binary still spans this range as zeros (objcopy fills the LMA gap to
     * the next section). After start.S zeros it, the heap starts here. */
    .bss (NOLOAD) : ALIGN(8)
    {
        __bss_start__ = .;
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        _bss_end = .;
        __bss_end__ = .;
    } > PSRAM

    /* LMA tail -- SRAM-resident sections placed in PSRAM right after _bss_end.
     * start.S copies these to SRAM at boot; the heap then overwrites the
     * PSRAM bytes (safe because the copy is done before sys_init / main). */

    .got : AT(ALIGN(_bss_end, 8)) ALIGN(8)
    {
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.got .got.*)
        *(.got.plt)
        *(.sdata .sdata.*)
        *(.srodata .srodata.*)
    } > SRAM

    _got_load  = LOADADDR(.got);
    _got_start = ADDR(.got);
    _got_end   = _got_start + SIZEOF(.got);

    /* @fast_data -- frequently-accessed globals in fast on-chip SRAM. */
    .sram_data : AT(ALIGN(_got_load + SIZEOF(.got), 8)) ALIGN(8)
    {
        *(.sram_data .sram_data.*)
    } > SRAM

    _sram_data_load  = LOADADDR(.sram_data);
    _sram_data_start = ADDR(.sram_data);
    _sram_data_end   = _sram_data_start + SIZEOF(.sram_data);

    /* TLS: .tdata + .tbss must be VMA-contiguous (they form the TLS template). */
    .tdata : AT(ALIGN(_sram_data_load + SIZEOF(.sram_data), 8)) ALIGN(8)
    {
        *(.tdata .tdata.*)
    } > SRAM

    _tdata_load  = LOADADDR(.tdata);
    _tdata_start = ADDR(.tdata);
    _tdata_end   = _tdata_start + SIZEOF(.tdata);

    .tbss (NOLOAD) : ALIGN(8)
    {
        _tbss_start = .;
        *(.tbss .tbss.*)
        _tbss_end = .;
    } > SRAM

    /* HBN RAM: persistent across hibernate, not initialized by startup */
    .hbn_ram (NOLOAD) : ALIGN(4)
    {
        *(.hbn_ram)
    } > HBNRAM

    /* PSRAM heap pool (default / slow for urt.driver.bl_common.alloc).
     * Starts at _bss_end and grows to end of PSRAM. The allocator reclaims
     * the LMA-tail bytes after start.S finishes the SRAM copies. */
    __psram_heap_start = _bss_end;
    __psram_heap_end   = ORIGIN(PSRAM) + LENGTH(PSRAM);

    /* SRAM heap pool (fast / dma / fastest -- D0 has no DTCM). End of .tbss
     * up to stack reservation at top of SRAM. */
    __sram_heap_start = _tbss_end;
    __sram_heap_end   = ORIGIN(SRAM) + LENGTH(SRAM) - 16K;

    /* Stack in fast on-chip SRAM, top 16K reserved. */
    _stack_top = ORIGIN(SRAM) + LENGTH(SRAM);
    _stack_low = __sram_heap_end;
    __StackTop = _stack_top;

    /* Compatibility aliases for get_sysinfo (urt.system.d). */
    __heap_start = __psram_heap_start;
    __heap_end   = __psram_heap_end;

    /* Vendor start_load.c expects these symbols for ITCM/DTCM/system RAM
     * copy loops. We don't use those sections, so define them as empty. */
    PROVIDE(__itcm_load_addr = 0);
    PROVIDE(__tcm_code_start__ = 0);
    PROVIDE(__tcm_code_end__ = 0);
    PROVIDE(__dtcm_load_addr = 0);
    PROVIDE(__tcm_data_start__ = 0);
    PROVIDE(__tcm_data_end__ = 0);
    PROVIDE(__system_ram_load_addr = 0);
    PROVIDE(__system_ram_data_start__ = 0);
    PROVIDE(__system_ram_data_end__ = 0);

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.gnu.hash)
        *(.gnu.linkonce.*)
    }
}
