module urt.internal.exception;

version (Windows)
    import urt.driver.windows.exception : _capture_trace, _caller_address, _resolve_address, _resolve_batch;
else version (Espressif)
    import urt.driver.esp32.exception : _capture_trace, _caller_address, _resolve_address, _resolve_batch;
else version (BareMetal)
    import urt.driver.baremetal.exception : _capture_trace, _caller_address, _resolve_address, _resolve_batch;
else
    import urt.driver.posix.exception : _capture_trace, _caller_address, _resolve_address, _resolve_batch;

nothrow @nogc:


// Public API

// Resolved symbol information for a single return address. Fields are
// best-effort - any of them may be empty/zero if the driver can't
// supply them (no on-device symtab, stripped binary, missing DWARF).
// `name` is the raw symbol as the driver sees it - possibly D-mangled
// (`_D...`); pass through `demangle_symbol` before display.
// String slices are owned by driver static/TLS storage - copy before
// the next `_resolve_address`/`_resolve_batch` call.
struct Resolved
{
    const(char)[] name;
    const(char)[] file;
    const(char)[] dir;
    uint   line;
    size_t offset;  // addr - symbol_base
}

// TCO-defeat anchor. Any wrapper that MUST be a real frame at runtime
// (because the fp walker is counting frames) calls defeat_tco() between
// the inner call and the return. A volatile write LLVM can't prove dead
// blocks both tail-call optimisation and prologue/frame elision.
private __gshared uint _tco_anchor;

pragma(inline, false)
void defeat_tco() @trusted nothrow @nogc
{
    import core.volatile : volatileLoad, volatileStore;
    volatileStore(&_tco_anchor, volatileLoad(&_tco_anchor) + 1);
}

pragma(inline, false)
size_t capture_trace(void*[] addrs) @trusted
{
    auto r = _capture_trace(addrs);
    defeat_tco();
    return r;
}

pragma(inline, false)
void* caller_address(uint skip = 0) @trusted
{
    auto r = _caller_address(skip);
    defeat_tco();
    return r;
}

bool resolve_address(void* addr, out Resolved r) @trusted
{
    return _resolve_address(addr, r);
}

bool resolve_batch(const(void*)[] addrs, Resolved[] results) @trusted
{
    assert(addrs.length == results.length);
    return _resolve_batch(addrs, results);
}

