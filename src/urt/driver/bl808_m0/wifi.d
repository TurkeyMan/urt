/// BL808 M0 WiFi driver.
///
/// Backs urt.driver.wifi's wifi_hw_* surface on the BL808 M0 core. The
/// vendor LMAC firmware (libwifi.a) and the PHY/RF driver (libbl606p_phyrf.a)
/// are linked in as binary archives; the vendor C sources we kept
/// (ipc_host, bl_cmds, bl_irqs, bl_msg_tx, utils_list) are compiled and
/// linked alongside. Init sequencing, lifetime management, RX event
/// dispatch, and the TX path live here in D. The vendor C is just RPC
/// plumbing and shared-memory ring management.
///
/// Architecture:
///
///   libwifi.a -- runs ON the M0, ~5.6MB of WiFi MAC / scan / AP / STA
///   libbl606p_phyrf.a -- PHY/RF + calibration
///        ^
///        | called via vendor C RPC stubs
///        |
///   vendor C (bl_msg_tx.c, ipc_host.c, bl_cmds.c, bl_irqs.c)
///        ^
///        | extern(C) into / called from
///        |
///   THIS MODULE
///        - provides g_bl_ops_funcs table (urt-backed)
///        - drives init sequence (D-side)
///        - dispatches RX events (D-side, bl_rx_e2a_handler)
///        - implements wifi_hw_* abstract API
///
/// All sequencing, retry, state transitions: D side.
/// All radio / MAC / PHY work: blob side.
/// Vendor C is the thin RPC pipe between them.
///
/// =====================================================================
/// STATUS -- bring-up is INCOMPLETE. The surface compiles and links
/// with zero unresolved symbols, but nothing has run on hardware. Order
/// of operations to actually work (each step blocks the next):
///
/// 1. M0 BOOTSTRAP -- not written. No clocks, no console UART, no IPC
///    handshake with D0, no vector table init. Until this lands, the
///    binary is unrunnable. Independent of this module.
///
/// 2. bl_msgackind cb -- currently a no-op (line ~115). LMAC fires this
///    on every command ACK; vendor expects it to walk cmd_mgr and call
///    cmd_mgr->llind so the WAIT_ACK flag is cleared and cmd_complete
///    fires. Without it, wifi_hw_open() hangs on the first bl_send_reset
///    inside bl_os_event_group_wait. See cmd_mgr_llind in bl_cmds.c.
///
/// 3. bl_utils_pbuf_alloc/free -- assert(false) stubs (line ~64). First
///    RX buffer request from the blob triggers an assertion. Allocator
///    needs to hand back 4-byte-aligned buffers sized for full WiFi frame
///    + LMAC RX header, from the urt heap.
///
/// 4. bl_txdatacfm cb -- no-op stub. TX completion handler; even if TX
///    worked, the host wouldn't know a frame had drained.
///
/// 5. wifi_hw_tx -- returns false. Ethernet TX needs ipc_host_txdesc_get
///    -> populate txdesc_host + bl_txhdr -> ipc_host_txdesc_push. Likely
///    candidate for the bl_shim.c TX helper.
///
/// 6. bl_ops_task_notify / task_wait (in bl_ops.d) -- stubs. The blob's
///    wifi_main task uses these for sleep/wake-on-completion; will wedge
///    the first time it waits.
///
/// What DOES work (in principle, never validated):
///   - g_bl_ops_funcs fully wired with urt-backed primitives
///   - Fibre yield/pump model for wifi_main cooperative scheduling
///   - Event dispatch chain: blob -> bl_rx_e2a_handler -> cmd_mgr.msgind
///     -> per-task on_* handlers -> WifiEventCallback
///   - IPC env init via bl_shim_ipc_init
///   - Most wifi_hw_* entries: open, close, set_mode (add_if/remove_if),
///     sta_configure (stash), sta_connect (via bl_shim_sta_connect),
///     sta_disconnect, ap_configure (apm_start), scan_start/stop/results,
///     ap_get_clients, raw_tx, get_mac, get_channel, get_rssi.
///
/// Critical path: bootstrap -> first console output -> first IPC
/// handshake -> first cmd-ack round trip -> wifi_main entry -> radio
/// init -> first scan.
/// =====================================================================

module urt.driver.bl808_m0.wifi;

version (BL808_M0):

nothrow @nogc:


// One radio on M0. (The chip has a single 2.4 GHz radio.)
enum uint num_wifi = 1;


// g_bl_ops_funcs lives in urt.driver.bl808_m0.bl_ops.
import urt.driver.bl808_m0.bl_ops;
import urt.driver.bl618.uart : uart0_hw_puts;
import urt.attribute : fast_data;


// ====================================================================
// Symbols the kept vendor C / closed blob expect from "elsewhere".
//
// The SDK has bl_utils.c / bl_main.c / wifi_hosal/ / bl_rx.c supplying
// these; we don't compile any of them, so we provide stubs here. All
// have C linkage so the vendor TUs can call them.
// ====================================================================

extern (C):

// bl_utils.c -- RX buffer alloc/free + STA index lookup.
uint* bl_utils_pbuf_alloc()
{
    // TODO: allocate RX buffer (must be 4-byte aligned, sized for max
    // WiFi frame + LMAC RX header). Wired when TX/RX path lands.
    assert(false, "bl_utils_pbuf_alloc not implemented");
}

void bl_utils_pbuf_free(uint* p)
{
    assert(false, "bl_utils_pbuf_free not implemented");
}

int bl_utils_idx_lookup(bl_hw* hw, ubyte* mac)
{
    // Used by AP-mode TX to find the STA slot. Linear scan of sta_table.
    foreach (i; 0 .. STA_TABLE_LEN)
    {
        if (!hw.sta_table[i].is_used)
            continue;
        if (hw.sta_table[i].sta_addr.array_[] == mac[0..6])
            return cast(int)i;
    }
    return hw.ap_bcmc_idx;
}

void bl_utils_dump() { uart0_hw_puts("[s:utils_dump]"); }

// bl_main.c -- cooperative scheduling point. The blob's wifi_main calls
// this when it has nothing else to do; we drain IPC + TX retry list.
void bl_main_event_handle()
{
    uart0_hw_puts("[s:bl_main_event_handle]");
    bl_irq_bottomhalf(&_bl_hw);
    // bl_tx_try_flush();  // TODO when TX path lands
}

// Other blob-side externs we MUST provide (libwifi.a has these as U only).
int  bl_supplicant_init(void* arg) { uart0_hw_puts("[s:supp_init]");        return 0; }

// bl_init, bl_pm_ops_register, bl_nap_calculate, bl_reset_evt are ALL
// defined inside libwifi.a (T symbols). Earlier we shadowed them with
// noop stubs via --allow-multiple-definition, which silently disabled
// vendor's LMAC task setup (me_init, sm_init, mm_init, apm_init, etc).
// That's why ME_CONFIG never got a CFM: TASK_ME wasn't registered.
// Leave vendor's versions alone -- the linker resolves them from
// libwifi.a now that we don't define duplicates.

// bl_sleep_check is the ONE deliberate override -- vendor's libwifi.a has
// its own bl_sleep_check that decides whether wifi_main can sleep. We
// force "no" (return 0) so wifi_main stays in its event-processing path
// instead of taking the PM/idle branch. Also signals wifi_main_in_main_loop
// on the first call so wifi_hw_open knows when to push the first A2E cmd.
// Periodic heartbeat every 65k calls to confirm wifi_main is still cycling.
int  bl_sleep_check(void* arg)
{
    import urt.io : writef;
    __gshared uint call_count;
    if ((++call_count & 0xFFFF) == 1)
        writef("[s:sleep_check #{0}]", call_count);
    if (call_count == 1)
    {
        import urt.driver.bl808_m0.bl_ops : wifi_main_in_main_loop;
        wifi_main_in_main_loop = true;
    }
    return 0;
}

