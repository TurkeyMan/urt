// Minimal object.d - replaces druntime's implicit root module.
//
// This file is the auditing frontier: every symbol added here is a
// symbol the compiler or linker demanded.  Keep it as small as possible.
module object;

static assert(__VERSION__ >= 2112,
    "uRT requires DMD frontend 2.112+ (DMD ≥2.112, LDC ≥1.42). " ~
    "Older frontends use TypeInfo-based AA hooks incompatible with uRT's template-based AAs.");

// ----------------------------------------------------------------------
// Platform-dependent ABI flags (must match druntime's detection)
// ----------------------------------------------------------------------

version (X86_64)
{
    version (DigitalMars) version = WithArgTypes;
    else version (Windows) {} // Win64 ABI doesn't need argTypes
    else version = WithArgTypes;
}
else version (AArch64)
{
    version (OSX) {}
    else version (iOS) {}
    else version (TVOS) {}
    else version (WatchOS) {}
    else version = WithArgTypes;
}

// ----------------------------------------------------------------------
// Fundamental type aliases (compiler hardcodes references to these)
// ----------------------------------------------------------------------

alias size_t = typeof(int.sizeof);
alias ptrdiff_t = typeof(cast(void*)0 - cast(void*)0);
alias nullptr_t = typeof(null);
alias noreturn = typeof(*null);

// needed so druntime's core.stdc.stdio compiles on AArch64
version (AArch64)
{
    extern(C++, std) struct __va_list
    {
        void* __stack;
        void* __gr_top;
        void* __vr_top;
        int __gr_offs;
        int __vr_offs;
    }
}

version (Windows)
    alias wchar wchar_t;
else version (Posix)
    alias dchar wchar_t;
else version (WASI)
    alias dchar wchar_t;
else version (FreeStanding)
    alias dchar wchar_t;

alias string  = immutable(char)[];
alias wstring = immutable(wchar)[];
alias dstring = immutable(dchar)[];

alias hash_t = size_t;

// Required by __importc_builtins.di for lazy module references in ImportC.
template imported(string name)
{
    mixin("import imported = " ~ name ~ ";");
}

// ----------------------------------------------------------------------
// Primitive tools
// ----------------------------------------------------------------------

// TODO: move the functions here so object doesn't import these modules...
public import urt.lifetime : move, forward;
public import urt.meta : Alias, AliasSeq;
public import urt.util : min, max, swap;

//alias Alias(alias a) = a;
//alias Alias(T) = T;
//
//alias AliasSeq(TList...) = TList;
//
//T min(T)(T a, T b) pure nothrow @nogc @safe
//    => b < a ? b : a;
//
//T max(T)(T a, T b) pure nothrow @nogc @safe
//    => b > a ? b : a;
//
//ref T swap(T)(ref T a, return ref T b)
//{
//    import urt.lifetime : move, moveEmplace;
//
//    T t = a.move;
//    b.move(a);
//    t.move(b);
//    return b;
//}
//
//T swap(T)(ref T a, T b)
//{
//    import urt.lifetime : move, moveEmplace;
//
//    auto t = a.move;
//    b.move(a);
//    return t.move;
//}

// ----------------------------------------------------------------------
// ^^ helpers
// ----------------------------------------------------------------------

static if (__VERSION__ >= 2113)
{
    static import urt.atomic;
    alias _d_atomicOp = urt.atomic.atomic_op;

    static import urt.math;
    alias _d_pow = urt.math.pow;

    auto _d_sqrt(T)(T x)
    {
        // TODO: should we have a `float` one?
        return urt.math.sqrt(x);
    }
}

// ----------------------------------------------------------------------
// Object - root of the class hierarchy
// ----------------------------------------------------------------------

class Object
{
@nogc:
    static if (__VERSION__ >= 2113)
        void* __monitor;

    size_t toHash() @trusted nothrow
    {
        size_t addr = cast(size_t) cast(void*) this;
        return addr ^ (addr >>> 4);
    }

    bool opEquals(Object rhs)
        => this is rhs;

    int opCmp(Object rhs)
        => 0;

    ptrdiff_t toString(char[] buffer) const nothrow
        => try_copy_string(buffer, "Object");
}

// Free-function opEquals for class types - the compiler lowers `a == b`
// on class objects to a call to this function.
bool opEquals(LHS, RHS)(LHS lhs, RHS rhs)
    if ((is(LHS : const Object) || is(LHS : const shared Object)) &&
        (is(RHS : const Object) || is(RHS : const shared Object)))
{
    static if (__traits(compiles, lhs.opEquals(rhs)) && __traits(compiles, rhs.opEquals(lhs)))
    {
        if (lhs is rhs)
            return true;
        if (lhs is null || rhs is null)
            return false;
        if (!lhs.opEquals(rhs))
            return false;
        if (typeid(lhs) is typeid(rhs) || !__ctfe && typeid(lhs).opEquals(typeid(rhs)))
            return true;
        return rhs.opEquals(lhs);
    }
    else
        return .opEquals!(Object, Object)(*cast(Object*) &lhs, *cast(Object*) &rhs);
}

// ----------------------------------------------------------------------
// TypeInfo - compiler generates references for typeid, AAs, etc.
// ----------------------------------------------------------------------

class TypeInfo
{
@nogc:
    size_t getHash(scope const void* p) @trusted nothrow const
        => 0;

    bool equals(scope const void* p1, scope const void* p2) @trusted const
        => p1 == p2;

    int compare(scope const void* p1, scope const void* p2) @trusted const
        => 0;

    @property size_t tsize() nothrow pure const @safe @nogc
        => 0;

    const(TypeInfo) next() nothrow pure const @nogc
        => null;

    size_t[] offTi() nothrow const
        => null;

    @property uint flags() nothrow pure const @safe @nogc
        => 0;

    @property size_t talign() nothrow pure const @safe @nogc
        => tsize;

    const(void)[] initializer() nothrow pure const @safe @nogc
        => null;

    @property immutable(void)* rtInfo() nothrow pure const @safe @nogc
        => null;

    version (WithArgTypes)
    {
        int argTypes(out TypeInfo arg1, out TypeInfo arg2) @safe nothrow
        {
            arg1 = null;
            arg2 = null;
            return 0;
        }
    }

    override size_t toHash() @trusted nothrow const
        => 0;

    override bool opEquals(Object rhs)
        => false;

    override int opCmp(Object rhs)
        => 0;

    override ptrdiff_t toString(char[] buffer) const nothrow
        => try_copy_string(buffer, "TypeInfo");
}

struct Interface
{
    TypeInfo_Class classinfo;
    void*[] vtbl;
    size_t offset;
}

struct OffsetTypeInfo
{
    size_t offset;
    TypeInfo ti;
}

class TypeInfo_Class : TypeInfo
{
@nogc:
    byte[]      m_init;
    string      name;
    void*[]     vtbl;
    Interface[] interfaces;
    TypeInfo_Class base;
    void*       destructor;
    void function(Object) nothrow @nogc classInvariant;

