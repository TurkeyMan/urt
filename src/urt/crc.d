module urt.crc;

import urt.meta : IntForWidth;
import urt.traits : is_unsigned_int;

nothrow @nogc:


enum Algorithm : ubyte
{
    crc8_smbus,
    crc16_usb,
    crc16_modbus,
    crc16_kermit,
    crc16_xmodem,
    crc16_ccitt_false,
    crc16_iso_hdlc,
    crc16_dnp,
    crc32_iso_hdlc,
    crc32_castagnoli,

    crc8_itu_t     = crc8_smbus,
    crc8_autosar   = crc8_smbus,
    crc16_default_short_packet  = crc16_kermit,     // good default choice for small packets
    crc32_default               = crc32_castagnoli, // has SSE4.2 hardware implementation

    // aliases
    crc16_bluetooth     = crc16_kermit,
    crc16_ccitt_true    = crc16_kermit,
    crc16_ccitt         = crc16_kermit,
    crc16_ezsp          = crc16_ccitt_false,
    crc16_ibm_sdlc      = crc16_iso_hdlc,
    crc32_nvme          = crc32_castagnoli,
}

struct crc_params
{
    ubyte width;
    bool reflect;
    uint poly;
    uint initial;
    uint final_xor;
    uint check;
}

alias CRCType(Algorithm algo) = IntForWidth!(param_table[algo].width);
alias crc_table(Algorithm algo) = crc_table!(param_table[algo].width, param_table[algo].poly, param_table[algo].reflect);

// compute a CRC with runtime parameters
T calculate_crc(T = uint)(const void[] data, ref const crc_params params, ref const T[256] table) pure
    if (is_unsigned_int!T)
{
    assert(params.width <= T.sizeof*8, "T is too small for the CRC width");

    const ubyte[] bytes = cast(ubyte[])data;

    T crc = cast(T)params.initial;

    if (params.reflect)
    {
        foreach (b; bytes)
            crc = (crc >> 8) ^ table[cast(ubyte)crc ^ b];
    }
    else
    {
        foreach (b; bytes)
            crc = cast(T)((crc << 8) ^ table[(crc >> 8) ^ b]);
    }

    return crc ^ cast(T)params.final_xor;
}

// compute a CRC with hard-coded parameters
T calculate_crc(Algorithm algo, T = CRCType!algo)(const void[] data, T initial = cast(T)param_table[algo].initial^param_table[algo].final_xor) pure
    if (!hardware_crc_support!(algo, T) && is_unsigned_int!T)
{
    enum crc_params params = param_table[algo];
    static assert(params.width <= T.sizeof*8, "T is too small for the CRC width");

    alias table = crc_table!algo;

    const ubyte[] bytes = cast(ubyte[])data;

    static if (params.final_xor)
        T crc = initial ^ params.final_xor;
    else
        T crc = initial;

    foreach (b; bytes)
    {
        static if (params.width <= 8)
            crc = table[crc ^ b];
        else static if (params.reflect)
            crc = (crc >> 8) ^ table[cast(ubyte)crc ^ b];
        else
            crc = cast(T)((crc << 8) ^ table[(crc >> 8) ^ b]);
    }

    static if (params.final_xor)
        return T(crc ^ params.final_xor);
    else
        return crc;
}

