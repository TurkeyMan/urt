/* BL808 M0 (T-Head E907 RV32IMAFC) startup
 *
 * System init core -- runs first out of reset on the M0 side of
 * the BL808 dual-core SoC.  Hands off to m0_bringup (D-side, start.d)
 * before sys_init so HBN/PDS/clock/PLL setup and any D0/LP handshake
 * happens before D module ctors run.
 *
 * Boot flow:
 *   1. CPU setup    -- disable IRQ, enable extensions, FPU, trap vectors, mtvt
 *   2. Retention    -- clear HBN/PDS sleep-state bits from prior wake
 *   3. Core regs    -- gp, tp, sp
 *   4. Section init -- .got, .tdata, .tbss, .bss, .data
 *   5. Caches       -- I-cache enable
 *   6. Interrupts   -- dispatch table, enable MIE+MEIE
 *   7. D runtime    -- m0_bringup, sys_init, .init_array, main
 *
 * T-Head custom CSR numbers:
 *   mxstatus = 0x7C0   (T-Head ISA extension enable)
 *   mhcr     = 0x7C1   (hardware cache control)
 *   mhint    = 0x7C5   (performance hints)
 *   mtvt     = 0x307   (CLIC vector table base -- standard RISC-V CLIC
 *                       spec, NOT a T-Head custom CSR. Confirmed against
 *                       vendor's riscv_encoding.h. Writing the wrong CSR
 *                       leaves mtvt=0 and every IRQ vectors via address 0,
 *                       hanging the chip silently.)
 */
#define CSR_MXSTATUS 0x7C0
#define CSR_MHCR     0x7C1
#define CSR_MHINT    0x7C5
#define CSR_MTVT     0x307

/* Early-boot UART setup. Bouffalo Boot2 is mute (doesn't print, doesn't
 * leave UART0 set up). The init block below uses pure MMIO writes -- no stack,
 * no .got, no .bss needed -- so m0_bringup can emit the first readable line.
 *
 * M1s Dock: UART0 -> BL702 USB-CDC bridge on GPIO22 (TX) / GPIO21 (RX).
 * 2 Mbaud from MCU PBCLK = XTAL = 40 MHz at cold-boot (no PLL yet).
 * BL702 fakes the baud so divisor precision is cosmetic.
 *
 * UART0 base 0x2000_A000, FIFO_WDATA offset 0x88 -> 0x2000_A088. */
#define UART0_FIFO_WDATA 0x2000A088

    .section .text.entry, "ax"
    .global _start
    .type   _start, @function
    .align 2