    enum ClassFlags : ushort
    {
        isCOMclass   = 0x1,
        noPointers   = 0x2,
        hasOffTi     = 0x4,
        hasCtor      = 0x8,
        hasGetMembers = 0x10,
        hasTypeInfo  = 0x20,
        isAbstract   = 0x40,
        isCPPclass   = 0x80,
        hasDtor      = 0x100,
        hasNameSig   = 0x200,
    }
    ClassFlags m_flags;
    ushort     depth;
    void*      deallocator;
    OffsetTypeInfo[] m_offTi;
    void function(Object) @nogc defaultConstructor;

    immutable(void)* m_RTInfo;
    override @property immutable(void)* rtInfo() nothrow pure const @safe { return m_RTInfo; }

    uint[4] nameSig;

    override @property size_t tsize() nothrow pure const @safe
    {
        return (void*).sizeof;
    }
}

// TypeInfo_Struct - compiler generates static instances for every struct type.
// Field layout must exactly match what the compiler emits.
class TypeInfo_Struct : TypeInfo
{
@nogc:
    override ptrdiff_t toString(char[] buffer) const nothrow
        => try_copy_string(buffer, name);

    override size_t toHash() @trusted nothrow const
        => hashOf(mangledName);

    override bool opEquals(Object o)
    {
        if (this is o) return true;
        auto s = cast(const TypeInfo_Struct) o;
        return s && this.mangledName == s.mangledName;
    }

    override size_t getHash(scope const void* p) @trusted pure nothrow const
    {
        if (xtoHash)
            return (*xtoHash)(p);
        return 0;
    }

    override bool equals(scope const void* p1, scope const void* p2) @trusted pure nothrow const
    {
        if (!p1 || !p2) return false;
        if (xopEquals)
        {
            const dg = _member_func(p1, xopEquals);
            return dg.xopEquals(p2);
        }
        return p1 == p2;
    }

    override int compare(scope const void* p1, scope const void* p2) @trusted pure nothrow const
    {
        if (p1 == p2) return 0;
        if (!p1) return -1;
        if (!p2) return 1;
        if (xopCmp)
        {
            const dg = _member_func(p1, xopCmp);
            return dg.xopCmp(p2);
        }
        return 0;
    }

    override @property size_t tsize() nothrow pure const
        => initializer().length;

    override const(void)[] initializer() nothrow pure const @safe @nogc
        => m_init;

    override @property uint flags() nothrow pure const
        => m_flags;

    override @property size_t talign() nothrow pure const
        => m_align;

    string mangledName;

    @property string name() nothrow const @trusted
        => mangledName; // no demangling - avoids pulling in core.demangle

    void[] m_init;

    @safe pure nothrow
    {
        size_t    function(in void*) @nogc                xtoHash;
        bool      function(in void*, in void*) @nogc      xopEquals;
        int       function(in void*, in void*) @nogc      xopCmp;
        ptrdiff_t function(in void*, const(char)[]) @nogc xtoString;

        enum StructFlags : uint
        {
            hasPointers = 0x1,
            isDynamicType = 0x2,
        }
        StructFlags m_flags;
    }
    union
    {
        void function(void*) @nogc                        xdtor;
        void function(void*, const TypeInfo_Struct) @nogc xdtorti;
    }
    void function(void*) xpostblit;

    uint m_align;

    version (WithArgTypes)
    {
        override int argTypes(out TypeInfo arg1, out TypeInfo arg2)
        {
            arg1 = m_arg1;
            arg2 = m_arg2;
            return 0;
        }

        TypeInfo m_arg1;
        TypeInfo m_arg2;
    }

    override @property immutable(void)* rtInfo() nothrow pure const @safe @nogc
        => m_RTInfo;

    immutable(void)* m_RTInfo;
}

class TypeInfo_Enum : TypeInfo
{
@nogc:
    override size_t getHash(scope const void* p) const { return base.getHash(p); }
    override bool equals(scope const void* p1, scope const void* p2) const { return base.equals(p1, p2); }
    override int compare(scope const void* p1, scope const void* p2) const { return base.compare(p1, p2); }
    override @property size_t tsize() nothrow pure const { return base.tsize; }
    override const(TypeInfo) next() nothrow pure const @nogc { return base.next; }
    override @property uint flags() nothrow pure const { return base.flags; }
    override @property size_t talign() nothrow pure const { return base.talign; }
    override @property immutable(void)* rtInfo() nothrow pure const @safe @nogc { return base.rtInfo; }

    override const(void)[] initializer() nothrow pure const @nogc
        => m_init.length ? m_init : base.initializer();

    version (WithArgTypes)
    {
        override int argTypes(out TypeInfo arg1, out TypeInfo arg2)
            => base.argTypes(arg1, arg2);
    }

    TypeInfo base;
    string   name;
    void[]   m_init;
}

class TypeInfo_Pointer : TypeInfo
{
@nogc:
    override @property size_t tsize() nothrow pure const
        => (void*).sizeof;

    override const(TypeInfo) next() nothrow pure const @nogc
        => m_next;

    TypeInfo m_next;
}

class TypeInfo_Array : TypeInfo
{
@nogc:
    override @property size_t tsize() nothrow pure const
        => (void[]).sizeof;

    override const(TypeInfo) next() nothrow pure const @nogc
        => value;

    TypeInfo value;
}

// Built-in array TypeInfo subclasses - the compiler generates references to
// these for common array types.  Empty subclasses are sufficient; the
// compiler fills in the `value` field.
class TypeInfo_Ah : TypeInfo_Array {}   // ubyte[]
class TypeInfo_Ag : TypeInfo_Array {}   // byte[]
class TypeInfo_Aa : TypeInfo_Array {}   // char[]
class TypeInfo_Aaya : TypeInfo_Array {} // string[]
class TypeInfo_At : TypeInfo_Array {}   // ushort[]
class TypeInfo_As : TypeInfo_Array {}   // short[]
class TypeInfo_Au : TypeInfo_Array {}   // wchar[]
class TypeInfo_Ak : TypeInfo_Array {}   // uint[]
class TypeInfo_Ai : TypeInfo_Array {}   // int[]
class TypeInfo_Aw : TypeInfo_Array {}   // dchar[]
class TypeInfo_Am : TypeInfo_Array {}   // ulong[]
class TypeInfo_Al : TypeInfo_Array {}   // long[]
class TypeInfo_Af : TypeInfo_Array {}   // float[]
class TypeInfo_Ad : TypeInfo_Array {}   // double[]
class TypeInfo_Av : TypeInfo_Array {}   // void[]

class TypeInfo_StaticArray : TypeInfo
{
@nogc:
    override @property size_t tsize() nothrow pure const
        => len * value.tsize;

    override const(TypeInfo) next() nothrow pure const @nogc
        => value;

    TypeInfo value;
    size_t   len;
}

class TypeInfo_Vector : TypeInfo
{
@nogc:
    override @property size_t tsize() nothrow pure const
        => base.tsize;