// bl_ps_params is provided by libwifi.a; do not shadow.

// IPC callbacks invoked from libwifi.a via the cb table.
//
// recv_msgack_ind / send_data_cfm fire from ipc_host_irq() when the
// LMAC raises MSG_ACK or TXCFM bits. radar/dbg/tbtt are rare; stubbed.
ubyte bl_radarind(void* pthis, void* hostid)   { uart0_hw_puts("[cb:radar]"); return 0; }

// LMAC has accepted a cmd we pushed; advance cmd_mgr so the waiter on
// the event_group wakes. host_id is the bl_cmd* we passed to msg_push;
// cmd_mgr->llind walks the pending list, clears WAIT_ACK, calls
// cmd_complete if no CFM is expected, and pushes any deferred next cmd.
ubyte bl_msgackind(void* pthis, void* hostid)
{
    uart0_hw_puts("[cb:msgack]");
    auto hw  = cast(bl_hw*)pthis;
    auto cmd = cast(bl_cmd*)hostid;
    if (hw is null || cmd is null)
        return 0;
    hw.cmd_mgr.llind(&hw.cmd_mgr, cmd);
    return 0;
}

ubyte bl_dbgind(void* pthis, void* hostid)     { uart0_hw_puts("[cb:dbg]");        return 0; }
int   bl_txdatacfm(void* pthis, void* host_id) { uart0_hw_puts("[cb:txdatacfm]");  return 0; }
void  bl_prim_tbtt_ind(void* pthis)            { uart0_hw_puts("[cb:prim_tbtt]"); }
void  bl_sec_tbtt_ind(void* pthis)             { uart0_hw_puts("[cb:sec_tbtt]"); }

// bl_rx_e2a_handler -- the missing piece. The blob's wifi_main calls
// this for every unsolicited LMAC->host message (CFMs and IND events).
// Dispatch matches the vendor pattern: walk cmd_mgr for a pending CFM
// matching msg->id; if no match, invoke per-task handler for events
// like SM_CONNECT_IND.
void bl_rx_e2a_handler(void* arg)
{
    import urt.io : writef;
    ipc_e2a_msg* msg = cast(ipc_e2a_msg*)arg;
    uint task = MSG_T(msg.id);
    uint idx  = MSG_I(msg.id);
    // Print raw bytes 0..15 of the msg so we can see actual field layout.
    auto raw = cast(uint*)msg;
    writef("[cb:e2a id={0,08X} t={1} i={2} raw={3,08X}/{4,08X}/{5,08X}/{6,08X}]",
        msg.id, task, idx, raw[0], raw[1], raw[2], raw[3]);

    msg_cb_fct cb;
    if (task < msg_hdlrs.length && idx < msg_hdlrs[task].length)
        cb = msg_hdlrs[task][idx];

    // cmd_mgr.msgind matches pending CFMs by reqid; cb fires for the
    // unmatched indications and copies their bodies into our state.
    _bl_hw.cmd_mgr.msgind(&_bl_hw.cmd_mgr, msg, cb);
}

// wifi_hosal -- power management hooks called from libwifi.a
int wifi_hosal_pm_event_register(int evt, void* cb, void* arg) { uart0_hw_puts("[s:hosal_pm_reg]");   return 0; }

// wifi_main's idle loop calls pm_post_event continuously when there's no
// other work. On real silicon, vendor's impl walks a registered-cb list and
// returns; the blob's loop then proceeds to wait/wfi. In our cooperative
// fibre, this is the natural place to yield to the host so it can pump IPC
// IRQs / queue ticks. Return -1 to mimic vendor's "pm_env not initialised"
// path which short-circuits the blob's PM machinery.
int wifi_hosal_pm_post_event(int evt, int val, void* retval)
{
    __gshared uint count;
    if ((count++ & 0xFF) == 0)
        uart0_hw_puts("[s:hosal_pm_post]");
    // Yield to the host fibre. bl_ops_msleep(1) -> urt.fibre.sleep(1.msecs)
    // when in-fibre, which is exactly our case.
    bl_ops_msleep(1);
    return -1;
}
int wifi_hosal_pm_state_run()
{
    __gshared bool seen;
    if (!seen) { seen = true; uart0_hw_puts("[s:hosal_pm_state_run.first]"); }
    return 0;
}
void wifi_hosal_rf_turn_on()                                   { uart0_hw_puts("[s:hosal_rf_on]"); }
void wifi_hosal_rf_turn_off()                                  { uart0_hw_puts("[s:hosal_rf_off]"); }

// LMAC IRQ entry points (defined inside libwifi.a). bl_irq_handler runs
// the IPC bottom-half; mac_irq services the MAC core IRQ. Both are void()
// so we wrap them to the void(uint) shape urt.driver.bl618.irq expects.
// Thunks must be extern(D) to match IrqHandler's D-linkage alias.
extern(C) void mac_irq();
extern(C) void bl_irq_handler();

// PHY / TPC config that vendor's cmd_stack_wifi sets before spawning the
// wifi_main task. Vendor source: bl_iot_sdk customer_app bl808_demo_linux
// main.c. We mirror the demo's table values; chip variant could need other
// values via factory-partition lookup (see hal_board_cfg TODO).
extern(C) void phy_powroffset_set(byte* power_offset);
extern(C) void bl_tpc_update_power_rate_11b(byte* power_rate_table);
extern(C) void bl_tpc_update_power_rate_11g(byte* power_rate_table);
extern(C) void bl_tpc_update_power_rate_11n(byte* power_rate_table);
extern(D) void _wifi_mac_irq_thunk(uint /+irq+/) @nogc nothrow
{
    __gshared bool seen;
    if (!seen) { seen = true; uart0_hw_puts("[irq:mac.first]"); }
    mac_irq();
}
extern(D) void _wifi_ipc_irq_thunk(uint /+irq+/) @nogc nothrow
{
    __gshared bool seen;
    if (!seen) { seen = true; uart0_hw_puts("[irq:ipc.first]"); }
    bl_irq_handler();
}

// Replaces dropped bl_tx.c version. ipc_host.c calls into this on
// soft-retry; D-side TX path will walk its pending list.
void bl_tx_resend()
{
    // TODO: walk our D-side TX list, re-queue pending entries.
}

// RX hand-off into the IP stack. Vendor bl_utils.c routes received frames
// through here into LWIP; we don't run LWIP, so drop the frame. When the
// D-side RX/iface path lands, dispatch via _rx_cb / _raw_rx_cb here.
int tcpip_stack_input(void* swdesc, ubyte status, void* hwhdr, uint msdu_offset, void* pkt, ubyte extra_status)
{
    uart0_hw_puts("[s:tcpip_in]");
    return 0;
}

// utils_crc32_stream -- vendor CRC helper pulled in by mm_check_beacon.
// Beacon CRC validation isn't on the critical path for wifi_open; stub.
struct crc32_stream_ctx { uint state; }
void utils_crc32_stream_init(crc32_stream_ctx* ctx)
{
    __gshared bool seen;
    if (!seen) { seen = true; uart0_hw_puts("[s:crc32_init.first]"); }
    if (ctx) ctx.state = 0;
}
void utils_crc32_stream_feed_block(crc32_stream_ctx* ctx, const(ubyte)* data, uint len) {}
uint utils_crc32_stream_results(crc32_stream_ctx* ctx)            { return 0; }