_start:
    /* -- 0. UART0 setup so markers transmit ---------------------- */
    /* Discovered via config matrix: at M0 cold-boot, MCU_PBCLK is at some
     * unknown PLL-derived frequency (Boot2 left it that way). XCLK however
     * is deterministically 40 MHz from XTAL, and the 160 MHz PLL is up. We
     * pick XCLK because the divisor math is simple (40 MHz / 20 = 2 Mbaud)
     * and the clock won't shift if downstream code touches the PLL. */

    /* HBN_GLB (0x2000_F030): select UART_CLK = XCLK (enum 2 -> SEL2=1, SEL=0).
     * 2-bit selector split across bit 15 (SEL2 = hi) and bit 2 (SEL = lo). */
    li      t0, 0x2000F030
    lw      t1, 0(t0)
    li      t2, 0xFFFF7FFB          /* ~((1<<2)|(1<<15)) -- clear both selector bits */
    and     t1, t1, t2
    li      t2, (1 << 15)           /* SEL2 = 1 */
    or      t1, t1, t2
    sw      t1, 0(t0)

    /* GLB_UART_CFG0 (0x2000_0150): enable UART peripheral clock, div = 0 */
    li      t0, 0x20000150
    lw      t1, 0(t0)
    li      t2, 0xFFFFFFF8          /* clear DIV bits 0-2 */
    and     t1, t1, t2
    ori     t1, t1, (1 << 4)        /* CLK_EN */
    sw      t1, 0(t0)

    /* GLB_PARM_CFG0 (0x2000_0510): UART swap groups bit 3 + bit 5 */
    li      t0, 0x20000510
    lw      t1, 0(t0)
    ori     t1, t1, (1 << 3) | (1 << 5)
    sw      t1, 0(t0)

    /* GPIO14 (TX) cfg @ 0x2000_08FC and GPIO15 (RX) cfg @ 0x2000_0900:
     *   IE=1, SMT=1, DRV=1, PU=1, OE=0, FUNC_SEL=7 (UART) -> 0x717 */
    li      t1, 0x00000717
    li      t0, 0x200008FC
    sw      t1, 0(t0)
    li      t0, 0x20000900
    sw      t1, 0(t0)

    /* GLB_UART_CFG2 (0x2000_0158): slot 8 <- UART0_TXD(2), slot 9 <- UART0_RXD(3) */
    li      t0, 0x20000158
    lw      t1, 0(t0)
    li      t2, 0xFFFFFF00
    and     t1, t1, t2
    li      t2, (2 << 0) | (3 << 4)
    or      t1, t1, t2
    sw      t1, 0(t0)

    /* UART0 BIT_PRD (0x2000_A008): 40 MHz / 2 Mbaud = 20. ((20-1)<<16)|(20-1) */
    li      t0, 0x2000A008
    li      t1, 0x00130013
    sw      t1, 0(t0)

    /* UART0 UTX_CONFIG (0x2000_A000):
     *   bit 0     UTX_EN
     *   bit 2     UTX_FRM_EN
     *   bits 10:8 = 7 (data bits field = data_bits - 1 -> 8 data bits)
     *   bits 12:11 = 1 (stop bits)
     * Total: 0xF05.  NB the field encodings: BIT_CNT_D = bits-1, BIT_CNT_P at
     * [12:11] (not [13:12] like the D0 driver has wrong). */
    li      t0, 0x2000A000
    li      t1, 0x00000F05
    sw      t1, 0(t0)

    /* -- 1. CPU setup ---------------------------------------------- */

    /* Disable interrupts */
    csrc    mstatus, 0x0008     /* MIE */

    /* Enable T-Head ISA extensions (THEADISAEE + MM) */
    li      t0, (1 << 22) | (1 << 15)
    csrs    CSR_MXSTATUS, t0

    /* Enable FPU (FS = Initial) -- E907 has single-precision FPU */
    li      t0, (1 << 13)
    csrs    mstatus, t0

    /* HBN/PDS retention bit clear -- wipe any sleep state left from prior HBN cycle */
    li      t0, 0x2000F034
    lw      t1, 0(t0)
    li      t2, 0xFFFFFF3F
    and     t1, t1, t2
    sw      t1, 0(t0)

    li      t0, 0x2000E020
    lw      t1, 0(t0)
    li      t2, 0x3FFFFF00
    and     t1, t1, t2
    sw      t1, 0(t0)

    li      t0, 0x2000E028
    lw      t1, 0(t0)
    li      t2, 0xFFF00000
    and     t1, t1, t2
    sw      t1, 0(t0)

    /* mtvec in CLIC mode (bits[1:0]=11). base = sync-trap handler only;
     * IRQs are dispatched via mtvt[id] entries, never through mtvec.base. */
    la      t0, _trap_exception
    ori     t0, t0, 3
    csrw    mtvec, t0

    /* CLIC vector table base -- flat .word table of handler addresses.
     * Every entry points at _clic_dispatch (ipush/ipop trampoline). */
    la      t0, __clic_vectors
    csrw    CSR_MTVT, t0

    /* -- 2. Core registers ----------------------------------------- */

    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      tp, _tdata_start
    la      sp, _stack_top

    /* -- 3. Section init ------------------------------------------- */

    /* Copy .ramfunc from flash (LMA) to ITCM (VMA) -- @critical functions.
     * Empty when the build has no @critical code; loop is then a no-op. */
    la      a0, _ramfunc_start
    la      a1, _ramfunc_load
    la      a2, _ramfunc_end
    bgeu    a0, a2, .Lramfunc_done