T calculate_crc(Algorithm algo, T = CRCType!algo)(const void[] data, T initial = cast(T)param_table[algo].initial^param_table[algo].final_xor) pure
    if (hardware_crc_support!(algo, T) && is_unsigned_int!T)
{
    version (Espressif)
    {
        enum crc_params params = param_table[algo];
        enum T fxor = cast(T)params.final_xor;

        const ubyte* ptr = cast(ubyte*)data.ptr;
        uint len = cast(uint)data.length;

        static if (params.width == 32)
        {
            static if (params.reflect)
                alias rom_crc = crc32_le;
            else
                alias rom_crc = crc32_be;
            return cast(T)(~rom_crc(cast(uint)~(initial ^ fxor), ptr, len) ^ fxor);
        }
        else static if (params.width == 16)
        {
            static if (params.reflect)
                alias rom_crc = crc16_le;
            else
                alias rom_crc = crc16_be;
            return cast(T)(cast(ushort)(~rom_crc(cast(ushort)~(initial ^ fxor), ptr, len) ^ fxor));
        }
        else static if (params.width == 8)
        {
            static if (params.reflect)
                alias rom_crc = crc8_le;
            else
                alias rom_crc = crc8_be;
            return cast(T)(cast(ubyte)(~rom_crc(cast(ubyte)~(initial ^ fxor), ptr, len) ^ fxor));
        }
    }
    else
        static assert(false, "Hardware CRC support claimed, but not implemented for this platform");
}


// computes 2 CRC's for 2 points in the data stream...
T calculate_crc_2(Algorithm algo, T = IntForWidth!(param_table[algo].width*2))(const void[] data, uint early_offset) pure
    if (!hardware_crc_support!(algo, T) && is_unsigned_int!T)
{
    enum crc_params params = param_table[algo];
    static assert(params.width * 2 <= T.sizeof*8, "T is too small for the CRC width");

    alias CT = CRCType!algo;
    alias table = crc_table!algo;

    const ubyte[] bytes = cast(ubyte[])data;

    CT high_crc = 0;
    CT crc = cast(CT)params.initial;

    size_t i = 0;
    for (; i < bytes.length; ++i)
    {
        if (i == early_offset)
        {
            high_crc = crc;
            goto fast_loop; // skips a redundant loop entry check
        }
        static if (params.width <= 8)
            crc = table[crc ^ bytes[i]];
        else static if (params.reflect)
            crc = (crc >> 8) ^ table[cast(ubyte)crc ^ bytes[i]];
        else
            crc = cast(CT)((crc << 8) ^ table[(crc >> 8) ^ bytes[i]]);
    }
    goto done; // skip over the fast loop entry check (which will fail)

    for (; i < bytes.length; ++i)
    {
    fast_loop:
        static if (params.width <= 8)
            crc = table[crc ^ bytes[i]];
        else static if (params.reflect)
            crc = (crc >> 8) ^ table[cast(ubyte)crc ^ bytes[i]];
        else
            crc = cast(CT)((crc << 8) ^ table[(crc >> 8) ^ bytes[i]]);
    }

done:
    static if (params.final_xor)
    {
        crc ^= cast(CT)params.final_xor;
        high_crc ^= cast(CT)params.final_xor;
    }

    static if (params.width <= 8)
        return cast(T)(cast(uint)crc | (cast(uint)high_crc << 8));
    else static if (params.width <= 16)
        return cast(T)(cast(uint)crc | (cast(uint)high_crc << 16));
    else static if (params.width <= 32)
        return cast(T)(cast(ulong)crc | (cast(ulong)high_crc << 32));
}