extern (D):


// ====================================================================
// IPC shared memory.
//
// The LMAC owns ipc_shared_env -- a 9668-byte COMMON symbol inside
// libwifi.a, linker-placed in our BSS. We just take its address.
//
// ipc_host_env_tag is fully opaque -- C-side (bl_shim_ipc_init) builds
// and registers it; D only holds the pointer in bl_hw.ipc_env.
// ====================================================================

struct ipc_host_env_tag;     // opaque

// 9668 bytes; defined inside libwifi.a as a COMMON symbol, linker
// allocates it automatically when we reference it.
struct ipc_shared_env_tag
{
    ubyte[9668] _opaque;
}
static assert(ipc_shared_env_tag.sizeof == 9668);

extern (C) __gshared ipc_shared_env_tag ipc_shared_env;

// IPC peripheral lives at REG_WIFI_REG_BASE(0x24000000) + IPC_REG_BASE_ADDR(0x00800000)
// = 0x24800000 on BL808. The 0x12000000 constants quoted in reg_ipc_app.h are
// DOCUMENTATION ONLY -- actual access goes through REG_IPC_APP_RD(env, INDEX) which
// computes env + 0x00800000 + 4*INDEX with env = REG_WIFI_REG_BASE. We spent a
// debug cycle writing 0x7FF into 0x1200000C (unmapped) while the real unmask at
// 0x2480000C stayed zero and IPC IRQ 79 never asserted.
enum uint IPC_BASE                  = 0x2480_0000;
enum uint IPC_APP2EMB_TRIGGER_REG   = IPC_BASE + 0x00;  // app -> emb wake
enum uint IPC_EMB2APP_RAWSTATUS_REG = IPC_BASE + 0x04;  // emb -> app raw bits
enum uint IPC_EMB2APP_ACK_REG       = IPC_BASE + 0x08;  // write-1-to-clear
enum uint IPC_EMB2APP_UNMASK_REG    = IPC_BASE + 0x0C;  // 1 = enable for that event class

extern (C) void ipc_emb2app_ack_clear(uint mask)
{
    *(cast(uint*)cast(size_t)IPC_EMB2APP_ACK_REG) = mask;
}

// IPC E2A unmask: enabling a bit lets the LMAC raise the IPC IRQ for that
// event class. With this at 0, even a CLIC-enabled WIFI_IPC_PUBLIC_IRQn
// line never asserts.
extern (C) void ipc_emb2app_unmask_set(uint mask)
{
    *(cast(uint*)cast(size_t)IPC_EMB2APP_UNMASK_REG) = mask;
}

// Bitmask of all E2A event classes (mirrors IPC_IRQ_E2A_ALL in ipc_shared.h):
//   TXCFM = ((1<<NX_TXQ_CNT)-1) << 7 = 0xF << 7 = 0x780  (NX_TXQ_CNT = 4)
//   RXDESC=8, MSG_ACK=4, MSG=2, DBG=1, TBTT_PRIM=16, TBTT_SEC=32, RADAR=64
//   Combined: 0x780 | 0x7F = 0x7FF
enum uint IPC_IRQ_E2A_ALL = 0x7FF;


// ====================================================================
// LMAC msg dispatch types (mirrored from lmac_msg.h / ipc_shared.h)
// ====================================================================

// 12-bit msg id: top 6 are task index, bottom 10 are message index.
// vendor C: #define MSG_T(m) ((m)>>10), MSG_I(m) ((m)&((1<<10)-1))
uint MSG_T(uint id) pure { return id >> 10; }
uint MSG_I(uint id) pure { return id & 0x3FF; }

// vendor encoded task_id = first_msg(task) >> 10
enum TASK_MM       = 0;
enum TASK_SCAN     = 1;
enum TASK_SCANU    = 2;
enum TASK_ME       = 3;
enum TASK_SM       = 4;
enum TASK_APM      = 5;
enum TASK_BAM      = 6;
enum TASK_RXU      = 7;
enum TASK_CFG      = 8;

// Per-task max message index (from MM_MAX, SM_MAX, etc.). We size the
// dispatch arrays here; if vendor adds new messages within the limit
// we already cover them.
enum MM_MAX_IDX    = 80;
enum SCANU_MAX_IDX = 32;
enum ME_MAX_IDX    = 32;
enum SM_MAX_IDX    = 32;
enum APM_MAX_IDX   = 32;
enum CFG_MAX_IDX   = 16;

// Message ids we explicitly dispatch (computed via vendor's KE_FIRST_MSG).
uint ke_msg_id(uint task, uint idx) pure { return (task << 10) | idx; }
enum SM_CONNECT_IND    = ke_msg_id(TASK_SM, 4);     // 0x1004
enum SM_DISCONNECT_IND = ke_msg_id(TASK_SM, 6);     // 0x1006
enum SCANU_START_CFM   = ke_msg_id(TASK_SCANU, 1);  // 0x0801
enum SCANU_RESULT_IND  = ke_msg_id(TASK_SCANU, 4);  // 0x0804
enum APM_STA_ADD_IND   = ke_msg_id(TASK_APM, 8);    // 0x1408
enum APM_STA_DEL_IND   = ke_msg_id(TASK_APM, 9);    // 0x1409

// ipc_e2a_msg.id is an int (ke_msg_id_t = enum -> int).
struct ipc_e2a_msg
{
    uint id;
    ubyte dummy_dest_id;
    ubyte _pad0;
    ubyte _pad1;
    ubyte _pad2;
    ubyte dummy_src_id;
    ubyte _pad3;
    ubyte _pad4;
    ubyte _pad5;
    uint param_len;
    // param[IPC_E2A_MSG_PARAM_SIZE] follows
    uint[1] param;
    // uint pattern at the end of vendor struct -- we don't touch it
}
// Note: vendor C uses ke_task_id_t which is an enum -> 4 bytes. Our
// padding above keeps the offsets correct for `id`, `param_len`,
// `param[]`. We never inspect dummy_dest_id/src_id; only id matters.

alias msg_cb_fct = extern (C) int function(bl_hw*, bl_cmd*, ipc_e2a_msg*) nothrow @nogc;


// ====================================================================
// Per-task message-id -> handler tables. The handler fires when no
// pending cmd matches the msg->id, i.e. it's an unsolicited indication.
// We dispatch only the events the WifiEventCallback contract cares about
// (sta connect/disconnect, AP client add/del, scan progress); everything
// else falls through silently.
// ====================================================================

@fast_data __gshared msg_cb_fct[MM_MAX_IDX]    mm_hdlrs;
@fast_data __gshared msg_cb_fct[SCANU_MAX_IDX] scanu_hdlrs;
@fast_data __gshared msg_cb_fct[ME_MAX_IDX]    me_hdlrs;
@fast_data __gshared msg_cb_fct[SM_MAX_IDX]    sm_hdlrs;
@fast_data __gshared msg_cb_fct[APM_MAX_IDX]   apm_hdlrs;
@fast_data __gshared msg_cb_fct[CFG_MAX_IDX]   cfg_hdlrs;

// One row per task. Outer length must cover the largest TASK_* index
// we look up (TASK_CFG = 8).
__gshared msg_cb_fct[][9] msg_hdlrs;