    TypeInfo base;
}

class TypeInfo_Function : TypeInfo
{
@nogc:
    override @property size_t tsize() nothrow pure const
        => 0;

    TypeInfo next;
    string deco;
}

class TypeInfo_Delegate : TypeInfo
{
@nogc:
    override @property size_t tsize() nothrow pure const
    {
        alias dg = int delegate();
        return dg.sizeof;
    }

    TypeInfo next;
    string deco;
}

class TypeInfo_Interface : TypeInfo
{
@nogc:
    override @property size_t tsize() nothrow pure const
        => (void*).sizeof;

    TypeInfo_Class info;
}

class TypeInfo_Tuple : TypeInfo
{
    TypeInfo[] elements;
}

class TypeInfo_AssociativeArray : TypeInfo
{
@nogc:
    override ptrdiff_t toString(char[] buffer) const nothrow
    {
        if (!buffer.ptr)
            return value.toString(null) + key.toString(null) + 2;
        ptrdiff_t l = value.toString(buffer);
        if (l < 0)
            return l;
        if (buffer.length < l + 2)
            return -1;
        buffer[l] = '[';
        ptrdiff_t k = key.toString(buffer[l + 1 .. $]);
        if (k < 0)
            return k;
        l += k + 2;
        if (buffer.length < l)
            return -1;
        buffer[l - 1] = ']';
        return l;
    }

    override bool opEquals(Object o)
    {
        if (this is o) return true;
        auto c = cast(const TypeInfo_AssociativeArray) o;
        return c && this.key == c.key && this.value == c.value;
    }

    override bool equals(scope const void* p1, scope const void* p2) @trusted const
        => xopEquals(p1, p2);

    override hash_t getHash(scope const void* p) nothrow @trusted const
        => xtoHash(p);

    override @property size_t tsize() nothrow pure const
        => (char[int]).sizeof;

    override const(void)[] initializer() const @trusted
        => (cast(void*)null)[0 .. (char[int]).sizeof];

    override const(TypeInfo) next() nothrow pure const @nogc { return value; }
    override @property uint flags() nothrow pure const { return 1; }

    private static import urt.internal.aa;
    alias Entry(K, V) = urt.internal.aa.Entry!(K, V);

    TypeInfo value;
    TypeInfo key;
    TypeInfo entry;

    bool function(scope const void* p1, scope const void* p2) nothrow @safe xopEquals;
    hash_t function(scope const void*) nothrow @safe xtoHash;

    alias aaOpEqual(K, V) = urt.internal.aa._aaOpEqual!(K, V);
    alias aaGetHash(K, V) = urt.internal.aa._aaGetHash!(K, V);

    override @property size_t talign() nothrow pure const
        => (char[int]).alignof;
}

class TypeInfo_Const : TypeInfo
{
@nogc:
    override size_t getHash(scope const void* p) const { return base.getHash(p); }
    override bool equals(scope const void* p1, scope const void* p2) const { return base.equals(p1, p2); }
    override int compare(scope const void* p1, scope const void* p2) const { return base.compare(p1, p2); }
    override @property size_t tsize() nothrow pure const { return base.tsize; }
    override const(TypeInfo) next() nothrow pure const @nogc { return base.next; }
    override @property uint flags() nothrow pure const { return base.flags; }
    override const(void)[] initializer() nothrow pure const @nogc { return base.initializer(); }
    override @property size_t talign() nothrow pure const { return base.talign; }

    TypeInfo base;
}

class TypeInfo_Invariant : TypeInfo_Const
{
}

class TypeInfo_Shared : TypeInfo_Const
{
}

class TypeInfo_Inout : TypeInfo_Const
{
}

// ----------------------------------------------------------------------
// TypeInfo for built-in types - compiler references these by mangled name
// (e.g. TypeInfo_k for uint).  Single-character suffixes follow D's type
// encoding: a=char, b=bool, d=double, f=float, g=byte, h=ubyte,
// i=int, k=uint, l=long, m=ulong, o=dchar, s=short, t=wchar,
// u=ushort, v=void, x=const, y=immutable.
// ----------------------------------------------------------------------

class TypeInfo_a : TypeInfo { override @property size_t tsize() nothrow pure const @safe @nogc { return char.sizeof; } }
class TypeInfo_b : TypeInfo { override @property size_t tsize() nothrow pure const @safe @nogc { return bool.sizeof; } }
class TypeInfo_d : TypeInfo { override @property size_t tsize() nothrow pure const @safe @nogc { return double.sizeof; } }
class TypeInfo_f : TypeInfo { override @property size_t tsize() nothrow pure const @safe @nogc { return float.sizeof; } }
class TypeInfo_g : TypeInfo { override @property size_t tsize() nothrow pure const @safe @nogc { return byte.sizeof; } }
class TypeInfo_h : TypeInfo { override @property size_t tsize() nothrow pure const @safe @nogc { return ubyte.sizeof; } }
class TypeInfo_i : TypeInfo { override @property size_t tsize() nothrow pure const @safe @nogc { return int.sizeof; } }
class TypeInfo_k : TypeInfo { override @property size_t tsize() nothrow pure const @safe @nogc { return uint.sizeof; } }
class TypeInfo_l : TypeInfo { override @property size_t tsize() nothrow pure const @safe @nogc { return long.sizeof; } }
class TypeInfo_m : TypeInfo { override @property size_t tsize() nothrow pure const @safe @nogc { return ulong.sizeof; } }
class TypeInfo_o : TypeInfo { override @property size_t tsize() nothrow pure const @safe @nogc { return dchar.sizeof; } }
class TypeInfo_s : TypeInfo { override @property size_t tsize() nothrow pure const @safe @nogc { return short.sizeof; } }
class TypeInfo_t : TypeInfo { override @property size_t tsize() nothrow pure const @safe @nogc { return wchar.sizeof; } }
class TypeInfo_u : TypeInfo { override @property size_t tsize() nothrow pure const @safe @nogc { return ushort.sizeof; } }
class TypeInfo_v : TypeInfo { override @property size_t tsize() nothrow pure const @safe @nogc { return 0; } }

// Helper for TypeInfo_Struct delegate dispatch.
// Uses a union to overlay raw delegate ABI (ptr + funcptr) with typed delegate fields.
private struct _member_func
{
    union
    {
        struct
        {
            const void* ptr;
            const void* funcptr;
        }

        @safe pure nothrow
        {
            bool delegate(in void*) @nogc xopEquals;
            int delegate(in void*) @nogc xopCmp;
        }
    }
}

// ----------------------------------------------------------------------
// __ArrayDtor - compiler lowers dynamic array destruction to this
// ----------------------------------------------------------------------

void __ArrayDtor(T)(scope T[] a)
{
    foreach_reverse (ref T e; a)
        e.__xdtor();
}

// ----------------------------------------------------------------------
// Compiler hook templates - array & AA literal lowering
// These are only called at runtime; CTFE evaluates literals directly.
// ----------------------------------------------------------------------

