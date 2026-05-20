module urt.driver.bl808_m0.wifi_pm;

version (BL808_M0):

import urt.driver.bl808_m0.bl_ops : bl_ops_msleep;

nothrow @nogc:
extern(C):


// wifi_hosal -- power management hooks called from libwifi.a. The SDK wires
// these through wifi_hosal_bl808.c to bl_pm.c before spawning wifi_main.
alias bl_pm_cb_t = extern(C) int function(void*) nothrow @nogc;

private enum PM_DISABLE = 0;
private enum PM_ENABLE  = 1;

private enum WLAN_PM_EVENT_CONTROL   = 0;
private enum WLAN_PM_EVENT_MAX       = 6;

private enum WLAN_CODE_PM_NOTIFY_START = 0;
private enum WLAN_CODE_PM_NOTIFY_STOP  = 1;
private enum WLAN_CODE_PM_START        = 2;
private enum WLAN_CODE_PM_STOP         = 3;

private enum PM_STATE_INITED  = 0;
private enum PM_STATE_STOP    = 1;
private enum PM_STATE_START   = 2;
private enum PM_STATE_STOPPED = 3;
private enum PM_STATE_RUNNING = 4;

private enum NODE_CAP_BIT_UAPSD_MODE     = 1u << 0;
private enum NODE_CAP_BIT_MAC_IDLE       = 1u << 1;
private enum NODE_CAP_BIT_MAC_DOZE       = 1u << 2;
private enum NODE_CAP_BIT_RF_ONOFF       = 1u << 3;
private enum NODE_CAP_BIT_WLAN_BLE_ABORT = 1u << 4;
private enum NODE_CAP_BIT_FORCE_SLEEP    = 1u << 5;

private enum PM_MODE_STA_NONE = 0;
private enum PM_MODE_STA_IDLE = 1;
private enum PM_MODE_STA_MESH = 2;
private enum PM_MODE_STA_DOZE = 3;
private enum PM_MODE_STA_COEX = 4;
private enum PM_MODE_STA_DOWN = 5;
private enum PM_MODE_AP_IDLE  = 6;

private struct PmNode
{
    int event;
    uint code;
    uint cap_bit;
    ushort priority;
    bl_pm_cb_t ops;
    void* arg;
    int enable;
}

private __gshared PmNode[32] _pm_nodes;
private __gshared uint _pm_node_count;
private __gshared uint _pm_wlan_capacity;
private __gshared uint _pm_bt_capacity = 0xFFFF;
private __gshared int  _pm_state = PM_STATE_INITED;

int wifi_hosal_pm_init()
{
    foreach (i; 0 .. _pm_nodes.length)
        _pm_nodes[i] = PmNode.init;
    _pm_node_count = 0;
    _pm_wlan_capacity = 0;
    _pm_bt_capacity = 0xFFFF;
    _pm_state = PM_STATE_INITED;
    return 0;
}

int wifi_hosal_pm_event_register(int event, uint code, uint cap_bit, ushort priority, bl_pm_cb_t ops, void* arg, int enable)
{
    if (event < 0 || event >= WLAN_PM_EVENT_MAX || _pm_node_count >= _pm_nodes.length)
        return -1;

    uint pos = _pm_node_count++;
    while (pos > 0 && priority < _pm_nodes[pos - 1].priority)
    {
        _pm_nodes[pos] = _pm_nodes[pos - 1];
        --pos;
    }

    _pm_nodes[pos] = PmNode(event, code, cap_bit, priority, ops, arg, enable);
    return 0;
}

int wifi_hosal_pm_deinit()
{
    _pm_node_count = 0;
    _pm_state = PM_STATE_INITED;
    return 0;
}

extern(D) private int pm_internal_process_event(int event, uint code)
{
    if (event != WLAN_PM_EVENT_CONTROL)
        return 0;

    if (code == WLAN_CODE_PM_NOTIFY_START)
    {
        if (_pm_state != PM_STATE_INITED && _pm_state != PM_STATE_STOPPED)
            return -1;
        _pm_state = PM_STATE_START;
    }
    else if (code == WLAN_CODE_PM_NOTIFY_STOP)
    {
        if (_pm_state != PM_STATE_RUNNING)
            return -1;
        _pm_state = PM_STATE_STOP;
    }

    return 0;
}

int wifi_hosal_pm_post_event(int event, uint code, uint* retval)
{
    if (event < 0 || event >= WLAN_PM_EVENT_MAX)
        return -1;

    if (retval)
        *retval = 0;

    foreach (i; 0 .. _pm_node_count)
    {
        auto node = &_pm_nodes[i];
        if (!node.enable || node.event != event || node.code != code)
            continue;
        if (((_pm_wlan_capacity & node.cap_bit) == 0) || ((_pm_bt_capacity & node.cap_bit) == 0))
            continue;
        if (event != WLAN_PM_EVENT_CONTROL && _pm_state != PM_STATE_RUNNING)
            return -1;
        if (node.ops)
        {
            int ret = node.ops(node.arg);
            if (ret && retval)
                *retval |= 1;
        }
    }

    int ret = pm_internal_process_event(event, code);
    bl_ops_msleep(1);
    return ret;
}