private void install_msg_hdlrs()
{
    sm_hdlrs[MSG_I(SM_CONNECT_IND)]       = &on_sm_connect_ind;
    sm_hdlrs[MSG_I(SM_DISCONNECT_IND)]    = &on_sm_disconnect_ind;
    scanu_hdlrs[MSG_I(SCANU_START_CFM)]   = &on_scanu_start_cfm;
    scanu_hdlrs[MSG_I(SCANU_RESULT_IND)]  = &on_scanu_result_ind;
    apm_hdlrs[MSG_I(APM_STA_ADD_IND)]     = &on_apm_sta_add_ind;
    apm_hdlrs[MSG_I(APM_STA_DEL_IND)]     = &on_apm_sta_del_ind;

    msg_hdlrs[TASK_MM]    = mm_hdlrs[];
    msg_hdlrs[TASK_SCANU] = scanu_hdlrs[];
    msg_hdlrs[TASK_ME]    = me_hdlrs[];
    msg_hdlrs[TASK_SM]    = sm_hdlrs[];
    msg_hdlrs[TASK_APM]   = apm_hdlrs[];
    msg_hdlrs[TASK_CFG]   = cfg_hdlrs[];
}


// ====================================================================
// Event-payload mirrors (only the head fields the handlers read).
// Full vendor structs are larger; we only access leading fields, and
// the buffer is sized by vendor C so we can't overrun.
// ====================================================================

struct sm_connect_ind_body
{
    ushort status_code;
    ushort reason_code;
    ubyte[6] bssid;
    bool   roamed;
    ubyte  vif_idx;
    ubyte  ap_idx;
    ubyte  ch_idx;
}

struct sm_disconnect_ind_body
{
    ushort status_code;
    ushort reason_code;
    ubyte  vif_idx;
}

struct scanu_result_ind_body
{
    ushort length;
    ushort framectrl;
    ushort center_freq;
    ubyte  band;
    ubyte  sta_idx;
    ubyte  inst_nbr;
    ubyte[6] sa;
    uint   tsflo;
    uint   tsfhi;
    byte   rssi;
    byte   ppm_abs;
    byte   ppm_rel;
    ubyte  flags;
    ubyte  data_rate;
    // payload[] follows: 802.11 beacon/probe-response starting at MAC hdr
}

struct apm_sta_add_ind_body
{
    ubyte[6] sta_addr;
    ubyte    sta_idx;
    ubyte    vif_idx;
}

struct apm_sta_del_ind_body
{
    ubyte sta_idx;
    ubyte vif_idx;
}


// ====================================================================
// Indication handlers. Called from cmd_mgr.msgind when no pending cmd
// matches msg->id. Each fires the user's event callback if one is set.
// ====================================================================

import urt.driver.wifi : WifiConfig, WifiStaConfig, WifiApConfig,
                         WifiScanConfig, WifiScanResult, WifiStaInfo,
                         WifiVif, WifiMode, WifiBand, WifiAuth,
                         WifiBandwidth, WifiEvent, Wifi,
                         WifiRxCallback, WifiRawRxCallback,
                         WifiEventCallback;

private void fire_event(WifiEvent event, const(void)* data)
{
    if (_event_cb)
        _event_cb(Wifi(0), event, data);
}

extern (C) int on_sm_connect_ind(bl_hw* hw, bl_cmd* cmd, ipc_e2a_msg* msg)
{
    auto body_ = cast(sm_connect_ind_body*)&msg.param[0];
    if (body_.status_code == 0)
        fire_event(WifiEvent.sta_connected, body_);
    else
        fire_event(WifiEvent.sta_disconnected, body_);
    return 0;
}

extern (C) int on_sm_disconnect_ind(bl_hw* hw, bl_cmd* cmd, ipc_e2a_msg* msg)
{
    auto body_ = cast(sm_disconnect_ind_body*)&msg.param[0];
    fire_event(WifiEvent.sta_disconnected, body_);
    return 0;
}

extern (C) int on_scanu_result_ind(bl_hw* hw, bl_cmd* cmd, ipc_e2a_msg* msg)
{
    if (_scan_results_count >= _scan_results.length)
        return 0;   // buffer full -- silently drop

    auto body_ = cast(scanu_result_ind_body*)&msg.param[0];
    auto r = &_scan_results[_scan_results_count++];
    r.bssid     = body_.sa;
    r.rssi      = body_.rssi;
    r.channel   = freq_to_channel(body_.center_freq);
    r.band      = body_.band == 0 ? WifiBand.band_2g4 : WifiBand.band_5g;
    r.bandwidth = WifiBandwidth.bw_20mhz;
    r.auth      = WifiAuth.open;   // TODO: decode from IEs in payload[]
    r.ssid_len  = 0;               // TODO: extract from beacon SSID IE
    return 0;
}

extern (C) int on_scanu_start_cfm(bl_hw* hw, bl_cmd* cmd, ipc_e2a_msg* msg)
{
    // Scan finished -- results are now ready in _scan_results.
    _scan_in_progress = false;
    fire_event(WifiEvent.scan_done, null);
    return 0;
}

extern (C) int on_apm_sta_add_ind(bl_hw* hw, bl_cmd* cmd, ipc_e2a_msg* msg)
{
    auto body_ = cast(apm_sta_add_ind_body*)&msg.param[0];
    fire_event(WifiEvent.ap_sta_connected, body_);
    return 0;
}

extern (C) int on_apm_sta_del_ind(bl_hw* hw, bl_cmd* cmd, ipc_e2a_msg* msg)
{
    auto body_ = cast(apm_sta_del_ind_body*)&msg.param[0];
    fire_event(WifiEvent.ap_sta_disconnected, body_);
    return 0;
}

// 2.4GHz: 2412 + 5*(n-1) MHz for n=1..13; 2484 for n=14.
private ubyte freq_to_channel(ushort mhz) pure
{
    if (mhz == 2484) return 14;
    if (mhz >= 2412 && mhz <= 2472) return cast(ubyte)((mhz - 2412) / 5 + 1);
    // 5GHz: 5180 + 5*(n-36) MHz for n>=36
    if (mhz >= 5180 && mhz <= 5825) return cast(ubyte)((mhz - 5180) / 5 + 36);
    return 0;
}


// ====================================================================
// urt.driver.wifi hw API -- the public surface we back.
// ====================================================================