void* _d_arrayliteralTX(T)(size_t length) @trusted pure nothrow
{
    assert(false, "Array literals require druntime");
}

alias AssociativeArray(Key, Value) = Value[Key];

public import urt.internal.aa : _d_aaIn, _d_aaDel, _d_aaNew, _d_aaEqual, _d_assocarrayliteralTX;
public import urt.internal.aa : _d_aaLen, _d_aaGetY, _d_aaGetRvalueX, _d_aaApply, _d_aaApply2;

private import urt.internal.aa : makeAA;

// Lower an AA to a newaa struct for static initialization.
auto _aaAsStruct(K, V)(V[K] aa) @safe
{
    assert(__ctfe);
    return makeAA!(K, V)(aa);
}

Tret _d_arraycatnTX(Tret, Tarr...)(auto ref Tarr froms) @trusted
{
    assert(false, "Array concatenation requires druntime");
}


T _d_newclassT(T)() @trusted
    if (is(T == class))
{
    assert(false, "new class requires druntime");
/+
    if (__ctfe)
        assert(false, "new class not supported at CTFE without druntime");

    import urt.mem : alloc, memcpy;

    enum sz = __traits(classInstanceSize, T);
    auto p = alloc(sz).ptr;
    if (p is null)
        assert(false, "out of memory in _d_newclassT");

    auto initSym = __traits(initSymbol, T);
    memcpy(p, initSym.ptr, sz);
    return cast(T)cast(void*)p;
+/
}

ref Tarr _d_arrayappendcTX(Tarr : T[], T)(return ref scope Tarr px, size_t n) @trusted
{
    assert(false, "Array append requires druntime");
}

ref Tarr _d_arrayappendT(Tarr : T[], T)(return ref scope Tarr x, scope Tarr y) @trusted
{
    assert(false, "Array append requires druntime");
}

// ----------------------------------------------------------------------
// Compiler hook templates - array operations, construction, etc.
// These are lowered by the compiler for various language constructs.
// ----------------------------------------------------------------------

T[] _d_newarrayT(T)(size_t length, bool isShared = false) @trusted
{
    import urt.mem.alloc : alloc;
//    assert(false, "new array requires druntime");
    return cast(T[])alloc(T.sizeof * length);
}

Tarr _d_newarraymTX(Tarr : U[], T, U)(size_t[] dims, bool isShared = false) @trusted
{
    assert(false, "new multi-dim array requires druntime");
}

T* _d_newitemT(T)() @trusted
{
    import urt.mem.alloc : alloc;
//    assert(false, "new item requires druntime");
    return cast(T*)alloc(T.sizeof).ptr;
}

T _d_newThrowable(T)() @trusted
    if (is(T : Throwable))
{
    assert(false, "new throwable requires druntime");
}

int __cmp(T)(scope const T[] lhs, scope const T[] rhs) @trusted
{
    immutable len = lhs.length <= rhs.length ? lhs.length : rhs.length;
    foreach (i; 0 .. len)
    {
        if (lhs.ptr[i] < rhs.ptr[i])
            return -1;
        if (lhs.ptr[i] > rhs.ptr[i])
            return 1;
    }
    return (lhs.length > rhs.length) - (lhs.length < rhs.length);
}

bool __equals(T1, T2)(scope const T1[] lhs, scope const T2[] rhs)
nothrow @nogc pure @trusted
if (__traits(isScalar, T1) && __traits(isScalar, T2))
{
    if (lhs.length != rhs.length)
        return false;
    static if (T1.sizeof == T2.sizeof
        && (T1.sizeof >= 4 || __traits(isUnsigned, T1) == __traits(isUnsigned, T2))
        && !__traits(isFloating, T1) && !__traits(isFloating, T2))
    {
        if (__ctfe)
        {
            foreach (i; 0 .. lhs.length)
                if (lhs.ptr[i] != rhs.ptr[i]) return false;
            return true;
        }
        else
        {
            import urt.mem : memcmp;
            return !lhs.length || 0 == memcmp(cast(const void*) lhs.ptr, cast(const void*) rhs.ptr, lhs.length * T1.sizeof);
        }
    }
    else
    {
        foreach (i; 0 .. lhs.length)
            if (lhs.ptr[i] != rhs.ptr[i]) return false;
        return true;
    }
}

bool __equals(T1, T2)(scope T1[] lhs, scope T2[] rhs)
if (!__traits(isScalar, T1) || !__traits(isScalar, T2))
{
    if (lhs.length != rhs.length)
        return false;
    foreach (i; 0 .. lhs.length)
        if (lhs[i] != rhs[i]) return false;
    return true;
}

TTo[] __ArrayCast(TFrom, TTo)(return scope TFrom[] from) @nogc pure @trusted
{
    const fromSize = from.length * TFrom.sizeof;
    if (fromSize % TTo.sizeof != 0)
        assert(false, "Array cast misalignment");
    return (cast(TTo*) from.ptr)[0 .. fromSize / TTo.sizeof];
}

Tarr _d_arrayctor(Tarr : T[], T)(return scope Tarr to, scope Tarr from) @trusted
{
    assert(false, "Array ctor requires druntime");
}

void _d_arraysetctor(Tarr : T[], T)(scope Tarr p, scope ref T value) @trusted
{
    assert(false, "Array set-ctor requires druntime");
}

Tarr _d_arrayassign_l(Tarr : T[], T)(return scope Tarr to, scope Tarr from) @trusted
{
    assert(false, "Array assign requires druntime");
}

Tarr _d_arrayassign_r(Tarr : T[], T)(return scope Tarr to, scope Tarr from) @trusted
{
    assert(false, "Array assign requires druntime");
}

void _d_arraysetassign(Tarr : T[], T)(return scope Tarr to, scope ref T value) @trusted
{
    assert(false, "Array set-assign requires druntime");
}

size_t _d_arraysetlengthT(Tarr : T[], T)(return ref scope Tarr arr, size_t newlength) @trusted
{
    assert(false, "Array setlength requires druntime");
}

// LDC wraps the above in a template namespace
template _d_arraysetlengthTImpl(Tarr : T[], T)
{
    size_t _d_arraysetlengthT(return scope ref Tarr arr, size_t newlength) @trusted pure nothrow
    {
        assert(false, "Array setlength requires druntime");
    }
}

string _d_assert_fail(A...)(const scope string comp, auto ref const scope A a)
{
    return "assertion failure";
}

// ----------------------------------------------------------------------
// Runtime hooks: assertions, array bounds checks
// These are referenced by compiler-generated code even in debug builds.
// ----------------------------------------------------------------------

extern(C) void _d_assert_msg(string msg, string file, uint line) nothrow @nogc
{
    import urt.exception : assert_handler;
    assert_handler()(file, line, msg);
}