.Lramfunc_copy:
    lw      t0, 0(a1)
    sw      t0, 0(a0)
    addi    a0, a0, 4
    addi    a1, a1, 4
    bltu    a0, a2, .Lramfunc_copy
.Lramfunc_done:

    /* Copy .got from flash (LMA) to OCRAM (VMA) */
    la      a0, _got_start
    la      a1, _got_load
    la      a2, _got_end
    bgeu    a0, a2, .Lgot_done
.Lgot_copy:
    lw      t0, 0(a1)
    sw      t0, 0(a0)
    addi    a0, a0, 4
    addi    a1, a1, 4
    bltu    a0, a2, .Lgot_copy
.Lgot_done:

    /* Copy .sram_data_tail from flash (LMA) to WIFIRAM (VMA) -- WiFi-side
     * @fast_data packed into the slack after the vendor .wifibss window. */
    la      a0, _sram_data_tail_start
    la      a1, _sram_data_tail_load
    la      a2, _sram_data_tail_end
    bgeu    a0, a2, .Lsram_data_tail_done
.Lsram_data_tail_copy:
    lw      t0, 0(a1)
    sw      t0, 0(a0)
    addi    a0, a0, 4
    addi    a1, a1, 4
    bltu    a0, a2, .Lsram_data_tail_copy
.Lsram_data_tail_done:

    /* Copy .sram_data from flash (LMA) to OCRAM (VMA) -- @fast_data globals.
     * Empty when no @fast_data is in use; loop is a no-op. */
    la      a0, _sram_data_start
    la      a1, _sram_data_load
    la      a2, _sram_data_end
    bgeu    a0, a2, .Lsram_data_done
.Lsram_data_copy:
    lw      t0, 0(a1)
    sw      t0, 0(a0)
    addi    a0, a0, 4
    addi    a1, a1, 4
    bltu    a0, a2, .Lsram_data_copy
.Lsram_data_done:

    /* Copy .tdata from flash to DTCM */
    la      a0, _tdata_start
    la      a1, _tdata_load
    la      a2, _tdata_end
    bgeu    a0, a2, .Ltdata_done
.Ltdata_copy:
    lw      t0, 0(a1)
    sw      t0, 0(a0)
    addi    a0, a0, 4
    addi    a1, a1, 4
    bltu    a0, a2, .Ltdata_copy
.Ltdata_done:

    /* Zero .tbss */
    la      a0, _tbss_start
    la      a2, _tbss_end
    bgeu    a0, a2, .Ltbss_done
.Ltbss_zero:
    sw      zero, 0(a0)
    addi    a0, a0, 4
    bltu    a0, a2, .Ltbss_zero
.Ltbss_done:

    /* Copy .data from flash to OCRAM */
    la      a0, _data_start
    la      a1, _data_load
    la      a2, _data_end
    bgeu    a0, a2, .Ldata_done
.Ldata_copy:
    lw      t0, 0(a1)
    sw      t0, 0(a0)
    addi    a0, a0, 4
    addi    a1, a1, 4
    bltu    a0, a2, .Ldata_copy
.Ldata_done:

    /* Zero .bss */
    la      a0, _bss_start
    la      a2, _bss_end
    bgeu    a0, a2, .Lbss_done
.Lbss_zero:
    sw      zero, 0(a0)
    addi    a0, a0, 4
    bltu    a0, a2, .Lbss_zero
