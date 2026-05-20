/* BL618 (T-Head E907 RV32IMAFC) startup
 *
 * Single-core startup -- no M0 handshake needed (unlike BL808).
 *
 * Boot flow:
 *   1. CPU setup    -- disable IRQ, enable extensions, FPU, trap vectors
 *   2. Core regs    -- gp, tp, sp
 *   3. Section init -- .got, .tdata, .tbss, .bss, .data
 *   4. Caches       -- I-cache enable
 *   5. Interrupts   -- CLIC init, enable MIE
 *   6. D runtime    -- sys_init, .init_array, main
 *
 * T-Head custom CSR numbers:
 *   mxstatus = 0x7C0   (T-Head ISA extension enable)
 *   mhcr     = 0x7C1   (hardware cache control)
 *   mhint    = 0x7C5   (performance hints)
 *   mtvt     = 0x307   (CLIC vector table base -- standard RISC-V CLIC)
 *
 * Trap dispatch: mtvec in CLIC mode (bits[1:0]=11) with base = _trap_exception
 * for sync traps. IRQs go through mtvt[id] -- a flat .word table of handler
 * addresses (here, every entry points at _clic_dispatch, the universal
 * ipush/ipop trampoline). See urt.driver.bl618.irq for the runtime side.
 */
#define CSR_MXSTATUS 0x7C0
#define CSR_MHCR     0x7C1
#define CSR_MHINT    0x7C5
#define CSR_MTVT     0x307

    .section .text.entry, "ax"
    .global _start
    .type   _start, @function
    .align 2

_start:
    /* -- 1. CPU setup ---------------------------------------------- */

    csrc    mstatus, 0x0008     /* clear MIE */

    /* Enable T-Head ISA extensions (THEADISAEE + MM) */
    li      t0, (1 << 22) | (1 << 15)
    csrs    CSR_MXSTATUS, t0

    /* Enable FPU (FS = Initial) -- E907 has single-precision FPU */
    li      t0, (1 << 13)
    csrs    mstatus, t0

    /* mtvec in CLIC mode (mode 11). base = sync-trap handler; IRQs are
     * dispatched via mtvt[id], not mtvec.base. */
    la      t0, _trap_exception
    ori     t0, t0, 3
    csrw    mtvec, t0

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

    la      a0, _tbss_start
    la      a2, _tbss_end
    bgeu    a0, a2, .Ltbss_done
.Ltbss_zero:
    sw      zero, 0(a0)
    addi    a0, a0, 4
    bltu    a0, a2, .Ltbss_zero
.Ltbss_done:

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

    la      a0, _bss_start
    la      a2, _bss_end
    bgeu    a0, a2, .Lbss_done
.Lbss_zero:
    sw      zero, 0(a0)
    addi    a0, a0, 4
    bltu    a0, a2, .Lbss_zero
.Lbss_done:

    /* -- 4. Caches ------------------------------------------------- */

    /* TODO: D-cache and branch prediction OFF -- we set only IE (bit 0).
     * Vendor enables MHCR=0x103F (DE | WB | WA | RS | BPE | L0BTB) and
     * MHINT=0x0C for D$ prefetch. Pure perf cost (~10x slower data on
     * OCRAM/PSRAM, branches stall), visible under real traffic. Before
     * flipping, configure SYSMAP CSRs so MMIO / DMA regions are
     * uncacheable -- otherwise stale IPC reads / invisible DMA writes. */
    li      t0, (1 << 0)        /* I-cache enable */
    csrs    CSR_MHCR, t0

    /* -- 5. D runtime ---------------------------------------------- */
    /* IRQ bring-up + mstatus.MIE enable live in sys_init via irq_init() +
     * irq_global_enable(). Keeping MIE off through the D ctor chain rules
     * out spurious IRQs before subsystems are wired. */

    call    sys_init

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
     * Zero fp so backtraces terminate cleanly at main; zero ra so a return
     * from main traps (caught by _crash_handler). */
    li      a0, 0
    li      a1, 0
    li      s0, 0
    li      ra, 0
    j       main

    .size _start, . - _start


/* -- CLIC vector table -- flat .word handler addresses --------------
 *
 * Each entry is the address the CPU jumps to when CLIC dispatches the
 * matching IRQ id. We point everything at _clic_dispatch so a single
 * trampoline handles every line; the dispatcher reads mcause to learn
 * which IRQ fired and looks up the registered handler in D-side state.
 *
 * Size must match urt.driver.bl618.irq.irq_max. */
    .section .rodata, "a"
    .align 6
    .global __clic_vectors
__clic_vectors:
    .rept 80
    .word _clic_dispatch
    .endr


/* -- IRQ dispatch stub ----------------------------------------------
 *
 * Entered from the CLIC hardware vector via mtvt[id]. The T-Head ipush
 * instruction pushes caller-saved GPRs + mepc + mcause onto the stack
 * (using mscratch as the IRQ stack pointer if non-zero). We clear MIE
 * immediately so a single driver round-trip never nests until we've
 * earned the right to.
 *
 * ipop pops everything and issues mret with hardware tail-chain. The
 * mepc / mcause CSRs are restored from the stack, which is what makes
 * nesting safe (vs a plain mret reading the live CSR, which a nested
 * IRQ would have clobbered). */
    .section .text, "ax"
    .align  2
    .global _clic_dispatch
    .type   _clic_dispatch, @function
    .option push
    .option arch, +xtheadint
_clic_dispatch:
    th.ipush
    csrci   mstatus, 0x8
    csrr    a0, mcause
    andi    a0, a0, 0x3FF
    call    _irq_dispatch
    th.ipop
    .size   _clic_dispatch, . - _clic_dispatch
    .option pop


/* -- Sync-trap (exception) handler ----------------------------------
 *
 * mtvec.base in CLIC mode lands here for exceptions only (IRQs go through
 * mtvt[id] above). Snapshot all GPRs into a stack frame matching the
 * regs[] layout expected by bl_common.exception._crash_handler, then dump
 * and spin. mtvec is redirected to a no-op so a double-fault here doesn't
 * recurse. */
    .section .text, "ax"
    .align  2
    .global _trap_exception
    .type   _trap_exception, @function
_trap_exception:
    la      t0, .Lcrash_spin2
    csrw    mtvec, t0

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

    addi    t0, sp, 128
    sw      t0,  4(sp)

    mv      a0, sp
    csrr    a1, mcause
    csrr    a2, mepc
    csrr    a3, mtval

    call    _crash_handler

.Lcrash_spin:
    wfi
    j       .Lcrash_spin

    .align  2
.Lcrash_spin2:
    wfi
    j       .Lcrash_spin2

    .size   _trap_exception, . - _trap_exception