extern(C) void _d_assertp(immutable(char)* file, uint line) nothrow @nogc @trusted
{
    import urt.mem : strlen;
    import urt.exception : assert_handler;
    auto f = file[0 .. file ? strlen(file) : 0];
    assert_handler()(f, line, null);
}

extern(C) void _d_assert(string file, uint line) nothrow @nogc
{
    import urt.exception : assert_handler;
    assert_handler()(file, line, null);
}

extern(C) void _d_arraybounds_indexp(string file, uint line, size_t index, size_t length) nothrow @nogc
{
    import urt.exception : assert_handler;
    assert_handler()(file, line, "array index out of bounds");
}

extern(C) void _d_arraybounds_slicep(string file, uint line, size_t lower, size_t upper, size_t length) nothrow @nogc
{
    import urt.exception : assert_handler;
    assert_handler()(file, line, "array slice out of bounds");
}

extern(C) void _d_arrayboundsp(string file, uint line) nothrow @nogc
{
    import urt.exception : assert_handler;
    assert_handler()(file, line, "array index out of bounds");
}

extern(C) void _d_arraybounds(string file, uint line) nothrow @nogc
{
    import urt.exception : assert_handler;
    assert_handler()(file, line, "array index out of bounds");
}

// Unittest assert hooks - the compiler generates these for assert() inside
// unittest blocks instead of the regular _d_assertp/_d_assert_msg.
extern(C) void _d_unittestp(immutable(char)* file, uint line) nothrow @nogc @trusted
{
    import urt.mem : strlen;
    import urt.exception : assert_handler;
    auto f = file[0 .. file ? strlen(file) : 0];
    assert_handler()(f, line, "unittest assertion failure");
}

extern(C) void _d_unittest_msg(string msg, string file, uint line) nothrow @nogc @trusted
{
    import urt.exception : assert_handler;
    assert_handler()(file, line, msg);
}

extern(C) void _d_unittest(string file, uint line) nothrow @nogc
{
    import urt.exception : assert_handler;
    assert_handler()(file, line, "unittest assertion failure");
}

// GC allocation hook - compiler lowers `new` to this.  In our @nogc world
// it should never be called from production code; provided so unittest
// blocks that accidentally use `new` can at least link.
extern(C) void* _d_allocmemory(size_t sz) nothrow @nogc @trusted
{
    import urt.mem.alloc : alloc;
    return alloc(sz).ptr;
}

// ----------------------------------------------------------------------
// LDC extern(C) runtime hooks
// LDC's codegen emits calls to old-style extern(C) functions for many
// operations where DMD uses template-based hooks.  These stubs satisfy
// the linker.  Implementations are provided where feasible; others
// assert(false) and must be fleshed out if the code path is hit.
// ----------------------------------------------------------------------

version (LDC)
{

// --- Bounds checks (LDC variants without 'p' suffix) -------------------

extern(C) void _d_arraybounds_index(string file, uint line, size_t index, size_t length) nothrow @nogc
{
    import urt.exception : assert_handler;
    if (auto handler = assert_handler)
        handler(file, line, "array index out of bounds");
    else
        _halt();
}

extern(C) void _d_arraybounds_slice(string file, uint line, size_t lower, size_t upper, size_t length) nothrow @nogc
{
    import urt.exception : assert_handler;
    if (auto handler = assert_handler)
        handler(file, line, "array slice out of bounds");
    else
        _halt();
}

// --- Array slice copy (LDC emits this for non-elaborate arr[] = other[]) -
// Bounds-checked memcpy: verifies dstlen == srclen, then copies raw bytes.

extern(C) void _d_array_slice_copy(void* dst, size_t dstlen, void* src, size_t srclen, size_t elemsize) nothrow @nogc @trusted
{
    assert(dstlen == srclen, "array slice lengths don't match for copy");
    import urt.mem : memcpy;
    memcpy(dst, src, dstlen * elemsize);
}

// --- Class allocation and casting (old-style extern C) -----------------

extern(C) void* _d_allocclass(TypeInfo_Class ci) nothrow @nogc @trusted
{
    import urt.mem : alloc, memcpy;
    auto init = ci.initializer;
    auto p = alloc(init.length).ptr;
    if (p !is null)
        memcpy(p, init.ptr, init.length);
    return p;
}

extern(C) Object _d_dynamic_cast(Object o, TypeInfo_Class c) nothrow @nogc @trusted
{
    // Traverse classinfo chain to check if o is-a c
    if (o is null) return null;
    auto oc = typeid(o);
    while (oc !is null)
    {
        if (oc is c)
            return o;
        oc = oc.base;
    }
    return null;
}

extern(C) void* _d_interface_cast(void* p, TypeInfo_Class c) nothrow @nogc @trusted
{
    // TODO: full interface casting requires traversing the Interface[] table
    // in the target object's classinfo to find the right vtable offset.
    // For now, return null (cast fails).
    return null;
}

// --- Struct array equality (old-style) ---------------------------------

extern(C) int _adEq2(void[] a1, void[] a2, TypeInfo ti) nothrow @nogc @trusted
{
    if (a1.length != a2.length) return 0;
    import urt.mem : memcmp;
    return memcmp(a1.ptr, a2.ptr, a1.length) == 0 ? 1 : 0;
}

} // version (LDC)

// --- Old-style array allocation (extern C) ------------------------------

extern(C) void[] _d_newarrayT(const TypeInfo ti, size_t length) nothrow @nogc @trusted
{
    import urt.mem.alloc : alloc;
    auto elemsize = ti.next ? ti.next.tsize : 1;
    return alloc(length * elemsize);
}

extern(C) void[] _d_newarrayiT(const TypeInfo ti, size_t length) nothrow @nogc @trusted
{
    import urt.mem.alloc : alloc;
    auto elemsize = ti.next ? ti.next.tsize : 1;
    return alloc(length * elemsize);
}

extern(C) void[] _d_newarrayU(const TypeInfo ti, size_t length) nothrow @nogc @trusted
{
    import urt.mem.alloc : alloc;
    auto elemsize = ti.next ? ti.next.tsize : 1;
    return alloc(length * elemsize);
}

// Unconditional halt - avoids circular dependency with assert.
private void _halt() nothrow @nogc @trusted
{
    version (D_InlineAsm_X86_64)
        asm nothrow @nogc { hlt; }
    else version (D_InlineAsm_X86)
        asm nothrow @nogc { hlt; }
    else
        *(cast(int*) null) = 0; // fallback: null deref
}

void __move_post_blt(S)(ref S newLocation, ref S oldLocation) nothrow
    if (is(S == struct))
{
    static if (__traits(hasMember, S, "__xpostblit"))
        newLocation.__xpostblit();
}

void __ArrayPostblit(T)(T[] a)
{
    foreach (ref e; a)
        static if (__traits(hasMember, T, "__xpostblit"))
            e.__xpostblit();
}

int __switch(T, caseLabels...)(const scope T[] condition) pure nothrow @safe @nogc
{
    foreach (i, s; caseLabels)
    {
        static if (is(typeof(s) : typeof(condition)))
        {
            if (condition == s)
                return cast(int) i;
        }
    }
    return -1;
}

