// HBN (Hibernate) RAM persistence -- 4KB at 0x20010000, survives deep sleep
// if VBAT is maintained. Shared across all Bouffalo variants that expose the
// AON/HBN domain (BL618, BL808 D0, BL808 M0). On BL808 both cores reference
// the same struct at the start of .hbn_ram, so whichever core boots first
// can restore wall-clock state seeded by the other.
//
// Storage strategy:
//   D0 build: storage defined in C (hbn_ram.c) and compiled into BAREMETAL
//             alongside start.S. This file declares the symbol extern.
//   M0 build: storage defined here in D via @persist, since the M0
//             BAREMETAL_SRCS does not include hbn_ram.c. The struct layout
//             must match D0's C definition exactly.
module urt.driver.bl_common.hbn;

import urt.attribute : persist, used;

@nogc nothrow:


/// Persistent state across hibernate cycles. Layout must stay byte-identical
/// to `struct hbn_persist` in third_party/urt/src/urt/driver/bl808/hbn_ram.c.
struct HbnPersist
{
    enum uint HBN_MAGIC = 0x4F57_4254; // "OWBT" (OpenWatt Boot Time)

    uint magic;
    long utc_offset; // HBN ticks from RTC epoch to Unix epoch
}

/// Access the persistent state in HBN RAM.
HbnPersist* hbn_persist() => &_hbn_persist;


private:

// @used pins the storage so --gc-sections keeps it even before any M0
// consumer exists, mirroring D0's hbn_ram.c which uses __attribute__((used)).
version (BL808_M0)
    extern(C) @persist @used __gshared HbnPersist _hbn_persist;
else
    extern(C) extern __gshared HbnPersist _hbn_persist;
