// BL618 platform package (T-Head E907 RV32IMAFC).
//
// Re-exports the chip's peripheral drivers. sys_init lives in
// urt.driver.bl_common.system and is shared with BL808 M0 / D0.
module urt.driver.bl618;

public import urt.driver.bl618.uart;
public import urt.driver.bl618.irq;
public import urt.driver.bl618.timer;
public import urt.driver.bl_common.trng;
public import urt.driver.bl_common.system;
