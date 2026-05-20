/// Windows exception driver.
///
/// Three compiler/arch flavours of EH runtime coexist, selected by inner
/// version blocks:
///   version (LDC)   - MSVC C++ SEH (RaiseException + table-based unwind)
///   version (Win32) - DMD SEH (_d_framehandler chain walk)
///   version (Win64) - DMD DEH (RBP-chain + ._deh section tables)
///
/// Stack-trace capture / symbol resolution uses DbgHelp (debug-only).
/// Ported from druntime.
module urt.driver.windows.exception;

version (Windows):

import urt.internal.exception : ClassInfo, Resolved, _d_isbaseof, _d_createTrace, terminate;

nothrow @nogc:


// ======================================================================
//  Stack trace support (DbgHelp, debug only)
// ======================================================================
//
// ===================================================================
//   !!! TODO !!!  THREADING IS NOT SUPPORTED.                        
//                                                                    
//   DbgHelp is NOT thread-safe. All calls to SymFromAddr,            
//   SymGetLineFromAddr64, SymInitialize, and StackWalk64 must be     
//   serialized with a CRITICAL_SECTION (or equivalent) before this   
//   program can use threads. The static scratch buffer inside        
//   _resolve_address is also shared across callers - replace with    
//   per-thread storage or a mutex when threading lands.              
// ===================================================================

// --- DbgHelp types ---------------------------------------------------

private struct SYMBOL_INFOA
{
    uint SizeOfStruct;
    uint TypeIndex;
    ulong[2] Reserved;
    uint Index;
    uint Size;
    ulong ModBase;
    uint Flags;
    ulong Value;
    ulong Address;
    uint Register;
    uint Scope;
    uint Tag;
    uint NameLen;
    uint MaxNameLen;
    char[1] Name; // variable-length
}

private struct IMAGEHLP_LINEA64
{
    uint SizeOfStruct;
    void* Key;
    uint LineNumber;
    const(char)* FileName;
    ulong Address;
}

// --- StackWalk64 types -----------------------------------------------

private alias HANDLE = void*;
private enum AddrModeFlat = 3;

private struct ADDRESS64
{
    ulong Offset;
    ushort Segment;
    uint Mode;
}

private struct STACKFRAME64
{
    ADDRESS64 AddrPC;
    ADDRESS64 AddrReturn;
    ADDRESS64 AddrFrame;
    ADDRESS64 AddrStack;
    ADDRESS64 AddrBStore;
    void* FuncTableEntry;
    ulong[4] Params;
    int Far;
    int Virtual;
    ulong[3] Reserved;
    ubyte[96] KdHelp; // KDHELP64, opaque
}

// CONTEXT - opaque aligned buffer, accessed via offset constants.
version (Win64)
{
    private enum CONTEXT_SIZE  = 1232;
    private enum CTX_FLAGS_OFF = 48;
    private enum CTX_IP_OFF    = 248;  // Rip
    private enum CTX_SP_OFF    = 152;  // Rsp
    private enum CTX_FP_OFF    = 160;  // Rbp
    private enum CTX_FULL      = 0x10000B;
    private enum MACHINE_TYPE  = 0x8664; // IMAGE_FILE_MACHINE_AMD64
}
else
{
    private enum CONTEXT_SIZE  = 716;
    private enum CTX_FLAGS_OFF = 0;
    private enum CTX_IP_OFF    = 184;  // Eip
    private enum CTX_SP_OFF    = 196;  // Esp
    private enum CTX_FP_OFF    = 180;  // Ebp
    private enum CTX_FULL      = 0x10007;
    private enum MACHINE_TYPE  = 0x014C; // IMAGE_FILE_MACHINE_I386
}

// --- Function pointer types ------------------------------------------

extern(Windows) nothrow @nogc
{
    private alias SymInitializeFn        = int  function(HANDLE, const(char)*, int);
    private alias SymSetOptionsFn        = uint function(uint);
    private alias SymFromAddrFn          = int  function(HANDLE, ulong, ulong*, SYMBOL_INFOA*);
    private alias SymGetLineFromAddr64Fn = int  function(HANDLE, ulong, uint*, IMAGEHLP_LINEA64*);
    private alias FuncTableAccessFn      = void* function(HANDLE, ulong);
    private alias GetModuleBaseFn        = ulong function(HANDLE, ulong);
    private alias StackWalk64Fn          = int  function(
        uint machineType, HANDLE hProcess, HANDLE hThread,
        STACKFRAME64* stackFrame, void* contextRecord,
        void* readMemory, FuncTableAccessFn funcTableAccess,
        GetModuleBaseFn getModuleBase, void* translateAddress);
}

// --- Globals ---------------------------------------------------------

private __gshared bool _dbg_inited;
private __gshared bool _dbg_available;
private __gshared HANDLE _dbg_process;
private __gshared SymFromAddrFn _sym_from_addr;
private __gshared SymGetLineFromAddr64Fn _sym_get_line;
private __gshared StackWalk64Fn _stack_walk64;
private __gshared FuncTableAccessFn _func_table_access64;
private __gshared GetModuleBaseFn _get_module_base64;

// --- Initialization --------------------------------------------------

private void dbghelp_init() @trusted
{
    if (_dbg_inited)
        return;
    _dbg_inited = true;

    auto hDbg = loadLibraryA("dbghelp.dll");
    if (hDbg is null)
        return;

    auto sym_init   = cast(SymInitializeFn)        getProcAddress(hDbg, "SymInitialize");
    auto sym_set_opt = cast(SymSetOptionsFn)        getProcAddress(hDbg, "SymSetOptions");
    _sym_from_addr   = cast(SymFromAddrFn)          getProcAddress(hDbg, "SymFromAddr");
    _sym_get_line    = cast(SymGetLineFromAddr64Fn) getProcAddress(hDbg, "SymGetLineFromAddr64");
    _stack_walk64   = cast(StackWalk64Fn)          getProcAddress(hDbg, "StackWalk64");
    _func_table_access64 = cast(FuncTableAccessFn)  getProcAddress(hDbg, "SymFunctionTableAccess64");
    _get_module_base64   = cast(GetModuleBaseFn)    getProcAddress(hDbg, "SymGetModuleBase64");

    if (sym_init is null || sym_set_opt is null || _sym_from_addr is null)
        return;

    // SYMOPT_DEFERRED_LOAD | SYMOPT_LOAD_LINES
    sym_set_opt(0x00000004 | 0x00000010);

    _dbg_process = cast(HANDLE) cast(size_t)-1; // GetCurrentProcess() pseudo-handle
    if (!sym_init(_dbg_process, null, 1)) // fInvadeProcess = TRUE
        return;

    _dbg_available = true;
}

