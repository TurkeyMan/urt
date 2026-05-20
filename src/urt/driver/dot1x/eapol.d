module urt.driver.dot1x.eapol;

nothrow @nogc:


private ushort be_u16(const(ubyte)* p) pure
{
    return cast(ushort)((cast(ushort)p[0] << 8) | p[1]);
}

enum ushort eth_p_eapol = 0x888E;

enum ubyte eapol_version_2001 = 1;
enum ubyte eapol_version_2004 = 2;

enum ubyte eapol_type_packet = 0;
enum ubyte eapol_type_start  = 1;
enum ubyte eapol_type_logoff = 2;
enum ubyte eapol_type_key    = 3;

enum size_t eapol_hdr_len = 4;   // ver + type + body_len(2)

struct EapolFrame
{
    ubyte version_;
    ubyte type;
    ushort body_length;
    const(ubyte)[] body;
}

bool decode_eapol(const(ubyte)[] frame, ref EapolFrame out_)
{
    if (frame.length < eapol_hdr_len)
        return false;

    ushort body_len = be_u16(frame.ptr + 2);
    if (cast(size_t)body_len + eapol_hdr_len > frame.length)
        return false;

    out_.version_ = frame[0];
    out_.type = frame[1];
    out_.body_length = body_len;
    out_.body = frame[eapol_hdr_len .. eapol_hdr_len + body_len];
    return true;
}

size_t encode_eapol_header(ubyte[] dst, ubyte version_, ubyte type, size_t body_len)
{
    if (dst.length < eapol_hdr_len || body_len > ushort.max)
        return 0;
    dst[0] = version_;
    dst[1] = type;
    dst[2] = cast(ubyte)(body_len >> 8);
    dst[3] = cast(ubyte)(body_len & 0xff);
    return eapol_hdr_len;
}