version (Tiny)
{
    const(char)[] demangle_symbol(const(char)[] mangled, char[]) @trusted
        => mangled;
}
else
{
    const(char)[] demangle_symbol(const(char)[] mangled, char[] buf) @trusted
    {
        import urt.array : beginsWith;
        import urt.conv : parse_uint;
        import urt.mem : memcpy;

        if (mangled.length < 3 || !mangled.beginsWith("_D"))
            return mangled;

        auto src = mangled[2 .. $];
        size_t pos = 0;
        bool first = true;

        while (src.length > 0)
        {
            auto ch = src[0];

            if (ch >= '1' && ch <= '9')
            {
                // LName: decimal length followed by that many characters
                size_t taken;
                size_t len = cast(size_t) parse_uint(src, &taken);
                src = src[taken .. $];
                if (len > src.length || pos + len + 1 > buf.length)
                    break;

                if (!first)
                    buf[pos++] = '.';
                first = false;

                buf[pos .. pos + len] = src[0 .. len];
                pos += len;
                src = src[len .. $];
            }
            else if (ch == 'Q')
            {
                // Back reference: base-26 offset pointing to an earlier LName.
                auto q_pos = cast(size_t)(src.ptr - mangled.ptr);
                src = src[1 .. $];

                size_t ref_val = 0;
                while (src.length > 0 && src[0] >= 'A' && src[0] <= 'Z')
                {
                    ref_val = ref_val * 26 + (src[0] - 'A');
                    src = src[1 .. $];
                }
                if (src.length > 0 && src[0] >= 'a' && src[0] <= 'z')
                {
                    ref_val = ref_val * 26 + (src[0] - 'a');
                    src = src[1 .. $];
                }
                else
                    break; // malformed

                if (ref_val >= q_pos)
                    break;
                auto target = mangled[q_pos - ref_val .. $];
                if (target.length == 0 || target[0] < '1' || target[0] > '9')
                    break;

                size_t taken;
                size_t len = cast(size_t) parse_uint(target, &taken);
                target = target[taken .. $];
                if (len > target.length || pos + len + 1 > buf.length)
                    break;

                if (!first)
                    buf[pos++] = '.';
                first = false;

                buf[pos .. pos + len] = target[0 .. len];
                pos += len;
            }
            else if (ch == '_' && src.length >= 3 && src[1] == '_' && (src[2] == 'T' || src[2] == 'U'))
            {
                // Template instance __T/__U: extract name, skip args until Z
                src = src[3 .. $];

                if (src.length > 0 && src[0] >= '1' && src[0] <= '9')
                {
                    size_t taken;
                    size_t len = cast(size_t) parse_uint(src, &taken);
                    src = src[taken .. $];
                    if (len <= src.length && pos + len + 1 <= buf.length)
                    {
                        if (!first)
                            buf[pos++] = '.';
                        first = false;

                        buf[pos .. pos + len] = src[0 .. len];
                        pos += len;
                        src = src[len .. $];
                    }
                }

                int depth = 1;
                while (src.length > 0 && depth > 0)
                {
                    if (src[0] == 'Z')
                        --depth;
                    else if (src.length >= 3 && src[0] == '_' && src[1] == '_' && (src[2] == 'T' || src[2] == 'U'))
                    {
                        ++depth;
                        src = src[2 .. $];
                    }
                    src = src[1 .. $];
                }
            }
            else if (ch == '0')
                src = src[1 .. $]; // anonymous - skip
            else
                break; // type signature - done
        }

        if (pos == 0)
            return mangled;

        // Append $TypeSignature if there's anything left
        if (src.length > 0 && pos + 1 + src.length <= buf.length)
        {
            buf[pos++] = '$';
            buf[pos .. pos + src.length] = src[];
            pos += src.length;
        }

        return buf[0 .. pos];
    }
}

// Print a captured trace to stderr.
//
// formats each frame as: `{dir}/{file}:{line} {name}+0x{offset} [0x{address}]`
// with graceful degradation:
//     file:line missing   → `??:?`
//     symbol missing      → drop the `name+0x...` component
//     nothing resolved    → `    0x{address}` only
// Stops after emitting `_Dmain` / `main` to hide C runtime tail noise.
version (Tiny)
{
    void print_trace(const(void*)[] addrs) @trusted
    {
        import urt.io : writef_to, WriteTarget;

        enum addr_fmt = size_t.sizeof == 4 ? "08x" : "016x";
        foreach (addr; addrs)
            writef_to!(WriteTarget.stderr, true)("    0x{0:" ~ addr_fmt ~ "}", cast(size_t) addr);
    }
}
else
{
    void print_trace(const(void*)[] addrs) @trusted
    {
        import urt.io : write_err, writef_to, WriteTarget;
        import urt.string : endsWith;

        if (addrs.length == 0)
            return;

        const n = addrs.length > max_frames ? max_frames : addrs.length;

        Resolved[max_frames] results;
        const have_symbols = _resolve_batch(addrs[0 .. n], results[0 .. n]);

        enum addr_fmt = size_t.sizeof == 4 ? "08x" : "016x";

        if (!have_symbols)
        {
            foreach (addr; addrs[0 .. n])
                writef_to!(WriteTarget.stderr, true)("    0x{0:" ~ addr_fmt ~ "}", cast(size_t) addr);
            return;
        }

        // Skip internal throw machinery - start after the last matching frame. Matches LDC druntime behavior.
        size_t start = 0;
        foreach (i; 0 .. n)
        {
            auto name = results[i].name;
            if (name.endsWith("_d_throw_exception") || name.endsWith("_d_throwdwarf"))
                start = i + 1;
        }

        foreach (i; start .. n)
        {
            auto addr = addrs[i];
            auto r = &results[i];
            const bool have_any = r.name.length > 0 || r.line > 0;

            if (!have_any)
            {
                writef_to!(WriteTarget.stderr, true)("    0x{0:" ~ addr_fmt ~ "}", cast(size_t) addr);
                continue;
            }

            // file:line (or ??:? when missing)
            if (r.line > 0 && r.file.length > 0)
            {
                if (r.dir.length > 0)
                {
                    const sep = (r.dir[$ - 1] == '/' || r.dir[$ - 1] == '\\') ? "" : "/";
                    writef_to!(WriteTarget.stderr, false)("    {0}{1}{2}:{3}", r.dir, sep, r.file, r.line);
                }
                else
                    writef_to!(WriteTarget.stderr, false)("    {0}:{1}", r.file, r.line);
            }
            else
                write_err("    ??:?");

            // symbol+offset (demangled)
            if (r.name.length > 0)
            {
                char[512] dbuf = void;
                auto dname = demangle_symbol(r.name, dbuf);
                writef_to!(WriteTarget.stderr, false)(" {0}+0x{1:x}", dname, r.offset);
            }

            writef_to!(WriteTarget.stderr, true)(" [0x{0:" ~ addr_fmt ~ "}]", cast(size_t) addr);

            // Stop at program entry - hides C runtime tail noise.
            if (r.name == "_Dmain" || r.name == "main")
                break;
        }
    }
}

