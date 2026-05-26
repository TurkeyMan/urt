module urt.time;

import urt.array : Array;
import urt.traits : is_some_float;

version (Windows)
{
    import urt.internal.sys.windows;

    extern(Windows) void GetSystemTimePreciseAsFileTime(FILETIME* lpSystemTimeAsFileTime) nothrow @nogc;
}
else version (Posix)
{
    import urt.internal.sys.posix;
}
else version (Embedded)
{
    import urt.driver.timer;
}

nothrow @nogc:

enum Day : ubyte
{
    Sunday,
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,
}

enum Month : ubyte
{
    Unspecified = 0,
    January,
    February,
    March,
    April,
    May,
    June,
    July,
    August,
    September,
    October,
    November,
    December,
}

enum Clock
{
    SystemTime,
    Monotonic,
}

alias MonoTime = Time!(Clock.Monotonic);
alias SysTime = Time!(Clock.SystemTime);

struct Time(Clock clock)
{
pure nothrow @nogc:

    ulong ticks;

    bool opCast(T : bool)() const
        => ticks != 0;

    T opCast(T)() const
        if (is(T == Time!c, Clock c) && c != clock)
    {
        static if (is(T == Time!c, Clock c) && c != clock)
        {
            static if (clock == Clock.Monotonic && c == Clock.SystemTime)
                return SysTime(ticks + sys_time_offset);
            else
                return MonoTime(ticks - sys_time_offset);
        }
        else
            static assert(false, "constraint out of sync");
    }

    bool opEquals(Time!clock b) const
        => ticks == b.ticks;

    int opCmp(Time!clock b) const
        => ticks < b.ticks ? -1 : ticks > b.ticks ? 1 : 0;

    Duration opBinary(string op, Clock c)(Time!c rhs) const if (op == "-")
    {
        ulong t1 = ticks;
        ulong t2 = rhs.ticks;
        static if (clock != c)
        {
            static if (clock == Clock.Monotonic)
                t1 += sys_time_offset;
            else
                t2 += sys_time_offset;
        }
        return Duration(t1 - t2);
    }

    Time opBinary(string op)(Duration rhs) const if (op == "+" || op == "-")
        => Time(mixin("ticks " ~ op ~ " rhs.ticks"));

    void opOpAssign(string op)(Duration rhs) if (op == "+" || op == "-")
    {
        mixin("ticks " ~ op ~ "= rhs.ticks;");
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        static if (clock == Clock.SystemTime)
        {
            DateTime dt = getDateTime(this);
            return dt.toString(buffer, format, formatArgs);
        }
        else
        {
            long ns = (ticks != 0 ? appTime(this) : Duration()).as!"nsecs";
            if (!buffer.ptr)
                return 2 + timeToString(ns, null);
            if (buffer.length < 2)
                return -1;
            buffer[0..2] = "T+";
            ptrdiff_t len = timeToString(ns, buffer[2..$]);
            return len < 0 ? len : 2 + len;
        }
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        static if (clock == Clock.SystemTime)
        {
            DateTime dt;
            ptrdiff_t len = dt.fromString(s);
            if (len >= 0)
                this = getSysTime(dt);
            return len;
        }
        else
        {
            assert(false, "TODO: ???"); // what is the format we parse?
        }
    }

    version (Windows)
    auto __debugOverview() const
    {
        import urt.mem;
        char[] b = debug_alloc!char(64);
        ptrdiff_t len = toString(b, null, null);
        return b[0..len];
    }
}

struct Duration
{
pure nothrow @nogc:

    long ticks;

    enum zero = Duration(0);
    enum max = Duration(long.max);
    enum min = Duration(long.min);

    bool opCast(T : bool)() const
        => ticks != 0;

    T opCast(T)() const if (is_some_float!T)
        => cast(T)ticks / cast(T)ticks_per_second;

    bool opEquals(Duration b) const
        => ticks == b.ticks;

    int opCmp(Duration b) const
        => ticks < b.ticks ? -1 : ticks > b.ticks ? 1 : 0;

    Duration opUnary(string op)() const if (op == "-")
        => Duration(-ticks);

    Duration opBinary(string op)(Duration rhs) const if (op == "+" || op == "-")
        => Duration(mixin("ticks " ~ op ~ " rhs.ticks"));

    void opOpAssign(string op)(Duration rhs)
        if (op == "+" || op == "-")
    {
        mixin("ticks " ~ op ~ "= rhs.ticks;");
    }

