/* BL808 D0 core (T-Head C906 RV64GC) startup
 *
 * Based on Bouffalo SDK startup.S + vectors.S, consolidated into
 * a single file with no SDK header dependencies.
 *
 * Boot flow:
 *   1. CPU setup    — wait for M0, disable IRQ, extensions, FPU, trap vectors
 *   2. Core regs    — gp, tp, sp
 *   3. Memory access — TZC release, clear PLIC
 *   4. Section init — .got, .tdata, .tbss, .bss, .data
 *   5. Caches       — I-cache, D-cache, prefetch
 *   6. Interrupts   — dispatch table, enable MIE+MEIE
 *   7. D runtime    — sys_init, .init_array, main
 *
 * T-Head custom CSR numbers (not in standard riscv asm):
 *   mxstatus = 0x7C0   (T-Head ISA extension enable)
 *   mhcr     = 0x7C1   (hardware cache control)
 *   mhint    = 0x7C5   (performance hints — prefetch, AMR)
 */
#define CSR_MXSTATUS 0x7C0
#define CSR_MHCR     0x7C1
#define CSR_MHINT    0x7C5

    .section .text.entry, "ax"
    .global _start
    .type   _start, @function
    .align 2

_start:
    /* ── 1. CPU setup ─────────────────────────────────────────────── */

    /* Wait for M0 to finish clock/peripheral init.
     * M0 switches D0's CPU clock (XTAL→PLL) AFTER starting D0, which
     * glitches the pipeline if we're executing. */
    li      t0, 1000000         /* ~80ms at 24MHz, ~5ms at 400MHz */
.Lwait_m0:
    addi    t0, t0, -1
    bnez    t0, .Lwait_m0

    /* Disable interrupts */
    csrc    mstatus, 0x0008     /* MIE */
    csrc    mstatus, 0x0002     /* SIE */

    /* Enable T-Head ISA extensions (THEADISAEE + MM) */
    li      t0, (1 << 22) | (1 << 15)
    csrs    CSR_MXSTATUS, t0

    /* Enable FPU (FS = Initial) and vector unit (VS = Initial) */
    li      t0, (1 << 13) | (1 << 23)
    csrs    mstatus, t0

    /* Set trap vector table (vectored mode) */
    la      t0, __vectors
    ori     t0, t0, 1
    csrw    mtvec, t0

    /* ── 2. Core registers ────────────────────────────────────────── */

    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      tp, _tdata_start
    la      sp, _stack_top

    /* ── 3. Memory access ─────────────────────────────────────────── */

    /* TZC for D0 (CPU group + PSRAMA/B region enable) is configured by M0
     * in urt.driver.bl808_m0.start.tzc_config_for_d0() before this core is
     * released from reset.  Earlier versions cleared bit 16 of 0x20005380
     * here, which was wrong polarity (bit 16 is region-enable; clearing it
     * disables PSRAM access). */

    /* Clear PLIC interrupt enables and pending bits */
    li      t0, 0xE0002000      /* PLIC enable base */
    li      t1, 0xE0001000      /* PLIC pending base */
    li      t2, 0
    li      t3, 4               /* 4 words = 128 bits */
.Lclear_plic:
    sw      t2, 0(t0)
    sw      t2, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    addi    t3, t3, -1
    bnez    t3, .Lclear_plic

    /* ── 4. Section init ──────────────────────────────────────────── */

    /* Copy .got from flash to SRAM (must come first — gp-relative access) */
    la      t0, _got_load
    la      t1, _got_start
    la      t2, _got_end
.Lcopy_got:
    bgeu    t1, t2, .Lgot_done
    ld      t3, 0(t0)
    sd      t3, 0(t1)
    addi    t0, t0, 8
    addi    t1, t1, 8
    j       .Lcopy_got
.Lgot_done:

    /* Copy .sram_data from PSRAM (LMA) to SRAM (VMA) -- @fast_data globals.
     * Empty when no @fast_data is in use; loop is a no-op. */
    la      t0, _sram_data_load
    la      t1, _sram_data_start
    la      t2, _sram_data_end
.Lcopy_sram_data:
    bgeu    t1, t2, .Lsram_data_done
    ld      t3, 0(t0)
    sd      t3, 0(t1)
    addi    t0, t0, 8
    addi    t1, t1, 8
    j       .Lcopy_sram_data
.Lsram_data_done:

    /* Copy .tdata from flash to SRAM (TLS initialized data) */
    la      t0, _tdata_load
    la      t1, _tdata_start
    la      t2, _tdata_end
.Lcopy_tdata:
    bgeu    t1, t2, .Ltdata_done
    ld      t3, 0(t0)
    sd      t3, 0(t1)
    addi    t0, t0, 8
    addi    t1, t1, 8
    j       .Lcopy_tdata