T calculate_crc_2(Algorithm algo, T = IntForWidth!(param_table[algo].width*2))(const void[] data, uint early_offset) pure
    if (hardware_crc_support!(algo, T) && is_unsigned_int!T)
{
    version (Espressif)
    {
        enum crc_params params = param_table[algo];

        const ubyte* buf = cast(ubyte*)data.ptr;
        uint len = cast(uint)data.length;

        enum uint fxor = params.final_xor;

        static if (params.width == 32)
        {
            static if (params.reflect)
                alias rom_crc = crc32_le;
            else
                alias rom_crc = crc32_be;

            uint raw_init = cast(uint)~(params.initial ^ fxor);
            uint raw_early = rom_crc(raw_init, buf, early_offset);
            uint early = ~raw_early ^ fxor;
            uint full = ~rom_crc(raw_early, buf + early_offset, len - early_offset) ^ fxor;
            return cast(T)(cast(ulong)full | (cast(ulong)early << 32));
        }
        else static if (params.width == 16)
        {
            static if (params.reflect)
                alias rom_crc = crc16_le;
            else
                alias rom_crc = crc16_be;

            ushort raw_init = cast(ushort)~(params.initial ^ fxor);
            ushort raw_early = rom_crc(raw_init, buf, early_offset);
            ushort early = cast(ushort)(~raw_early ^ fxor);
            ushort full = cast(ushort)(~rom_crc(raw_early, buf + early_offset, len - early_offset) ^ fxor);
            return cast(T)(cast(uint)full | (cast(uint)early << 16));
        }
        else static if (params.width == 8)
        {
            static if (params.reflect)
                alias rom_crc = crc8_le;
            else
                alias rom_crc = crc8_be;

            ubyte raw_init = cast(ubyte)~(params.initial ^ fxor);
            ubyte raw_early = rom_crc(raw_init, buf, early_offset);
            ubyte early = cast(ubyte)(~raw_early ^ fxor);
            ubyte full = cast(ubyte)(~rom_crc(raw_early, buf + early_offset, len - early_offset) ^ fxor);
            return cast(T)(cast(ushort)full | (cast(ushort)early << 8));
        }
    }
    else
        static assert(false, "Hardware CRC support claimed, but not implemented for this platform");
}


T[256] generate_crc_table(T)(ref const crc_params params) pure
    if (is_unsigned_int!T)
{
    enum type_width = T.sizeof * 8;
    assert(params.width <= type_width && params.width > type_width/2, "CRC width must match the size of the type");
    T top_bit = cast(T)(1 << (params.width - 1));

    T[256] table = void;

    foreach (T i; 0..256)
    {
        T crc = i;
        if (params.reflect)
            crc = reflect(crc, 8);

        crc <<= (params.width - 8);  // Shift to align with the polynomial width
        foreach (_; 0..8)
        {
            if ((crc & top_bit) != 0)
                crc = cast(T)((crc << 1) ^ params.poly);
            else
                crc <<= 1;
        }

        if (params.reflect)
            crc = reflect(crc, params.width);

        table[i] = crc;
    }

    return table;
}