    long as(string base)() const
    {
        static if (base == "nsecs")
            return ticks*nsec_multiplier;
        else static if (base == "usecs")
            return ticks*nsec_multiplier / 1_000;
        else static if (base == "msecs")
            return ticks*nsec_multiplier / 1_000_000;
        else static if (base == "seconds")
            return ticks*nsec_multiplier / 1_000_000_000;
        else static if (base == "minutes")
            return ticks*nsec_multiplier / 60_000_000_000;
        else static if (base == "hours")
            return ticks*nsec_multiplier / 3_600_000_000_000;
        else static if (base == "days")
            return ticks*nsec_multiplier / 86_400_000_000_000;
        else static if (base == "weeks")
            return ticks*nsec_multiplier / 604_800_000_000_000;
        else
            static assert(false, "Invalid base");
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        return timeToString(as!"nsecs", buffer);
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        import urt.conv : parse_int;
        import urt.string.ascii : is_alpha, ieq;

        if (s.length == 0)
            return -1;

        size_t offset = 0;
        long total_nsecs = 0;
        ubyte last_unit = 8;

        while (offset < s.length)
        {
            // Parse number
            size_t len;
            long value = s[offset..$].parse_int(&len);
            if (len == 0)
                return last_unit != 8 ? offset : -1;
            offset += len;

            if (offset >= s.length)
                return -1;

            // Parse unit
            size_t unit_start = offset;
            while (offset < s.length && s[offset].is_alpha)
                offset++;

            if (offset == unit_start)
                return -1;

            const(char)[] unit = s[unit_start..offset];

            // Convert unit to nanoseconds and check for duplicates
            ubyte this_unit;
            if (unit.ieq("w"))
            {
                value *= 604_800_000_000_000;
                this_unit = 7;
            }
            else if (unit.ieq("d"))
            {
                value *= 86_400_000_000_000;
                this_unit = 6;
            }
            else if (unit.ieq("h"))
            {
                value *= 3_600_000_000_000;
                this_unit = 5;
            }
            else if (unit.ieq("m"))
            {
                value *= 60_000_000_000;
                this_unit = 4;
            }
            else if (unit.ieq("s"))
            {
                value *= 1_000_000_000;
                this_unit = 3;
            }
            else if (unit.ieq("ms"))
            {
                value *= 1_000_000;
                this_unit = 2;
            }
            else if (unit.ieq("us"))
            {
                value *= 1_000;
                this_unit = 1;
            }
            else if (unit.ieq("ns"))
                this_unit = 0;
            else
                return -1;

            // Check for ordering, duplicates, and only one of ms/us/ns may be present
            if (this_unit >= last_unit || (this_unit < 2 && last_unit < 3))
                return -1;
            last_unit = this_unit;

            total_nsecs += value;
        }

        if (last_unit == 8)
            return -1;

        ticks = total_nsecs / nsec_multiplier;
        return offset;
    }

    version (Windows)
    {
        auto __debugOverview() const
            => cast(double)this;
    }
}

alias Timer = FixedTimer!();

struct FixedTimer(uint milliseconds = 0)
{
nothrow @nogc:
    MonoTime startTime;

    static if (milliseconds == 0)
    {
        Duration timeout;

        this(Duration timeout)
        {
            setTimeout(timeout);
            reset();
        }

        void setTimeout(Duration timeout) pure
        {
            this.timeout = timeout;
        }
    }

    void reset(MonoTime now = getTime()) pure
    {
        startTime = now;
    }

    bool expired(MonoTime now = getTime()) const pure
    {
        static if (milliseconds != 0)
            return now - startTime >= milliseconds.msecs;
        else
            return now - startTime >= timeout;
    }

    Duration elapsed(MonoTime now = getTime()) const pure
        => now - startTime;

    Duration remaining(MonoTime now = getTime()) const pure
    {
        static if (milliseconds != 0)
            return milliseconds.msecs - (now - startTime);
        else
            return timeout - (now - startTime);
    }

    Duration expiredDuration(MonoTime now = getTime()) const pure
        => -remaining(now);
}

struct DateTime
{
pure nothrow @nogc:

    short year;
    Month month;
    Day wday;
    ubyte day;
    ubyte hour;
    ubyte minute;
    ubyte second;
    uint ns;

    ushort msec() const => ns / 1_000_000;
    uint usec() const => ns / 1_000;

    bool leapYear() const => year % 4 == 0 && (year % 100 != 0 || year % 400 == 0); // && year >= -44; <- this is the year leap years were invented...

    Duration opBinary(string op)(DateTime rhs) const if (op == "-")
    {
        // complicated...
        assert(false);
    }

    DateTime opBinary(string op)(Duration rhs) const if (op == "+" || op == "-")
    {
        // complicated...
        assert(false);
    }

    void opOpAssign(string op)(Duration rhs) if (op == "+" || op == "-")
    {
        this = mixin("this " ~ op ~ " rhs;");
    }