public void terminate() @trusted
{
    import urt.io : writeln_err;
    writeln_err("Unhandled exception -- no catch handler found, terminating.");

    if (_tls_trace.length > 0)
    {
        writeln_err("  stack trace:");
        print_trace(_tls_trace.addrs[0 .. _tls_trace.length]);
    }

    import urt.internal.stdc.stdlib : abort;
    abort();
}


// Shared state

enum max_frames = 32;

struct StackTraceData
{
    void*[max_frames] addrs;
    ubyte length;
}

private StackTraceData _tls_trace;  // static = TLS in D


// Druntime hooks (extern(C), linker-visible)

alias ClassInfo = TypeInfo_Class;

extern(C) int _d_isbaseof(scope ClassInfo oc, scope const ClassInfo c) pure @trusted
{
    if (oc is c)
        return true;

    do
    {
        if (oc.base is c)
            return true;

        foreach (iface; oc.interfaces)
        {
            if (iface.classinfo is c || _d_isbaseof(iface.classinfo, c))
                return true;
        }

        oc = oc.base;
    }
    while (oc);

    return false;
}


extern(C) void _d_createTrace(Throwable, void*) @trusted
{
    debug
        _tls_trace.length = cast(ubyte) _capture_trace(_tls_trace.addrs[]);
}

extern(C) void _d_printLastTrace(Throwable t) @trusted
{
    debug
    {
        import urt.io : writeln_err, writef_to, WriteTarget;

        if (_tls_trace.length == 0)
            return;

        if (t !is null)
        {
            auto msg = t.msg;
            writef_to!(WriteTarget.stderr, true)("Exception: {0}", msg);
        }

        writeln_err("  stack trace:");
        print_trace(_tls_trace.addrs[0 .. _tls_trace.length]);
    }
}


version (unittest)
{
    private bool eh_contains(const(char)[] haystack, const(char)[] needle) @trusted nothrow @nogc
    {
        if (needle.length == 0)
            return true;
        if (needle.length > haystack.length)
            return false;
        foreach (i; 0 .. haystack.length - needle.length + 1)
            if (haystack[i .. i + needle.length] == needle)
                return true;
        return false;
    }

    // Skip-count verification layers. Each calls defeat_tco() between the
    // inner call and the return so LDC keeps the frame instead of tail-
    // calling. Distinct, grep-friendly names make the resolved symbols
    // easy to match.

    private void* eh_ca_layer_0(uint skip) @trusted nothrow @nogc
    {
        auto pc = caller_address(skip);
        defeat_tco();
        return pc;
    }

    private void* eh_ca_layer_1(uint skip) @trusted nothrow @nogc
    {
        auto pc = eh_ca_layer_0(skip);
        defeat_tco();
        return pc;
    }

    private void* eh_ca_layer_2(uint skip) @trusted nothrow @nogc
    {
        auto pc = eh_ca_layer_1(skip);
        defeat_tco();
        return pc;
    }

    // Demangler target - `.mangleof` gives us the real D-mangled form at
    // compile time, so the test is stable across compilers.
    private void eh_demangle_target() @trusted nothrow @nogc {}

    // Helper: this unittest function is what we expect to find as the
    // caller in the capture_trace and skip-count tests below. defeat_tco
    // keeps eh_capture_here as a real frame so the walker captures
    // capture_trace's saved ra (= a PC inside eh_capture_here) as buf[0].
    private size_t eh_capture_here(void*[] buf) @trusted nothrow @nogc
    {
        auto n = capture_trace(buf);
        defeat_tco();
        return n;
    }
}