// --- Kernel32/ntdll imports ------------------------------------------

pragma(mangle, "LoadLibraryA")
extern(Windows) private void* loadLibraryA(const(char)*);

pragma(mangle, "GetProcAddress")
extern(Windows) private void* getProcAddress(void*, const(char)*);

pragma(mangle, "RtlCaptureStackBackTrace")
extern(Windows) private ushort rtlCaptureStackBackTrace(
    uint FramesToSkip, uint FramesToCapture, void** BackTrace, uint* BackTraceHash);

pragma(mangle, "RtlCaptureContext")
extern(Windows) private void rtlCaptureContext(void* contextRecord);

pragma(mangle, "GetCurrentThread")
extern(Windows) private HANDLE getCurrentThread();

// --- StackWalk64 fallback --------------------------------------------

private size_t stack_walk64_capture(ref void*[32] addrs) @trusted
{
    dbghelp_init();

    if (_stack_walk64 is null || _func_table_access64 is null || _get_module_base64 is null)
        return 0;

    align(16) ubyte[CONTEXT_SIZE] ctx = 0;
    *cast(uint*)(ctx.ptr + CTX_FLAGS_OFF) = CTX_FULL;
    rtlCaptureContext(ctx.ptr);

    STACKFRAME64 sf;
    version (Win64)
    {
        sf.AddrPC.Offset    = *cast(ulong*)(ctx.ptr + CTX_IP_OFF);
        sf.AddrFrame.Offset = *cast(ulong*)(ctx.ptr + CTX_FP_OFF);
        sf.AddrStack.Offset = *cast(ulong*)(ctx.ptr + CTX_SP_OFF);
    }
    else
    {
        sf.AddrPC.Offset    = *cast(uint*)(ctx.ptr + CTX_IP_OFF);
        sf.AddrFrame.Offset = *cast(uint*)(ctx.ptr + CTX_FP_OFF);
        sf.AddrStack.Offset = *cast(uint*)(ctx.ptr + CTX_SP_OFF);
    }
    sf.AddrPC.Mode    = AddrModeFlat;
    sf.AddrFrame.Mode = AddrModeFlat;
    sf.AddrStack.Mode = AddrModeFlat;

    auto hThread = getCurrentThread();
    size_t n = 0;

    // Skip internal frames (_d_createTrace + stack_walk64_capture + RtlCaptureContext)
    uint skip = 3;

    while (n < 32)
    {
        if (!_stack_walk64(MACHINE_TYPE, _dbg_process, hThread,
                &sf, ctx.ptr, null, _func_table_access64, _get_module_base64, null))
            break;
        if (sf.AddrPC.Offset == 0)
            break;
        if (skip > 0)
        {
            --skip;
            continue;
        }
        addrs[n++] = cast(void*) cast(size_t) sf.AddrPC.Offset;
    }
    return n;
}


// --- Driver interface -------------------------------------------------
//
// All three primitives assume they are called through a one-level public
// wrapper in urt.internal.exception (kept non-inlined via pragma(inline,
// false)). That wrapper's frame is accounted for in the skip counts
// below. Direct callers (like _d_createTrace) get the same semantics
// because their frame substitutes for the missing wrapper.

/// Capture the caller's call stack. First entry = return address of the
/// function that called the public `capture_trace` wrapper.
size_t _capture_trace(void*[] addrs) @trusted
{
    if (addrs.length == 0)
        return 0;
    auto count = cast(uint) addrs.length;
    // +2: skip _capture_trace itself + the public wrapper. addrs[0]
    // is then the PC inside USER (where USER called capture_trace).
    auto n = rtlCaptureStackBackTrace(2, count, addrs.ptr, null);
    if (n == 0 && addrs.length >= 32)
    {
        void*[32] scratch = void;
        auto k = stack_walk64_capture(scratch);
        auto copy = k < addrs.length ? k : addrs.length;
        addrs[0 .. copy] = scratch[0 .. copy];
        n = cast(ushort) copy;
    }
    return n;
}

/// Return the return address of the `skip`-th frame above the public
/// `caller_address` wrapper's caller. `skip=0` is the call site of
/// that caller - useful from inside an allocator to find the alloc
/// site.
void* _caller_address(uint skip) @trusted
{
    void* addr;
    // +3: skip _caller_address itself + public wrapper + USER's own
    // frame. With skip=0 the returned PC is in USER's caller - the
    // semantic the doc promises ("call site of the caller", useful for
    // allocation-site tracking).
    if (rtlCaptureStackBackTrace(skip + 3, 1, &addr, null) == 0)
        return null;
    return addr;
}

/// Resolve addr to symbol + optional file + line via DbgHelp.
/// Returned slices are owned by a static buffer - copy if you need
/// them across another call.
bool _resolve_address(void* addr, out Resolved r) @trusted
{
    import urt.mem : strlen;

    dbghelp_init();
    if (!_dbg_available)
        return false;

    static align(8) ubyte[SYMBOL_INFOA.sizeof + 256] sym_buf;
    sym_buf[] = 0;
    auto p_sym = cast(SYMBOL_INFOA*) sym_buf.ptr;
    p_sym.SizeOfStruct = SYMBOL_INFOA.sizeof;
    p_sym.MaxNameLen = 256;

    ulong disp;
    if (!_sym_from_addr(_dbg_process, cast(ulong) addr, &disp, p_sym))
        return false;
    r.name = p_sym.Name.ptr[0 .. strlen(p_sym.Name.ptr)];
    r.offset = cast(size_t) disp;

    uint disp32;
    IMAGEHLP_LINEA64 line_info;
    line_info.SizeOfStruct = IMAGEHLP_LINEA64.sizeof;
    if (_sym_get_line !is null &&
        _sym_get_line(_dbg_process, cast(ulong) addr, &disp32, &line_info))
    {
        r.file = line_info.FileName[0 .. strlen(line_info.FileName)];
        r.line = line_info.LineNumber;
    }
    return true;
}

