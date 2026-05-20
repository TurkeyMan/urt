module urt.atomic;

enum MemoryOrder
{
    relaxed = 0,
    consume = 1,
    acquire = 2,
    release = 3,
    acq_rel = 4,
    seq_cst = 5,
    seq = 5,
}

// DMD lowers to these names...
alias atomicLoad = atomic_load;
alias atomicStore = atomic_store;
alias atomicOp = atomic_op;
alias atomicExchange = atomic_exchange;
alias atomicFetchAdd = atomic_fetch_add;
alias atomicFetchSub = atomic_fetch_sub;


version (LDC)
{
    // -----------------------------------------------------------------------
    // LDC: LLVM intrinsics - architecture-generic
    // -----------------------------------------------------------------------

    nothrow @nogc @safe:
    pragma(inline, true):

    T atomic_load(MemoryOrder ms = MemoryOrder.seq, T)(ref const T val) pure @trusted
        if (!is(T == shared))
    {
        alias A = _AtomicType!T;
        A result = llvm_atomic_load!A(cast(shared A*)&val, _ordering!ms);
        return *cast(inout(T)*)&result;
    }

    TailShared!T atomic_load(MemoryOrder ms = MemoryOrder.seq, T)(auto ref shared const T val) pure @trusted
    {
        alias A = _AtomicType!T;
        A result = llvm_atomic_load!A(cast(shared A*)&val, _ordering!ms);
        return *cast(TailShared!T*)&result;
    }

    void atomic_store(MemoryOrder ms = MemoryOrder.seq, T, V)(ref shared T val, V newval) pure @trusted
        if (__traits(compiles, { *cast(T*)&val = newval; }))
    {
        alias A = _AtomicType!T;
        T tmp = newval;
        llvm_atomic_store!A(*cast(A*)&tmp, cast(shared A*)&val, _ordering!ms);
    }

    TailShared!T atomic_op(string op, T, V1)(ref shared T val, V1 mod) pure @trusted
        if (__traits(compiles, mixin("*cast(T*)&val" ~ op ~ "mod")))
    {
        // use LLVM atomic RMW where possible
        static if (__traits(isIntegral, T) && T.sizeof <= size_t.sizeof)
        {
            alias A = _AtomicType!T;
            static if (op == "+=")
            {
                auto old = llvm_atomic_rmw_add!A(cast(shared A*)&val, cast(A)mod, _ordering!(MemoryOrder.seq));
                auto result = cast(T)(old + cast(A)mod);
                return *cast(TailShared!T*)&result;
            }
            else static if (op == "-=")
            {
                auto old = llvm_atomic_rmw_sub!A(cast(shared A*)&val, cast(A)mod, _ordering!(MemoryOrder.seq));
                auto result = cast(T)(old - cast(A)mod);
                return *cast(TailShared!T*)&result;
            }
            else
            {
                // CAS loop for other ops
                return _cas_op_loop!(op, T, V1)(val, mod);
            }
        }
        else
            return _cas_op_loop!(op, T, V1)(val, mod);
    }

    bool cas(T, V1, V2)(shared(T)* here, V1 ifThis, V2 writeThis) pure @trusted
    {
        alias A = _AtomicType!T;
        T cmp = cast(T)ifThis;
        T desired = cast(T)writeThis;
        auto result = llvm_atomic_cmp_xchg!A(cast(shared A*)here, *cast(A*)&cmp, *cast(A*)&desired,
            _ordering!(MemoryOrder.seq), _ordering!(MemoryOrder.seq), false);
        return result.exchanged;
    }

    T atomic_exchange(MemoryOrder ms = MemoryOrder.seq, T, V)(shared(T)* here, V exchangeWith) pure @trusted
    {
        alias A = _AtomicType!T;
        T tmp = cast(T)exchangeWith;
        A result = llvm_atomic_rmw_xchg!A(cast(shared A*)here, *cast(A*)&tmp, _ordering!ms);
        return *cast(T*)&result;
    }

    T atomic_fetch_add(MemoryOrder ms = MemoryOrder.seq, T)(ref shared T val, T mod) pure @trusted
        if (__traits(isIntegral, T))
    {
        alias A = _AtomicType!T;
        return cast(T)llvm_atomic_rmw_add!A(cast(shared A*)&val, cast(A)mod, _ordering!ms);
    }

    T atomic_fetch_sub(MemoryOrder ms = MemoryOrder.seq, T)(ref shared T val, T mod) pure @trusted
        if (__traits(isIntegral, T))
    {
        alias A = _AtomicType!T;
        return cast(T)llvm_atomic_rmw_sub!A(cast(shared A*)&val, cast(A)mod, _ordering!ms);
    }

    void atomic_fence(MemoryOrder ms = MemoryOrder.seq)() pure @trusted
    {
        llvm_memory_fence(_ordering!ms);
    }

    void pause() pure @trusted
    {
        version (X86)
            enum inst = "pause";
        else version (X86_64)
            enum inst = "pause";
        else version (ARM)
        {
            static if (__traits(targetHasFeature, "v6k"))
                enum inst = "yield";
            else
                enum inst = null;
        }
        else version (AArch64)
            enum inst = "yield";
        else
            enum inst = null;

        static if (inst !is null)
            asm pure nothrow @nogc @trusted { (inst); }
    }

    // --- LDC private helpers ---

    private TailShared!T _cas_op_loop(string op, T, V1)(ref shared T val, V1 mod) pure @trusted
    {
        alias A = _AtomicType!T;
        A current = llvm_atomic_load!A(cast(shared A*)&val, _ordering!(MemoryOrder.seq));
        while (true)
        {
            auto tmp = *cast(T*)&current;
            mixin("tmp " ~ op ~ " mod;");
            auto result = llvm_atomic_cmp_xchg!A(cast(shared A*)&val, current, *cast(A*)&tmp,
                _ordering!(MemoryOrder.seq), _ordering!(MemoryOrder.seq), false);
            if (result.exchanged)
                return *cast(TailShared!T*)&tmp;
            current = result.previousValue;
        }
    }

    private template _ordering(MemoryOrder ms)
    {
        static if (ms == MemoryOrder.acquire)
            enum _ordering = AtomicOrdering.Acquire;
        else static if (ms == MemoryOrder.release)
            enum _ordering = AtomicOrdering.Release;
        else static if (ms == MemoryOrder.acq_rel)
            enum _ordering = AtomicOrdering.AcquireRelease;
        else static if (ms == MemoryOrder.seq)
            enum _ordering = AtomicOrdering.SequentiallyConsistent;
        else // raw/relaxed/consume
            enum _ordering = AtomicOrdering.Monotonic;
    }

    private template _AtomicType(T)
    {
        static if (T.sizeof == ubyte.sizeof)
            alias _AtomicType = ubyte;
        else static if (T.sizeof == ushort.sizeof)
            alias _AtomicType = ushort;
        else static if (T.sizeof == uint.sizeof)
            alias _AtomicType = uint;
        else static if (T.sizeof == ulong.sizeof)
            alias _AtomicType = ulong;
        else
            static assert(false, "Cannot atomically load/store type of size " ~ T.sizeof.stringof);
    }

    // LLVM atomic intrinsic declarations
    private:

    enum AtomicOrdering
    {
        Monotonic = 2,
        Acquire = 4,
        Release = 5,
        AcquireRelease = 6,
        SequentiallyConsistent = 7,
    }

    enum SynchronizationScope
    {
        SingleThread = 0,
        CrossThread = 1,
    }

    struct CmpXchgResult(T)
    {
        T previousValue;
        bool exchanged;
    }

    pragma(LDC_atomic_load)
        T llvm_atomic_load(T)(in shared T* ptr, AtomicOrdering ordering) pure @trusted;

    pragma(LDC_atomic_store)
        void llvm_atomic_store(T)(T val, shared T* ptr, AtomicOrdering ordering) pure @trusted;

    pragma(LDC_atomic_rmw, "xchg")
        T llvm_atomic_rmw_xchg(T)(shared T* ptr, T val, AtomicOrdering ordering) pure @trusted;

    pragma(LDC_atomic_rmw, "add")
        T llvm_atomic_rmw_add(T)(in shared T* ptr, T val, AtomicOrdering ordering) pure @trusted;

    pragma(LDC_atomic_rmw, "sub")
        T llvm_atomic_rmw_sub(T)(in shared T* ptr, T val, AtomicOrdering ordering) pure @trusted;

    pragma(LDC_atomic_cmp_xchg)
        CmpXchgResult!T llvm_atomic_cmp_xchg(T)(shared T* ptr, T cmp, T val,
            AtomicOrdering successOrdering, AtomicOrdering failureOrdering, bool weak) pure @trusted;

    pragma(LDC_fence)
        void llvm_memory_fence(AtomicOrdering ordering) pure @trusted;
}
else version (D_InlineAsm_X86_64)
{
    // -----------------------------------------------------------------------
    // DMD x86_64: inline assembly
    // -----------------------------------------------------------------------

    nothrow @nogc @safe:

    T atomic_load(MemoryOrder ms = MemoryOrder.seq, T)(ref const T val) pure @trusted
        if (!is(T == shared))
    {
        static if (ms == MemoryOrder.seq)
        {
            // seq_cst load: use lock cmpxchg to get full barrier
            size_t storage = void;
            auto srcPtr = cast(size_t)&val;

            enum ValReg = SizedReg!(DX, T);
            enum ResReg = SizedReg!(AX, T);

            mixin(simpleFormat!(q{
                asm pure nothrow @nogc @trusted
                {
                    mov RCX, srcPtr;
                    mov %0, 0;
                    mov %1, 0;
                    lock; cmpxchg [RCX], %0;
                    lea RCX, storage;
                    mov [RCX], %1;
                }
            }, [ValReg, ResReg]));

            return *cast(T*)&storage;
        }
        else
            return val;
    }

    TailShared!T atomic_load(MemoryOrder ms = MemoryOrder.seq, T)(auto ref shared const T val) pure @trusted
    {
        return atomic_load!ms(*cast(const T*)&val);
    }

    void atomic_store(MemoryOrder ms = MemoryOrder.seq, T, V)(ref shared T val, V newval) pure @trusted
        if (__traits(compiles, { *cast(T*)&val = newval; }))
    {
        static if (ms == MemoryOrder.seq)
        {
            // seq_cst store: use xchg (has implicit lock)
            auto destPtr = cast(size_t)cast(T*)&val;
            T tmp = newval;

            enum ValReg = SizedReg!(AX, T);

            mixin(simpleFormat!(q{
                asm pure nothrow @nogc @trusted
                {
                    mov %0, tmp;
                    mov RCX, destPtr;
                    lock; xchg [RCX], %0;
                }
            }, [ValReg]));
        }
        else
            *cast(T*)&val = newval;
    }

    TailShared!T atomic_op(string op, T, V1)(ref shared T val, V1 mod) pure @trusted
        if (__traits(compiles, mixin("*cast(T*)&val" ~ op ~ "mod")))
    {
        static if ((op == "+=" || op == "-=") && __traits(isIntegral, T) && T.sizeof <= size_t.sizeof)
        {
            auto ptr = cast(T*)&val;
            static if (op == "+=")
            {
                T old = _asm_fetch_add!T(ptr, cast(T)mod);
                return cast(TailShared!T)(old + cast(T)mod);
            }
            else
            {
                T old = _asm_fetch_add!T(ptr, cast(T)-cast(IntOrLong!T)mod);
                return cast(TailShared!T)(old - cast(T)mod);
            }
        }
        else
        {
            // CAS loop
            auto ptr = cast(T*)&val;
            while (true)
            {
                T current = *ptr;
                T desired = current;
                mixin("desired " ~ op ~ " mod;");
                if (_asm_cas!T(ptr, &current, desired))
                    return *cast(TailShared!T*)&desired;
            }
        }
    }

    bool cas(T, V1, V2)(shared(T)* here, V1 ifThis, V2 writeThis) pure @trusted
    {
        T cmp = cast(T)ifThis;
        return _asm_cas!T(cast(T*)here, &cmp, cast(T)writeThis);
    }

    T atomic_exchange(MemoryOrder ms = MemoryOrder.seq, T, V)(shared(T)* here, V exchangeWith) pure @trusted
    {
        auto ptr = cast(T*)here;
        T tmp = cast(T)exchangeWith;
        size_t storage = void;
        auto destPtr = cast(size_t)ptr;

        enum DestReg = SizedReg!CX;
        enum ValReg = SizedReg!(AX, T);

        mixin(simpleFormat!(q{
            asm pure nothrow @nogc @trusted
            {
                mov %1, tmp;
                mov %0, destPtr;
                lock; xchg [%0], %1;
                lea %0, storage;
                mov [%0], %1;
            }
        }, [DestReg, ValReg]));

        return *cast(T*)&storage;
    }

    T atomic_fetch_add(MemoryOrder ms = MemoryOrder.seq, T)(ref shared T val, T mod) pure @trusted
        if (__traits(isIntegral, T))
    {
        return _asm_fetch_add!T(cast(T*)&val, mod);
    }

    T atomic_fetch_sub(MemoryOrder ms = MemoryOrder.seq, T)(ref shared T val, T mod) pure @trusted
        if (__traits(isIntegral, T))
    {
        return _asm_fetch_add!T(cast(T*)&val, cast(T)-cast(IntOrLong!T)mod);
    }

    void atomic_fence(MemoryOrder ms = MemoryOrder.seq)() pure @trusted
    {
        static if (ms != MemoryOrder.relaxed)
        {
            asm pure nothrow @nogc @trusted
            {
                mfence;
            }
        }
    }

    void pause() pure @trusted
    {
        asm pure nothrow @nogc @trusted
        {
            pause;
        }
    }

    // --- DMD x86_64 private helpers ---
    private:

    T _asm_fetch_add(T)(T* dest, T value) pure @trusted
    {
        size_t storage = void;
        auto destPtr = cast(size_t)dest;

        enum DestReg = SizedReg!DX;
        enum ValReg = SizedReg!(AX, T);

        mixin(simpleFormat!(q{
            asm pure nothrow @nogc @trusted
            {
                mov %1, value;
                mov %0, destPtr;
                lock; xadd [%0], %1;
                lea %0, storage;
                mov [%0], %1;
            }
        }, [DestReg, ValReg]));

        return *cast(T*)&storage;
    }

    bool _asm_cas(T)(T* dest, T* compare, T value) pure @trusted
    {
        bool success;
        auto destPtr = cast(size_t)dest;
        auto cmpPtr = cast(size_t)compare;

        enum SrcReg = SizedReg!CX;
        enum ValueReg = SizedReg!(DX, T);
        enum CompareReg = SizedReg!(AX, T);

        mixin(simpleFormat!(q{
            asm pure nothrow @nogc @trusted
            {
                mov %1, value;
                mov %0, cmpPtr;
                mov %2, [%0];

                mov %0, destPtr;
                lock; cmpxchg [%0], %1;

                setz success;
                mov %0, cmpPtr;
                mov [%0], %2;
            }
        }, [SrcReg, ValueReg, CompareReg]));

        return success;
    }
}
else version (D_InlineAsm_X86)
{
    // -----------------------------------------------------------------------
    // DMD x86 (32-bit): inline assembly
    // -----------------------------------------------------------------------

    nothrow @nogc @safe:

    T atomic_load(MemoryOrder ms = MemoryOrder.seq, T)(ref const T val) pure @trusted
        if (!is(T == shared))
    {
        static assert(T.sizeof <= 4, "64-bit atomicLoad not supported on 32-bit target");

        static if (ms == MemoryOrder.seq)
        {
            size_t storage = void;

            enum ValReg = SizedReg!(DX, T);
            enum ResReg = SizedReg!(AX, T);

            mixin(simpleFormat!(q{
                asm pure nothrow @nogc @trusted
                {
                    mov ECX, val;
                    mov %0, 0;
                    mov %1, 0;
                    lock; cmpxchg [ECX], %0;
                    lea ECX, storage;
                    mov [ECX], %1;
                }
            }, [ValReg, ResReg]));

            return *cast(T*)&storage;
        }
        else
            return val;
    }

    TailShared!T atomic_load(MemoryOrder ms = MemoryOrder.seq, T)(auto ref shared const T val) pure @trusted
    {
        return atomic_load!ms(*cast(const T*)&val);
    }

    void atomic_store(MemoryOrder ms = MemoryOrder.seq, T, V)(ref shared T val, V newval) pure @trusted
        if (__traits(compiles, { *cast(T*)&val = newval; }))
    {
        static assert(T.sizeof <= 4, "64-bit atomicStore not supported on 32-bit target");

        static if (ms == MemoryOrder.seq)
        {
            T tmp = newval;
            enum ValReg = SizedReg!(AX, T);

            mixin(simpleFormat!(q{
                asm pure nothrow @nogc @trusted
                {
                    mov %0, tmp;
                    mov ECX, val;
                    lock; xchg [ECX], %0;
                }
            }, [ValReg]));
        }
        else
            *cast(T*)&val = newval;
    }

    TailShared!T atomic_op(string op, T, V1)(ref shared T val, V1 mod) pure @trusted
        if (__traits(compiles, mixin("*cast(T*)&val" ~ op ~ "mod")))
    {
        static assert(T.sizeof <= 4, "64-bit atomicOp not supported on 32-bit target");

        static if ((op == "+=" || op == "-=") && __traits(isIntegral, T) && T.sizeof <= 4)
        {
            auto ptr = cast(T*)&val;
            static if (op == "+=")
            {
                T old = _asm_fetch_add!T(ptr, cast(T)mod);
                return cast(TailShared!T)(old + cast(T)mod);
            }
            else
            {
                T old = _asm_fetch_add!T(ptr, cast(T)-cast(IntOrLong!T)mod);
                return cast(TailShared!T)(old - cast(T)mod);
            }
        }
        else
        {
            auto ptr = cast(T*)&val;
            while (true)
            {
                T current = *ptr;
                T desired = current;
                mixin("desired " ~ op ~ " mod;");
                if (_asm_cas!T(ptr, &current, desired))
                    return *cast(TailShared!T*)&desired;
            }
        }
    }

    bool cas(T, V1, V2)(shared(T)* here, V1 ifThis, V2 writeThis) pure @trusted
    {
        static assert(T.sizeof <= 4, "64-bit cas not supported on 32-bit target");
        T cmp = cast(T)ifThis;
        return _asm_cas!T(cast(T*)here, &cmp, cast(T)writeThis);
    }

    T atomic_exchange(MemoryOrder ms = MemoryOrder.seq, T, V)(shared(T)* here, V exchangeWith) pure @trusted
    {
        static assert(T.sizeof <= 4, "64-bit atomicExchange not supported on 32-bit target");

        auto ptr = cast(T*)here;
        T tmp = cast(T)exchangeWith;
        size_t storage = void;

        enum ValReg = SizedReg!(AX, T);

        mixin(simpleFormat!(q{
            asm pure nothrow @nogc @trusted
            {
                mov %0, tmp;
                mov ECX, ptr;
                lock; xchg [ECX], %0;
                lea ECX, storage;
                mov [ECX], %0;
            }
        }, [ValReg]));

        return *cast(T*)&storage;
    }

    T atomic_fetch_add(MemoryOrder ms = MemoryOrder.seq, T)(ref shared T val, T mod) pure @trusted
        if (__traits(isIntegral, T))
    {
        static assert(T.sizeof <= 4, "64-bit atomicFetchAdd not supported on 32-bit target");
        return _asm_fetch_add!T(cast(T*)&val, mod);
    }

    T atomic_fetch_sub(MemoryOrder ms = MemoryOrder.seq, T)(ref shared T val, T mod) pure @trusted
        if (__traits(isIntegral, T))
    {
        static assert(T.sizeof <= 4, "64-bit atomicFetchSub not supported on 32-bit target");
        return _asm_fetch_add!T(cast(T*)&val, cast(T)-cast(IntOrLong!T)mod);
    }

    void atomic_fence(MemoryOrder ms = MemoryOrder.seq)() pure @trusted
    {
        static if (ms != MemoryOrder.relaxed)
        {
            // x86 without guaranteed SSE2 - mfence may not exist.
            // lock; add is a full barrier on all x86.
            asm pure nothrow @nogc @trusted
            {
                push EAX;
                lock; add [ESP], 0;
                pop EAX;
            }
        }
    }

    void pause() pure @trusted
    {
        asm pure nothrow @nogc @trusted
        {
            pause;
        }
    }

    // --- DMD x86 private helpers ---
    private:

    T _asm_fetch_add(T)(T* dest, T value) pure @trusted
    {
        size_t storage = void;

        enum DestReg = SizedReg!DX;
        enum ValReg = SizedReg!(AX, T);

        mixin(simpleFormat!(q{
            asm pure nothrow @nogc @trusted
            {
                mov %1, value;
                mov %0, dest;
                lock; xadd [%0], %1;
                lea %0, storage;
                mov [%0], %1;
            }
        }, [DestReg, ValReg]));

        return *cast(T*)&storage;
    }

    bool _asm_cas(T)(T* dest, T* compare, T value) pure @trusted
    {
        bool success;

        enum SrcReg = SizedReg!CX;
        enum ValueReg = SizedReg!(DX, T);
        enum CompareReg = SizedReg!(AX, T);

        mixin(simpleFormat!(q{
            asm pure nothrow @nogc @trusted
            {
                mov %1, value;
                mov %0, compare;
                mov %2, [%0];

                mov %0, dest;
                lock; cmpxchg [%0], %1;

                setz success;
                mov %0, compare;
                mov [%0], %2;
            }
        }, [SrcReg, ValueReg, CompareReg]));

        return success;
    }
}
else
{
    // -----------------------------------------------------------------------
    // Fallback: plain load/store for single-core / cooperative-multitasking
    // targets (e.g. Xtensa, bare-metal RISC-V)
    // -----------------------------------------------------------------------

    nothrow @nogc @safe:

    T atomic_load(MemoryOrder ms = MemoryOrder.seq, T)(ref const T val) pure @trusted
        if (!is(T == shared))
    {
        return val;
    }

    TailShared!T atomic_load(MemoryOrder ms = MemoryOrder.seq, T)(auto ref shared const T val) pure @trusted
    {
        return *cast(TailShared!T*)&val;
    }

    void atomic_store(MemoryOrder ms = MemoryOrder.seq, T, V)(ref shared T val, V newval) pure @trusted
        if (__traits(compiles, { *cast(T*)&val = newval; }))
    {
        *cast(T*)&val = newval;
    }

    TailShared!T atomic_op(string op, T, V1)(ref shared T val, V1 mod) pure @trusted
        if (__traits(compiles, mixin("*cast(T*)&val" ~ op ~ "mod")))
    {
        auto ptr = cast(T*)&val;
        mixin("*ptr " ~ op ~ " mod;");
        return *cast(TailShared!T*)ptr;
    }

    bool cas(T, V1, V2)(shared(T)* here, V1 ifThis, V2 writeThis) pure @trusted
    {
        auto ptr = cast(T*)here;
        if (*ptr == ifThis)
        {
            *ptr = writeThis;
            return true;
        }
        return false;
    }

    T atomic_exchange(MemoryOrder ms = MemoryOrder.seq, T, V)(shared(T)* here, V exchangeWith) pure @trusted
    {
        auto ptr = cast(T*)here;
        T old = *ptr;
        *ptr = exchangeWith;
        return old;
    }

    T atomic_fetch_add(MemoryOrder ms = MemoryOrder.seq, T)(ref shared T val, T mod) pure @trusted
        if (__traits(isIntegral, T))
    {
        auto ptr = cast(T*)&val;
        T old = *ptr;
        *ptr += mod;
        return old;
    }

    T atomic_fetch_sub(MemoryOrder ms = MemoryOrder.seq, T)(ref shared T val, T mod) pure @trusted
        if (__traits(isIntegral, T))
    {
        auto ptr = cast(T*)&val;
        T old = *ptr;
        *ptr -= mod;
        return old;
    }

    void atomic_fence(MemoryOrder ms = MemoryOrder.seq)() pure @trusted {}
    void pause() pure @trusted {}
}