unittest
{
    // capture_trace produces a non-empty trace whose first frame
    // is in the function that called it (eh_capture_here).

    void*[max_frames] buf;
    auto n = eh_capture_here(buf[]);
    assert(n > 0);
    foreach (addr; buf[0 .. n])
        assert(addr !is null);

    // First captured frame should resolve to the immediate caller -
    // eh_capture_here. (Skipped on platforms with no symbol table.)
    Resolved r;
    if (resolve_address(buf[0], r))
    {
        char[512] dbuf;
        auto name = demangle_symbol(r.name, dbuf);
        assert(eh_contains(name, "eh_capture_here"), name);
    }

    // caller_address skip walks one frame per increment, starting
    // from the caller of the function that called caller_address.

    // From eh_ca_layer_0:
    //   skip=0 → PC inside eh_ca_layer_1  (layer_0's caller)
    //   skip=1 → PC inside eh_ca_layer_2  (layer_1's caller)
    //   skip=2 → PC inside this unittest  (layer_2's caller)
    auto pc0 = eh_ca_layer_2(0);
    auto pc1 = eh_ca_layer_2(1);
    auto pc2 = eh_ca_layer_2(2);

    assert(pc0 !is null);
    assert(pc1 !is null);
    assert(pc2 !is null);

    // Distinct PCs - each skip level yields a different call site.
    assert(pc0 != pc1);
    assert(pc1 != pc2);
    assert(pc0 != pc2);

    // Strong check via the symbol resolver. Bare-metal / ESP32 have no
    // on-device symtab and silently skip - the distinct-PC check above
    // is the strongest assertion they can verify.
    char[512] name;

    if (resolve_address(pc0, r))
    {
        auto mangle = demangle_symbol(r.name, name);
        assert(eh_contains(mangle, "eh_ca_layer_1"), mangle);
    }
    if (resolve_address(pc1, r))
    {
        auto mangle = demangle_symbol(r.name, name);
        assert(eh_contains(mangle, "eh_ca_layer_2"), mangle);
    }

    // demangler

    // Non-D / degenerate inputs pass through unchanged. This holds for both
    // the real demangler and the Tiny stub (which returns input unchanged
    // for everything), so these asserts always run.
    assert(demangle_symbol("main", name) == "main");
    assert(demangle_symbol("", name) == "");
    assert(demangle_symbol("_D", name) == "_D");
    assert(demangle_symbol("?MyClass@@QAEXXZ", name) == "?MyClass@@QAEXXZ");

    // Real demangling tests -- skipped on Tiny because the stub there just
    // returns input unchanged (size optimisation; offline addr2line gives
    // the symbol name anyway).
    version (Tiny) {}
    else
    {
        // Real D mangling via .mangleof - qualified path must contain the
        // function name and at least one module-separator dot.
        auto dem = demangle_symbol(eh_demangle_target.mangleof, name);
        assert(eh_contains(dem, "eh_demangle_target"), dem);
        bool has_dot = false;
        foreach (c; dem) if (c == '.')
        {
            has_dot = true;
            break;
        }
        assert(has_dot, dem);

        // Hand-crafted ABI-compliant manglings - parse must recover the
        // qualified name prefix regardless of the trailing type signature.
        assert(eh_contains(demangle_symbol("_D3foo3barFZv", name), "foo.bar"));
        assert(eh_contains(demangle_symbol("_D3foo3bar3bazFZv", name), "foo.bar.baz"));

        // Malformed input must not crash - output is undefined but safe.
        demangle_symbol("_D999zzz", name);      // LName length overflows src
        demangle_symbol("_D3fooQ", name);       // Q back-ref with no offset
        demangle_symbol("_D__T1aZ", name);      // template with minimal content
    }
}
