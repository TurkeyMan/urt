/// Bouffalo RISC-V crash handler (shared across BL618, BL808 D0 and BL808 M0).
///
/// Called from _trap_exception in start.S. Prints exception info, register
/// dump, and stack backtrace to UART0. Requires -frame-pointer=all for
/// reliable backtrace.
///
/// Register width follows size_t: 32-bit on E907 (BL618 / BL808 M0),
/// 64-bit on C906 (BL808 D0). The uart0_* sink is selected by
/// urt.driver.uart's version dispatch.
module urt.driver.bl_common.exception;

import urt.driver.baremetal.exception : walk_fp_chain;
import urt.driver.uart;

@nogc nothrow:

// Register the .eh_frame section with the libgcc unwinder so a D throw
// (assertion failure, fibre abort, etc.) can walk the stack. Called from
// sys_init before anything that might raise; without it, the first throw
// loops inside libgcc looking for an unwind table and pegs the CPU.
extern(C) void exception_init()
{
    __register_frame_info(&__eh_frame_start, &__eh_frame_object);
}


private:

extern(C) void __register_frame_info(const void*, void*);
extern(C) extern const ubyte __eh_frame_start;
__gshared ubyte[48] __eh_frame_object;  // libgcc unwinder state -- opaque

immutable const(char)*[16] exception_names = [
    "Instruction address misaligned",
    "Instruction access fault",
    "Illegal instruction",
    "Breakpoint",
    "Load address misaligned",
    "Load access fault",
    "Store address misaligned",
    "Store access fault",
    "Environment call from U-mode",
    "Environment call from S-mode",
    "Reserved",
    "Environment call from M-mode",
    "Instruction page fault",
    "Load page fault",
    "Reserved",
    "Store page fault",
];

immutable const(char)*[31] rnames = [
    "ra ", "sp ", "gp ", "tp ",
    "t0 ", "t1 ", "t2 ",
    "s0 ", "s1 ",
    "a0 ", "a1 ", "a2 ", "a3 ",
    "a4 ", "a5 ", "a6 ", "a7 ",
    "s2 ", "s3 ", "s4 ", "s5 ",
    "s6 ", "s7 ", "s8 ", "s9 ",
    "s10", "s11",
    "t3 ", "t4 ", "t5 ", "t6 ",
];

public:

/// regs[] layout matches the save order in _trap_exception (start.S):
///  [0]=ra [1]=sp [2]=gp [3]=tp [4]=t0..[6]=t2
///  [7]=s0/fp [8]=s1 [9]=a0..[16]=a7
///  [17]=s2..[26]=s11 [27]=t3..[30]=t6
extern(C) void _crash_handler(size_t* regs, size_t mcause, size_t mepc, size_t mtval) @nogc nothrow
{
    uart0_print("\n\n*** CRASH ***\nException: ");

    size_t cause = mcause & (size_t.max >> 1);
    if (cause < 16)
        uart0_print(exception_names[cause]);
    else
        uart0_print("Unknown exception");

    uart0_print(" (cause=");
    uart0_hex(mcause);
    uart0_print(")\n  mepc  = ");
    uart0_hex(mepc);
    uart0_print("\n  mtval = ");
    uart0_hex(mtval);
    uart0_print("\n\nRegisters:\n");

    foreach (i; 0 .. 31)
    {
        uart0_print("  ");
        uart0_print(rnames[i]);
        uart0_print(" = ");
        uart0_hex(regs[i]);
        if ((i % 4) == 3 || i == 30)
            uart0_putc('\n');
    }

    uart0_print("\nBacktrace:\n  [0] ");
    uart0_hex(mepc);
    uart0_print("  (faulting PC)\n");

    void*[32] addrs = void;
    const n = walk_fp_chain(regs[7], addrs[]); // s0 = frame pointer

    foreach (depth, addr; addrs[0 .. n])
    {
        uart0_print("  [");
        const d = depth + 1;
        if (d < 10)
            uart0_putc(cast(char)('0' + d));
        else
        {
            uart0_putc(cast(char)('0' + d / 10));
            uart0_putc(cast(char)('0' + d % 10));
        }
        uart0_print("] ");
        uart0_hex(cast(size_t) addr);
        uart0_putc('\n');
    }

    uart0_print("\n*** HALTED ***\n");
}
