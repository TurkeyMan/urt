module urt.crc;

import urt.meta : IntForWidth;
import urt.traits : is_unsigned_int;

nothrow @nogc:


enum Algorithm : ubyte
{
    crc16_usb,
    crc16_modbus,
    crc16_kermit,
    crc16_xmodem,
    crc16_ccitt_false,
    crc16_iso_hdlc,
    crc16_dnp,
    crc32_iso_hdlc,
    crc32_castagnoli,

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
    if (is_unsigned_int!T)
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
        static if (params.reflect)
            crc = (crc >> 8) ^ table[cast(ubyte)crc ^ b];
        else
            crc = cast(T)((crc << 8) ^ table[(crc >> 8) ^ b]);
    }

    static if (params.final_xor)
        return T(crc ^ params.final_xor);
    else
        return crc;
}

// computes 2 CRC's for 2 points in the data stream...
T calculate_crc_2(Algorithm algo, T = IntForWidth!(param_table[algo].width*2))(const void[] data, uint early_offset) pure
    if (is_unsigned_int!T)
{
    enum crc_params params = param_table[algo];
    static assert(params.width * 2 <= T.sizeof*8, "T is too small for the CRC width");

    alias table = crc_table!algo;

    const ubyte[] bytes = cast(ubyte[])data;

    T high_crc = 0;
    T crc = cast(T)params.initial;

    size_t i = 0;
    for (; i < bytes.length; ++i)
    {
        if (i == early_offset)
        {
            high_crc = crc;
            goto fast_loop; // skips a redundant loop entry check
        }
        static if (params.reflect)
            crc = (crc >> 8) ^ table[cast(ubyte)crc ^ bytes[i]];
        else
            crc = cast(T)((crc << 8) ^ table[(crc >> 8) ^ bytes[i]]);
    }
    goto done; // skip over the fast loop entry check (which will fail)

    for (; i < bytes.length; ++i)
    {
    fast_loop:
        static if (params.reflect)
            crc = (crc >> 8) ^ table[cast(ubyte)crc ^ bytes[i]];
        else
            crc = cast(T)((crc << 8) ^ table[(crc >> 8) ^ bytes[i]]);
    }

done:
    static if (params.final_xor)
    {
        crc ^= cast(T)params.final_xor;
        high_crc ^= cast(T)params.final_xor;
    }

    static if (params.width <= 8)
        return ushort(crc | high_crc << 8);
    else static if (params.width <= 16)
        return uint(crc | high_crc << 16);
    else if (params.width <= 32)
        return ulong(crc | high_crc << 32);
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

    assert(calculate_crc!(Algorithm.crc16_modbus)(checkData[]) == param_table[Algorithm.crc16_modbus].check);
    assert(calculate_crc!(Algorithm.crc16_ezsp)(checkData[]) == param_table[Algorithm.crc16_ezsp].check);
    assert(calculate_crc!(Algorithm.crc16_kermit)(checkData[]) == param_table[Algorithm.crc16_kermit].check);
    assert(calculate_crc!(Algorithm.crc16_usb)(checkData[]) == param_table[Algorithm.crc16_usb].check);
    assert(calculate_crc!(Algorithm.crc16_xmodem)(checkData[]) == param_table[Algorithm.crc16_xmodem].check);
    assert(calculate_crc!(Algorithm.crc16_iso_hdlc)(checkData[]) == param_table[Algorithm.crc16_iso_hdlc].check);
    assert(calculate_crc!(Algorithm.crc16_dnp)(checkData[]) == param_table[Algorithm.crc16_dnp].check);
    assert(calculate_crc!(Algorithm.crc32_iso_hdlc)(checkData[]) == param_table[Algorithm.crc32_iso_hdlc].check);
    assert(calculate_crc!(Algorithm.crc32_castagnoli)(checkData[]) == param_table[Algorithm.crc32_castagnoli].check);

    // check that rolling CRC works...
    ushort crc = calculate_crc!(Algorithm.crc16_modbus)(checkData[0 .. 5]);
    assert(calculate_crc!(Algorithm.crc16_modbus)(checkData[5 .. 9], crc) == param_table[Algorithm.crc16_modbus].check);
           crc = calculate_crc!(Algorithm.crc16_iso_hdlc)(checkData[0 .. 5]);
    assert(calculate_crc!(Algorithm.crc16_iso_hdlc)(checkData[5 .. 9], crc) == param_table[Algorithm.crc16_iso_hdlc].check);
    uint crc32 = calculate_crc!(Algorithm.crc32_iso_hdlc)(checkData[0 .. 5]);
    assert(calculate_crc!(Algorithm.crc32_iso_hdlc)(checkData[5 .. 9], crc32) == param_table[Algorithm.crc32_iso_hdlc].check);
}


private:

enum crc_params[] param_table = [
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
T reflect(T)(T value, ubyte bits)
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