int wifi_hosal_pm_state_run()
{
    final switch (_pm_state)
    {
        case PM_STATE_INITED:
            return -1;
        case PM_STATE_START:
            _pm_state = PM_STATE_RUNNING;
            return wifi_hosal_pm_post_event(WLAN_PM_EVENT_CONTROL, WLAN_CODE_PM_START, null);
        case PM_STATE_STOP:
            _pm_state = PM_STATE_STOPPED;
            return wifi_hosal_pm_post_event(WLAN_PM_EVENT_CONTROL, WLAN_CODE_PM_STOP, null);
        case PM_STATE_RUNNING:
            return 0;
        case PM_STATE_STOPPED:
            return -1;
    }
}

int wifi_hosal_pm_capacity_set(int level)
{
    uint capacity;
    final switch (level)
    {
        case PM_MODE_STA_NONE:
            return -1;
        case PM_MODE_STA_IDLE:
            capacity = NODE_CAP_BIT_UAPSD_MODE | NODE_CAP_BIT_MAC_IDLE;
            break;
        case PM_MODE_STA_MESH:
            capacity = NODE_CAP_BIT_UAPSD_MODE | NODE_CAP_BIT_MAC_IDLE |
                       NODE_CAP_BIT_WLAN_BLE_ABORT | NODE_CAP_BIT_FORCE_SLEEP;
            break;
        case PM_MODE_STA_DOZE:
            capacity = NODE_CAP_BIT_UAPSD_MODE | NODE_CAP_BIT_MAC_IDLE |
                       NODE_CAP_BIT_MAC_DOZE | NODE_CAP_BIT_RF_ONOFF |
                       NODE_CAP_BIT_FORCE_SLEEP;
            break;
        case PM_MODE_STA_COEX:
            capacity = NODE_CAP_BIT_UAPSD_MODE | NODE_CAP_BIT_MAC_IDLE |
                       NODE_CAP_BIT_MAC_DOZE | NODE_CAP_BIT_RF_ONOFF |
                       NODE_CAP_BIT_WLAN_BLE_ABORT;
            break;
        case PM_MODE_STA_DOWN:
            capacity = NODE_CAP_BIT_MAC_IDLE | NODE_CAP_BIT_MAC_DOZE |
                       NODE_CAP_BIT_RF_ONOFF;
            break;
        case PM_MODE_AP_IDLE:
            capacity = NODE_CAP_BIT_MAC_IDLE | NODE_CAP_BIT_MAC_DOZE;
            break;
    }
    _pm_wlan_capacity = capacity;
    return 0;
}

int wifi_hosal_pm_event_switch(int event, uint code, int enable)
{
    int ret = -1;
    foreach (i; 0 .. _pm_node_count)
    {
        auto node = &_pm_nodes[i];
        if (node.event == event && node.code == code)
        {
            node.enable = enable;
            ret = 0;
        }
    }
    return ret;
}

int wifi_hosal_rf_turn_on(void* arg)
{
    // Mirrors the RF portion of vendor AON_LowPower_Exit_PDS0(). The blob
    // calls this before rf_init and around RF/channel state transitions; a
    // no-op here leaves the MAC alive but the analog RF path dark.
    enum uint AON_RF_TOP_AON = 0x2000_F880;
    enum uint AON_MISC       = 0x2000_F808;
    enum uint GLB_CGEN_CFG0  = 0x2000_0000;
    enum uint PU_MBG         = 1u << 0;
    enum uint PU_LDO15RF     = 1u << 1;
    enum uint PU_SFREG       = 1u << 2;
    enum uint SW_WB_EN       = 1u << 1;

    import urt.driver.bl618.timer : mtime_read;
    static void delay_us(ulong us)
    {
        ulong start = mtime_read();
        while (mtime_read() - start < us) {}
    }

    auto rf = cast(uint*)cast(size_t)AON_RF_TOP_AON;
    uint v = *rf | PU_MBG;
    *rf = v;
    delay_us(20);
    v |= PU_LDO15RF;
    *rf = v;
    delay_us(60);
    v |= PU_SFREG;
    *rf = v;
    delay_us(20);

    auto misc = cast(uint*)cast(size_t)AON_MISC;
    *misc = *misc | SW_WB_EN;

    auto cgen = cast(uint*)cast(size_t)GLB_CGEN_CFG0;
    *cgen = *cgen | (1u << 6) | (1u << 7);

    return 0;
}

int wifi_hosal_rf_turn_off(void* arg)
{
    // The blob calls this during normal channel/RF transitions; powering down
    // here leaves the MAC alive while the analog RF path goes dark.
    return 0;
}
