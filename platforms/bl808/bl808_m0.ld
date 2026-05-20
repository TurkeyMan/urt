/* BL808 M0 core (T-Head E907 RV32IMAFC) linker script
 *
 * Memory layout follows vendor M1s_BL808_SDK/components/platform/soc/bl808/
 *   bl808_e907_std/bl808_bsp_driver/startup/m0/bl808_flash.ld in spirit:
 * keep the vendor split: 48K system SRAM below a 96K WiFi SRAM window.
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
 *   XRAM    : 0x40000000  16K    EMI shared RAM for M0/LP/D0 IPC
 *   OCRAM   : 0x22020000  64K    @fast_data + ocram heap + stack
 *   WIFIRAM : 0x22030000  96K    vendor .wifibss + WiFi-side @fast_data tail
 *   PSRAM   : 0x50000000  1MB    .data + @bulk_data + .bss + .tdata + .tbss + slow heap
 *
 * OCRAM layout (low to high):
 *   .sram_data       @fast_data; LMA in flash, copied at boot
 *   ocram heap       small DMA-reachable heap, fills gap to stack low
 *   stack            16K, grows down to the WiFi window boundary
 *
 * WIFIRAM layout (low to high):
 *   .wifibss         vendor-selected WiFi shared/DMA state
 *   .got             GOT + small data, hot indirect-call surface
 *   .sram_data_tail  WiFi adapter @fast_data, packed into .wifibss slack
 *
 * Notes:
 *   - WIFIRAM base 0x22030000 is hardware-fixed: PHY DMA wires are routed
 *     to this exact bank. Moving the base (even within OCRAM) kills the
 *     radio. Tested 2026-05-26: same selective list at 0x22024000 = no TX.
 *   - LENGTH stays 96K. Extending to 160K (matching vendor's `ram_memory`)
 *     with *libwifi.a:*(COMMON) hangs at wifi_hw_open. Vendor's selective
 *     curation is load-bearing even though the linker rule looks "all in".
 *   - GLB_SRAM_CFG3.EM_SEL = 0xFF set by m0_bringup carves the top 64K of
 *     the WRAM bank as EM (dual-port for WiFi DSP DMA). We don't put any
 *     sections in EM; libwifi uses it for internal scratch.
 *   - DTCM cannot be reached by peripheral DMA; the allocator routes
 *     MemFlags.dma to the OCRAM pool only.
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
    XRAM   (rw)  : ORIGIN = 0x40000000, LENGTH = 16K
    OCRAM  (rwx) : ORIGIN = 0x22020000, LENGTH = 64K
    /* WIFIRAM base MUST be 0x22030000 (tested 2026-05-26: moving to 0x22024000
     * killed beacon TX -- PHY DMA is physically routed to this bank). LENGTH
     * stays 96K with codex's selective COMMON list; expanding to 160K with
     * *libwifi.a:*(COMMON) hangs at wifi_hw_open (some COMMON wakes up a
     * subsystem that needs host-side init we don't provide). */
    WIFIRAM(rwx) : ORIGIN = 0x22030000, LENGTH = 96K
    PSRAM  (rwx) : ORIGIN = 0x50000000, LENGTH = 1M
}

