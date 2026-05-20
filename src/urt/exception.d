/// Assert handler registration for uRT.
module urt.exception;

import urt.attribute : noinline;

nothrow @nogc:


alias AssertHandler = void function(string file, size_t line, string msg) nothrow @nogc;

AssertHandler assert_handler() @property nothrow @nogc @trusted
    => _assert_handler;

void assert_handler(AssertHandler handler) @property nothrow @nogc @trusted
{
    if (handler is null)
        _assert_handler = &urt_assert;
    else
        _assert_handler = handler;
}


private:

__gshared AssertHandler _assert_handler = &urt_assert;

@noinline
void urt_assert(string file, size_t line, string msg) nothrow @nogc
{
    if (msg.length == 0)
        msg = "Assertion failed";

    version (BareMetal)
    {
        import urt.driver.uart : uart0_puts;
        import urt.internal.exception : capture_trace;
        import urt.mem.temp : tconcat;

        uart0_puts(tconcat("\n*** ASSERT: ", msg, " at ", file, ':', line, '\n'));

        // Skip frame[0] -- with capture_trace as a real frame (defeat_tco),
        // its saved ra points back into urt_assert itself, which is noise.
        // Frame[1] is the assert site inside the calling function.
        void*[16] addrs = void;
        const n = capture_trace(addrs[]);
        if (n > 1)
        {
            uart0_puts("Backtrace (resolve with addr2line):\n");
            enum digits = size_t.sizeof * 2;
            char[4 + digits + 1] hex_buf = void;
            hex_buf[0 .. 4] = "  0x";
            hex_buf[$ - 1] = '\n';
            foreach (addr; addrs[1 .. n])
            {
                size_t v = cast(size_t) addr;
                foreach_reverse (j; 4 .. 4 + digits)
                {
                    const ubyte nib = v & 0xF;
                    hex_buf[j] = cast(char)(nib < 10 ? '0' + nib : 'a' + nib - 10);
                    v >>= 4;
                }
                uart0_puts(hex_buf[]);
            }
        }

        while (true) {}
    }
    else version (Espressif)
    {
        import urt.io : writef_to, WriteTarget;
        writef_to!(WriteTarget.stdout, true)("*** ASSERT: {2} at {0}:{1}", file, line, msg);
        import urt.internal.stdc.stdlib : exit;
        exit(-1);
    }
    else
    {
        debug
        {
            import urt.io : writef_to, WriteTarget;
            import urt.dbg;

            version (Windows)
                writef_to!(WriteTarget.debugstring, true)("{0}({1}): {2}", file, line, msg);
            writef_to!(WriteTarget.stdout, true)("{0}({1}): {2}", file, line, msg);

            breakpoint();
        }
        else
        {
            import urt.internal.stdc.stdlib : exit;
            exit(-1);
        }
    }
}
