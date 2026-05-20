/// Bare-metal exception/crash driver.
///
/// Provides the stack-trace driver interface for bare-metal targets
/// (BK7231, BL618, BL808, RP2350, STM32, ...). No symbol resolution is
/// available on-device - addresses are printed raw; decode offline with
/// `addr2line -e <elf> <addr>`.
///
/// Requires the compiler to keep the frame pointer live
/// (`-frame-pointer=all` on LDC). Without it the fp chain is garbage.
module urt.driver.baremetal.exception;

version (BareMetal):

import urt.attribute : noinline;
import urt.internal.exception : Resolved;

nothrow @nogc:

// Linker symbols bounding the valid stack range. Used by the fp-chain
// walker to stop dereferencing junk. Each bare-metal linker script in
// this tree defines both. _stack_low is the bottom of the stack reservation
// (not _bss_end -- on M0 the stack is in OCRAM while .bss is in PSRAM, so
// the two no longer share a region).
//
// These are absolute linker symbols with no storage -- only their addresses
// matter. Declaring as `char` (size 1, never read) and using `&sym` is the
// correct C/D pattern; declaring as `void*` would tell the compiler to
// dereference 4/8 bytes at the symbol's address (i.e. read past stack top).
extern(C) extern __gshared char _stack_top;
extern(C) extern __gshared char _stack_low;


// --- Shared fp-chain walker -------------------------------------------
//
// RV64 / AArch64 / ARM-AAPCS all share the same prologue layout when
// -frame-pointer=all is in effect:
//   fp[-1] = saved return address
//   fp[-2] = saved previous frame pointer
// (indices in machine-word units; RV64 uses fp-8 / fp-16 in bytes).
//
// On 32-bit ARM AAPCS the layout is fp[0] = prev fp, fp[+1] = saved lr
// for Thumb prologues - we don't currently target that combo, so stick
// to the standard layout for now.
//
/// Walk the frame-pointer chain starting at `fp`, writing return addresses
/// into `out_addrs`. Returns the number of frames captured.
size_t walk_fp_chain(size_t fp, void*[] out_addrs) @trusted
{
    if (out_addrs.length == 0)
        return 0;

    const stack_hi = cast(size_t) &_stack_top;
    const stack_lo = cast(size_t) &_stack_low;

    size_t n = 0;
    while (n < out_addrs.length)
    {
        if (fp < stack_lo || fp >= stack_hi || (fp & (size_t.sizeof - 1)) != 0)
            break;

        const ret_addr = *cast(size_t*)(fp - size_t.sizeof);
        const prev_fp  = *cast(size_t*)(fp - 2 * size_t.sizeof);

        if (ret_addr == 0)
            break;

        out_addrs[n++] = cast(void*) ret_addr;

        if (prev_fp == 0 || prev_fp <= fp)
            break;
        fp = prev_fp;
    }
    return n;
}


// --- Read own frame pointer -------------------------------------------

private size_t read_fp() @trusted
{
    size_t fp;
    version (RISCV64)
        asm nothrow @nogc @trusted { "mv %0, s0" : "=r"(fp); }
    else version (RISCV32)
        asm nothrow @nogc @trusted { "mv %0, s0" : "=r"(fp); }
    else version (AArch64)
        asm nothrow @nogc @trusted { "mov %0, x29" : "=r"(fp); }
    else version (ARM)
        asm nothrow @nogc @trusted { "mov %0, r11" : "=r"(fp); }
    else version (Xtensa)
        asm nothrow @nogc @trusted { "mov %0, a7" : "=r"(fp); } // Xtensa: a7 with -mno-serialize-volatile
    else
        fp = 0; // unknown arch - capture returns empty
    return fp;
}


// --- Driver interface -------------------------------------------------
//
// All three primitives assume they are called through a one-level public
// wrapper in urt.internal.exception (kept non-inlined via pragma(inline,
// false)). The wrapper's frame is accounted for in the skip counts.

/// Capture the caller's call stack. First entry = return address of
/// the function that called the public `capture_trace` wrapper.
@noinline
size_t _capture_trace(void*[] addrs) @trusted
{
    // LLVM elides _capture_trace's prologue and reads s0 before saving it,
    // so read_fp() returns the CALLER's fp -- not our own. With LTO/tail-call
    // chains (eh_capture_here -> capture_trace -> _capture_trace all tail-
    // calling), this collapses to whichever frame is the topmost non-tail-
    // called caller. Walk from there directly; the old "step up once"
    // overshot whenever the wrapper chain tail-called.
    auto fp = read_fp();
    if (fp == 0)
        return 0;
    return walk_fp_chain(fp, addrs);
}

/// Return the return address of the `skip`-th frame above the public
/// `caller_address` wrapper's caller.
@noinline
void* _caller_address(uint skip) @trusted
{
    // Same elision/tail-call pattern as _capture_trace: read_fp() returns
    // the topmost non-tail-called caller's fp. With LLVM tail-calling the
    // public capture_address wrapper, that is USER's fp directly. So
    //   buf[0] = USER's saved ra = inside USER's caller   ← skip=0 wants this
    //   buf[1] = caller's caller                          ← skip=1
    auto fp = read_fp();
    if (fp == 0)
        return null;

    void*[32] buf = void;
    const need = skip + 1;
    if (need > buf.length)
        return null;
    const got = walk_fp_chain(fp, buf[0 .. need]);
    if (got < need)
        return null;
    return buf[skip];
}

/// On bare-metal we have no on-device symbol table. Always returns
/// false; decode the address offline with `addr2line`.
bool _resolve_address(void* addr, out Resolved r) @trusted
{
    return false;
}

/// No on-device symbols - caller should treat `results[]` as empty.
bool _resolve_batch(const(void*)[] addrs, Resolved[] results) @trusted
{
    return false;
}