    int opCmp(DateTime dt) const
    {
        int r = year - dt.year;
        if (r != 0) return r;
        r = month - dt.month;
        if (r != 0) return r;
        r = day - dt.day;
        if (r != 0) return r;
        r = hour - dt.hour;
        if (r != 0) return r;
        r = minute - dt.minute;
        if (r != 0) return r;
        r = second - dt.second;
        if (r != 0) return r;
        return ns - dt.ns;
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        import urt.conv : format_int, format_uint;

        ptrdiff_t len;
        if (!buffer.ptr)
        {
            len = 15; // all the fixed chars
            len += year.format_int(null);
            if (ns)
            {
                ++len; // the dot
                uint nsecs = ns;
                uint m = 0;
                while (nsecs)
                {
                    ++len;
                    uint digit = nsecs / digit_multipliers[m];
                    nsecs -= digit * digit_multipliers[m++];
                }
            }
            return len;
        }

        len = year.format_int(buffer[]);
        if (len < 0 || len + 15 > buffer.length)
            return -1;
        size_t offset = len;
        buffer[offset++] = '-';
        buffer[offset++] = '0' + (month / 10);
        buffer[offset++] = '0' + (month % 10);
        buffer[offset++] = '-';
        buffer[offset++] = '0' + (day / 10);
        buffer[offset++] = '0' + (day % 10);
        buffer[offset++] = 'T';
        buffer[offset++] = '0' + (hour / 10);
        buffer[offset++] = '0' + (hour % 10);
        buffer[offset++] = ':';
        buffer[offset++] = '0' + (minute / 10);
        buffer[offset++] = '0' + (minute % 10);
        buffer[offset++] = ':';
        buffer[offset++] = '0' + (second / 10);
        buffer[offset++] = '0' + (second % 10);
        if (ns)
        {
            if (offset == buffer.length)
                return -1;
            buffer[offset++] = '.';
            uint nsecs = ns;
            uint m = 0;
            while (nsecs)
            {
                if (offset == buffer.length)
                    return -1;
                int digit = nsecs / digit_multipliers[m];
                buffer[offset++] = cast(char)('0' + digit);
                nsecs -= digit * digit_multipliers[m++];
            }
        }
        // TODO: timezone suffix?
        return offset;
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        import urt.conv : parse_int, parse_uint;
        import urt.string.ascii : ieq, is_numeric, is_whitespace, to_lower;

        month = Month.Unspecified;
        day = 0;
        hour = 0;
        minute = 0;
        second = 0;
        ns = 0;

        size_t offset = 0;

        // parse year
        if (s.length >= 2 && s[0..2].ieq("bc"))
        {
            offset = 2;
            if (s.length >= 3 && s[2] == ' ')
                ++offset;
        }
        size_t len;
        long value = s[offset..$].parse_int(&len);
        if (len == 0)
            return -1;
        if (offset > 0)
        {
            if (value <= 0)
                return -1; // no year 0, or negative years BC!
            value = -value + 1;
        }
        if (value < short.min || value > short.max)
            return -1;
        year = cast(short)value;
        offset += len;

        if (offset == s.length || (s[offset] != '-' && s[offset] != '/'))
            return offset;

        // parse month
        value = s[++offset..$].parse_int(&len);
        if (len == 0)
        {
            if (s.length < 3)
                return -1;
            foreach (i; 0..12)
            {
                if (s[offset..offset+3].ieq(g_month_names[i]))
                {
                    value = i + 1;
                    len = 3;
                    goto got_month;
                }
            }
            return -1;
        got_month:
        }
        else if (value < 1 || value > 12)
            return -1;
        month = cast(Month)value;
        offset += len;

        if (offset == s.length || (s[offset] != '-' && s[offset] != '/'))
            return offset;

        // parse day
        value = s[++offset..$].parse_int(&len);
        if (len == 0 || value < 1 || value > 31)
            return -1;
        day = cast(ubyte)value;
        offset += len;

        if (offset == s.length || (s[offset] != 'T' && s[offset] != ' '))
            return offset;

        // parse hour
        value = s[++offset..$].parse_int(&len);
        if (len != 2 || value < 0 || value > 23)
            return -1;
        hour = cast(ubyte)value;
        offset += len;

        if (offset == s.length)
            return offset;

        if (s[offset] == ':')
        {
            // parse minute
            value = s[++offset..$].parse_int(&len);
            if (len != 2 || value < 0 || value > 59)
                return -1;
            minute = cast(ubyte)value;
            offset += len;

            if (offset == s.length)
                return offset;

            if (s[offset] == ':')
            {
                // parse second
                value = s[++offset..$].parse_int(&len);
                if (len != 2 || value < 0 || value > 59)
                    return -1;
                second = cast(ubyte)value;
                offset += len;

                if (offset < s.length && s[offset] == '.')
                {
                    // parse fractions
                    ++offset;
                    uint multiplier = 100_000_000;
                    while (offset < s.length && multiplier > 0 && s[offset].is_numeric)
                    {
                        ns += (s[offset++] - '0') * multiplier;
                        multiplier /= 10;
                    }
                    if (multiplier == 100_000_000)
                        return offset-1; // no number after the dot
                }
            }
            else if (s[offset] == '.')
            {
                // fraction of minute
                assert(false, "TODO");
            }
        }
        else if (s[offset] == '.')
        {
            // fraction of hour
            assert(false, "TODO");
        }

        if (offset == s.length)
            return offset;

        if (s[offset].to_lower == 'z')
        {
            // TODO: UTC timezone designator...
//            assert(false, "TODO: we need to know our local timezone...");

            return offset + 1;
        }

        size_t tz_offset = offset;
        if (s[offset] == ' ')
            ++tz_offset;
        if (s[tz_offset] != '-' && s[tz_offset] != '+')
            return offset;
        bool tz_neg = s[tz_offset] == '-';
        tz_offset += 1;

        // parse timezone (00:00)
        int tz_hr, tz_min;

        value = s[tz_offset..$].parse_uint(&len);
        if (len == 0)
            return offset;

        if (len == 4)
        {
            if (value > 2359)
                return -1;
            tz_min = cast(int)(value % 100);
            if (tz_min > 59)
                return -1;
            tz_hr = cast(int)(value / 100);
            tz_offset += 4;
        }
        else
        {
            if (len != 2 || value > 59)
                return -1;

            tz_hr = cast(int)value;
            tz_offset += 2;

            if (tz_offset < s.length && s[tz_offset] == ':')
            {
                value = s[tz_offset+1..$].parse_uint(&len);
                if (len != 0)
                {
                    if (len != 2 || value > 59)
                        return -1;
                    tz_min = cast(int)value;
                    tz_offset += 3;
                }
            }
        }

        if (tz_neg)
            tz_hr = -tz_hr;

//        assert(false, "TODO: we need to know our local timezone...");

        return tz_offset;
    }
}

struct TimeOfDay
{
pure nothrow @nogc:

    ubyte hour;
    ubyte minute;
    ubyte second;
    uint ns;

    ushort msec() const => cast(ushort)(ns / 1_000_000);
    uint usec() const => ns / 1_000;

    Duration opBinary(string op)(TimeOfDay rhs) const if (op == "-")
    {
        long lhs_ns = (cast(long)hour*3600 + cast(long)minute*60 + cast(long)second) * 1_000_000_000 + ns;
        long rhs_ns = (cast(long)rhs.hour*3600 + cast(long)rhs.minute*60 + cast(long)rhs.second) * 1_000_000_000 + rhs.ns;
        return (lhs_ns - rhs_ns).nsecs;
    }