.Lbss_done:

    /* Zero .wifibss -- vendor WiFi shared/LMAC state. This section is
     * NOLOAD in the linker script, but the SDK still clears it explicitly
     * during start_load before wifi_main touches COMMON state. */
    la      a0, __wifi_bss_start
    la      a2, __wifi_bss_end
    bgeu    a0, a2, .Lwifi_bss_done
.Lwifi_bss_zero:
    sw      zero, 0(a0)
    addi    a0, a0, 4
    bltu    a0, a2, .Lwifi_bss_zero
.Lwifi_bss_done:

    /* -- 4. Caches ------------------------------------------------- */

    /* D-cache and branch prediction are intentionally OFF -- we set
     * only IE (bit 0). Vendor's csi_dcache_enable writes MHCR=0x103F
     * (DE | WB | WA | RS | BPE | L0BTB), and MHINT=0x0C for D$ prefetch +
     * write-buffer auto-merge.
     *
     * Functional: chip works either way, this is purely a perf cost --
     * data loads/stores hit SRAM directly (~10x slower on OCRAM, worse on
     * PSRAM), and every conditional branch stalls the pipeline. Visible
     * once wifi/TLS are running real traffic.
     *
     * Before flipping: we MUST first configure the SYSMAP CSRs to mark
     * MMIO / DMA regions as uncacheable. Without that, enabling D-cache
     * could return stale IPC status reads or hide DMA writes. Vendor sets
     * SYSMAP via Tzc_Sec_PSRAMA_Access_Set_Not_Lock and friends before
     * csi_dcache_enable. Our start.d:d0_image_load already brackets PSRAM
     * writes with D-cache disable/enable, implying the original intent. */
    li      t0, (1 << 0)        /* IE: I-cache enable */
    csrs    CSR_MHCR, t0

    /* -- 5. Interrupts --------------------------------------------- */
    /* IRQ controller setup + mstatus.MIE enable are owned by sys_init
     * (bl_common/system.d), which calls irq_init() then irq_global_enable()
     * once every subsystem is in a known state. MIE stays off through
     * m0_bringup -- chip init is pure MMIO and doesn't need IRQs. */

    /* -- 6. D runtime ---------------------------------------------- */

    /* M0 init: HBN/PDS/clock/PLL setup, D0/LP handshake (D-side) */
    call    m0_bringup

    call    sys_init

    /* Run .init_array (D module constructors, etc.) */
    la      s0, __init_array_start
    la      s1, __init_array_end
    bgeu    s0, s1, .Linit_done
.Linit_loop:
    lw      t0, 0(s0)
    jalr    t0
    addi    s0, s0, 4
    bltu    s0, s1, .Linit_loop
.Linit_done:

    /* Enter main -- urt/package.d's extern(C) main(int argc, char** argv).
     * argc=0/argv=null so the D-side _Dmain sees an empty args slice.
     * Zero fp so stack walks terminate cleanly at main; zero ra so a return
     * from main traps (caught by _crash_handler). */
    li      a0, 0
    li      a1, 0
    li      s0, 0
    li      ra, 0
    j       main

    .size _start, . - _start

/* -- CLIC vector table -- flat .word handler addresses --------------
 *
 * Every entry points at _clic_dispatch; that trampoline reads mcause to
 * learn the IRQ id and dispatches via the runtime handler table in D
 * (urt.driver.bl618.irq). Size must match irq_max in that module. */
    .section .rodata, "a"
    .align 6
    .global __clic_vectors
__clic_vectors:
    .rept 80
    .word _clic_dispatch
    .endr

