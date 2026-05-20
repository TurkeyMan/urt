module urt.io;

nothrow @nogc:

enum WriteTarget : ubyte
{
    stdout = 0,
    stderr = 1,
    debugstring = 2,    // Windows OutputDebugStringA
}

template write_to(WriteTarget target, bool newline = false)
{
    int write_to(const(char)[] str)
    {
        static if (target == WriteTarget.stdout || target == WriteTarget.stderr)
        {
            version (Espressif)
            {
                foreach (ch; str)
                    esp_rom_uart_putc(ch);
                static if (newline)
                    esp_rom_uart_putc('\n');
                return cast(int) str.length;
            }
            else version (FreeStanding)
            {
                import urt.driver.uart : uart0_puts;
                uart0_puts(str);
                static if (newline)
                    uart0_puts("\n");
                return cast(int) str.length;
            }
            else
            {
                fwrite(str.ptr, 1, str.length, target == WriteTarget.stdout ? stdout : stderr);
                if (newline)
                    fwrite("\n".ptr, 1, "\n".length, target == WriteTarget.stdout ? stdout : stderr);
                return cast(int)(str.length + "\n".length);
            }
        }
        else static if (target == WriteTarget.debugstring)
        {
            version (Windows)
            {
                import core.sys.windows.windows;
                OutputDebugStringA(str.ptr);
                static if (newline)
                    OutputDebugStringA("\n");
                return cast(int)str.length + newline;
            }
            else
            {
                // is stderr the best analogy on other platforms?
                return write_to!(WriteTarget.stderr, newline)(str);
            }
        }
         else
            static assert(0, "Invalid WriteTarget");
    }

    int write_to(Args...)(ref Args args)
        if (Args.length != 1 || !is(Args[0] : const(char)[]))
    {
        import urt.string.format;
        import urt.mem.temp;

        size_t len = concat(null, args).length;
        const(char)[] t = concat(cast(char[])talloc(len), args);
        return write_to(t);
    }
}

int writef_to(WriteTarget target, bool newline = false, Args...)(const(char)[] fmt, ref Args args)
    if (Args.length == 0)
    => write_to!(target, newline)(fmt);

int writef_to(WriteTarget target, bool newline = false, Args...)(const(char)[] fmt, ref Args args)
    if (Args.length > 0)
{
    import urt.string.format;
    import urt.mem.temp;

    size_t len = format(null, fmt, args).length;
    const(char)[] t = format(cast(char[])talloc(len), fmt, args);
    return write_to!(target, newline)(t);
}

alias write = write_to!(WriteTarget.stdout, false);
alias writeln = write_to!(WriteTarget.stdout, true);
alias write_err = write_to!(WriteTarget.stderr, false);
alias writeln_err = write_to!(WriteTarget.stderr, true);
alias write_debug = write_to!(WriteTarget.debugstring, false);
alias writeln_debug = write_to!(WriteTarget.debugstring, true);

void flush(WriteTarget target = WriteTarget.stdout)() nothrow @nogc
{
    version (Espressif)
    {
        // ROM UART writes are unbuffered
    }
    else version (FreeStanding)
    {
        // UART writes are unbuffered - nothing to flush
    }
    else
    {
        static if (target == WriteTarget.stdout || target == WriteTarget.stderr)
            fflush(target == WriteTarget.stdout ? stdout : stderr);
    }
}

int writef(Args...)(ref Args args)
    => writef_to!(WriteTarget.stdout, false)(args);
int writelnf(Args...)(ref Args args)
    => writef_to!(WriteTarget.stdout, true)(args);

unittest
{
    writeln("\nHello, World!");
    writeln("Hello", " World!");
    writelnf("Hello, World! {0}", "wow!");

    writeln();
    writeln(10u, " why count ", 20, '?');

    write("Hello there ");
    write("mister ", "robot ");
    writef("how do {0} do?\n", "you");
}


private:

version (Espressif)
{
    // ROM UART putc -- in mask ROM, zero code size
    extern(C) void esp_rom_uart_putc(char c) nothrow @nogc;
}
else version (FreeStanding) {}
else
    import urt.internal.stdc.stdio : stdout, stderr, fwrite, fflush;