bool wifi_hw_open(ubyte port, ref const WifiConfig cfg)
{
    import urt.driver.bl808_m0.bl_ops : bl_ops_task_create;
    import urt.driver.uart : uart0_puts;
    import urt.driver.bl618.irq : irq_set_handler, irq_set_enable;

    if (port != 0)
        return false;

    install_msg_hdlrs();

    // IPC env: cb table the blob calls into us through (recv_msgack_ind,
    // send_data_cfm, etc). bl_shim_ipc_init wires the table to our extern(C)
    // D stubs and calls ipc_host_init + bl_cmd_mgr_init.
    uart0_puts("wifi: ipc_init\n");
    if (bl_shim_ipc_init(&_bl_hw, &ipc_shared_env) != 0)
    {
        uart0_puts("wifi: ipc_init FAILED\n");
        return false;
    }
    ipc_emb2app_ack_clear(0xFFFFFFFF);

    uart0_puts("wifi: irqs_init\n");
    if (bl_irqs_init(&_bl_hw) != 0)
    {
        uart0_puts("wifi: irqs_init FAILED\n");
        return false;
    }

    // Enable the WiFi MAC core clock before wifi_main runs. Without this
    // the MAC engine isn't clocked and writes inside ipc_emb_init (called
    // from wifi_main) stall on the bus -- chip wedges silently. Vendor's
    // wifi.c calls bl_wifi_clock_enable() before bl_main_rtthread_start.
    //
    // GLB_WIFI_CFG0 (0x200003B0) bits[3:0] = MAC core clock divider.
    // Vendor passes 1 -> 40 MHz.
    uart0_puts("wifi: enable WiFi MAC core clock\n");
    {
        auto reg = cast(uint*)cast(size_t)0x200003B0;
        uint val = *reg;
        val = (val & ~0xFu) | 1u;
        *reg = val;
    }

    // Unmask all E2A event classes on the IPC side so the LMAC will actually
    // raise WIFI_IPC_PUBLIC_IRQn when it has work for the host. With this at
    // 0, the CLIC enable below is wired but the line never asserts. Vendor
    // does this in cfg80211_init before bl_wifi_enable_irq.
    uart0_puts("wifi: ipc_emb2app_unmask_set(E2A_ALL)\n");
    ipc_emb2app_unmask_set(IPC_IRQ_E2A_ALL);

    // Wire the LMAC interrupts to the blob's own handlers (mac_irq and
    // bl_irq_handler are defined inside libwifi.a). On real silicon these
    // fire when the LMAC raises WIFI / IPC bits via the platform CLIC.
    // Vendor's bl_wifi_enable_irq does the same registration; replicating
    // it lets us stop simulating IRQs via wifi_pump_one_for_host.
    //   WIFI_IRQn            = 16 + 54 = 70  (MAC -> CPU)
    //   WIFI_IPC_PUBLIC_IRQn = 16 + 63 = 79  (IPC ack / msg / txcfm / rxdesc)
    uart0_puts("wifi: install LMAC IRQs (70, 79)\n");
    irq_set_handler(70, &_wifi_mac_irq_thunk);
    irq_set_handler(79, &_wifi_ipc_irq_thunk);
    irq_set_enable(70);
    irq_set_enable(79);

    // PHY/TPC tables vendor's cmd_stack_wifi sets before spawning the
    // wifi_main task. Without these, the blob's "Configure IPC" path may
    // bash MAC engine registers whose driving values depend on the TPC
    // table being preset. See BRINGUP_PARITY.md section 5.
    uart0_puts("wifi: phy_powroffset_set + tpc_update\n");
    {
        byte[14] zero_offset = 0;
        byte[4]  tpc_11b = [0x14, 0x14, 0x14, 0x12];
        byte[8]  tpc_11g = [0x12, 0x12, 0x12, 0x12, 0x12, 0x12, 0xe, 0xe];
        byte[8]  tpc_11n = [0x12, 0x12, 0x12, 0x12, 0x12, 0x10, 0xe, 0xe];
        phy_powroffset_set(zero_offset.ptr);
        bl_tpc_update_power_rate_11b(tpc_11b.ptr);
        bl_tpc_update_power_rate_11g(tpc_11g.ptr);
        bl_tpc_update_power_rate_11n(tpc_11n.ptr);
    }

    // Spawn wifi_main as a fibre. Mirrors vendor's hal_wifi_start_firmware_task
    // (xTaskCreateStatic(wifi_main, "fw", 1536, NULL, 30, ...)). The blob does
    // its own phy_init / mac init / IPC setup from inside wifi_main; the
    // direct phy_init call we used to make from here crashed because phy_init
    // expects an arg the blob populates internally. bl_ops_task_create wires
    // a fibre that yields when the blob blocks on sem/event/queue/task_wait,
    // and host pumps it via wifi_fibre_pump (called from wifi_hw_poll AND
    // implicitly from bl_ops_event_group_wait when we wait for a CFM below).
    uart0_puts("wifi: spawn wifi_main\n");
    void* fw_handle;
    if (bl_ops_task_create("fw".ptr, cast(void*)&wifi_main, 1536, null, 30, fw_handle) != 0)
    {
        uart0_puts("wifi: spawn wifi_main FAILED\n");
        return false;
    }

    // Pump wifi_main through its full init (rf_on, Configure IPC, Configure
    // MAC, bl_init, pm_ops_register) BEFORE pushing the first A2E command.
    // Vendor's Configure-IPC step inside wifi_main writes IPC peripheral
    // state (incl. A2E_TRIGGER) -- if we bl_send_reset first, that write
    // clobbers our doorbell bit and wifi_main never sees the message.
    // bl_sleep_check is wifi_main's first call once it enters its event
    // loop; we use that as the "ready" sentinel.
    uart0_puts("wifi: pumping wifi_main to event-loop entry\n");
    {
        import urt.driver.bl808_m0.bl_ops : wifi_fibre_pump, wifi_main_in_main_loop;
        uint pumps;
        while (!wifi_main_in_main_loop && pumps < 1_000_000)
        {
            wifi_fibre_pump();
            ++pumps;
        }
        if (!wifi_main_in_main_loop)
            uart0_puts("wifi: WARNING wifi_main never reached event loop\n");
    }

    // Match vendor cfg80211_init order exactly (bl_main.c:486-528):
    //   bl_hw->mod_params = &bl_mod_params   (line 495, BEFORE everything)
    //   bl_platform_on / ipc_host_enable_irq / bl_wifi_enable_irq (done above)
    //   bl_send_reset
    //   bl_os_msleep(5)                      (line 512)
    //   bl_send_version_req
    //   bl_set_vers (cosmetic printf, skipped)
    //   bl_handle_dynparams
    //   bl_send_me_config_req
    //   bl_send_me_chan_config_req
    // bl_send_start is NOT in cfg80211_init -- it's later, for STA bring-up.
    // mod_params must be wired *before* anything reads it -- handle_dynparams
    // and me_config_req both deref it; vendor's bl_send_reset path may
    // depend on it too on the LMAC side.
    uart0_puts("wifi: wire mod_params\n");
    _bl_hw.mod_params = &bl_mod_params;

    uart0_puts("wifi: bl_send_reset\n");
    if (bl_send_reset(&_bl_hw) != 0)
    {
        uart0_puts("wifi: bl_send_reset FAILED\n");
        return false;
    }

    // Vendor's bl_os_msleep(5) -- LMAC settles after reset before next cmd.
    // urt.system.sleep wedges here (steals mtimecmp from the periodic
    // timer); pump the fibre while real time elapses so wifi_main also
    // gets CPU during the settle.
    uart0_puts("wifi: post-reset settle 5ms\n");
    {
        import urt.driver.bl808_m0.bl_ops : wifi_fibre_pump;
        import urt.driver.bl618.timer : mtime_read;
        ulong start = mtime_read();
        while (mtime_read() - start < 5_000)  // mtime is 1MHz -> 5000us = 5ms
            wifi_fibre_pump();
    }
    uart0_puts("wifi: settle done\n");

    uart0_puts("wifi: bl_send_version_req\n");
    ubyte[128] version_cfm = 0;  // mm_version_cfm body; size is small, 128 is safe
    if (bl_send_version_req(&_bl_hw, version_cfm.ptr) != 0)
    {
        uart0_puts("wifi: bl_send_version_req FAILED\n");
        return false;
    }

    uart0_puts("wifi: bl_handle_dynparams\n");
    if (bl_handle_dynparams(&_bl_hw) != 0)
    {
        uart0_puts("wifi: bl_handle_dynparams FAILED\n");
        return false;
    }

    uart0_puts("wifi: bl_send_me_config_req\n");
    if (bl_send_me_config_req(&_bl_hw) != 0)
    {
        uart0_puts("wifi: bl_send_me_config_req FAILED\n");
        return false;
    }
    uart0_puts("wifi: bl_send_me_chan_config_req\n");
    if (bl_send_me_chan_config_req(&_bl_hw) != 0)
    {
        uart0_puts("wifi: bl_send_me_chan_config_req FAILED\n");
        return false;
    }

    _bl_hw.is_up = 1;
    uart0_puts("wifi: OPEN OK\n");
    return true;
}