void __switch_error()(string file = __FILE__, size_t line = __LINE__)
{
    assert(false, "Final switch error");
}

template _d_delstructImpl(T)
{
    void _d_delstruct(ref T p) @trusted
    {
        p = null;
    }
}

nothrow @nogc @trusted pure extern(C) void _d_delThrowable(scope Throwable) {}

// ----------------------------------------------------------------------
// _arrayOp - compiler hook for vectorized array slice operations.
// DMD lowers `dest[] = a[] ^ b[]` to `_arrayOp!(T[], T[], T[], "^", "=")(dest, a, b)`.
// Args are in Reverse Polish Notation (RPN).
// ----------------------------------------------------------------------

template _arrayOp(Args...)
{
    static if (is(Args[0] == E[], E))
    {
        alias T = E;

        T[] _arrayOp(T[] res, _Filter!(_is_type, Args[1 .. $]) args) nothrow @nogc @trusted
        {
            foreach (pos; 0 .. res.length)
                mixin(_scalar_exp!(Args[1 .. $]) ~ ";");
            return res;
        }
    }
}

// ---- _arrayOp helpers (all private, CTFE-only) ----

private template _Filter(alias pred, args...)
{
    static if (args.length == 0)
        alias _Filter = AliasSeq!();
    else static if (pred!(args[0]))
        alias _Filter = AliasSeq!(args[0], _Filter!(pred, args[1 .. $]));
    else
        alias _Filter = _Filter!(pred, args[1 .. $]);
}

private enum _is_type(T) = true;
private enum _is_type(alias a) = false;

private bool _is_unary_op(string op) pure nothrow @safe @nogc
    => op.length > 0 && op[0] == 'u';

private bool _is_binary_op(string op) pure nothrow @safe @nogc
{
    if (op == "^^") return true;
    if (op.length != 1) return false;
    switch (op[0])
    {
    case '+', '-', '*', '/', '%', '|', '&', '^':
        return true;
    default:
        return false;
    }
}

private bool _is_binary_assign_op(string op)
    => op.length >= 2 && op[$ - 1] == '=' && _is_binary_op(op[0 .. $ - 1]);

// Convert size_t to string at CTFE.
private string _size_to_str(size_t num) pure @safe
{
    enum digits = "0123456789";
    if (num < 10) return digits[num .. num + 1];
    return _size_to_str(num / 10) ~ digits[num % 10 .. num % 10 + 1];
}

// Generate element-wise mixin expression from RPN args (CTFE-evaluated enum).
// Uses a fixed-size stack with depth counter to avoid dynamic array operations
// (which would require _d_arraysetlengthT at semantic analysis time).
private enum _scalar_exp(Args...) = () {
    string[Args.length] stack;
    size_t depth;
    size_t args_idx;

    static if (is(Args[0] == U[], U))
        alias Type = U;
    else
        alias Type = Args[0];

    foreach (i, arg; Args)
    {
        static if (is(arg == E[], E))
        {
            stack[depth] = "args[" ~ _size_to_str(args_idx++) ~ "][pos]";
            ++depth;
        }
        else static if (is(arg))
        {
            stack[depth] = "args[" ~ _size_to_str(args_idx++) ~ "]";
            ++depth;
        }
        else static if (_is_unary_op(arg))
        {
            auto op = arg[0] == 'u' ? arg[1 .. $] : arg;
            static if (is(Type : int))
                stack[depth - 1] = "cast(typeof(" ~ stack[depth - 1] ~ "))" ~ op ~ "cast(int)(" ~ stack[depth - 1] ~ ")";
            else
                stack[depth - 1] = op ~ stack[depth - 1];
        }
        else static if (arg == "=")
        {
            stack[depth - 1] = "res[pos] = cast(T)(" ~ stack[depth - 1] ~ ")";
        }
        else static if (_is_binary_assign_op(arg))
        {
            stack[depth - 1] = "res[pos] " ~ arg ~ " cast(T)(" ~ stack[depth - 1] ~ ")";
        }
        else static if (_is_binary_op(arg))
        {
            stack[depth - 2] = "(" ~ stack[depth - 2] ~ " " ~ arg ~ " " ~ stack[depth - 1] ~ ")";
            --depth;
        }
    }
    return stack[0];
}();

// ----------------------------------------------------------------------
// _d_cast - dynamic class cast, walks TypeInfo_Class.base chain
// ----------------------------------------------------------------------

void* _d_cast(To, From)(From o) @trusted
    if (is(From == class) && is(To == class))
{
    if (o is null) return null;
    auto ci = typeid(o);
    auto target = typeid(To);
    do
    {
        if (ci is target) return cast(void*) o;
        ci = ci.base;
    }
    while (ci !is null);
    return null;
}

void* _d_cast(To, From)(From o) @trusted
    if (is(From == class) && is(To == interface))
{
    if (o is null) return null;
    // Walk interface list - not implemented yet, fall back to null
    assert(false, "Interface cast not yet implemented");
}

// ----------------------------------------------------------------------
// Throwable / Exception / Error - exception hierarchy
// ----------------------------------------------------------------------

class Throwable : Object
{
    string msg;
    Throwable next;
    string file;
    size_t line;

    private uint _refcount;

    @nogc @safe pure nothrow this(string msg, Throwable next = null)
    {
        this.msg = msg;
        this.next = next;
    }

    @nogc @safe pure nothrow this(string msg, string file, size_t line, Throwable next = null)
    {
        this.msg = msg;
        this.file = file;
        this.line = line;
        this.next = next;
    }

    const(char)[] message() const @nogc @safe pure nothrow
        => msg;

    @system @nogc final pure nothrow ref uint refcount() return
        => _refcount;

    static Throwable chainTogether(return scope Throwable e1, return scope Throwable e2) nothrow @nogc
    {
        if (!e1)
            return e2;
        if (!e2)
            return e1;
        for (auto e = e1; ; e = e.next)
        {
            if (!e.next)
            {
                e.next = e2;
                break;
            }
        }
        return e1;
    }
}

class Exception : Throwable
{
    @nogc @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }
}

class Error : Throwable
{
    Throwable bypassedException;

    @nogc @safe pure nothrow this(string msg, Throwable next = null)
    {
        super(msg, next);
    }

    @nogc @safe pure nothrow this(string msg, string file, size_t line, Throwable next = null)
    {
        super(msg, file, line, next);
    }
}

// ----------------------------------------------------------------------
// destroy - compiler generates calls for scope guards, etc.
// ----------------------------------------------------------------------

void destroy(bool initialize = true, T)(ref T obj) if (is(T == struct))
{
    destruct_recurse(obj);
    static if (initialize)
    {
        static if (__traits(isZeroInit, T))
            (cast(ubyte*)&obj)[0 .. T.sizeof] = 0;
        else
        {
            auto init = __traits(initSymbol, T);
            (cast(ubyte*)&obj)[0 .. T.sizeof] = (cast(const ubyte*)init.ptr)[0 .. T.sizeof];
        }
    }
}