/* -- IRQ dispatch stub ----------------------------------------------
 *
 * Entered from the CLIC hardware vector via mtvt[id]. ipush pushes
 * caller-saved GPRs + mepc + mcause to the stack (T-Head custom; uses
 * mscratch as the IRQ stack pointer if non-zero). We clear MIE
 * immediately so a single ISR doesn't nest until we've earned the
 * right to. ipop pops and issues mret with hardware tail-chaining.
 * Restoring mepc/mcause from the stack (rather than relying on the
 * live CSR) is what makes nesting safe -- the bare sw/lw + mret path
 * corrupts the outer frame on nested IRQs.
 *
 * FPU save/restore: th.ipush handles ONLY integer regs. RISC-V ABI
 * marks ft0-ft11 + fa0-fa7 as caller-saved; LDC can spill into them
 * even for nominally-integer D code at -O2 (memcpy idiom, register
 * pressure). Without this stanza, a timer IRQ firing during ecdh
 * (which has scratch values live in f-regs) corrupts the interrupted
 * code and ecdh hangs forever in a now-impossible loop condition.
 * Vendor's trap_c does the same (riscv_savefpu / restorefpu around
 * the dispatched handler). RV32F = 32 single-precision f-regs * 4
 * bytes = 128 bytes; allocate room on the IRQ stack between ipush
 * and the handler call. */
    .section .text, "ax"
    .align  2
    .global _clic_dispatch
    .type   _clic_dispatch, @function
    .option push
    .option arch, +xtheadint
_clic_dispatch:
    th.ipush
    csrr    t0, mepc
    la      t1, __irq_sample_mepc
    sw      t0, 0(t1)
    csrr    t0, mcause
    la      t1, __irq_sample_mcause
    sw      t0, 0(t1)
    mv      t0, sp
    la      t1, __irq_sample_sp
    sw      t0, 0(t1)
    csrci   mstatus, 0x8
    csrr    a0, mcause
    andi    a0, a0, 0x3FF
    call    _irq_dispatch
    th.ipop
    .size   _clic_dispatch, . - _clic_dispatch
    .option pop

/* -- Exception (sync trap) -- save all regs + dump --------------- */
    .align 2
_trap_exception:
    /* Redirect mtvec to a spin so double-faults don't recurse */
    la      t0, .Lcrash_spin2
    csrw    mtvec, t0

    /* Save all 31 GP regs for the crash handler. 31*4 = 124, frame
     * rounded to 128 for 16-byte alignment. Layout matches D0:
     *   [0]=ra [1]=sp [2]=gp [3]=tp [4]=t0..[6]=t2
     *   [7]=s0/fp [8]=s1 [9]=a0..[16]=a7
     *   [17]=s2..[26]=s11 [27]=t3..[30]=t6 */
    addi    sp, sp, -128
    sw      ra,   0(sp)
    sw      sp,   4(sp)
    sw      gp,   8(sp)
    sw      tp,  12(sp)
    sw      t0,  16(sp)
    sw      t1,  20(sp)
    sw      t2,  24(sp)
    sw      s0,  28(sp)
    sw      s1,  32(sp)
    sw      a0,  36(sp)
    sw      a1,  40(sp)
    sw      a2,  44(sp)
    sw      a3,  48(sp)
    sw      a4,  52(sp)
    sw      a5,  56(sp)
    sw      a6,  60(sp)
    sw      a7,  64(sp)
    sw      s2,  68(sp)
    sw      s3,  72(sp)
    sw      s4,  76(sp)
    sw      s5,  80(sp)
    sw      s6,  84(sp)
    sw      s7,  88(sp)
    sw      s8,  92(sp)
    sw      s9,  96(sp)
    sw      s10,100(sp)
    sw      s11,104(sp)
    sw      t3, 108(sp)
    sw      t4, 112(sp)
    sw      t5, 116(sp)
    sw      t6, 120(sp)

    /* Fix saved sp to the pre-trap value */
    addi    t0, sp, 128
    sw      t0,  4(sp)

    /* a0 = regs*, a1 = mcause, a2 = mepc, a3 = mtval */
    mv      a0, sp
    csrr    a1, mcause
    csrr    a2, mepc
    csrr    a3, mtval

    call    _crash_handler

.Lcrash_spin:
    wfi
    j       .Lcrash_spin

    .align 2
.Lcrash_spin2:
    wfi
    j       .Lcrash_spin2