.Ltdata_done:

    /* Zero .tbss in SRAM (TLS zero-initialized data) */
    la      t0, _tbss_start
    la      t1, _tbss_end
.Lzero_tbss:
    bgeu    t0, t1, .Ltbss_done
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       .Lzero_tbss
.Ltbss_done:

    /* Zero BSS in PSRAM */
    la      t0, _bss_start
    la      t1, _bss_end
.Lzero_bss:
    bgeu    t0, t1, .Lbss_done
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       .Lzero_bss
.Lbss_done:

    /* Copy .data from flash to PSRAM */
    la      t0, _data_load
    la      t1, _data_start
    la      t2, _data_end
.Lcopy_data:
    bgeu    t1, t2, .Ldata_done
    ld      t3, 0(t0)
    sd      t3, 0(t1)
    addi    t0, t0, 8
    addi    t1, t1, 8
    j       .Lcopy_data
.Ldata_done:

    /* ── 5. Caches ────────────────────────────────────────────────── */

    li      t0, 0x3             /* IE + DE */
    csrs    CSR_MHCR, t0
    li      t0, (1 << 2) | (1 << 8) | (1 << 12)
    csrs    CSR_MHINT, t0

    /* ── 6. Interrupts ────────────────────────────────────────────── */

    csrs    mstatus, 0x0008     /* MIE */
    li      t0, (1 << 11)       /* MEIE */
    csrs    mie, t0

    /* ── 7. D runtime ─────────────────────────────────────────────── */

    call    sys_init

    /* .init_array — LDC module info registration */
    la      t0, __init_array_start
    la      t1, __init_array_end
.Linit_array_loop:
    bgeu    t0, t1, .Linit_array_done
    ld      t2, 0(t0)
    jalr    ra, t2
    addi    t0, t0, 8
    j       .Linit_array_loop
.Linit_array_done:

    /* Enter main -- urt/package.d's extern(C) main(int argc, char** argv).
     * argc=0/argv=null so the D-side _Dmain sees an empty args slice.
     * Zero fp so backtraces terminate cleanly at main; zero ra so a return
     * from main traps (caught by _crash_handler). */
    li      a0, 0
    li      a1, 0
    li      s0, 0
    li      ra, 0
    j       main


/* ================================================================
 * Machine-mode trap vector table (vectored mode)
 *
 * mtvec[1:0] = 01 means: on interrupt with cause N, jump to
 * mtvec_base + N * 4. Each entry is a single jump instruction.
 * ================================================================ */

    .section .text, "ax"
    .align  6
    .global __vectors
    .type   __vectors, @object
__vectors:
    .option push
    .option norvc
    j   _trap_exception         /*  0: exception (sync trap) */
    j   _trap_default           /*  1: S-mode software interrupt */
    j   _trap_default           /*  2: reserved */
    j   _trap_msoft             /*  3: M-mode software interrupt */
    j   _trap_default           /*  4: reserved */
    j   _trap_default           /*  5: S-mode timer */
    j   _trap_default           /*  6: reserved */
    j   _trap_mtimer            /*  7: M-mode timer */
    j   _trap_default           /*  8: reserved */
    j   _trap_default           /*  9: S-mode external */
    j   _trap_default           /* 10: reserved */
    j   _trap_mext              /* 11: M-mode external interrupt */
    .option pop


/* ================================================================
 * Trap handlers
 * ================================================================ */

    .align 2
_trap_default:
    j   _trap_default

    .align 2
_trap_msoft:
    mret

/*
 * ISR save/restore macros.
 *
 * Integer caller-saved: ra, t0-t6, a0-a7 (16 regs × 8 = 128 bytes)
 * FP caller-saved: ft0-ft11, fa0-fa7 (20 regs × 8 = 160 bytes)
 * Total frame: 288 bytes
 */

.macro  ISR_SAVE
    addi    sp, sp, -288
    sd      ra,   0(sp)
    sd      t0,   8(sp)
    sd      t1,  16(sp)
    sd      t2,  24(sp)
    sd      t3,  32(sp)
    sd      t4,  40(sp)
    sd      t5,  48(sp)
    sd      t6,  56(sp)
    sd      a0,  64(sp)
    sd      a1,  72(sp)
    sd      a2,  80(sp)
    sd      a3,  88(sp)
    sd      a4,  96(sp)
    sd      a5, 104(sp)
    sd      a6, 112(sp)
    sd      a7, 120(sp)
    fsd     ft0,  128(sp)
    fsd     ft1,  136(sp)
    fsd     ft2,  144(sp)
    fsd     ft3,  152(sp)
    fsd     ft4,  160(sp)
    fsd     ft5,  168(sp)
    fsd     ft6,  176(sp)
    fsd     ft7,  184(sp)
    fsd     ft8,  192(sp)
    fsd     ft9,  200(sp)
    fsd     ft10, 208(sp)
    fsd     ft11, 216(sp)
    fsd     fa0,  224(sp)
    fsd     fa1,  232(sp)
    fsd     fa2,  240(sp)
    fsd     fa3,  248(sp)
    fsd     fa4,  256(sp)
    fsd     fa5,  264(sp)
    fsd     fa6,  272(sp)
    fsd     fa7,  280(sp)
