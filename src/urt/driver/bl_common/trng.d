// Bouffalo hardware TRNG driver (SEC_ENG block), shared across BL618 and BL808.
//
// Vendor reference: bl808_sec_eng.c Sec_Eng_Trng_{Enable,Read}. We don't
// pull in the whole sec_eng TU just for the TRNG -- the register layout is
// stable across the BL family and this is the only peripheral inside
// SEC_ENG we currently consume.
//
// SEC_ENG_BASE      = 0x2000_4000
// CTRL_0 @ +0x200   bits: 0=BUSY (r), 1=TRIG_1T (wo), 2=EN, 3=DOUT_CLR_1T (wo),
//                          4=HT_ERROR (r), 9=INT_CLR_1T (wo)
// DOUT_0..7 @ +0x208..+0x224   32 bytes of output per Read
//
// On BL808 D0 the SEC_ENG path depends on M0 having opened a TZC window. If
// BUSY never clears on D0 the path isn't open and this needs to become an
// IPC RPC to M0's TRNG.
module urt.driver.bl_common.trng;

import core.volatile;

@nogc nothrow:


private enum uint SEC_ENG_BASE = 0x2000_4000;
private enum uint TRNG_CTRL_0  = SEC_ENG_BASE + 0x200;
private enum uint TRNG_DOUT_0  = SEC_ENG_BASE + 0x208;

private enum uint BIT_BUSY     = 1U << 0;
private enum uint BIT_TRIG     = 1U << 1;
private enum uint BIT_EN       = 1U << 2;
private enum uint BIT_DOUT_CLR = 1U << 3;
private enum uint BIT_INT_CLR  = 1U << 9;
// Must stay set in polled mode -- TRNG raises SEC_TRNG_IRQn (#28) on every
// completion otherwise. Found by ecdh hang: with MIE on and this bit clear,
// the peripheral asserts its IRQ at the CLIC, IP latches on a line with
// IE=0 + null handler, and BUSY stops clearing on subsequent triggers.
// Matches vendor's Sec_Eng_Trng_Int_Disable in bl808_sec_eng.c.
private enum uint BIT_INT_MASK = 1U << 11;

// Loose timeout for the BUSY wait: TRNG produces 32 bytes in tens of
// microseconds at the default reseed interval; this caps a real hang.
private enum uint BUSY_TIMEOUT = 100_000;

private __gshared bool _enabled = false;


bool trng_init()
{
    if (_enabled)
        return true;

    uint v = mmio_load(TRNG_CTRL_0);
    v |= BIT_EN | BIT_INT_MASK;
    mmio_store(TRNG_CTRL_0, v);
    v |= BIT_INT_CLR;
    mmio_store(TRNG_CTRL_0, v);

    if (!wait_not_busy())
        return false;

    v = mmio_load(TRNG_CTRL_0) | BIT_INT_CLR;
    mmio_store(TRNG_CTRL_0, v);

    _enabled = true;
    return true;
}

// Read one 32-byte block. Returns false on timeout. Caller must have run
// trng_init() first -- sys_init does this for every Bouffalo build.
bool trng_read_block(ubyte[32] dst)
{
    uint v = mmio_load(TRNG_CTRL_0) | BIT_TRIG;
    mmio_store(TRNG_CTRL_0, v);

    if (!wait_not_busy())
        return false;

    // Mirror vendor IRQ handler: clear INT after each completion so the
    // peripheral's pending-IRQ state stays clean across back-to-back reads.
    mmio_store(TRNG_CTRL_0, mmio_load(TRNG_CTRL_0) | BIT_INT_CLR);

    foreach (i; 0 .. 8)
    {
        const uint word = mmio_load(TRNG_DOUT_0 + i * 4);
        const size_t off = i * 4;
        dst[off + 0] = cast(ubyte)(word);
        dst[off + 1] = cast(ubyte)(word >> 8);
        dst[off + 2] = cast(ubyte)(word >> 16);
        dst[off + 3] = cast(ubyte)(word >> 24);
    }

    // Clear TRIG, then pulse DOUT_CLR so the next trigger starts fresh.
    v = mmio_load(TRNG_CTRL_0) & ~BIT_TRIG;
    mmio_store(TRNG_CTRL_0, v);
    mmio_store(TRNG_CTRL_0, v | BIT_DOUT_CLR);
    mmio_store(TRNG_CTRL_0, v);

    return true;
}

// Fill an arbitrary-length buffer.
bool trng_read(ubyte[] dst)
{
    while (dst.length > 0)
    {
        ubyte[32] block = void;
        if (!trng_read_block(block))
            return false;

        const size_t n = dst.length < 32 ? dst.length : 32;
        dst[0 .. n] = block[0 .. n];
        dst = dst[n .. $];
    }
    return true;
}

// mbedtls entropy poll callback. urt/internal/mbedtls.c registers this as
// an MBEDTLS_ENTROPY_SOURCE_STRONG source when MBEDTLS_NO_PLATFORM_ENTROPY
// is defined (i.e. on every embedded config we ship). Through that, all
// crypto_random_bytes calls eventually pull from this TRNG.
extern(C) int urt_platform_entropy_poll(void* data, ubyte* output, size_t len, size_t* olen)
{
    if (!trng_read(output[0 .. len]))
    {
        *olen = 0;
        return -1;
    }
    *olen = len;
    return 0;
}


private:

pragma(inline, true) uint mmio_load(uint addr)
    => volatileLoad(cast(uint*)cast(size_t)addr);

pragma(inline, true) void mmio_store(uint addr, uint val)
    => volatileStore(cast(uint*)cast(size_t)addr, val);

bool wait_not_busy()
{
    uint count = BUSY_TIMEOUT;
    while ((mmio_load(TRNG_CTRL_0) & BIT_BUSY) != 0)
    {
        if (--count == 0)
            return false;
    }
    return true;
}