void wifi_hw_close(ubyte port)
{
    if (_bl_hw.vif_index_sta >= 0)
    {
        bl_send_remove_if(&_bl_hw, cast(ubyte)_bl_hw.vif_index_sta);
        _bl_hw.vif_index_sta = -1;
    }
    if (_bl_hw.vif_index_ap >= 0)
    {
        bl_send_apm_stop_req(&_bl_hw, cast(ubyte)_bl_hw.vif_index_ap);
        bl_send_remove_if(&_bl_hw, cast(ubyte)_bl_hw.vif_index_ap);
        _bl_hw.vif_index_ap = -1;
    }
    _bl_hw.is_up = 0;
}

bool wifi_hw_set_mode(ubyte port, WifiMode mode)
{
    final switch (mode)
    {
    case WifiMode.none:
        wifi_hw_close(port);
        return true;
    case WifiMode.monitor:
        return wifi_set_monitor_mode(true);
    case WifiMode.sta:
        return ensure_vif_sta() && tear_down_vif_ap();
    case WifiMode.ap:
        return ensure_vif_ap() && tear_down_vif_sta();
    case WifiMode.apsta:
        return ensure_vif_sta() && ensure_vif_ap();
    }
}

bool wifi_hw_sta_configure(ubyte port, ref const WifiStaConfig cfg)
{
    // Stash for use in sta_connect. Copy the bytes; the caller's slice
    // backing may be transient.
    if (cfg.ssid.length > _sta_cfg_ssid_buf.length)
        return false;
    if (cfg.password.length > _sta_cfg_pw_buf.length)
        return false;
    _sta_cfg_ssid_buf[0 .. cfg.ssid.length] = cast(ubyte[])cfg.ssid;
    _sta_cfg_ssid_len = cast(ubyte)cfg.ssid.length;
    _sta_cfg_pw_buf[0 .. cfg.password.length] = cast(ubyte[])cfg.password;
    _sta_cfg_pw_len = cast(ubyte)cfg.password.length;
    _sta_cfg_bssid = cfg.bssid;
    _sta_cfg_band = cfg.band;
    _sta_cfg_pmf  = cfg.pmf_required;
    return true;
}

bool wifi_hw_sta_connect(ubyte port)
{
    if (!ensure_vif_sta())
        return false;

    // bl_shim_sta_connect lives in bl_shim.c -- builds the awkward
    // cfg80211_connect_params on the C side from flat args.
    ubyte* bssid;
    foreach (b; _sta_cfg_bssid)
    {
        if (b)
        {
            bssid = _sta_cfg_bssid.ptr;
            break;
        }
    }
    enum NL80211_AUTHTYPE_OPEN_SYSTEM = 0;
    int r = bl_shim_sta_connect(
        &_bl_hw,
        _sta_cfg_ssid_buf.ptr, _sta_cfg_ssid_len,
        bssid,
        cast(char*)_sta_cfg_pw_buf.ptr, _sta_cfg_pw_len,
        NL80211_AUTHTYPE_OPEN_SYSTEM,
    );
    return r == 0;
}

bool wifi_hw_sta_disconnect(ubyte port)
{
    return bl_send_sm_disconnect_req(&_bl_hw) == 0;
}

bool wifi_hw_ap_configure(ubyte port, ref const WifiApConfig cfg)
{
    if (!ensure_vif_ap())
        return false;

    // bl_send_apm_start_req takes flat args -- the rare ergonomic
    // vendor function. ssid/password are null-terminated; copy into
    // local buffers (vendor reads then immediately constructs the msg).
    if (cfg.ssid.length >= _ap_ssid_buf.length)
        return false;
    if (cfg.password.length >= _ap_pw_buf.length)
        return false;
    _ap_ssid_buf[0 .. cfg.ssid.length] = cast(ubyte[])cfg.ssid;
    _ap_ssid_buf[cfg.ssid.length] = 0;
    _ap_pw_buf[0 .. cfg.password.length] = cast(ubyte[])cfg.password;
    _ap_pw_buf[cfg.password.length] = 0;

    apm_start_cfm cfm;
    int r = bl_send_apm_start_req(
        &_bl_hw, &cfm,
        cast(char*)_ap_ssid_buf.ptr,
        cast(char*)_ap_pw_buf.ptr,
        cfg.channel == 0 ? 1 : cfg.channel,
        cast(ubyte)_bl_hw.vif_index_ap,
        cfg.hidden ? 1 : 0,
        100,    // beacon interval = 100 TUs (102.4 ms), Linux default
    );
    if (r != 0 || cfm.status != 0)
        return false;
    return true;
}

size_t wifi_hw_ap_get_clients(ubyte port, WifiStaInfo[] buf)
{
    size_t n;
    foreach (i; 0 .. STA_TABLE_LEN)
    {
        if (n >= buf.length) break;
        if (!_bl_hw.sta_table[i].is_used) continue;
        buf[n].mac  = _bl_hw.sta_table[i].sta_addr.array_;
        buf[n].rssi = _bl_hw.sta_table[i].rssi;
        ++n;
    }
    return n;
}

bool wifi_hw_scan_start(ubyte port, ref const WifiScanConfig cfg)
{
    if (_scan_in_progress)
        return false;

    _scan_results_count = 0;
    _scan_in_progress = true;

    // bl_send_scanu_para is small enough to construct on stack.
    // channels = null + channel_num = 0 means "all channels".
    bl_send_scanu_para p;
    if (cfg.channel != 0)
    {
        _scan_channel_one[0] = channel_to_freq(cfg.channel, cfg.band);
        p.channels = _scan_channel_one.ptr;
        p.channel_num = 1;
    }
    p.duration_scan = cfg.dwell_ms == 0 ? 110 : cfg.dwell_ms;
    p.scan_mode = cfg.passive ? 1 : 0;

    if (bl_send_scanu_req(&_bl_hw, &p) != 0)
    {
        _scan_in_progress = false;
        return false;
    }
    return true;
}

void wifi_hw_scan_stop(ubyte port)
{
    // Vendor exposes no scan-cancel for SCANU. We just stop accepting
    // further results; scan completes on its own.
    _scan_in_progress = false;
}

size_t wifi_hw_scan_get_results(ubyte port, WifiScanResult[] buf)
{
    size_t n = _scan_results_count;
    if (n > buf.length) n = buf.length;
    buf[0 .. n] = _scan_results[0 .. n];
    return n;
}

bool wifi_hw_tx(ubyte port, WifiVif vif, const(ubyte)[] data)
{
    // TODO: TX path requires txdesc construction + ipc_host_txdesc_push.
    // Big enough to warrant its own pass.
    return false;
}

void wifi_hw_set_rx_callback(ubyte port, WifiRxCallback cb)
{
    _rx_cb = cb;
}

bool wifi_hw_raw_tx(ubyte port, const(ubyte)[] frame)
{
    // bl_send_scanu_raw_send takes a raw 802.11 frame from monitor mode.
    return bl_send_scanu_raw_send(&_bl_hw, cast(ubyte*)frame.ptr, cast(int)frame.length) == 0;
}

void wifi_hw_set_raw_rx_callback(ubyte port, WifiRawRxCallback cb)
{
    _raw_rx_cb = cb;
}