.endm

.macro  ISR_RESTORE
    fld     ft0,  128(sp)
    fld     ft1,  136(sp)
    fld     ft2,  144(sp)
    fld     ft3,  152(sp)
    fld     ft4,  160(sp)
    fld     ft5,  168(sp)
    fld     ft6,  176(sp)
    fld     ft7,  184(sp)
    fld     ft8,  192(sp)
    fld     ft9,  200(sp)
    fld     ft10, 208(sp)
    fld     ft11, 216(sp)
    fld     fa0,  224(sp)
    fld     fa1,  232(sp)
    fld     fa2,  240(sp)
    fld     fa3,  248(sp)
    fld     fa4,  256(sp)
    fld     fa5,  264(sp)
    fld     fa6,  272(sp)
    fld     fa7,  280(sp)
    ld      ra,   0(sp)
    ld      t0,   8(sp)
    ld      t1,  16(sp)
    ld      t2,  24(sp)
    ld      t3,  32(sp)
    ld      t4,  40(sp)
    ld      t5,  48(sp)
    ld      t6,  56(sp)
    ld      a0,  64(sp)
    ld      a1,  72(sp)
    ld      a2,  80(sp)
    ld      a3,  88(sp)
    ld      a4,  96(sp)
    ld      a5, 104(sp)
    ld      a6, 112(sp)
    ld      a7, 120(sp)
    addi    sp, sp, 288
.endm

    .align 2
_trap_mtimer:
    ISR_SAVE
    call    _timer_irq_handler
    ISR_RESTORE
    mret

    .align 2
_trap_mext:
    ISR_SAVE

    /* Read PLIC claim register to get IRQ number */
    li      t0, 0xE0200004
    lw      a0, 0(t0)
    beqz    a0, .Lmext_done

    call    _irq_dispatch

    /* Write IRQ number back to PLIC claim to complete */
    li      t0, 0xE0200004
    sw      a0, 0(t0)

.Lmext_done:
    ISR_RESTORE
    mret

    .align 2
_trap_exception:
    /* Redirect mtvec to a simple spin so double-faults don't recurse */
    la      t0, .Lcrash_spin2
    csrw    mtvec, t0

    /* Save ALL registers to stack for the crash handler */
    addi    sp, sp, -256
    sd      ra,   0(sp)
    sd      sp,   8(sp)       /* saved sp (pre-exception value + 256) */
    sd      gp,  16(sp)
    sd      tp,  24(sp)
    sd      t0,  32(sp)
    sd      t1,  40(sp)
    sd      t2,  48(sp)
    sd      s0,  56(sp)       /* fp */
    sd      s1,  64(sp)
    sd      a0,  72(sp)
    sd      a1,  80(sp)
    sd      a2,  88(sp)
    sd      a3,  96(sp)
    sd      a4, 104(sp)
    sd      a5, 112(sp)
    sd      a6, 120(sp)
    sd      a7, 128(sp)
    sd      s2, 136(sp)
    sd      s3, 144(sp)
    sd      s4, 152(sp)
    sd      s5, 160(sp)
    sd      s6, 168(sp)
    sd      s7, 176(sp)
    sd      s8, 184(sp)
    sd      s9, 192(sp)
    sd      s10, 200(sp)
    sd      s11, 208(sp)
    sd      t3, 216(sp)
    sd      t4, 224(sp)
    sd      t5, 232(sp)
    sd      t6, 240(sp)

    /* Fix saved sp to the value before our addi */
    addi    t0, sp, 256
    sd      t0, 8(sp)

    /* a0 = pointer to saved register block on stack */
    mv      a0, sp
    /* a1 = mcause */
    csrr    a1, mcause
    /* a2 = mepc (faulting PC) */
    csrr    a2, mepc
    /* a3 = mtval (faulting address/instruction) */
    csrr    a3, mtval

    call    _crash_handler

    /* If crash handler returns or double-faults, spin here */
.Lcrash_spin:
    wfi
    j       .Lcrash_spin

    /* Non-vectored mtvec target for double-fault: spin immediately */
    .align 2
.Lcrash_spin2:
    wfi
    j       .Lcrash_spin2