// Destruct a struct by calling its __xdtor, but only if it truly belongs
// to this type (Bugzilla 14746).
void destruct_recurse(S)(ref S s) if (is(S == struct))
{
    static if (__traits(hasMember, S, "__xdtor") && __traits(isSame, S, __traits(parent, s.__xdtor)))
        s.__xdtor();
}

void destruct_recurse(E, size_t n)(ref E[n] arr)
{
    foreach_reverse (ref elem; arr)
        destruct_recurse(elem);
}

void destroy(bool initialize = true, T)(T obj) if (is(T == class))
{
    static if (__traits(hasMember, T, "__xdtor"))
        obj.__xdtor();
}

void destroy(bool initialize = true, T)(ref T obj) if (!is(T == struct) && !is(T == class))
{
    static if (initialize)
        obj = T.init;
}

// ----------------------------------------------------------------------
// .dup / .idup - array duplication properties
// ----------------------------------------------------------------------

@property immutable(T)[] idup(T)(T[] a) @trusted
{
    assert(__ctfe, "idup is only supported at compile time");
    // CTFE-compatible: the interpreter handles ~= natively.
    // At runtime this would assert via _d_arrayappendcTX.
    immutable(T)[] r;
    foreach (ref e; a)
        r ~= cast(immutable(T)) e;
    return r;
}

@property T[] dup(T)(const(T)[] a) @trusted
{
    assert(__ctfe, "dup is only supported at compile time");
    T[] r;
    foreach (ref e; a)
        r ~= cast(T) e;
    return r;
}

// ----------------------------------------------------------------------
// Compiler-generated struct equality/comparison fallbacks
// ----------------------------------------------------------------------

bool _xopEquals(in void*, in void*)
    => false;

bool _xopCmp(in void*, in void*)
    => false;

// ----------------------------------------------------------------------
// hashOf - used by AAs and anywhere .toHash is needed
// ----------------------------------------------------------------------

size_t hashOf(T)(auto ref T val, size_t seed = 0) pure nothrow @nogc @trusted
{
    import urt.hash : fnv1a, fnv1a64, fnv1_initial;

    static if (is(T : const(char)[]))
    {
        static if (is(size_t == uint))
            return fnv1a(cast(ubyte[])val, seed ? seed : fnv1_initial!uint);
        else
            return fnv1a64(cast(ubyte[])val, seed ? seed : fnv1_initial!ulong);
    }
    else static if (is(T V : V*))
    {
        // Pointers - CTFE compatible
        if (__ctfe)
        {
            if (val is null)
                return seed;
            assert(0, "Unable to hash non-null pointer at compile time");
        }
        size_t v = cast(size_t)val;
        return _fnv(v ^ (v >> 4), seed);
    }
    else static if (__traits(isIntegral, T))
    {
        // Integers - CTFE compatible, no reinterpreting cast
        static if (T.sizeof <= size_t.sizeof)
            return _fnv(cast(size_t)val, seed);
        else
            return _fnv(cast(size_t)(val ^ (val >>> (size_t.sizeof * 8))), seed);
    }
    else static if (__traits(isFloating, T))
    {
        // At CTFE we cannot reinterpret float bits; use lossy integer cast
        // it'd be better if we could work out the magnitude and multipley the significant bits into an integer
        if (__ctfe)
            return _fnv(cast(size_t)cast(long)val, seed);
        static if (is(size_t == uint))
            return fnv1a((cast(ubyte*)&val)[0..T.sizeof], seed ? seed : fnv1_initial!uint);
        else
            return fnv1a64((cast(ubyte*)&val)[0..T.sizeof], seed ? seed : fnv1_initial!uint);
    }
    else static if (is(T == struct))
    {
        // Structs - hash each field (CTFE compatible)
        size_t h = seed;
        foreach (ref field; val.tupleof)
            h = hashOf(field, h);
        return h;
    }
    else static if (is(T == enum))
    {
        static if (is(T EType == enum))
            return hashOf(cast(EType)val, seed);
        else
            return _fnv(0, seed);
    }
    else
        return seed;
}

private size_t _fnv(size_t val, size_t seed) pure nothrow @nogc @trusted
{
    import urt.hash : fnv1a, fnv1a64, fnv1_initial;

    // maybe it's better to write out the algorithm inline...?
    if (__ctfe)
    {
        static if (is(size_t == uint))
        {
            ubyte[4] bytes = [ val & 0xFF, (val >> 8) & 0xFF, (val >> 16) & 0xFF, (val >> 24) & 0xFF ];
            return fnv1a(bytes, seed ? seed : fnv1_initial!uint);
        }
        else
        {
            ubyte[8] bytes = [ val & 0xFF, (val >> 8) & 0xFF, (val >> 16) & 0xFF, (val >> 24) & 0xFF,
                               (val >> 32) & 0xFF, (val >> 40) & 0xFF, (val >> 48) & 0xFF, (val >> 56) & 0xFF ];
            return fnv1a64(bytes, seed ? seed : fnv1_initial!ulong);
        }
    }
    static if (is(size_t == uint))
        return fnv1a((cast(ubyte*)&val)[0..4], seed ? seed : fnv1_initial!uint);
    else
        return fnv1a64((cast(ubyte*)&val)[0..8], seed ? seed : fnv1_initial!ulong);
}

// ----------------------------------------------------------------------
// ModuleInfo - compiler emits one per module with ctor/dtor/unittest info.
// Variable-sized: fields are packed after the header based on flag bits.
// ----------------------------------------------------------------------

enum
{
    MIctorstart       = 0x1,
    MIctordone        = 0x2,
    MIstandalone      = 0x4,
    MItlsctor         = 0x8,
    MItlsdtor         = 0x10,
    MIctor            = 0x20,
    MIdtor            = 0x40,
    MIxgetMembers     = 0x80,
    MIictor           = 0x100,
    MIunitTest        = 0x200,
    MIimportedModules = 0x400,
    MIlocalClasses    = 0x800,
    MIname            = 0x1000,
}