// -----------------------------------------------------------------------
// Shared helpers
// -----------------------------------------------------------------------

template TailShared(U) if (!is(U == shared))
{
    alias TailShared = .TailShared!(shared U);
}

template TailShared(S) if (is(S == shared))
{
    static if (is(S U == shared U))
    {
        static if (is(S : U))
            alias TailShared = U;
        else
            alias TailShared = S;
    }
    else
        static assert(false);
}

private:

template IntOrLong(T)
{
    static if (T.sizeof > 4)
        alias IntOrLong = long;
    else
        alias IntOrLong = int;
}

// DMD inline-asm helpers (shared between x86 and x86_64)
version (D_InlineAsm_X86)
    enum _have_dmd_asm = true;
else version (D_InlineAsm_X86_64)
    enum _have_dmd_asm = true;
else
    enum _have_dmd_asm = false;

static if (_have_dmd_asm)
{
    enum : int
    {
        AX, BX, CX, DX, DI, SI, R8, R9
    }

    immutable string[4][8] registerNames = [
        ["AL", "AX", "EAX", "RAX"],
        ["BL", "BX", "EBX", "RBX"],
        ["CL", "CX", "ECX", "RCX"],
        ["DL", "DX", "EDX", "RDX"],
        ["DIL", "DI", "EDI", "RDI"],
        ["SIL", "SI", "ESI", "RSI"],
        ["R8B", "R8W", "R8D", "R8"],
        ["R9B", "R9W", "R9D", "R9"],
    ];

    template RegIndex(T)
    {
        static if (T.sizeof == 1)
            enum RegIndex = 0;
        else static if (T.sizeof == 2)
            enum RegIndex = 1;
        else static if (T.sizeof == 4)
            enum RegIndex = 2;
        else static if (T.sizeof == 8)
            enum RegIndex = 3;
        else
            static assert(false, "Invalid type");
    }

    enum SizedReg(int reg, T = size_t) = registerNames[reg][RegIndex!T];

    // CTFE-only helper for building asm strings. Templated so it doesn't
    // inherit the module-level @nogc (string concat is fine at compile time).
    template simpleFormat(string format, string[] args)
    {
        enum simpleFormat = _simpleFormatImpl(format, args);
    }

    string _simpleFormatImpl()(string format, const(string)[] args) pure @safe
    {
        string result;
        outer: while (format.length)
        {
            foreach (i; 0 .. format.length)
            {
                if (format[i] == '%' || format[i] == '?')
                {
                    bool isQ = format[i] == '?';
                    result ~= format[0 .. i++];
                    assert(i < format.length, "Invalid format string");
                    if (format[i] == '%' || format[i] == '?')
                    {
                        assert(!isQ, "Invalid format string");
                        result ~= format[i++];
                    }
                    else
                    {
                        int index = 0;
                        assert(format[i] >= '0' && format[i] <= '9', "Invalid format string");
                        while (i < format.length && format[i] >= '0' && format[i] <= '9')
                            index = index * 10 + (ubyte(format[i++]) - ubyte('0'));
                        if (!isQ)
                            result ~= args[index];
                        else if (!args[index])
                        {
                            size_t j = i;
                            for (; j < format.length;)
                            {
                                if (format[j++] == '\n')
                                    break;
                            }
                            i = j;
                        }
                    }
                    format = format[i .. $];
                    continue outer;
                }
            }
            result ~= format;
            break;
        }
        return result;
    }
}