/// Resolve many addresses. DbgHelp has no batch primitive - loop.
/// Returns false if DbgHelp is unavailable; otherwise true (individual
/// failed entries stay `Resolved.init` thanks to `out` auto-zeroing).
bool _resolve_batch(const(void*)[] addrs, Resolved[] results) @trusted
{
    dbghelp_init();
    if (!_dbg_available)
        return false;
    foreach (i, a; addrs)
        _resolve_address(cast(void*) a, results[i]);
    return true;
}

// ======================================================================
//  Exception-handling runtime (compiler-specific)
// ======================================================================

version (GDC)
{
    static assert(false, "GDC exception runtime not ported");
}
else version (LDC)
{

// ----------------------------------------------------------------------
// LDC MSVC SEH exception handling
// ----------------------------------------------------------------------


// --- Windows ABI types ---------------------------------------------------

private alias DWORD = uint;
private alias ULONG_PTR = size_t;

extern(Windows) void RaiseException(DWORD dwExceptionCode, DWORD dwExceptionFlags, DWORD nNumberOfArguments, ULONG_PTR* lpArguments);

// --- MSVC SEH structures -------------------------------------------------

// On Win64, type info pointers are 32-bit offsets from a heap base.
version (Win64)
    private struct ImgPtr(T) { uint offset; }
else
    private alias ImgPtr(T) = T*;

private alias PMFN = ImgPtr!(void function(void*));

private struct TypeDescriptor
{
    uint hash;
    void* spare;
    char[1] name; // variable-size, zero-terminated
}

private struct PMD
{
    int mdisp;
    int pdisp;
    int vdisp;
}

private struct CatchableType
{
    uint properties;
    ImgPtr!TypeDescriptor pType;
    PMD thisDisplacement;
    int sizeOrOffset;
    PMFN copyFunction;
}

private enum CT_IsSimpleType = 0x00000001;

private struct CatchableTypeArray
{
    int nCatchableTypes;
    ImgPtr!CatchableType[1] arrayOfCatchableTypes; // variable size
}

private struct _ThrowInfo
{
    uint attributes;
    PMFN pmfnUnwind;
    PMFN pForwardCompat;
    ImgPtr!CatchableTypeArray pCatchableTypeArray;
}

private struct CxxExceptionInfo
{
    size_t Magic;
    Throwable* pThrowable;
    _ThrowInfo* ThrowInfo;
    version (Win64) void* ImgBase;
}

private enum int STATUS_MSC_EXCEPTION = 0xe0000000 | ('m' << 16) | ('s' << 8) | ('c' << 0);
private enum EXCEPTION_NONCONTINUABLE = 0x01;
private enum EH_MAGIC_NUMBER1 = 0x19930520;


// --- EH Heap (image-relative pointer support) ----------------------------

version (Win64)
{
    private struct EHHeap
    {
    nothrow @nogc:

        void* base;
        size_t capacity;
        size_t length;

        void initialize(size_t initial_capacity)
        {
            import urt.mem : alloc;
            base = alloc(initial_capacity).ptr;
            capacity = initial_capacity;
            length = size_t.sizeof; // offset 0 reserved (null sentinel)
        }

        size_t alloc(size_t size)
        {
            import urt.mem : alloc, memcpy;
            auto offset = length;
            enum align_mask = size_t.sizeof - 1;
            auto new_length = (length + size + align_mask) & ~align_mask;
            auto new_capacity = capacity;
            while (new_length > new_capacity)
                new_capacity *= 2;
            if (new_capacity != capacity)
            {
                auto new_base = alloc(new_capacity).ptr;
                memcpy(new_base, base, length);
                // Old base leaks - may be referenced by in-flight exceptions.
                base = new_base;
                capacity = new_capacity;
            }
            length = new_length;
            return offset;
        }
    }

    private __gshared EHHeap _eh_heap;

    private ImgPtr!T eh_malloc(T)(size_t size = T.sizeof)
    {
        return ImgPtr!T(cast(uint) _eh_heap.alloc(size));
    }

    private T* to_pointer(T)(ImgPtr!T img_ptr)
    {
        return cast(T*)(cast(ubyte*) _eh_heap.base + img_ptr.offset);
    }
}
else // Win32
{
    private ImgPtr!T eh_malloc(T)(size_t size = T.sizeof)
    {
        import urt.mem : alloc;
        return cast(T*)alloc(size).ptr;
    }

    private T* to_pointer(T)(T* img_ptr)
    {
        return img_ptr;
    }
}


// --- ThrowInfo cache (simple linear-scan arrays) -------------------------
// No mutex - OpenWatt's exception paths are single-threaded.

private enum EH_CACHE_SIZE = 64;

private __gshared ClassInfo[EH_CACHE_SIZE] _throw_info_keys;
private __gshared ImgPtr!_ThrowInfo[EH_CACHE_SIZE] _throw_info_vals;
private __gshared size_t _throw_info_len;

private __gshared ClassInfo[EH_CACHE_SIZE] _catchable_keys;
private __gshared ImgPtr!CatchableType[EH_CACHE_SIZE] _catchable_vals;
private __gshared size_t _catchable_len;

private __gshared bool _eh_initialized;

private void ensure_eh_init()
{
    if (_eh_initialized)
        return;
    version (Win64)
        _eh_heap.initialize(0x10000);
    _eh_initialized = true;
}


// --- ThrowInfo generation ------------------------------------------------

private ImgPtr!CatchableType get_catchable_type(ClassInfo ti)
{
    import urt.mem : memcpy;

    foreach (i; 0 .. _catchable_len)
        if (_catchable_keys[i] is ti)
            return _catchable_vals[i];

    const sz = TypeDescriptor.sizeof + ti.name.length + 1;
    auto td = eh_malloc!TypeDescriptor(sz);
    auto ptd = td.to_pointer;

    ptd.hash = 0;
    ptd.spare = null;
    ptd.name.ptr[0] = 'D';
    memcpy(ptd.name.ptr + 1, ti.name.ptr, ti.name.length);
    ptd.name.ptr[ti.name.length + 1] = 0;

    auto ct = eh_malloc!CatchableType();
    ct.to_pointer[0] = CatchableType(
        CT_IsSimpleType, td, PMD(0, -1, 0),
        cast(int) size_t.sizeof, PMFN.init);

    if (_catchable_len < EH_CACHE_SIZE)
    {
        _catchable_keys[_catchable_len] = ti;
        _catchable_vals[_catchable_len] = ct;
        ++_catchable_len;
    }
    return ct;
}

private ImgPtr!_ThrowInfo get_throw_info(ClassInfo ti)
{
    foreach (i; 0 .. _throw_info_len)
        if (_throw_info_keys[i] is ti)
            return _throw_info_vals[i];

    int classes = 0;
    for (ClassInfo tic = ti; tic !is null; tic = tic.base)
        ++classes;

    const arr_size = int.sizeof + classes * ImgPtr!(CatchableType).sizeof;
    ImgPtr!CatchableTypeArray cta = eh_malloc!CatchableTypeArray(arr_size);
    to_pointer(cta).nCatchableTypes = classes;

    size_t c = 0;
    for (ClassInfo tic = ti; tic !is null; tic = tic.base)
        cta.to_pointer.arrayOfCatchableTypes.ptr[c++] = get_catchable_type(tic);

    auto tinf = eh_malloc!_ThrowInfo();
    *(tinf.to_pointer) = _ThrowInfo(0, PMFN.init, PMFN.init, cta);

    if (_throw_info_len < EH_CACHE_SIZE)
    {
        _throw_info_keys[_throw_info_len] = ti;
        _throw_info_vals[_throw_info_len] = tinf;
        ++_throw_info_len;
    }
    return tinf;
}


// --- Exception stack (thread-local) --------------------------------------

private struct ExceptionStack
{
nothrow @nogc:

    void push(Throwable e)
    {
        if (_length == _cap)
            grow();
        _p[_length++] = e;
    }

    Throwable pop()
    {
        return _p[--_length];
    }

    void shrink(size_t sz)
    {
        while (_length > sz)
            _p[--_length] = null;
    }

    ref inout(Throwable) opIndex(size_t idx) inout
    {
        return _p[idx];
    }

    size_t find(Throwable e)
    {
        for (size_t i = _length; i > 0;)
            if (_p[--i] is e)
                return i;
        return ~cast(size_t) 0;
    }

    @property size_t length() const { return _length; }

private:

    void grow()
    {
        import urt.mem : alloc, free, memcpy;
        immutable ncap = _cap ? 2 * _cap : 16;
        auto p = cast(Throwable*)alloc(ncap * size_t.sizeof).ptr;
        if (_length > 0)
            memcpy(p, _p, _length * size_t.sizeof);
        if (_p !is null)
            free((cast(void*)_p)[0 .. _cap * size_t.sizeof]);
        _p = p;
        _cap = ncap;
    }

    size_t _length;
    Throwable* _p;
    size_t _cap;
}

private ExceptionStack _exception_stack;


// --- Exception chaining --------------------------------------------------

private Throwable chain_exceptions(Throwable e, Throwable t)
{
    if (!cast(Error) e)
        if (auto err = cast(Error) t)
        {
            err.bypassedException = e;
            return err;
        }
    return Throwable.chainTogether(e, t);
}


// --- Core SEH API --------------------------------------------------------

extern(C) void _d_throw_exception(Throwable throwable)
{
    if (throwable is null || typeid(throwable) is null)
    {
        terminate();
        assert(0);
    }

    auto refcount = throwable.refcount();
    if (refcount)
        throwable.refcount() = refcount + 1;

    ensure_eh_init();

    _exception_stack.push(throwable);
    _d_createTrace(throwable, null);

    CxxExceptionInfo info;
    info.Magic = EH_MAGIC_NUMBER1;
    info.pThrowable = &throwable;
    info.ThrowInfo = get_throw_info(typeid(throwable)).to_pointer;
    version (Win64)
        info.ImgBase = _eh_heap.base;

    RaiseException(STATUS_MSC_EXCEPTION, EXCEPTION_NONCONTINUABLE,
        info.sizeof / size_t.sizeof, cast(ULONG_PTR*) &info);
}

extern(C) Throwable _d_eh_enter_catch(void* ptr, ClassInfo catch_type)
{
    if (ptr is null)
        return null;

    auto e = *(cast(Throwable*) ptr);
    size_t pos = _exception_stack.find(e);
    if (pos >= _exception_stack.length())
        return null; // not a D exception

    auto caught = e;

    // Chain inner unhandled exceptions as collateral
    for (size_t p = pos + 1; p < _exception_stack.length(); ++p)
        e = chain_exceptions(e, _exception_stack[p]);
    _exception_stack.shrink(pos);

    if (e !is caught)
    {
        if (_d_isbaseof(typeid(e), catch_type))
            *cast(Throwable*) ptr = e;
        else
            _d_throw_exception(e); // rethrow collateral
    }
    return e;
}

extern(C) bool _d_enter_cleanup(void* ptr) @trusted
{
    // Prevents LLVM from optimizing away cleanup (finally) blocks.
    return true;
}

extern(C) void _d_leave_cleanup(void* ptr) @trusted
{
}

} // version (LDC)
else version (Win32)
{

// ----------------------------------------------------------------------
// DMD Win32 SEH-based exception handling
// ----------------------------------------------------------------------


// ----------------------------------------------------------------------
// Win32 SEH-based exception handling
// ----------------------------------------------------------------------

// Windows types (inlined to avoid core.sys.windows dependency)
alias DWORD = uint;
alias BYTE = ubyte;
alias PVOID = void*;
alias ULONG_PTR = size_t;

enum size_t EXCEPTION_MAXIMUM_PARAMETERS = 15;
enum DWORD EXCEPTION_NONCONTINUABLE = 1;
enum EXCEPTION_UNWIND = 6;
enum EXCEPTION_COLLATERAL = 0x100;

enum DWORD STATUS_DIGITAL_MARS_D_EXCEPTION = (3 << 30) | (1 << 29) | (0 << 28) | ('D' << 16) | 1;

struct EXCEPTION_RECORD
{
    DWORD ExceptionCode;
    DWORD ExceptionFlags;
    EXCEPTION_RECORD* ExceptionRecord;
    PVOID ExceptionAddress;
    DWORD NumberParameters;
    ULONG_PTR[EXCEPTION_MAXIMUM_PARAMETERS] ExceptionInformation;
}

enum MAXIMUM_SUPPORTED_EXTENSION = 512;

struct FLOATING_SAVE_AREA
{
    DWORD ControlWord, StatusWord, TagWord;
    DWORD ErrorOffset, ErrorSelector;
    DWORD DataOffset, DataSelector;
    BYTE[80] RegisterArea;
    DWORD Cr0NpxState;
}

struct CONTEXT
{
    DWORD ContextFlags;
    DWORD Dr0, Dr1, Dr2, Dr3, Dr6, Dr7;
    FLOATING_SAVE_AREA FloatSave;
    DWORD SegGs, SegFs, SegEs, SegDs;
    DWORD Edi, Esi, Ebx, Edx, Ecx, Eax;
    DWORD Ebp, Eip, SegCs, EFlags, Esp, SegSs;
    BYTE[MAXIMUM_SUPPORTED_EXTENSION] ExtendedRegisters;
}

struct EXCEPTION_POINTERS
{
    EXCEPTION_RECORD* ExceptionRecord;
    CONTEXT* ContextRecord;
}

enum EXCEPTION_DISPOSITION
{
    ExceptionContinueExecution,
    ExceptionContinueSearch,
    ExceptionNestedException,
    ExceptionCollidedUnwind,
}

alias LanguageSpecificHandler = extern(C)
    EXCEPTION_DISPOSITION function(
        EXCEPTION_RECORD* exceptionRecord,
        DEstablisherFrame* frame,
        CONTEXT* context,
        void* dispatcherContext);

extern(Windows) void RaiseException(DWORD, DWORD, DWORD, void*);
extern(Windows) void RtlUnwind(void* targetFrame, void* targetIp, EXCEPTION_RECORD* pExceptRec, void* valueForEAX);

extern(C) extern __gshared DWORD _except_list; // FS:[0]

// Data structures - compiler-generated exception handler tables (Win32)

struct DEstablisherFrame
{
    DEstablisherFrame* prev;
    LanguageSpecificHandler handler;
    DWORD table_index;
    DWORD ebp;
}

struct DHandlerInfo
{
    int prev_index;
    uint cioffset;          // offset to DCatchInfo data from start of table
    void* finally_code;     // pointer to finally code (!=null if try-finally)
}

struct DHandlerTable
{
    void* fptr;             // pointer to start of function
    uint espoffset;
    uint retoffset;
    DHandlerInfo[1] handler_info;
}

struct DCatchBlock
{
    ClassInfo type;
    uint bpoffset;          // EBP offset of catch var
    void* code;             // catch handler code pointer
}

struct DCatchInfo
{
    uint ncatches;
    DCatchBlock[1] catch_block;
}

// InFlight exception list (per-stack, swapped on fiber switches)

EXCEPTION_RECORD* inflight_exception_list = null;

extern(C) void* _d_eh_swapContext(void* newContext)
{
    auto old = inflight_exception_list;
    inflight_exception_list = cast(EXCEPTION_RECORD*) newContext;
    return old;
}

private EXCEPTION_RECORD* skip_collateral_exceptions(EXCEPTION_RECORD* n) @trusted
{
    while (n.ExceptionRecord && n.ExceptionFlags & EXCEPTION_COLLATERAL)
        n = n.ExceptionRecord;
    return n;
}

// SEH to D exception translation

private Throwable _d_translate_se_to_d_exception(EXCEPTION_RECORD* exceptionRecord, CONTEXT*) @trusted
{
    if (exceptionRecord.ExceptionCode == STATUS_DIGITAL_MARS_D_EXCEPTION)
        return cast(Throwable) cast(void*)(exceptionRecord.ExceptionInformation[0]);

    // Non-D (hardware) exceptions: cannot create Error objects without GC.
    terminate();
    assert(0);
}

// _d_throwc - throw a D exception via Windows SEH

private void throw_impl(Throwable h) @trusted
{
    auto refcount = h.refcount();
    if (refcount)
        h.refcount() = refcount + 1;

    _d_createTrace(h, null);
    RaiseException(STATUS_DIGITAL_MARS_D_EXCEPTION, EXCEPTION_NONCONTINUABLE, 1, cast(void*)&h);
}

extern(C) void _d_throwc(Throwable h) @trusted
{
    version (D_InlineAsm_X86)
        asm @nogc nothrow
        {
            naked;
            enter 0, 0;
            mov EAX, [EBP + 8];
            call throw_impl;
            leave;
            ret;
        }
}

// _d_framehandler - SEH frame handler called by OS for each frame.
// The handler table address is passed in EAX by compiler-generated thunks.

extern(C) EXCEPTION_DISPOSITION _d_framehandler(
    EXCEPTION_RECORD* exceptionRecord,
    DEstablisherFrame* frame,
    CONTEXT* context,
    void* dispatcherContext) @trusted
{
    DHandlerTable* handler_table;
    asm @nogc nothrow { mov handler_table, EAX; }

    if (exceptionRecord.ExceptionFlags & EXCEPTION_UNWIND)
    {
        // Unwind phase: call all finally blocks in this frame
        _d_local_unwind(handler_table, frame, -1, &unwindCollisionExceptionHandler);
    }
    else
    {
        // Search phase: look for a matching catch handler

        EXCEPTION_RECORD* master = null;
        ClassInfo master_class_info = null;

        int prev_ndx;
        for (auto ndx = frame.table_index; ndx != -1; ndx = prev_ndx)
        {
            auto phi = &handler_table.handler_info.ptr[ndx];
            prev_ndx = phi.prev_index;

            if (phi.cioffset)
            {
                auto pci = cast(DCatchInfo*)(cast(ubyte*) handler_table + phi.cioffset);
                auto ncatches = pci.ncatches;

                foreach (i; 0 .. ncatches)
                {
                    auto pcb = &pci.catch_block.ptr[i];

                    // Walk the collateral exception chain to find the master
                    EXCEPTION_RECORD* er = exceptionRecord;
                    master = null;
                    master_class_info = null;

                    for (;;)
                    {
                        if (er.ExceptionCode == STATUS_DIGITAL_MARS_D_EXCEPTION)
                        {
                            ClassInfo ci = (**(cast(ClassInfo**)(er.ExceptionInformation[0])));
                            if (!master && !(er.ExceptionFlags & EXCEPTION_COLLATERAL))
                            {
                                master = er;
                                master_class_info = ci;
                                break;
                            }
                            if (_d_isbaseof(ci, typeid(Error)))
                            {
                                master = er;
                                master_class_info = ci;
                            }
                        }
                        else
                        {
                            // Non-D exception - cannot translate without GC
                            terminate();
                        }

                        if (!(er.ExceptionFlags & EXCEPTION_COLLATERAL))
                            break;

                        if (er.ExceptionRecord)
                            er = er.ExceptionRecord;
                        else
                            er = inflight_exception_list;
                    }

                    if (_d_isbaseof(master_class_info, pcb.type))
                    {
                        // Found matching catch handler

                        auto original_exception = skip_collateral_exceptions(exceptionRecord);
                        if (original_exception.ExceptionRecord is null
                            && !(exceptionRecord is inflight_exception_list))
                            original_exception.ExceptionRecord = inflight_exception_list;
                        inflight_exception_list = exceptionRecord;

                        // Global unwind: call finally blocks in intervening frames
                        _d_global_unwind(frame, exceptionRecord);

                        // Local unwind: call finally blocks skipped in this frame
                        _d_local_unwind(handler_table, frame, ndx,
                            &searchCollisionExceptionHandler);

                        frame.table_index = prev_ndx;

                        // Build D exception chain from SEH records
                        EXCEPTION_RECORD* z = exceptionRecord;
                        Throwable prev = null;
                        Error master_error = null;

                        for (;;)
                        {
                            Throwable w = _d_translate_se_to_d_exception(z, context);
                            if (z == master && (z.ExceptionFlags & EXCEPTION_COLLATERAL))
                                master_error = cast(Error) w;
                            prev = Throwable.chainTogether(w, prev);
                            if (!(z.ExceptionFlags & EXCEPTION_COLLATERAL))
                                break;
                            z = z.ExceptionRecord;
                        }

                        Throwable pti;
                        if (master_error)
                        {
                            master_error.bypassedException = prev;
                            pti = master_error;
                        }
                        else
                            pti = prev;

                        inflight_exception_list = z.ExceptionRecord;

                        // Initialize catch variable and jump to handler
                        int regebp = cast(int)&frame.ebp;
                        *cast(Object*)(regebp + pcb.bpoffset) = pti;

                        {
                            uint catch_esp;
                            alias fp_t = void function();
                            fp_t catch_addr = cast(fp_t) pcb.code;
                            catch_esp = regebp - handler_table.espoffset - fp_t.sizeof;
                            asm @nogc nothrow
                            {
                                mov EAX, catch_esp;
                                mov ECX, catch_addr;
                                mov [EAX], ECX;
                                mov EBP, regebp;
                                mov ESP, EAX;
                                ret;
                            }
                        }
                    }
                }
            }
        }
    }
    return EXCEPTION_DISPOSITION.ExceptionContinueSearch;
}

// Exception filter for __try/__except around Dmain

extern(C) int _d_exception_filter(EXCEPTION_POINTERS* eptrs, int retval, Object* exception_object) @trusted
{
    *exception_object = _d_translate_se_to_d_exception(eptrs.ExceptionRecord, eptrs.ContextRecord);
    return retval;
}

// Collision exception handlers

extern(C) EXCEPTION_DISPOSITION searchCollisionExceptionHandler(
    EXCEPTION_RECORD* exceptionRecord,
    DEstablisherFrame*,
    CONTEXT*,
    void* dispatcherContext) @trusted
{
    if (!(exceptionRecord.ExceptionFlags & EXCEPTION_UNWIND))
    {
        auto n = skip_collateral_exceptions(exceptionRecord);
        n.ExceptionFlags |= EXCEPTION_COLLATERAL;
        return EXCEPTION_DISPOSITION.ExceptionContinueSearch;
    }
    // Collision during SEARCH phase - restart from 'frame'
    *(cast(void**) dispatcherContext) = dispatcherContext; // frame
    return EXCEPTION_DISPOSITION.ExceptionCollidedUnwind;
}

extern(C) EXCEPTION_DISPOSITION unwindCollisionExceptionHandler(
    EXCEPTION_RECORD* exceptionRecord,
    DEstablisherFrame* frame,
    CONTEXT*,
    void* dispatcherContext) @trusted
{
    if (!(exceptionRecord.ExceptionFlags & EXCEPTION_UNWIND))
    {
        auto n = skip_collateral_exceptions(exceptionRecord);
        n.ExceptionFlags |= EXCEPTION_COLLATERAL;
        return EXCEPTION_DISPOSITION.ExceptionContinueSearch;
    }
    // Collision during UNWIND phase - restart from 'frame.prev'
    *(cast(void**) dispatcherContext) = frame.prev;
    return EXCEPTION_DISPOSITION.ExceptionCollidedUnwind;
}

// Local unwind - run finally blocks in the current frame

extern(C) void _d_local_unwind(DHandlerTable* handler_table, DEstablisherFrame* frame, int stop_index, LanguageSpecificHandler collision_handler) @trusted
{
    // Install collision handler on SEH chain
    asm @nogc nothrow
    {
        push dword ptr -1;
        push dword ptr 0;
        push collision_handler;
        push dword ptr FS:_except_list;
        mov FS:_except_list, ESP;
    }

    for (auto i = frame.table_index; i != -1 && i != stop_index;)
    {
        auto phi = &handler_table.handler_info.ptr[i];
        i = phi.prev_index;

        if (phi.finally_code)
        {
            auto catch_ebp = &frame.ebp;
            auto blockaddr = phi.finally_code;
            asm @nogc nothrow
            {
                push EBX;
                mov EBX, blockaddr;
                push EBP;
                mov EBP, catch_ebp;
                call EBX;
                pop EBP;
                pop EBX;
            }
        }
    }

    // Remove collision handler from SEH chain
    asm @nogc nothrow
    {
        pop FS:_except_list;
        add ESP, 12;
    }
}

// Global unwind - thin wrapper around RtlUnwind

extern(C) int _d_global_unwind(DEstablisherFrame* pFrame, EXCEPTION_RECORD* eRecord) @trusted
{
    asm @nogc nothrow
    {
        naked;
        push EBP;
        mov EBP, ESP;
        push ECX;
        push EBX;
        push ESI;
        push EDI;
        push EBP;
        push 0;
        push dword ptr 12[EBP]; // eRecord
        call __system_unwind;
        jmp __unwind_exit;
    __system_unwind:
        push dword ptr 8[EBP];  // pFrame
        call RtlUnwind;
    __unwind_exit:
        pop EBP;
        pop EDI;
        pop ESI;
        pop EBX;
        pop ECX;
        mov ESP, EBP;
        pop EBP;
        ret;
    }
}

// Local unwind for goto/return across finally blocks

extern(C) void _d_local_unwind2() @trusted
{
    asm @nogc nothrow
    {
        naked;
        jmp _d_localUnwindForGoto;
    }
}

extern(C) void _d_localUnwindForGoto(DHandlerTable* handler_table, DEstablisherFrame* frame, int stop_index) @trusted
{
    _d_local_unwind(handler_table, frame, stop_index, &searchCollisionExceptionHandler);
}

// Monitor handler stubs (for synchronized blocks)

extern(C) EXCEPTION_DISPOSITION _d_monitor_handler(EXCEPTION_RECORD* exceptionRecord, DEstablisherFrame*, CONTEXT*, void*) @trusted
{
    if (exceptionRecord.ExceptionFlags & EXCEPTION_UNWIND)
    {
        // TODO: _d_monitorexit(cast(Object)cast(void*)frame.table_index);
    }
    return EXCEPTION_DISPOSITION.ExceptionContinueSearch;
}

extern(C) void _d_monitor_prolog(void*, void*, Object) @trusted
{
    // TODO: _d_monitorenter(h);
}

extern(C) void _d_monitor_epilog(void*, void*, Object) @trusted
{
    // TODO: _d_monitorexit(h);
}



} // version (Win32)
else version (Win64)
{

// ----------------------------------------------------------------------
// DMD Win64 - RBP-chain walking with ._deh section tables
// ----------------------------------------------------------------------


// ----------------------------------------------------------------------
// Win64 - RBP-chain walking with ._deh section tables
// ----------------------------------------------------------------------

// Data structures - compiler-generated exception handler tables

struct DHandlerInfo
{
    uint offset;            // offset from function address to start of guarded section
    uint endoffset;         // offset of end of guarded section
    int prev_index;         // previous table index
    uint cioffset;          // offset to DCatchInfo data from start of table (!=0 if try-catch)
    size_t finally_offset;  // offset to finally code to execute (!=0 if try-finally)
}

struct DHandlerTable
{
    uint espoffset;         // offset of ESP from EBP
    uint retoffset;         // offset from start of function to return code
    size_t nhandlers;       // dimension of handler_info[]
    DHandlerInfo[1] handler_info;
}

struct DCatchBlock
{
    ClassInfo type;         // catch type
    size_t bpoffset;        // EBP offset of catch var
    size_t codeoffset;      // catch handler offset
}

struct DCatchInfo
{
    size_t ncatches;        // number of catch blocks
    DCatchBlock[1] catch_block;
}

struct FuncTable
{
    void* fptr;             // pointer to start of function
    DHandlerTable* handlertable;
    uint fsize;             // size of function in bytes
}

// InFlight exception tracking (per-stack, swapped on fiber switches)

private struct InFlight
{
    InFlight* next;
    void* addr;
    Throwable t;
}

private __gshared InFlight* __inflight = null;

extern(C) void* _d_eh_swapContext(void* newContext)
{
    auto old = __inflight;
    __inflight = cast(InFlight*) newContext;
    return old;
}

// DEH section scanning - find exception handler tables in the binary

version (Windows)
    extern(C) extern __gshared ubyte __ImageBase;

private __gshared immutable(FuncTable)* _deh_start;
private __gshared immutable(FuncTable)* _deh_end;

private void ensure_deh_loaded() @trusted
{
    if (_deh_start !is null)
        return;

    version (Windows)
    {
        auto section = find_pe_section(cast(void*) &__ImageBase, "._deh\0\0\0");
        if (section.length)
        {
            _deh_start = cast(immutable(FuncTable)*) section.ptr;
            _deh_end = cast(immutable(FuncTable)*)(section.ptr + section.length);
        }
    }
    else version (linux)
    {
        // TODO: ELF section scanning for .deh
    }
}

/// PE section lookup - duplicated from urt.package to avoid import cycle.
private void[] find_pe_section(void* imageBase, string name) @trusted
{
    if (name.length > 8)
        return null;

    auto base = cast(ubyte*) imageBase;
    if (base[0] != 0x4D || base[1] != 0x5A)
        return null;

    auto lfanew = *cast(int*)(base + 0x3C);
    auto pe = base + lfanew;
    if (pe[0] != 'P' || pe[1] != 'E' || pe[2] != 0 || pe[3] != 0)
        return null;

    auto fileHeader = pe + 4;
    ushort numSections = *cast(ushort*)(fileHeader + 2);
    ushort optHeaderSize = *cast(ushort*)(fileHeader + 16);
    auto sections = fileHeader + 20 + optHeaderSize;

    foreach (i; 0 .. numSections)
    {
        auto sec = sections + i * 40;
        auto secName = (cast(char*) sec)[0 .. 8];
        bool match = true;
        foreach (j; 0 .. 8)
        {
            if (secName[j] != name[j])
            {
                match = false;
                break;
            }
        }
        if (match)
        {
            auto virtualSize = *cast(uint*)(sec + 8);
            auto virtualAddress = *cast(uint*)(sec + 12);
            return (base + virtualAddress)[0 .. virtualSize];
        }
    }
    return null;
}

// Handler table lookup

immutable(FuncTable)* __eh_finddata(void* address) @trusted
{
    ensure_deh_loaded();
    if (_deh_start is null)
        return null;
    return __eh_finddata_range(address, _deh_start, _deh_end);
}

immutable(FuncTable)* __eh_finddata_range(void* address, immutable(FuncTable)* pstart, immutable(FuncTable)* pend) @trusted
{
    for (auto ft = pstart; ; ft++)
    {
    Lagain:
        if (ft >= pend)
            break;

        version (Win64)
        {
            // MS Linker sometimes inserts zero padding between .obj sections
            if (ft.fptr == null)
            {
                ft = cast(immutable(FuncTable)*)(cast(void**) ft + 1);
                goto Lagain;
            }
        }

        immutable(void)* fptr = ft.fptr;
        version (Win64)
        {
            // Follow JMP indirection from /DEBUG linker
            if ((cast(ubyte*) fptr)[0] == 0xE9)
                fptr = fptr + 5 + *cast(int*)(fptr + 1);
        }

        if (fptr <= address && address < cast(void*)(cast(char*) fptr + ft.fsize))
            return ft;
    }
    return null;
}

// Stack frame walking

size_t __eh_find_caller(size_t regbp, size_t* pretaddr) @trusted
{
    size_t bp = *cast(size_t*) regbp;

    if (bp)
    {
        // Stack grows downward - new BP must be above old
        if (bp <= regbp)
            terminate();

        *pretaddr = *cast(size_t*)(regbp + size_t.sizeof);
    }
    return bp;
}

// _d_throwc - the core throw implementation (RBP-chain walking)

alias fp_t = int function();

extern(C) void _d_throwc(Throwable h) @trusted
{
    size_t regebp;

    version (D_InlineAsm_X86)
        asm nothrow @nogc { mov regebp, EBP; }
    else version (D_InlineAsm_X86_64)
        asm nothrow @nogc { mov regebp, RBP; }

    // Increment reference count if refcounted
    auto refcount = h.refcount();
    if (refcount)
        h.refcount() = refcount + 1;

    _d_createTrace(h, null);

    while (1)
    {
        size_t retaddr;

        regebp = __eh_find_caller(regebp, &retaddr);
        if (!regebp)
            break;

        auto func_table = __eh_finddata(cast(void*) retaddr);
        auto handler_table = func_table ? func_table.handlertable : null;
        if (!handler_table)
            continue;

        auto funcoffset = cast(size_t) func_table.fptr;
        version (Win64)
        {
            // Follow JMP indirection from /DEBUG linker
            if ((cast(ubyte*) funcoffset)[0] == 0xE9)
                funcoffset = funcoffset + 5 + *cast(int*)(funcoffset + 1);
        }

        // Find start index for retaddr in handler table
        auto dim = handler_table.nhandlers;
        auto index = -1;
        for (uint i = 0; i < dim; i++)
        {
            auto phi = &handler_table.handler_info.ptr[i];
            if (retaddr > funcoffset + phi.offset &&
                retaddr <= funcoffset + phi.endoffset)
                index = i;
        }

        // Handle inflight exception chaining
        if (dim)
        {
            auto phi = &handler_table.handler_info.ptr[index + 1];
            auto prev = cast(InFlight*) &__inflight;
            auto curr = prev.next;

            if (curr !is null && curr.addr == cast(void*)(funcoffset + phi.finally_offset))
            {
                auto e = cast(Error) h;
                if (e !is null && (cast(Error) curr.t) is null)
                {
                    e.bypassedException = curr.t;
                    prev.next = curr.next;
                }
                else
                {
                    h = Throwable.chainTogether(curr.t, h);
                    prev.next = curr.next;
                }
            }
        }

        // Walk handler table entries
        int prev_ndx;
        for (auto ndx = index; ndx != -1; ndx = prev_ndx)
        {
            auto phi = &handler_table.handler_info.ptr[ndx];
            prev_ndx = phi.prev_index;

            if (phi.cioffset)
            {
                // Catch handler
                auto pci = cast(DCatchInfo*)(cast(char*) handler_table + phi.cioffset);
                auto ncatches = pci.ncatches;

                for (uint i = 0; i < ncatches; i++)
                {
                    auto ci = **cast(ClassInfo**) h;
                    auto pcb = &pci.catch_block.ptr[i];

                    if (_d_isbaseof(ci, pcb.type))
                    {
                        // Initialize catch variable
                        *cast(void**)(regebp + pcb.bpoffset) = cast(void*) h;

                        // Jump to catch block - does not return
                        {
                            size_t catch_esp;
                            fp_t catch_addr;

                            catch_addr = cast(fp_t)(funcoffset + pcb.codeoffset);
                            catch_esp = regebp - handler_table.espoffset - fp_t.sizeof;

                            version (D_InlineAsm_X86)
                                asm nothrow @nogc
                                {
                                    mov EAX, catch_esp;
                                    mov ECX, catch_addr;
                                    mov [EAX], ECX;
                                    mov EBP, regebp;
                                    mov ESP, EAX;
                                    ret;
                                }
                            else version (D_InlineAsm_X86_64)
                                asm nothrow @nogc
                                {
                                    mov RAX, catch_esp;
                                    mov RCX, catch_esp;
                                    mov RCX, catch_addr;
                                    mov [RAX], RCX;
                                    mov RBP, regebp;
                                    mov RSP, RAX;
                                    ret;
                                }
                        }
                    }
                }
            }
            else if (phi.finally_offset)
            {
                // Finally block
                auto blockaddr = cast(void*)(funcoffset + phi.finally_offset);
                InFlight inflight;

                inflight.addr = blockaddr;
                inflight.next = __inflight;
                inflight.t = h;
                __inflight = &inflight;

                version (D_InlineAsm_X86)
                    asm nothrow @nogc
                    {
                        push EBX;
                        mov EBX, blockaddr;
                        push EBP;
                        mov EBP, regebp;
                        call EBX;
                        pop EBP;
                        pop EBX;
                    }
                else version (D_InlineAsm_X86_64)
                    asm nothrow @nogc
                    {
                        sub RSP, 8;
                        push RBX;
                        mov RBX, blockaddr;
                        push RBP;
                        mov RBP, regebp;
                        call RBX;
                        pop RBP;
                        pop RBX;
                        add RSP, 8;
                    }

                if (__inflight is &inflight)
                    __inflight = __inflight.next;
            }
        }
    }
    terminate();
}


} // version (Win64)