struct ModuleInfo
{
    uint _flags;
    uint _index;

const:
    private void* addr_of(int flag) return nothrow pure @nogc @trusted
    {
        void* p = cast(void*)&this + ModuleInfo.sizeof;

        if (flags & MItlsctor)
        {
            if (flag == MItlsctor)
                return p;
            p += (void function()).sizeof;
        }
        if (flags & MItlsdtor)
        {
            if (flag == MItlsdtor)
                return p;
            p += (void function()).sizeof;
        }
        if (flags & MIctor)
        {
            if (flag == MIctor)
                return p;
            p += (void function()).sizeof;
        }
        if (flags & MIdtor)
        {
            if (flag == MIdtor)
                return p;
            p += (void function()).sizeof;
        }
        if (flags & MIxgetMembers)
        {
            if (flag == MIxgetMembers)
                return p;
            p += (void*).sizeof;
        }
        if (flags & MIictor)
        {
            if (flag == MIictor)
                return p;
            p += (void function()).sizeof;
        }
        if (flags & MIunitTest)
        {
            if (flag == MIunitTest)
                return p;
            p += (void function()).sizeof;
        }
        if (flags & MIimportedModules)
        {
            if (flag == MIimportedModules)
                return p;
            p += size_t.sizeof + *cast(size_t*)p * (immutable(ModuleInfo)*).sizeof;
        }
        if (flags & MIlocalClasses)
        {
            if (flag == MIlocalClasses)
                return p;
            p += size_t.sizeof + *cast(size_t*)p * (TypeInfo_Class).sizeof;
        }
        if (true || flags & MIname)
        {
            if (flag == MIname)
                return p;
        }
        assert(0);
    }

    @property uint flags() nothrow pure @nogc
        => _flags;

    @property void function() tlsctor() nothrow pure @nogc @trusted
        => flags & MItlsctor ? *cast(typeof(return)*)addr_of(MItlsctor) : null;

    @property void function() tlsdtor() nothrow pure @nogc @trusted
        => flags & MItlsdtor ? *cast(typeof(return)*)addr_of(MItlsdtor) : null;

    @property void function() ctor() nothrow pure @nogc @trusted
        => flags & MIctor ? *cast(typeof(return)*)addr_of(MIctor) : null;

    @property void function() dtor() nothrow pure @nogc @trusted
        => flags & MIdtor ? *cast(typeof(return)*)addr_of(MIdtor) : null;

    @property void function() ictor() nothrow pure @nogc @trusted
        => flags & MIictor ? *cast(typeof(return)*)addr_of(MIictor) : null;

    @property void function() unitTest() nothrow pure @nogc @trusted
        => flags & MIunitTest ? *cast(typeof(return)*)addr_of(MIunitTest) : null;

    @property immutable(ModuleInfo*)[] importedModules() return nothrow pure @nogc @trusted
    {
        if (flags & MIimportedModules)
        {
            auto p = cast(size_t*)addr_of(MIimportedModules);
            return (cast(immutable(ModuleInfo*)*)(p + 1))[0 .. *p];
        }
        return null;
    }

    @property string name() nothrow @nogc @trusted
    {
        // LDC always emits the name after the packed fields, even without
        // setting MIname.  addr_of(MIname) handles this (see `true ||` guard).
        auto p = cast(immutable char*)addr_of(MIname);
        size_t len = 0;
        while (p[len] != 0) ++len;
        return p[0 .. len];
    }
}

// ----------------------------------------------------------------------
// Module registration - LDC uses _Dmodule_ref linked list
//
// On ELF targets the compiler generates .init_array entries that chain
// ModuleReference structs into _Dmodule_ref. On Linux, glibc's crt0
// calls .init_array automatically. On bare-metal, start.S does it.
// ----------------------------------------------------------------------

version (Windows) {}
else
    extern(C) __gshared void* _Dmodule_ref = null;

version (linux)
{
    struct CompilerDSOData
    {
        size_t _version;
        void** _slot;
        immutable(ModuleInfo*)* _minfo_beg, _minfo_end;
    }

    extern(C) __gshared immutable(ModuleInfo*)* _elf_minfo_beg;
    extern(C) __gshared immutable(ModuleInfo*)* _elf_minfo_end;

    extern(C) void _d_dso_registry(CompilerDSOData* data) nothrow @nogc
    {
        if (data._version < 1)
            return;

        if (*data._slot is null)
        {
            *data._slot = cast(void*)data;
            _elf_minfo_beg = data._minfo_beg;
            _elf_minfo_end = data._minfo_end;
        }
        else
        {
            *data._slot = null;
            _elf_minfo_beg = null;
            _elf_minfo_end = null;
        }
    }
}

// ----------------------------------------------------------------------
// TypeInfo for const/immutable char[] - compiler references by name
// ----------------------------------------------------------------------

class TypeInfo_Axa : TypeInfo_Array {}  // const(char)[]
class TypeInfo_Aya : TypeInfo_Array {}  // immutable(char)[] = string

// ----------------------------------------------------------------------
// _d_invariant - contract invariant hook (matches rt.invariant_ mangling)
// ----------------------------------------------------------------------

pragma(mangle, "_D2rt10invariant_12_d_invariantFC6ObjectZv")
void _d_invariant_impl(Object o) nothrow @nogc
{
    assert(o !is null);
    auto c = typeid(o);
    do
    {
        if (c.classInvariant)
            c.classInvariant(o);
        c = c.base;
    }
    while (c);
}

// ----------------------------------------------------------------------
// Compiler-generated memset intrinsics (struct initialization)
// ----------------------------------------------------------------------

private struct Bits128 { ulong[2] v; }
private struct Bits80  { ubyte[real.sizeof] v; }
private struct Bits160 { ubyte[2 * real.sizeof] v; }

extern(C) nothrow @nogc @trusted
{
    short* _memset16(short* p, short value, size_t count)
    {
        foreach (i; 0 .. count)
            p[i] = value;
        return p;
    }

    int* _memset32(int* p, int value, size_t count)
    {
        foreach (i; 0 .. count)
            p[i] = value;
        return p;
    }

    long* _memset64(long* p, long value, size_t count)
    {
        foreach (i; 0 .. count)
            p[i] = value;
        return p;
    }

    Bits80* _memset80(Bits80* p, Bits80 value, size_t count)
    {
        foreach (i; 0 .. count)
            p[i] = value;
        return p;
    }

    Bits128* _memset128(Bits128* p, Bits128 value, size_t count)
    {
        foreach (i; 0 .. count)
            p[i] = value;
        return p;
    }

    void[]* _memset128ii(void[]* p, void[] value, size_t count)
    {
        foreach (i; 0 .. count)
            p[i] = value;
        return p;
    }

    Bits160* _memset160(Bits160* p, Bits160 value, size_t count)
    {
        foreach (i; 0 .. count)
            p[i] = value;
        return p;
    }

    float* _memsetFloat(float* p, float value, size_t count)
    {
        foreach (i; 0 .. count)
            p[i] = value;
        return p;
    }

    double* _memsetDouble(double* p, double value, size_t count)
    {
        foreach (i; 0 .. count)
            p[i] = value;
        return p;
    }

    void* _memsetn(void* p, void* value, int count, size_t sizelem)
    {
        auto dst = cast(ubyte*) p;
        auto src = cast(ubyte*) value;
        foreach (_; 0 .. count)
        {
            foreach (j; 0 .. sizelem)
                dst[j] = src[j];
            dst += sizelem;
        }
        return p;
    }
}

private ptrdiff_t try_copy_string(char[] buffer, const(char)[] src) pure nothrow @nogc
{
    if (buffer.ptr)
    {
        if (buffer.length < src.length)
            return -1;
        buffer[0 .. src.length] = src[];
    }
    return src.length;
}