unittest
{
    immutable ubyte[9] checkData = ['1','2','3','4','5','6','7','8','9'];

    // verify all algorithms against their check values ("123456789")
    assert(calculate_crc!(Algorithm.crc8_smbus)(checkData[]) == param_table[Algorithm.crc8_smbus].check);
    assert(calculate_crc!(Algorithm.crc16_modbus)(checkData[]) == param_table[Algorithm.crc16_modbus].check);
    assert(calculate_crc!(Algorithm.crc16_ezsp)(checkData[]) == param_table[Algorithm.crc16_ezsp].check);
    assert(calculate_crc!(Algorithm.crc16_kermit)(checkData[]) == param_table[Algorithm.crc16_kermit].check);
    assert(calculate_crc!(Algorithm.crc16_usb)(checkData[]) == param_table[Algorithm.crc16_usb].check);
    assert(calculate_crc!(Algorithm.crc16_xmodem)(checkData[]) == param_table[Algorithm.crc16_xmodem].check);
    assert(calculate_crc!(Algorithm.crc16_iso_hdlc)(checkData[]) == param_table[Algorithm.crc16_iso_hdlc].check);
    assert(calculate_crc!(Algorithm.crc16_dnp)(checkData[]) == param_table[Algorithm.crc16_dnp].check);
    assert(calculate_crc!(Algorithm.crc32_iso_hdlc)(checkData[]) == param_table[Algorithm.crc32_iso_hdlc].check);
    assert(calculate_crc!(Algorithm.crc32_castagnoli)(checkData[]) == param_table[Algorithm.crc32_castagnoli].check);

    // rolling CRC: split at multiple points and verify accumulation
    static foreach (split; 1 .. 9)
    {
        assert(calculate_crc!(Algorithm.crc8_smbus)(checkData[split .. 9],
            calculate_crc!(Algorithm.crc8_smbus)(checkData[0 .. split])) == param_table[Algorithm.crc8_smbus].check);
        assert(calculate_crc!(Algorithm.crc16_modbus)(checkData[split .. 9],
            calculate_crc!(Algorithm.crc16_modbus)(checkData[0 .. split])) == param_table[Algorithm.crc16_modbus].check);
        assert(calculate_crc!(Algorithm.crc16_kermit)(checkData[split .. 9],
            calculate_crc!(Algorithm.crc16_kermit)(checkData[0 .. split])) == param_table[Algorithm.crc16_kermit].check);
        assert(calculate_crc!(Algorithm.crc16_iso_hdlc)(checkData[split .. 9],
            calculate_crc!(Algorithm.crc16_iso_hdlc)(checkData[0 .. split])) == param_table[Algorithm.crc16_iso_hdlc].check);
        assert(calculate_crc!(Algorithm.crc16_xmodem)(checkData[split .. 9],
            calculate_crc!(Algorithm.crc16_xmodem)(checkData[0 .. split])) == param_table[Algorithm.crc16_xmodem].check);
        assert(calculate_crc!(Algorithm.crc16_ccitt_false)(checkData[split .. 9],
            calculate_crc!(Algorithm.crc16_ccitt_false)(checkData[0 .. split])) == param_table[Algorithm.crc16_ccitt_false].check);
        assert(calculate_crc!(Algorithm.crc32_iso_hdlc)(checkData[split .. 9],
            calculate_crc!(Algorithm.crc32_iso_hdlc)(checkData[0 .. split])) == param_table[Algorithm.crc32_iso_hdlc].check);
    }

    // empty data returns the default initial value
    assert(calculate_crc!(Algorithm.crc8_smbus)(null) == 0x00);
    assert(calculate_crc!(Algorithm.crc32_iso_hdlc)(null) == 0x0000_0000);
    assert(calculate_crc!(Algorithm.crc16_kermit)(null) == 0x0000);
    assert(calculate_crc!(Algorithm.crc16_iso_hdlc)(null) == 0x0000);
    assert(calculate_crc!(Algorithm.crc16_xmodem)(null) == 0x0000);
    assert(calculate_crc!(Algorithm.crc16_ccitt_false)(null) == 0xFFFF);
    assert(calculate_crc!(Algorithm.crc16_modbus)(null) == 0xFFFF);

    // single byte
    assert(calculate_crc!(Algorithm.crc32_iso_hdlc)("A") == 0xD3D9_9E8B);

    // dual CRC: verify both halves
    // reflected, final_xor=0
    uint dual16_k = calculate_crc_2!(Algorithm.crc16_kermit)(checkData[], 5);
    assert((dual16_k & 0xFFFF) == param_table[Algorithm.crc16_kermit].check);
    assert((dual16_k >> 16) == calculate_crc!(Algorithm.crc16_kermit)(checkData[0 .. 5]));

    // reflected, final_xor=mask
    uint dual16_h = calculate_crc_2!(Algorithm.crc16_iso_hdlc)(checkData[], 5);
    assert((dual16_h & 0xFFFF) == param_table[Algorithm.crc16_iso_hdlc].check);
    assert((dual16_h >> 16) == calculate_crc!(Algorithm.crc16_iso_hdlc)(checkData[0 .. 5]));

    ulong dual32 = calculate_crc_2!(Algorithm.crc32_iso_hdlc)(checkData[], 5);
    assert((dual32 & 0xFFFF_FFFF) == param_table[Algorithm.crc32_iso_hdlc].check);
    assert((dual32 >> 32) == calculate_crc!(Algorithm.crc32_iso_hdlc)(checkData[0 .. 5]));

    // unreflected, final_xor=0
    uint dual16_x = calculate_crc_2!(Algorithm.crc16_xmodem)(checkData[], 5);
    assert((dual16_x & 0xFFFF) == param_table[Algorithm.crc16_xmodem].check);
    assert((dual16_x >> 16) == calculate_crc!(Algorithm.crc16_xmodem)(checkData[0 .. 5]));

    // 8-bit unreflected
    ushort dual8 = calculate_crc_2!(Algorithm.crc8_smbus)(checkData[], 5);
    assert((dual8 & 0xFF) == param_table[Algorithm.crc8_smbus].check);
    assert((dual8 >> 8) == calculate_crc!(Algorithm.crc8_smbus)(checkData[0 .. 5]));
}