    TimeOfDay opBinary(string op)(Duration rhs) const if (op == "+" || op == "-")
    {
        long tod_ns = (cast(long)hour*3600 + cast(long)minute*60 + cast(long)second) * 1_000_000_000 + ns;
        static if (op == "+")
            tod_ns += rhs.as!"nsecs";
        else
            tod_ns -= rhs.as!"nsecs";
        enum long day_ns = 86_400_000_000_000;
        tod_ns = ((tod_ns % day_ns) + day_ns) % day_ns;
        TimeOfDay r;
        r.ns = cast(uint)(tod_ns % 1_000_000_000);
        long sod = tod_ns / 1_000_000_000;
        r.second = cast(ubyte)(sod % 60);
        r.minute = cast(ubyte)((sod / 60) % 60);
        r.hour = cast(ubyte)(sod / 3600);
        return r;
    }

    void opOpAssign(string op)(Duration rhs) if (op == "+" || op == "-")
    {
        this = mixin("this " ~ op ~ " rhs;");
    }

    int opCmp(TimeOfDay tod) const
    {
        int r = hour - tod.hour;
        if (r != 0) return r;
        r = minute - tod.minute;
        if (r != 0) return r;
        r = second - tod.second;
        if (r != 0) return r;
        return cast(int)ns - cast(int)tod.ns;
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        if (!buffer.ptr)
        {
            ptrdiff_t len = 8;
            if (ns)
            {
                ++len;
                uint nsecs = ns;
                uint m = 0;
                while (nsecs)
                {
                    ++len;
                    uint digit = nsecs / digit_multipliers[m];
                    nsecs -= digit * digit_multipliers[m++];
                }
            }
            return len;
        }

        if (buffer.length < 8)
            return -1;
        size_t offset = 0;
        buffer[offset++] = cast(char)('0' + (hour / 10));
        buffer[offset++] = cast(char)('0' + (hour % 10));
        buffer[offset++] = ':';
        buffer[offset++] = cast(char)('0' + (minute / 10));
        buffer[offset++] = cast(char)('0' + (minute % 10));
        buffer[offset++] = ':';
        buffer[offset++] = cast(char)('0' + (second / 10));
        buffer[offset++] = cast(char)('0' + (second % 10));
        if (ns)
        {
            if (offset == buffer.length)
                return -1;
            buffer[offset++] = '.';
            uint nsecs = ns;
            uint m = 0;
            while (nsecs)
            {
                if (offset == buffer.length)
                    return -1;
                int digit = nsecs / digit_multipliers[m];
                buffer[offset++] = cast(char)('0' + digit);
                nsecs -= digit * digit_multipliers[m++];
            }
        }
        return offset;
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        import urt.conv : parse_int;
        import urt.string.ascii : is_numeric;

        hour = 0;
        minute = 0;
        second = 0;
        ns = 0;

        if (s.length == 0)
            return -1;

        size_t offset = 0;
        size_t len;
        long value = s[offset..$].parse_int(&len);
        if (len != 2 || value < 0 || value > 23)
            return -1;
        hour = cast(ubyte)value;
        offset += len;

        if (offset == s.length || s[offset] != ':')
            return offset;

        value = s[++offset..$].parse_int(&len);
        if (len != 2 || value < 0 || value > 59)
            return -1;
        minute = cast(ubyte)value;
        offset += len;

        if (offset == s.length || s[offset] != ':')
            return offset;

        value = s[++offset..$].parse_int(&len);
        if (len != 2 || value < 0 || value > 59)
            return -1;
        second = cast(ubyte)value;
        offset += len;

        if (offset < s.length && s[offset] == '.')
        {
            ++offset;
            uint multiplier = 100_000_000;
            while (offset < s.length && multiplier > 0 && s[offset].is_numeric)
            {
                ns += (s[offset++] - '0') * multiplier;
                multiplier /= 10;
            }
            if (multiplier == 100_000_000)
                return offset-1;
        }

        return offset;
    }

    version (Windows)
    auto __debugOverview() const
    {
        import urt.mem;
        char[] b = debug_alloc!char(20);
        ptrdiff_t len = toString(b, null, null);
        return b[0..len];
    }
}

TimeOfDay time_of_day(DateTime dt) pure
{
    TimeOfDay t;
    t.hour = dt.hour;
    t.minute = dt.minute;
    t.second = dt.second;
    t.ns = dt.ns;
    return t;
}

TimeOfDay time_of_day(SysTime t) pure
    => time_of_day(getDateTime(t));

SysTime next_occurrence(SysTime now, TimeOfDay tod, ubyte weekday_mask = 0x7F) pure
{
    if ((weekday_mask & 0x7F) == 0)
        weekday_mask = 0x7F;

    ulong now_ns = unixTimeNs(now);
    enum ulong day_ns = 86_400_000_000_000UL;
    ulong day_start = now_ns - now_ns % day_ns;
    ulong tod_ns = (cast(ulong)tod.hour*3600 + cast(ulong)tod.minute*60 + cast(ulong)tod.second) * 1_000_000_000UL + tod.ns;

    DateTime dt = getDateTime(now);
    ubyte wday = cast(ubyte)dt.wday;

    foreach (_; 0 .. 7)
    {
        if (weekday_mask & (1 << wday))
        {
            ulong candidate = day_start + tod_ns;
            if (candidate > now_ns)
                return from_unix_time_ns(candidate);
        }
        day_start += day_ns;
        wday = cast(ubyte)((wday + 1) % 7);
    }

    return from_unix_time_ns(day_start + tod_ns);
}