SECTIONS
{
    .text : ALIGN(4)
    {
        KEEP(*(.text.entry))
        . = ALIGN(4);
        *(.text .text.*)
        *(.sclock_rlt_code .sclock_rlt_code.*)
    } > FLASH

    .rodata : ALIGN(8)
    {
        *(.rodata .rodata.*)
        *(.sclock_rlt_const .sclock_rlt_const.*)

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

    .xram (NOLOAD) : ALIGN(4)
    {
        _xram_start = .;
        *(.xram .xram.*)
        . = ALIGN(4);
        _xram_end = .;
    } > XRAM

    /* Vendor WiFi shared/DMA state goes at the fixed 96K WiFi window base.
     * The reference SDK does not place every libwifi COMMON here; it places
     * only the shared rings/buffers and a few crypto/scan scratch objects.
     * Keeping this at 0x22030000 matters because the LMAC/PHY side appears
     * to treat this WRAM window specially, not merely "any address in SRAM". */
    .wifibss (NOLOAD) : ALIGN(16)
    {
        __wifi_bss_start = .;
        *(.wifi_ram*)
        *ipc_shared.o(COMMON)
        *ipc_shared.o(.bss .bss.*)
        *sdu_shared.o(COMMON)
        *sdu_shared.o(.bss .bss.*)
        *hal_desc.o(COMMON)
        *hal_desc.o(.bss .bss.*)
        *txl_buffer_shared.o(COMMON)
        *txl_buffer_shared.o(.bss .bss.*)
        *txl_frame_shared.o(COMMON)
        *txl_frame_shared.o(.bss .bss.*)
        *scan_shared.o(COMMON)
        *scan_shared.o(.bss .bss.*)
        *scanu_shared.o(COMMON)
        *scanu_shared.o(.bss .bss.*)
        *mfp_bip.o(COMMON)
        *mfp_bip.o(.bss .bss.*)
        *me_mic.o(COMMON)
        *me_mic.o(.bss .bss.*)
        *bl_sta_mgmt_others.o(COMMON)
        *bl_sta_mgmt_others.o(.bss .bss.*)
        *bl_pmk_mgmt.o(COMMON)
        *bl_pmk_mgmt.o(.bss .bss.*)
        *bl_pmk_mgmt_internal.o(COMMON)
        *bl_pmk_mgmt_internal.o(.bss .bss.*)
        *rx_swdesc.o(COMMON)
        *rx_swdesc.o(.bss .bss.*)
        *rxl_cntrl.o(COMMON)
        *rxl_cntrl.o(.bss .bss.*)
        *rxl_hwdesc.o(COMMON)
        *rxl_hwdesc.o(.bss .bss.*)
        *rxu_cntrl.o(COMMON)
        *rxu_cntrl.o(.bss .bss.*)
        *txl_buffer.o(COMMON)
        *txl_buffer.o(.bss .bss.*)
        *txl_cfm.o(COMMON)
        *txl_cfm.o(.bss .bss.*)
        *txl_cntrl.o(COMMON)
        *txl_cntrl.o(.bss .bss.*)
        *txl_frame.o(COMMON)
        *txl_frame.o(.bss .bss.*)
        *ipc_emb.o(COMMON)
        *ipc_emb.o(.bss .bss.*)
        *rc.o(COMMON)
        *rc.o(.data .data.* .bss .bss.*)
        *chan.o(COMMON)
        *chan.o(.data .data.* .bss .bss.*)
        *bam.o(COMMON)
        *bam.o(.data .data.* .bss .bss.*)
        *me.o(COMMON)
        *me.o(.data .data.* .bss .bss.*)
        *mm.o(COMMON)
        *mm.o(.data .data.* .bss .bss.*)
        *ke_env.o(COMMON)
        *ke_env.o(.data .data.* .bss .bss.*)
        *sm.o(COMMON)
        *sm.o(.data .data.* .bss .bss.*)
        *scan.o(COMMON)
        *scan.o(.data .data.* .bss .bss.*)
        *apm.o(COMMON)
        *apm.o(.data .data.* .bss .bss.*)
        *mm_timer.o(COMMON)
        *mm_timer.o(.data .data.* .bss .bss.*)

        . = ALIGN(16);
        __wifi_bss_end = .;
    } > WIFIRAM

    /* GOT + small data. LMA in flash, start.S copies at boot.
     * Every indirect call / SDA load hits this region, so keeping it out of
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

    /* WiFi-side @fast_data packed into the slack after .wifibss. */
    .sram_data_tail : ALIGN(4)
    {
        *(.sram_data.wifi .sram_data.wifi.*)
    } > WIFIRAM AT > FLASH

    _sram_data_tail_load  = LOADADDR(.sram_data_tail);
    _sram_data_tail_start = ADDR(.sram_data_tail);
    _sram_data_tail_end   = _sram_data_tail_start + SIZEOF(.sram_data_tail);

    /* @fast_data -- app-side fast data in system SRAM. */
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

    /* PSRAM heap pool: end of .tbss up to top of slice. */
    __psram_heap_start = _tbss_end;
    __psram_heap_end   = ORIGIN(PSRAM) + LENGTH(PSRAM);

    /* Stack at the top of OCRAM, immediately below WIFIRAM.
     * 4K was tried (vendor-style, DTCM-only)
     * and overflowed once the AP path reached the main loop. 16K is the
     * smallest size that's stayed safe; revisit with the high-water-mark
     * scan before shrinking. */
    _stack_top = ORIGIN(OCRAM) + LENGTH(OCRAM);
    _stack_low = _stack_top - 16K;
    __StackTop = _stack_top;

    /* OCRAM heap pool: between fast data and stack. DMA-reachable; the
     * allocator's MemFlags.dma routes here. */
    __ocram_heap_start = _sram_data_end;
    __ocram_heap_end   = _stack_low;

    ASSERT(__ocram_heap_start <= __ocram_heap_end, "OCRAM overflow: .xram + .sram_data + heap + stack don't fit in 64K")
    ASSERT(_sram_data_tail_end <= ORIGIN(WIFIRAM) + LENGTH(WIFIRAM), "WIFIRAM overflow: .wifibss + .got + .sram_data_tail don't fit in 96K")

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

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.gnu.hash)
        *(.gnu.linkonce.*)
    }
}