bool wifi_hw_get_mac(ubyte port, WifiVif vif, ref ubyte[6] mac)
{
    int idx = vif == WifiVif.sta ? _bl_hw.vif_index_sta : _bl_hw.vif_index_ap;
    if (idx < 0 || idx >= VIF_TABLE_LEN)
        return false;
    // bl_vif doesn't carry its own MAC; the add_if call passed one in.
    // We saved it in _vif_mac_*. Return that.
    mac = vif == WifiVif.sta ? _vif_mac_sta : _vif_mac_ap;
    return true;
}

ubyte wifi_hw_get_channel(ubyte port)
{
    return _current_channel;
}

byte wifi_hw_get_rssi(ubyte port)
{
    // STA RSSI lands in sta_table[ap_idx].rssi via SM_CONNECT_IND. We
    // saved ap_idx at connect time.
    if (_sta_ap_idx >= STA_TABLE_LEN) return 0;
    return _bl_hw.sta_table[_sta_ap_idx].rssi;
}

bool wifi_hw_set_tx_power(ubyte port, byte power_dbm)
{
    // No direct vendor call; goes through mod_params at start time.
    // TODO when we wire bl_mod_params updates dynamically.
    return false;
}

void wifi_hw_set_event_callback(ubyte port, WifiEventCallback cb)
{
    _event_cb = cb;
}

void wifi_hw_poll(ubyte port)
{
    if (_bl_hw.is_up && _bl_hw.ipc_env !is null)
        bl_irq_bottomhalf(&_bl_hw);
    wifi_fibre_pump();
}


// ====================================================================
// VIF lifecycle helpers
// ====================================================================

// Linux nl80211_iftype values used by bl_send_add_if.
private enum NL80211_IFTYPE_STATION = 2;
private enum NL80211_IFTYPE_AP      = 3;
private enum NL80211_IFTYPE_MONITOR = 6;

private bool ensure_vif_sta()
{
    if (_bl_hw.vif_index_sta >= 0)
        return true;
    mm_add_if_cfm cfm;
    _vif_mac_sta = _default_mac;
    if (bl_send_add_if(&_bl_hw, _vif_mac_sta.ptr, NL80211_IFTYPE_STATION, false, &cfm) != 0)
        return false;
    if (cfm.status != 0)
        return false;
    _bl_hw.vif_index_sta = cfm.inst_nbr;
    return true;
}

private bool tear_down_vif_sta()
{
    if (_bl_hw.vif_index_sta < 0)
        return true;
    bl_send_remove_if(&_bl_hw, cast(ubyte)_bl_hw.vif_index_sta);
    _bl_hw.vif_index_sta = -1;
    return true;
}

private bool ensure_vif_ap()
{
    if (_bl_hw.vif_index_ap >= 0)
        return true;
    mm_add_if_cfm cfm;
    _vif_mac_ap = _default_mac;
    _vif_mac_ap[5] ^= 0x80;     // distinguish AP MAC from STA MAC
    if (bl_send_add_if(&_bl_hw, _vif_mac_ap.ptr, NL80211_IFTYPE_AP, false, &cfm) != 0)
        return false;
    if (cfm.status != 0)
        return false;
    _bl_hw.vif_index_ap = cfm.inst_nbr;
    return true;
}

private bool tear_down_vif_ap()
{
    if (_bl_hw.vif_index_ap < 0)
        return true;
    bl_send_apm_stop_req(&_bl_hw, cast(ubyte)_bl_hw.vif_index_ap);
    bl_send_remove_if(&_bl_hw, cast(ubyte)_bl_hw.vif_index_ap);
    _bl_hw.vif_index_ap = -1;
    return true;
}

private bool wifi_set_monitor_mode(bool enable)
{
    mm_monitor_cfm cfm;
    int r = enable ? bl_send_monitor_enable(&_bl_hw, &cfm)
                   : bl_send_monitor_disable(&_bl_hw, &cfm);
    return r == 0 && cfm.status == 0;
}

private ushort channel_to_freq(ubyte ch, WifiBand band) pure
{
    if (band == WifiBand.band_5g || ch >= 36)
        return cast(ushort)(5180 + (ch - 36) * 5);
    if (ch == 14)
        return 2484;
    return cast(ushort)(2412 + (ch - 1) * 5);
}


// ====================================================================
// Vendor C entry points we call (extern(C) bindings).
// ====================================================================

extern (C):

int  bl_send_reset(bl_hw* bl_hw);
int  bl_send_start(bl_hw* bl_hw);
int  bl_send_version_req(bl_hw* bl_hw, void* cfm);
int  bl_handle_dynparams(bl_hw* bl_hw);
int  bl_send_me_config_req(bl_hw* bl_hw);
int  bl_send_me_chan_config_req(bl_hw* bl_hw);

// Global bl_mod_params from vendor's bl_mod_params.c. Vendor's
// cfg80211_init wires bl_hw->mod_params = &bl_mod_params before any
// command that reads mod_params fields (handle_dynparams, me_config_req).
// Opaque to D; we just need its address.
extern __gshared int bl_mod_params;
int  bl_send_add_if(bl_hw* bl_hw, const(ubyte)* mac, int iftype, bool p2p, mm_add_if_cfm* cfm);
int  bl_send_remove_if(bl_hw* bl_hw, ubyte inst_nbr);
int  bl_send_monitor_enable(bl_hw* bl_hw, mm_monitor_cfm* cfm);
int  bl_send_monitor_disable(bl_hw* bl_hw, mm_monitor_cfm* cfm);
int  bl_send_monitor_channel_set(bl_hw* bl_hw, mm_monitor_channel_cfm* cfm, int channel, int use_40mhz);
int  bl_send_sm_disconnect_req(bl_hw* bl_hw);
int  bl_send_channel_set_req(bl_hw* bl_hw, int channel);
int  bl_send_scanu_req(bl_hw* bl_hw, bl_send_scanu_para* para);
int  bl_send_scanu_raw_send(bl_hw* bl_hw, ubyte* pkt, int len);
int  bl_send_apm_start_req(bl_hw* bl_hw, apm_start_cfm* cfm, char* ssid, char* password,
                           int channel, ubyte vif_index, ubyte hidden_ssid, ushort bcn_int);
int  bl_send_apm_stop_req(bl_hw* bl_hw, ubyte vif_idx);

// bl_shim.c -- wraps awkward vendor types with flat-arg helpers.
int  bl_shim_sta_connect(bl_hw* bl_hw, const(ubyte)* ssid, uint ssid_len,
                         const(ubyte)* bssid_or_null,
                         const(char)* psk, ubyte psk_len, int auth_type);

int  bl_irqs_init(bl_hw* bl_hw);
void bl_irq_bottomhalf(bl_hw* bl_hw);

// bl_shim.c -- ports vendor bl_utils.c's bl_ipc_init. Allocates the
// host env via the OS adapter (-> our urt heap), wires the cb table to
// our extern(C) D stubs, calls ipc_host_init + bl_cmd_mgr_init.
int  bl_shim_ipc_init(bl_hw* bl_hw, ipc_shared_env_tag* shared_mem);

// libwifi.a entry point. Long-lived task; we spawn it on a fibre and pump
// it from wifi_hw_poll. Param is unused by the blob (vendor SDK passes NULL).
void wifi_main(void* param);

// PHY/RF (from libbl606p_phyrf.a). phy_init is called from inside wifi_main
// by the blob with its own config arg -- do not call from host code.
int  phy_init();
int  phy_set_channel(ubyte band, ubyte type, ushort prim20, ushort center1, ushort center2, ubyte index);


// ====================================================================
// Vendor message structs we touch directly (small / leaf only)
// ====================================================================

extern (D):

struct mm_add_if_cfm
{
    ubyte status;
    ubyte inst_nbr;
}
static assert(mm_add_if_cfm.sizeof == 2);