Duration dur(string base)(long value) pure
{
    static if (base == "nsecs")
        return Duration(value / nsec_multiplier);
    else static if (base == "usecs")
        return Duration(value*1_000 / nsec_multiplier);
    else static if (base == "msecs")
        return Duration(value*1_000_000 / nsec_multiplier);
    else static if (base == "seconds")
        return Duration(value*1_000_000_000 / nsec_multiplier);
    else static if (base == "minutes")
        return Duration(value*60_000_000_000 / nsec_multiplier);
    else static if (base == "hours")
        return Duration(value*3_600_000_000_000 / nsec_multiplier);
    else static if (base == "days")
        return Duration(value*86_400_000_000_000 / nsec_multiplier);
    else static if (base == "weeks")
        return Duration(value*604_800_000_000_000 / nsec_multiplier);
    else
        static assert(false, "Invalid base");
}

alias nsecs   = dur!"nsecs";
alias usecs   = dur!"usecs";
alias msecs   = dur!"msecs";
alias seconds = dur!"seconds";

MonoTime getTime()
{
    version (Windows)
    {
        LARGE_INTEGER now;
        QueryPerformanceCounter(&now);
        return MonoTime(now.QuadPart);
    }
    else version (Posix)
    {
        timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        return MonoTime(ts.tv_sec * 1_000_000_000 + ts.tv_nsec);
    }
    else version (Embedded)
    {
        static if (has_mtime)
            return MonoTime(mtime_read());
        else
            static assert(false, "getTime: no monotonic timer for this platform");
    }
    else
    {
        static assert(false, "TODO");
    }
}

SysTime getSysTime()
{
    version (Windows)
    {
        FILETIME ft;
        GetSystemTimePreciseAsFileTime(&ft);
        return SysTime(*cast(ulong*)&ft);
    }
    else version (Posix)
    {
        timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        return SysTime(ts.tv_sec * 1_000_000_000 + ts.tv_nsec);
    }
    else version (Embedded)
    {
        static if (has_mtime)
            return SysTime(mtime_read() + sys_time_offset);
        else
            static assert(false, "getSysTime: no monotonic timer for this platform");
    }
    else
    {
        static assert(false, "TODO");
    }
}

SysTime getSysTime(DateTime time) pure
{
    return from_unix_time_ns(datetime_to_unix_ns(time));
}

DateTime getDateTime()
{
    return getDateTime(getSysTime());
}

DateTime getDateTime(SysTime time) pure
{
    return unix_ns_to_datetime(unixTimeNs(time));
}

Duration getAppTime()
    => getTime() - startTime;

Duration appTime(MonoTime t) pure
    => t - startTime;
Duration appTime(SysTime t) pure
    => cast(MonoTime)t - startTime;

ulong unixTimeNs(SysTime t) pure
{
    version (Windows)
        return (t.ticks - unix_epoch_as_filetime) * 100UL;
    else version (Posix)
        return t.ticks;
    else version (Embedded)
        return t.ticks * nsec_multiplier;
    else
        static assert(false, "TODO");
}

SysTime from_unix_time_ns(ulong ns) pure
{
    version (Windows)
        return SysTime(ns / 100UL + unix_epoch_as_filetime);
    else version (Posix)
        return SysTime(ns);
    else version (Embedded)
        return SysTime(ns / nsec_multiplier);
    else
        static assert(false, "TODO");
}

Duration abs(Duration d) pure
    => Duration(d.ticks < 0 ? -d.ticks : d.ticks);

bool wall_time_set()
{
    return has_wall_time;
}

void set_utc_time(ulong unix_ns)
{
    cast()sys_time_offset = unix_ns / nsec_multiplier - getTime().ticks;
    has_wall_time = true;

    version (Windows)
    {
        import urt.internal.sys.windows;

        ulong ft = unix_ns / 100 + unix_epoch_as_filetime;
        SYSTEMTIME st;
        FileTimeToSystemTime(cast(FILETIME*)&ft, &st);
        SetSystemTime(&st);
    }
    else version (Posix)
    {
        timespec ts;
        ts.tv_sec = cast(time_t)(unix_ns / 1_000_000_000);
        ts.tv_nsec = cast(uint)(unix_ns % 1_000_000_000);
        clock_settime(CLOCK_REALTIME, &ts);
    }
    else version (Embedded)
    {
        static if (has_rtc)
        {
            auto p = hbn_persist();
            ulong mtime_ticks = unix_ns / nsec_multiplier;
            ulong sec = mtime_ticks / mtime_freq_hz;
            ulong frac = mtime_ticks % mtime_freq_hz;
            ulong hbn_ticks = sec * rtc_freq_hz + frac * rtc_freq_hz / mtime_freq_hz;
            p.utc_offset = cast(long)hbn_ticks - cast(long)rtc_read();
            p.magic = HbnPersist.HBN_MAGIC;
        }
    }

    notify_clock_change();
}


alias ClockChangeHandler = void delegate() nothrow @nogc;

void subscribe_clock_change(ClockChangeHandler h)
{
    _clock_change_handlers ~= h;
}

void unsubscribe_clock_change(ClockChangeHandler h)
{
    debug assert(g_iterating_clock_change == false, "must not unsubscribe from a clock_change handler");
    foreach (i, hh; _clock_change_handlers)
    {
        if (hh is h)
        {
            _clock_change_handlers.removeSwapLast(i);
            return;
        }
    }
}

void notify_clock_change()
{
    debug g_iterating_clock_change = true;
    foreach (h; _clock_change_handlers)
        h();
    debug g_iterating_clock_change = false;
}

debug __gshared g_iterating_clock_change = false;


private:

__gshared Array!ClockChangeHandler _clock_change_handlers;

__gshared immutable MonoTime startTime;

