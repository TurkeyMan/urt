module urt.meta.nullable;

import urt.string.format : formatValue, FormatArg;
import urt.traits;


template Nullable(T)
    if (is(T == class) || is(T == U[], U) || is(T == U*, U))
{
    struct Nullable
    {
        enum T null_value = null;
        T value = null_value;

        this(T v)
        {
            value = v;
        }

        bool opCast(T : bool)() const
            => value !is null_value;

        bool opEquals(typeof(null)) const
            => value is null;
        bool opEquals(T v) const
            => value == v;

        void opAssign(U)(U v)
            if (is(U : T))
        {
            value = v;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (value is null)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}

template Nullable(T)
    if (is_boolean!T)
{
    struct Nullable
    {
        enum ubyte null_value = 0xFF;
        private ubyte _value = null_value;

        this(typeof(null))
        {
            _value = null_value;
        }
        this(T v)
        {
            _value = v;
        }

        bool value() const
            => _value == 1;

        bool opCast(T : bool)() const
            => _value != null_value;

        bool opEquals(typeof(null)) const
            => _value == null_value;
        bool opEquals(T v) const
            => _value == cast(ubyte)v;

        void opAssign(typeof(null))
        {
            _value = null_value;
        }
        void opAssign(U)(U v)
            if (is(U : T))
        {
            assert(v != null_value);
            _value = cast(ubyte)v;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (value == null_value)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}

template Nullable(T)
    if (is_some_int!T)
{
    struct Nullable
    {
        enum T null_value = is_signed_int!T ? T.min : T.max;
        T value = null_value;

        this(typeof(null))
        {
            value = null_value;
        }
        this(T v)
        {
            value = v;
        }

        bool opCast(T : bool)() const
            => value != null_value;

        bool opEquals(typeof(null)) const
            => value == null_value;
        bool opEquals(T v) const
            => value != null_value && value == v;

        void opAssign(typeof(null))
        {
            value = null_value;
        }
        void opAssign(U)(U v)
            if (is(U : T))
        {
            assert(v != null_value);
            value = v;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (value == null_value)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}

template Nullable(T)
    if (is_some_float!T)
{
    struct Nullable
    {
        enum T null_value = T.nan;
        T value = null_value;

        this(typeof(null))
        {
            value = null_value;
        }
        this(T v)
        {
            value = v;
        }

        bool opCast(T : bool)() const
            => value !is null_value;

        bool opEquals(typeof(null)) const
            => value is null_value;
        bool opEquals(T v) const
            => value == v; // because nan doesn't compare with anything

        void opAssign(typeof(null))
        {
            value = null_value;
        }
        void opAssign(U)(U v)
            if (is(U : T))
        {
            value = v;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (value is null_value)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}

template Nullable(T)
    if (is(T == struct))
{
    import urt.lifetime : moveEmplace;

    struct Nullable
    {
        T value = void;
        bool is_value = false;

        this(typeof(null))
        {
            is_value = false;
        }
        this(T v)
        {
            moveEmplace(v, value);
            is_value = true;
        }

        ~this()
        {
            if (is_value)
                value.destroy();
        }

        bool opCast(T : bool)() const
            => is_value;

        bool opEquals(typeof(null)) const
            => !is_value;
        bool opEquals(T v) const
            => is_value && value == v;

        void opAssign(typeof(null))
        {
            if (is_value)
                value.destroy();
            is_value = false;
        }
        void opAssign(U)(U v)
            if (is(U : T))
        {
            if (!is_value)
                moveEmplace(v, value);
            else
                value = v;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (!is_value)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}

template Nullable(T)
    if (is(T == enum))
{
    struct Nullable
    {
        T value;
        bool is_value;

        this(typeof(null))
        {
            is_value = false;
        }
        this(T v)
        {
            value = v;
            is_value = true;
        }

        bool opCast(T : bool)() const
            => is_value;

        bool opEquals(typeof(null)) const
            => !is_value;
        bool opEquals(T v) const
            => is_value && value == v;

        void opAssign(typeof(null))
        {
            is_value = false;
        }
        void opAssign(T v)
        {
            value = v;
            is_value = true;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (!is_value)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}