private:

version (Espressif)
{
    // ESP32 have CRC functions in the mask rom which we'll use where applicable

    version (ESP32_S2) enum has_rom_crc_be = false;
    else               enum has_rom_crc_be = true;

    private extern(C) pure nothrow @nogc
    {
        uint crc32_le(uint crc, const ubyte* buf, uint len);
        ushort crc16_le(ushort crc, const ubyte* buf, uint len);
        ubyte crc8_le(ubyte crc, const ubyte* buf, uint len);
        static if (has_rom_crc_be)
        {
            uint crc32_be(uint crc, const ubyte* buf, uint len);
            ushort crc16_be(ushort crc, const ubyte* buf, uint len);
            ubyte crc8_be(ubyte crc, const ubyte* buf, uint len);
        }
    }

    private enum rom_crc_match(Algorithm algo) = (
        (param_table[algo].width == 32 && param_table[algo].poly == 0x04C1_1DB7) ||
        (param_table[algo].width == 16 && param_table[algo].poly == 0x1021) ||
        (param_table[algo].width ==  8 && param_table[algo].poly == 0x07)
    );

    enum hardware_crc_support(Algorithm algo, T) = is(T == CRCType!algo) && rom_crc_match!algo && (param_table[algo].reflect || has_rom_crc_be);
}
else
{
    enum hardware_crc_support(Algorithm algo, T) = false;
}

enum crc_params[] param_table = [
    crc_params( 8, false, 0x07,   0x0000, 0x0000, 0xF4),   // crc8_smbus
    crc_params(16, true,  0x8005, 0xFFFF, 0xFFFF, 0xB4C8), // crc16_usb
    crc_params(16, true,  0x8005, 0xFFFF, 0x0000, 0x4B37), // crc16_modbus
    crc_params(16, true,  0x1021, 0x0000, 0x0000, 0x2189), // crc16_kermit
    crc_params(16, false, 0x1021, 0x0000, 0x0000, 0x31C3), // crc16_xmodem
    crc_params(16, false, 0x1021, 0xFFFF, 0x0000, 0x29B1), // crc16_ccitt_false
    crc_params(16, true,  0x1021, 0xFFFF, 0xFFFF, 0x906E), // crc16_iso_hdlc
    crc_params(16, true,  0x3D65, 0x0000, 0xFFFF, 0xEA82), // crc16_dnp
    crc_params(32, true,  0x04C11DB7, 0xFFFFFFFF, 0xFFFFFFFF, 0xCBF43926), // crc32_iso_hdlc
    crc_params(32, true,  0x1EDC6F41, 0xFFFFFFFF, 0xFFFFFFFF, 0xE3069283), // crc32_castagnoli
];

// helper function to reflect bits (reverse bit order)
T reflect(T)(T value, ubyte bits) pure
{
    T result = 0;
    foreach (i; 0..bits)
    {
        if (value & (1 << i))
            result |= 1 << (bits - 1 - i);
    }
    return result;
}

// this minimises the number of table instantiations
template crc_table(uint width, uint poly, bool reflect)
{
    __gshared immutable crc_table = generate_crc_table!(IntForWidth!width)(crc_params(width, reflect, poly, 0, 0, 0));
}