__gshared immutable string[12] g_month_names = [ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" ];
__gshared immutable uint[9] digit_multipliers = [ 100_000_000, 10_000_000, 1_000_000, 100_000, 10_000, 1_000, 100, 10, 1 ];

version (Windows)
{
    enum ulong unix_epoch_as_filetime = 116_444_736_000_000_000UL;

    enum uint ticks_per_second = 10_000_000; // QPC has been 10mHz for several decades. I don't think it can ever change...
    enum uint nsec_multiplier = 100;
}
else version (Posix)
{
    enum uint ticks_per_second = 1_000_000_000;
    enum uint nsec_multiplier = 1;
}
else version (Embedded)
{
    enum uint ticks_per_second = mtime_freq_hz;
    enum uint nsec_multiplier = 1_000_000_000 / mtime_freq_hz;
}

__gshared immutable ulong sys_time_offset;
__gshared bool has_wall_time;

package(urt) void init_clock()
{
    cast()startTime = getTime();

    version (Windows)
    {
        import urt.internal.sys.windows;
        import urt.util : min;

        LARGE_INTEGER freq;
        QueryPerformanceFrequency(&freq);
        assert(cast(uint)freq.QuadPart == ticks_per_second, "Unexpected QPC frequency! urt needs to be updated...");

        // we want the ftime for QPC 0; which should be the boot time
        // we'll repeat this 100 times and take the minimum, and we should be within probably nanoseconds of the correct value
        LARGE_INTEGER qpc;
        ulong ftime, boot_time = ulong.max;
        foreach (i; 0 .. 100)
        {
            QueryPerformanceCounter(&qpc);
            GetSystemTimePreciseAsFileTime(cast(FILETIME*)&ftime);
            boot_time = min(boot_time, ftime - qpc.QuadPart);
        }
        cast()sys_time_offset = boot_time;
        has_wall_time = true;
    }
    else version (Posix)
    {
        import urt.util : min;

        // this doesn't really give time since boot, since MONOTIME is not guaranteed to be zero at system startup...
        timespec mt, rt;
        ulong boot_time = ulong.max;
        foreach (i; 0 .. 100)
        {
            clock_gettime(CLOCK_MONOTONIC, &mt);
            clock_gettime(CLOCK_REALTIME, &rt);
            boot_time = min(boot_time, rt.tv_sec*1_000_000_000 + rt.tv_nsec - mt.tv_sec*1_000_000_000 - mt.tv_nsec);
        }
        cast()sys_time_offset = boot_time;
        has_wall_time = true;
    }
    else version (Embedded)
    {
        timer_init();

        static if (has_rtc)
        {
            rtc_enable();
            recalc_sys_time_offset();
        }
        else
        {
            cast()sys_time_offset = 0;
        }
    }
    else
        static assert(false, "TODO");
}

ptrdiff_t timeToString(long ns, char[] buffer) pure
{
    import urt.conv : format_int;

    int hr = cast(int)(ns / 3_600_000_000_000);
    ns = ns < 0 ? -ns % 3_600_000_000_000 : ns % 3_600_000_000_000;
    uint remainder = cast(uint)(ns % 1_000_000_000);

    if (!buffer.ptr)
    {
        size_t tail = 6;
        if (remainder)
        {
            ++tail;
            uint m = 0;
            do
            {
                ++tail;
                uint digit = cast(uint)(remainder / digit_multipliers[m]);
                remainder -= digit * digit_multipliers[m++];
            }
            while (remainder);
        }
        return hr.format_int(null, 10, 2, '0') + tail;
    }

    ptrdiff_t len = hr.format_int(buffer, 10, 2, '0');
    if (len < 0 || buffer.length < len + 6)
        return -1;

    uint min_sec = cast(uint)(ns / 1_000_000_000);
    uint min = min_sec / 60;
    uint sec = min_sec % 60;

    buffer.ptr[len++] = ':';
    buffer.ptr[len++] = cast(char)('0' + (min / 10));
    buffer.ptr[len++] = cast(char)('0' + (min % 10));
    buffer.ptr[len++] = ':';
    buffer.ptr[len++] = cast(char)('0' + (sec / 10));
    buffer.ptr[len++] = cast(char)('0' + (sec % 10));
    if (remainder)
    {
        if (buffer.length < len + 2)
            return -1;
        buffer.ptr[len++] = '.';
        uint i = 0;
        while (remainder)
        {
            if (buffer.length <= len)
                return -1;
            uint m = digit_multipliers[i++];
            uint digit = cast(uint)(remainder / m);
            buffer.ptr[len++] = cast(char)('0' + digit);
            remainder -= digit * m;
        }
    }
    return len;
}

unittest
{
    import urt.mem.temp;

    assert(tconcat(msecs(3_600_000*3 + 60_000*47 + 1000*34 + 123))[] == "03:47:34.123");
    assert(tconcat(msecs(3_600_000*-123))[] == "-123:00:00");
    assert(tconcat(usecs(3_600_000_000*-123 + 1))[] == "-122:59:59.999999");
    assert(MonoTime().toString(null, null, null) == 10);
    assert(tconcat(getTime())[0..2] == "T+");

    // Test Duration.fromString with compound formats
    Duration d;

    // Simple single units
    assert(d.fromString("5s") == 2 && d.as!"seconds" == 5);
    assert(d.fromString("10m") == 3 && d.as!"minutes" == 10);

    // Compound durations
    assert(d.fromString("1h30m") == 5 && d.as!"minutes" == 90);
    assert(d.fromString("5m30s") == 5 && d.as!"seconds" == 330);

    // Duplicate units should fail
    assert(d.fromString("30m30m") == -1);
    assert(d.fromString("1h2h") == -1);
    assert(d.fromString("5s10s") == -1);

    // Out-of-order units should fail
    assert(d.fromString("30s5m") == -1);  // s before m
    assert(d.fromString("1m2h") == -1);   // m before h
    assert(d.fromString("5s10ms5m") == -1);  // m after s
    assert(d.fromString("5s10ms10ns") == -1);  // ms and ns (only one sub-second unit allowed)

    // Improper units should fail
    assert(d.fromString("30z") == -1);  // not a time denomination

    // Correctly ordered units should work
    assert(d.fromString("1d2h30m15s") == 10 && d.as!"seconds" == 86_400 + 7_200 + 1_800 + 15);

    // Test DateTime.fromString
    DateTime dt;
    assert(dt.fromString("2024-06-15T12:34:56") == 19);
    assert(dt.fromString("-100/06/15 12:34:56") == 19);
    assert(dt.fromString("BC100-AUG-15 12:34:56.789") == 25);
    assert(dt.fromString("BC 10000-AUG-15 12:34:56.789123456") == 34);
    assert(dt.fromString("1-1-1 01:01:01") == 14);
    assert(dt.fromString("1-1-1 01:01:01.") == 14);
    assert(dt.fromString("2025") == 4);
    assert(dt.fromString("2025-10") == 7);
    assert(dt.fromString("2025-01-01") == 10);
    assert(dt.fromString("2025-01-01 00") == 13);
    assert(dt.fromString("2025-01-01 00:10") == 16);
    assert(dt.fromString("2025-01-01 00:10z") == 17);
    assert(dt.fromString("2025-01-01 00+00:00") == 19);
    assert(dt.fromString("2025-01-01 00-1030") == 18);
    assert(dt.fromString("2025-01-01 00+08") == 16);

    assert(dt.fromString("BC -10") == -1);
    assert(dt.fromString("2024-0-15 12:34:56") == -1);
    assert(dt.fromString("2024-13-15 12:34:56") == -1);
    assert(dt.fromString("2024-1-0 12:34:56") == -1);
    assert(dt.fromString("2024-1-32 12:34:56") == -1);
    assert(dt.fromString("2024-1-1 24:34:56") == -1);
    assert(dt.fromString("2024-1-1 01:60:56") == -1);
    assert(dt.fromString("2024-1-1 01:01:60") == -1);
    assert(dt.fromString("10000-1-1 1:01:01") == -1);

    // ---- TimeOfDay ----

    TimeOfDay tod;
    assert(tod.fromString("10:30") == 5 && tod.hour == 10 && tod.minute == 30 && tod.second == 0 && tod.ns == 0);
    assert(tod.fromString("10:30:45") == 8 && tod.second == 45);
    assert(tod.fromString("10:30:45.5") == 10 && tod.ns == 500_000_000);
    assert(tod.fromString("23:59:59.999999999") == 18 && tod.ns == 999_999_999);
    assert(tod.fromString("00:00:00") == 8);

    assert(tod.fromString("24:00") == -1);
    assert(tod.fromString("10:60") == -1);
    assert(tod.fromString("10:30:60") == -1);
    assert(tod.fromString("1:30") == -1);
    assert(tod.fromString("") == -1);

    tod = TimeOfDay(10, 30, 0, 0);
    assert(tconcat(tod)[] == "10:30:00");
    tod.ns = 123_000_000;
    assert(tconcat(tod)[] == "10:30:00.123");

    // arithmetic
    tod = TimeOfDay(10, 30, 0, 0);
    auto tod2 = tod + dur!"minutes"(45);
    assert(tod2.hour == 11 && tod2.minute == 15 && tod2.second == 0);
    auto tod3 = tod - dur!"hours"(11);
    assert(tod3.hour == 23 && tod3.minute == 30); // wrap backwards
    auto tod4 = tod + dur!"hours"(25);
    assert(tod4.hour == 11 && tod4.minute == 30); // wrap forwards
    Duration diff = TimeOfDay(11, 0, 0, 0) - TimeOfDay(10, 30, 0, 0);
    assert(diff.as!"minutes" == 30);

    // extract from DateTime / SysTime
    dt = DateTime.init;
    dt.year = 2025; dt.month = Month.June; dt.day = 15;
    dt.hour = 8; dt.minute = 30; dt.second = 45; dt.ns = 123_456_789;
    tod = time_of_day(dt);
    assert(tod.hour == 8 && tod.minute == 30 && tod.second == 45 && tod.ns == 123_456_789);

    // ---- unix_ns_to_datetime / datetime_to_unix_ns ----

    // Unix epoch: 1970-01-01 00:00:00 UTC, Thursday
    dt = unix_ns_to_datetime(0);
    assert(dt.year == 1970 && dt.month == Month.January && dt.day == 1);
    assert(dt.hour == 0 && dt.minute == 0 && dt.second == 0 && dt.ns == 0);
    assert(dt.wday == Day.Thursday);

    // Round-trip at epoch
    assert(datetime_to_unix_ns(dt) == 0);

    // 2000-01-01 00:00:00 UTC = 946684800 seconds, Saturday
    dt = unix_ns_to_datetime(946_684_800UL * 1_000_000_000);
    assert(dt.year == 2000 && dt.month == Month.January && dt.day == 1);
    assert(dt.wday == Day.Saturday);
    assert(datetime_to_unix_ns(dt) == 946_684_800UL * 1_000_000_000);

    // 2024-02-29 (leap year) 12:00:00 = 1709208000 seconds, Thursday
    dt = unix_ns_to_datetime(1_709_208_000UL * 1_000_000_000);
    assert(dt.year == 2024 && dt.month == Month.February && dt.day == 29);
    assert(dt.hour == 12 && dt.minute == 0 && dt.second == 0);
    assert(dt.wday == Day.Thursday);
    assert(datetime_to_unix_ns(dt) == 1_709_208_000UL * 1_000_000_000);

    // 1900-03-01 - 1900 is NOT a leap year (century rule)
    // 1900-03-01 00:00:00 = -2203891200 seconds... negative, skip
    // Instead test 2100-03-01 (also not a leap year)
    // 2100-03-01 00:00:00 = 4107542400 seconds, Monday
    dt = unix_ns_to_datetime(4_107_542_400UL * 1_000_000_000);
    assert(dt.year == 2100 && dt.month == Month.March && dt.day == 1);
    assert(dt.wday == Day.Monday);

    // 2000 IS a leap year (400-year rule), Feb 29 exists
    // 2000-02-29 00:00:00 = 951782400 seconds, Tuesday
    dt = unix_ns_to_datetime(951_782_400UL * 1_000_000_000);
    assert(dt.year == 2000 && dt.month == Month.February && dt.day == 29);
    assert(dt.wday == Day.Tuesday);

    // Sub-second precision: 2025-06-15 08:30:45.123456789
    dt.year = 2025; dt.month = Month.June; dt.day = 15;
    dt.hour = 8; dt.minute = 30; dt.second = 45; dt.ns = 123_456_789;
    ulong ns = datetime_to_unix_ns(dt);
    auto dt2 = unix_ns_to_datetime(ns);
    assert(dt2.year == 2025 && dt2.month == Month.June && dt2.day == 15);
    assert(dt2.hour == 8 && dt2.minute == 30 && dt2.second == 45);
    assert(dt2.ns == 123_456_789);

    // Dec 31 ? Jan 1 boundary
    dt = unix_ns_to_datetime(1_735_689_599UL * 1_000_000_000); // 2024-12-31 23:59:59
    assert(dt.year == 2024 && dt.month == Month.December && dt.day == 31);
    assert(dt.hour == 23 && dt.minute == 59 && dt.second == 59);
    dt = unix_ns_to_datetime(1_735_689_600UL * 1_000_000_000); // 2025-01-01 00:00:00
    assert(dt.year == 2025 && dt.month == Month.January && dt.day == 1);
    assert(dt.wday == Day.Wednesday);
}


DateTime unix_ns_to_datetime(ulong ns) pure
{
    ulong total_sec = ns / 1_000_000_000;
    uint remainder_ns = cast(uint)(ns % 1_000_000_000);

    uint sod = cast(uint)(total_sec % 86_400);
    long days = cast(long)(total_sec / 86_400);

    DateTime dt;
    dt.hour = cast(ubyte)(sod / 3600);
    dt.minute = cast(ubyte)(sod % 3600 / 60);
    dt.second = cast(ubyte)(sod % 60);
    dt.ns = remainder_ns;

    dt.wday = cast(Day)((days + 4) % 7);

    days += 719_468;
    long era = (days >= 0 ? days : days - 146_096) / 146_097;
    uint doe = cast(uint)(days - era * 146_097);
    uint yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    long y = yoe + era * 400;
    uint doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    uint mp = (5 * doy + 2) / 153;
    uint d = doy - (153 * mp + 2) / 5 + 1;
    uint m = mp < 10 ? mp + 3 : mp - 9;
    if (m <= 2)
        ++y;

    dt.year = cast(short)y;
    dt.month = cast(Month)m;
    dt.day = cast(ubyte)d;

    return dt;
}

ulong datetime_to_unix_ns(DateTime dt) pure
{
    long y = dt.year;
    uint m = dt.month;
    uint d = dt.day;

    if (m <= 2)
        --y;
    long era = (y >= 0 ? y : y - 399) / 400;
    uint yoe = cast(uint)(y - era * 400);
    uint doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
    uint doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    long days = era * 146_097 + doe - 719_468;

    ulong total_sec = cast(ulong)(days * 86_400 + dt.hour*3600 + dt.minute*60 + dt.second);

    return total_sec * 1_000_000_000 + dt.ns;
}

version (Embedded) static if (has_rtc)
{
    __gshared ulong last_hbn;

    void correct_drift()
    {
        auto p = hbn_persist();
        if (p.magic != HbnPersist.HBN_MAGIC)
            return;

        ulong now_hbn = rtc_read();

        // detect 40-bit wrap: counter went backwards since last check
        if (now_hbn < last_hbn)
            p.utc_offset += ulong(1) << 40;
        last_hbn = now_hbn;

        ulong sys_mtime = mtime_read() + sys_time_offset;

        // What does HBN + offset think it is (converted to mtime ticks)?
        ulong hbn_total = now_hbn + p.utc_offset;
        ulong sys_hbn = hbn_total / rtc_freq_hz * mtime_freq_hz
                        + hbn_total % rtc_freq_hz * mtime_freq_hz / rtc_freq_hz;

        // difference is accumulated drift; fold into utc_offset
        long drift_mtime = sys_mtime - sys_hbn;
        p.utc_offset += drift_mtime * rtc_freq_hz / mtime_freq_hz;
    }

    void recalc_sys_time_offset()
    {
        auto p = hbn_persist();
        if (p.magic == HbnPersist.HBN_MAGIC)
        {
            last_hbn = rtc_read();
            long hbn_total = cast(long)(last_hbn + p.utc_offset);
            long hbn_unix_mtime = hbn_total / rtc_freq_hz * mtime_freq_hz
                                + hbn_total % rtc_freq_hz * mtime_freq_hz / rtc_freq_hz;
            cast()sys_time_offset = cast(ulong)(hbn_unix_mtime - cast(long)mtime_read());
            has_wall_time = true;
        }
    }
}
