module urt.driver.bl808_m0.wifi_lmac;

version (BL808_M0):

import urt.attribute : section;

nothrow @nogc:
extern(C):


// IPC shared memory.
//
// The LMAC owns ipc_shared_env -- a 9668-byte COMMON symbol inside
// libwifi.a, linker-placed in our BSS. We just take its address.
//
// ipc_host_env_tag is fully opaque -- C-side (bl_shim_ipc_init) builds
// and registers it; D only holds the pointer in bl_hw.ipc_env.
// ====================================================================

struct ipc_host_env_tag;     // opaque

// 9668 bytes; vendor places this in ram_wifi with the rest of .wifibss.
// lld does not reliably catch the libwifi COMMON selector for this symbol, so
// define a strong symbol in .wifi_ram; start.S clears the NOLOAD range.
struct ipc_shared_env_tag
{
    ubyte[9668] _opaque;
}
static assert(ipc_shared_env_tag.sizeof == 9668);

@section(".wifi_ram") align(4) __gshared ipc_shared_env_tag ipc_shared_env;

// REG_IPC_APP_RD(env, INDEX) addresses REG_WIFI_REG_BASE + IPC_REG_BASE_ADDR.
// The 0x12000000 constants in reg_ipc_app.h are not mapped on BL808 M0.
enum uint IPC_BASE                  = 0x2480_0000;
enum uint IPC_APP2EMB_TRIGGER_REG   = IPC_BASE + 0x00;  // app -> emb wake
enum uint IPC_EMB2APP_RAWSTATUS_REG = IPC_BASE + 0x04;  // emb -> app raw bits
enum uint IPC_EMB2APP_ACK_REG       = IPC_BASE + 0x08;  // write-1-to-clear
enum uint IPC_EMB2APP_UNMASK_REG    = IPC_BASE + 0x0C;  // 1 = enable for that event class

void ipc_emb2app_ack_clear(uint mask)
{
    *(cast(uint*)cast(size_t)IPC_EMB2APP_ACK_REG) = mask;
}

// IPC E2A unmask: enabling a bit lets the LMAC raise the IPC IRQ for that
// event class. With this at 0, even a CLIC-enabled WIFI_IPC_PUBLIC_IRQn
// line never asserts.
void ipc_emb2app_unmask_set(uint mask)
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
extern(D) uint MSG_T(uint id) pure { return id >> 10; }
extern(D) uint MSG_I(uint id) pure { return id & 0x3FF; }

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
extern(D) uint ke_msg_id(uint task, uint idx) pure { return (task << 10) | idx; }
// bl60x_fw_api.h enum sm_msg_tag:
//   0=SM_CONNECT_REQ, 1=SM_CONNECT_CFM, 2=SM_CONNECT_IND,
//   3=SM_DISCONNECT_REQ, 4=SM_DISCONNECT_CFM, 5=SM_DISCONNECT_IND.
// STA logs showed unsolicited 0x1002 with cb=0x0; using the AP-style slots
// here dropped association completion on the floor.
enum SM_CONNECT_IND    = ke_msg_id(TASK_SM, 2);     // 0x1002
enum SM_DISCONNECT_IND = ke_msg_id(TASK_SM, 5);     // 0x1005
enum SCANU_START_CFM   = ke_msg_id(TASK_SCANU, 1);  // 0x0801
enum SCANU_RESULT_IND  = ke_msg_id(TASK_SCANU, 4);  // 0x0804
// Per vendor bl60x_fw_api.h enum apm_msg_tag (starts at KE_FIRST_MSG(TASK_APM)):
//   0=APM_START_REQ, 1=APM_START_CFM, 2=APM_STOP_REQ, 3=APM_STOP_CFM,
//   4=APM_STA_ADD_IND, 5=APM_STA_DEL_IND, 6=APM_STA_CONNECT_TIMEOUT_IND,
//   7=APM_STA_DEL_REQ, 8=APM_STA_DEL_CFM, 9=APM_CONF_MAX_STA_REQ
// We previously had 8/9 here -- wrong slots, IND messages from LMAC fell on
// our null handlers. STA admissions were happening but the host never saw them.
enum APM_STA_ADD_IND              = ke_msg_id(TASK_APM, 4);  // 0x1404
enum APM_STA_DEL_IND              = ke_msg_id(TASK_APM, 5);  // 0x1405
enum APM_STA_CONNECT_TIMEOUT_IND  = ke_msg_id(TASK_APM, 6);  // 0x1406

// libwifi.a was compiled with -fshort-enums: ke_msg_id_t is uint16,
// ke_task_id_t is uint8. Total header = 8 bytes (NOT 16). Our vendor C
// compile now also passes -fshort-enums so the shared-mem layout matches.
// History: with int-enums (16-byte header), the blob read dest at byte 2
// (= our id's third byte = 0) for every host msg, so ME_CONFIG_REQ
// (dest=ME=3) got routed to MM task (dest=0) and dropped.
struct ipc_e2a_msg
{
    ushort id;             // 0-1
    ubyte dummy_dest_id;   // 2
    ubyte dummy_src_id;    // 3
    uint param_len;        // 4-7 (naturally aligned)
    uint[1] param;         // 8+
    // uint pattern at the end of vendor struct -- we don't touch it
}

alias msg_cb_fct = extern (C) int function(bl_hw*, bl_cmd*, ipc_e2a_msg*) nothrow @nogc;

struct sm_connect_ind_body
{
    ushort status_code;
    ushort reason_code;
    ubyte[6] bssid;
    bool   roamed;
    ubyte  vif_idx;
    ubyte  ap_idx;
    ubyte  ch_idx;
    bool   qos;
    ubyte  acm;
    ushort assoc_req_ie_len;
    ushort assoc_rsp_ie_len;
}
static assert(sm_connect_ind_body.sizeof == 20);

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
}