struct mm_monitor_cfm
{
    uint status;
    uint enable;
    uint[8] data;
}
static assert(mm_monitor_cfm.sizeof == 40);

struct mm_monitor_channel_cfm
{
    uint status;
    uint band;
    uint freq;
    uint center_freq1;
    uint center_freq2;
    uint type;
}

struct apm_start_cfm
{
    ubyte status;
    ubyte vif_idx;
    ubyte ch_idx;
    ubyte bcmc_idx;
}
static assert(apm_start_cfm.sizeof == 4);

struct mac_addr
{
    ubyte[6] array_;
}

struct mac_ssid
{
    ubyte length;
    ubyte[32] array_;
}

struct bl_send_scanu_para
{
    ushort*   channels;
    ushort    channel_num;
    mac_addr* bssid;
    mac_ssid* ssid;
    ubyte*    mac;
    ubyte     scan_mode;
    uint      duration_scan;
}


// ====================================================================
// struct bl_hw and its nested types -- the central vendor state object.
//
// Mirrored from bl_defs.h / bl_cmds.h / cfg80211.h / ieee80211.h for RV32
// ilp32f with CFG_TXDESC=4, CFG_STA_MAX=5, CFG_BL_STATISTIC undefined.
// The static asserts at the bottom catch any drift from a vendor resync.
// ====================================================================

enum NX_VIRT_DEV_MAX    = 2;
enum NX_REMOTE_STA_MAX  = 5;
enum VIF_TABLE_LEN      = NX_VIRT_DEV_MAX + NX_REMOTE_STA_MAX;   // 7
enum STA_TABLE_LEN      = NX_REMOTE_STA_MAX + NX_VIRT_DEV_MAX;   // 7

struct list_head
{
    list_head* next;
    list_head* prev;
}

struct ieee80211_mcs_info
{
    ubyte[10] rx_mask;
    ushort    rx_highest;
    ubyte     tx_params;
    ubyte[3]  reserved;
}

struct ieee80211_sta_ht_cap
{
    ushort cap;
    bool   ht_supported;
    ubyte  ampdu_factor;
    ubyte  ampdu_density;
    ieee80211_mcs_info mcs;
}

struct bl_sta
{
    mac_addr sta_addr;
    ubyte    is_used;
    ubyte    sta_idx;
    ubyte    vif_idx;
    ubyte    vlan_idx;
    ubyte    qos;
    byte     rssi;
    ubyte    data_rate;
    uint     tsflo;
    uint     tsfhi;
}

struct bl_vif
{
    list_head list;
    void*     dev;
    bool      up;
    union variant_t
    {
        struct sta_t   { bl_sta* ap;   bl_sta* tdls_sta; }
        struct ap_t    { list_head sta_list; ubyte bcmc_index; }
        struct ap_vlan_t { bl_vif* master; bl_sta* sta_4a; }
        sta_t     sta;
        ap_t      ap;
        ap_vlan_t ap_vlan;
    }
    variant_t variant;
}

enum bl_cmd_mgr_state : int
{
    DEINIT  = 0,
    INITED  = 1,
    CRASHED = 2,
}

struct bl_cmd_mgr
{
    bl_cmd_mgr_state state;
    uint next_tkn;
    uint queue_sz;
    uint max_queue_sz;
    list_head cmds;
    void* lock;
    extern (C) int  function(bl_cmd_mgr*, bl_cmd*)                  nothrow @nogc queue;
    extern (C) int  function(bl_cmd_mgr*, bl_cmd*)                  nothrow @nogc llind;
    extern (C) int  function(bl_cmd_mgr*, ipc_e2a_msg*, msg_cb_fct) nothrow @nogc msgind;
    extern (C) void function(bl_cmd_mgr*)                           nothrow @nogc print;
    extern (C) void function(bl_cmd_mgr*)                           nothrow @nogc drain;
}

struct bl_cmd
{
    list_head list;
    uint id;
    uint reqid;
    void* a2e_msg;     // struct lmac_msg*
    void* e2a_msg;
    uint tkn;
    ushort flags;
    void* complete;    // BL_EventGroup_t
    uint result;
}

struct bl_hw
{
    int        is_up;
    bl_cmd_mgr cmd_mgr;
    ipc_host_env_tag* ipc_env;
    list_head  vifs;
    bl_vif[VIF_TABLE_LEN] vif_table;
    bl_sta[STA_TABLE_LEN] sta_table;
    uint       drv_flags;
    void*      mod_params;
    ieee80211_sta_ht_cap ht_cap;
    int vif_index_sta;
    int vif_index_ap;
    int sta_idx;
    int ap_bcmc_idx;
}

// Drift checks against the vendor C build (RV32 ilp32f, CFG_TXDESC=4,
// CFG_STA_MAX=5, CFG_BL_STATISTIC undef).
static assert(bl_hw.sizeof                 == 476);
static assert(bl_hw.is_up.offsetof         ==   0);
static assert(bl_hw.cmd_mgr.offsetof       ==   4);
static assert(bl_hw.ipc_env.offsetof       ==  52);
static assert(bl_hw.vifs.offsetof          ==  56);
static assert(bl_hw.vif_table.offsetof     ==  64);
static assert(bl_hw.sta_table.offsetof     == 260);
static assert(bl_hw.drv_flags.offsetof     == 428);
static assert(bl_hw.mod_params.offsetof    == 432);
static assert(bl_hw.ht_cap.offsetof        == 436);
static assert(bl_hw.vif_index_sta.offsetof == 460);
static assert(bl_vif.sizeof                ==  28);
static assert(bl_sta.sizeof                ==  24);
static assert(bl_cmd_mgr.sizeof            ==  48);
static assert(list_head.sizeof             ==   8);
static assert(ieee80211_sta_ht_cap.sizeof  ==  22);


// ====================================================================
// Module state
// ====================================================================

private:

__gshared WifiRxCallback     _rx_cb;
__gshared WifiRawRxCallback  _raw_rx_cb;
__gshared WifiEventCallback  _event_cb;

// Owned by D, populated by vendor C. Passed by pointer to bl_irqs_init,
// every bl_send_*, etc.
@fast_data __gshared bl_hw _bl_hw;

// MAC for the VIFs we create. Real builds will pull this from OTP /
// efuse via vendor calls; for now hardcoded so the build is exercisable.
__gshared ubyte[6] _default_mac  = [0xC0, 0x49, 0xEF, 0x00, 0x00, 0x01];
__gshared ubyte[6] _vif_mac_sta;
__gshared ubyte[6] _vif_mac_ap;

// STA config stashed by sta_configure for later sta_connect.
__gshared ubyte[32] _sta_cfg_ssid_buf;
__gshared ubyte     _sta_cfg_ssid_len;
__gshared ubyte[64] _sta_cfg_pw_buf;
__gshared ubyte     _sta_cfg_pw_len;
__gshared ubyte[6]  _sta_cfg_bssid;
__gshared WifiBand  _sta_cfg_band;
__gshared bool      _sta_cfg_pmf;
__gshared ubyte     _sta_ap_idx = ubyte.max;  // sta_table slot for our AP

// AP config buffers (null-terminated copies for bl_send_apm_start_req)
__gshared ubyte[33] _ap_ssid_buf;
__gshared ubyte[65] _ap_pw_buf;

// Scan state
__gshared bool _scan_in_progress;
__gshared WifiScanResult[16] _scan_results;
__gshared size_t _scan_results_count;
__gshared ushort[1] _scan_channel_one;

__gshared ubyte _current_channel;