struct apm_sta_add_ind_body
{
    uint     flags;
    ubyte[6] sta_addr;
    ubyte    vif_idx;
    ubyte    sta_idx;
    byte     rssi;
    ubyte[3] _pad0;
    uint     tsflo;
    uint     tsfhi;
    ubyte    data_rate;
}

struct apm_sta_del_ind_body
{
    ushort status_code;
    ushort reason_code;
    ubyte  sta_idx;
}

// Vendor C entry points we call (extern(C) bindings).
// ====================================================================

int  bl_send_reset(bl_hw* bl_hw);
int  bl_send_start(bl_hw* bl_hw);
int  bl_send_version_req(bl_hw* bl_hw, void* cfm);
int  bl_handle_dynparams(bl_hw* bl_hw);
int  bl_send_me_config_req(bl_hw* bl_hw);
int  bl_send_me_chan_config_req(bl_hw* bl_hw);

// Sets static module-globals country_default + channels_default in bl_msg_tx.c.
// Must be called before any APM_START_REQ; otherwise the beacon's country IE is
// empty (length 0) and the LMAC silently refuses to transmit beacons.
void bl_msg_update_channel_cfg(const(char)* code);

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
int  bl_send_apm_conf_max_sta_req(bl_hw* bl_hw, ubyte max_sta_supported);

// bl_shim.c -- wraps awkward vendor types with flat-arg helpers.
int  bl_shim_sta_connect(bl_hw* bl_hw, const(ubyte)* ssid, uint ssid_len,
                         const(ubyte)* bssid_or_null,
                         const(char)* psk, ubyte psk_len,
                         const(ubyte)* pmk, ubyte pmk_len,
                         int auth_type, ushort freq);

int  bl_irqs_init(bl_hw* bl_hw);
void bl_irq_bottomhalf(bl_hw* bl_hw);

// bl_shim.c -- ports vendor bl_utils.c's bl_ipc_init. Allocates the
// host env via the OS adapter (-> our urt heap), wires the cb table to
// our extern(C) D stubs, calls ipc_host_init + bl_cmd_mgr_init.
int  bl_shim_ipc_init(bl_hw* bl_hw, ipc_shared_env_tag* shared_mem);

// libwifi.a entry point. Long-lived task; we spawn it on a fibre and pump
// it from wifi_hw_poll. Param is unused by the blob (vendor SDK passes NULL).
void wifi_main(void* param);

struct phy_channel_info
{
    uint info1;
    uint info2;
}
static assert(phy_channel_info.sizeof == 8);

// PHY/RF (from libbl606p_phyrf.a). phy_init is called from inside wifi_main
// by the blob with its own config arg -- do not call from host code.
void phy_get_channel(phy_channel_info* info, ubyte index);
ubyte phy_get_mac_freq();
void phy_get_rf_gain_capab(byte* max, byte* min);
void rf_dump_status();


// ====================================================================
// Vendor message structs we touch directly (small / leaf only)
// ====================================================================

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

struct utils_list_hdr
{
    utils_list_hdr* next;
}
static assert(utils_list_hdr.sizeof == 4);

struct hostdesc
{
    uint pbuf_addr;
    uint packet_addr;
    ushort packet_len;
    uint status_addr;
    mac_addr eth_dest_addr;
    mac_addr eth_src_addr;
    ushort ethertype;
    ushort[4] pn;
    ushort sn;
    ushort timestamp;
    ubyte tid;
    ubyte vif_idx;
    ubyte staid;
    ushort flags;
    uint[4] pbuf_chained_ptr;
    uint[4] pbuf_chained_len;
}
static assert(hostdesc.sizeof == 80);
static assert(hostdesc.status_addr.offsetof == 12);
static assert(hostdesc.eth_dest_addr.offsetof == 16);
static assert(hostdesc.flags.offsetof == 46);

struct txdesc_host
{
    uint ready;
    uint[1600 / 4] eth_packet;
    hostdesc host;
    uint[204 / 4] pad_txdesc;
    uint[400 / 4] pad_buf;
}
static assert(txdesc_host.sizeof == 2288);

struct pbuf
{
    pbuf* next;
    void* payload;
    ushort tot_len;
    ushort len;
    ubyte type;
    ubyte flags;
    ushort ref_;
}
static assert(pbuf.sizeof == 16);

alias bl_custom_tx_callback_t = extern(C) void function(void* cb_arg, bool tx_ok) nothrow @nogc;

struct bl_custom_tx_cfm
{
    bl_custom_tx_callback_t cb;
    void* cb_arg;
}
static assert(bl_custom_tx_cfm.sizeof == 8);

struct bl_txhdr
{
    utils_list_hdr item;
    uint status;
    uint* p;
    hostdesc host;
    bl_custom_tx_cfm custom_cfm;
}
static assert(bl_txhdr.sizeof == 100);

struct tx_slot
{
    pbuf pb;
    bl_txhdr hdr;
    bool used;
}

enum TXDESC_CNT0 = 4;

@section(".sram_data.wifi") align(4) __gshared tx_slot[TXDESC_CNT0] _tx_slots;

txdesc_host* ipc_host_txdesc_get(ipc_host_env_tag* env);
void ipc_host_txdesc_push(ipc_host_env_tag* env, void* host_id);

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
    // Vif slots default to -1 (no VIF). Vendor C never writes these except
    // through bl_send_add_if's CFM, so without this default the boot-time
    // "set_mode(none)" path would tear-down phantom VIF 0 against LMAC.
    int vif_index_sta = -1;
    int vif_index_ap  = -1;
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
