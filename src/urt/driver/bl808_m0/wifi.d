module urt.driver.bl808_m0.wifi;

version (BL808_M0):

import urt.driver.bl808_m0.bl_ops;
import urt.driver.bl808_m0.wifi_lmac;
import urt.driver.bl808_m0.wifi_pm;
import urt.driver.bl808_m0.wifi_wpa;
import urt.attribute : fast_data, section;
import urt.driver.wifi;
import urt.driver.wpa.eapol;

enum uint num_wifi = 1;
enum ubyte wifi_max_ap_clients = 5;

nothrow @nogc:


// TODO(bl808-wifi)
// - AP WPA auth is single-client state; move it to per-STA state, enforce
//   max_clients in the join path, and lift the current WPA max-clients=1
//   restriction.
// - Replace the hardcoded base MAC with the chip OTP/efuse MAC and derive
//   STA/AP VIF MACs from it.
// - Push STA/AP connect and auth failure reasons up through the API/status
//   path consistently.
// - Add GTK rekey support to the STA four-way path.
// - Handle msg-3 retransmit/replay and key reinstall rules with complete WPA
//   semantics before adding more AKM/cipher suites.
// - Replace magic vendor offsets/probes with mirrored structs or static
//   drift checks where possible, especially WifiConnectParmView,
//   _wpa_parse_wpa_ie output layout, hwhdr offsets, and SM_CONNECT_IND tails.
// - Audit null-hwhdr RX VIF attribution in tcpip_stack_input.
// - Rework event delivery so connect/disconnect bounces cannot be coalesced
//   by the generic baremetal polling layer.
// - Decide whether the blob timer shim needs real timer firing, not just
//   recorded state.
// - Confirm bl_ops allocation/free semantics under AllocTracking and blob DMA
//   use.
// - Revisit ISR/FPU save requirements for LDC-generated code.
// - Move AP-side WPA out of this driver once the shape settles.
// - Update vendor/wifi/PATCHES.md whenever vendor C divergences change.


// ====================================================================
// WiFi driver API
// ====================================================================

void wifi_hw_set_wake_callback(void function() nothrow @nogc cb)
{
    urt.driver.bl808_m0.bl_ops.wifi_set_wake_callback(cb);
}

bool wifi_hw_open(ubyte port, ref const WifiConfig cfg)
{
    import urt.driver.bl808_m0.bl_ops : bl_ops_task_create;
    import urt.driver.uart : uart0_puts;
    import urt.driver.bl618.irq : irq_set_handler, irq_set_enable;
    import urt.driver.bl618.timer : mtime_read;

    if (port != 0)
        return false;
    _configured_channel = cfg.channel;
    _current_channel = 0;
    _sta_candidate_channel = 0;

    enum uint GLB_WIFI_PLL_CFG0 = 0x2000_0810;
    enum uint PU_WIFIPLL_POSTDIV = 1u << 4;
    {
        uint pll0_pre = *cast(uint*)cast(size_t)GLB_WIFI_PLL_CFG0;
        *cast(uint*)cast(size_t)GLB_WIFI_PLL_CFG0 = pll0_pre | PU_WIFIPLL_POSTDIV;
        ulong start = mtime_read();
        while (mtime_read() - start < 100) {}
    }

    bl_wifi_register_wpa_cb_internal(&_wpa_stub_table);

    install_msg_hdlrs();

    if (bl_shim_ipc_init(&_bl_hw, &ipc_shared_env) != 0)
    {
        uart0_puts("wifi: ipc_init FAILED\n");
        return false;
    }
    ipc_emb2app_ack_clear(0xFFFFFFFF);

    if (bl_irqs_init(&_bl_hw) != 0)
    {
        uart0_puts("wifi: irqs_init FAILED\n");
        return false;
    }

    {
        auto reg = cast(uint*)cast(size_t)0x200003B0;
        *reg = (*reg & ~0xFu) | 1u;
    }

    ipc_emb2app_unmask_set(IPC_IRQ_E2A_ALL);

    irq_set_handler(70, &_wifi_mac_irq_thunk);
    irq_set_handler(79, &_wifi_ipc_irq_thunk);
    irq_set_enable(70);
    irq_set_enable(79);

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

    wifi_hosal_pm_init();

    void* fw_handle;
    if (bl_ops_task_create("fw".ptr, cast(void*)&wifi_main, 1536, null, 30, fw_handle) != 0)
    {
        uart0_puts("wifi: spawn wifi_main FAILED\n");
        return false;
    }

    {
        import urt.driver.bl808_m0.bl_ops : wifi_fibre_pump, wifi_main_in_main_loop;
        uint pumps;
        while (!wifi_main_in_main_loop && pumps < 32)
        {
            wifi_fibre_pump();
            ++pumps;
        }
        if (!wifi_main_in_main_loop)
        {
            uart0_puts("wifi: wifi_main never reached event loop\n");
            return false;
        }
    }

    _bl_hw.mod_params = &bl_mod_params;
    _bl_hw.vifs.next = &_bl_hw.vifs;
    _bl_hw.vifs.prev = &_bl_hw.vifs;

    if (bl_send_reset(&_bl_hw) != 0)
    {
        uart0_puts("wifi: bl_send_reset FAILED\n");
        return false;
    }

    {
        import urt.driver.bl808_m0.bl_ops : wifi_fibre_pump;
        import urt.driver.bl618.timer : mtime_read;
        ulong start = mtime_read();
        while (mtime_read() - start < 5_000)
            wifi_fibre_pump();
    }

    ubyte[128] version_cfm = 0;
    if (bl_send_version_req(&_bl_hw, version_cfm.ptr) != 0)
    {
        uart0_puts("wifi: bl_send_version_req FAILED\n");
        return false;
    }

    if (bl_handle_dynparams(&_bl_hw) != 0)
    {
        uart0_puts("wifi: bl_handle_dynparams FAILED\n");
        return false;
    }

    if (bl_send_me_config_req(&_bl_hw) != 0)
    {
        uart0_puts("wifi: bl_send_me_config_req FAILED\n");
        return false;
    }

    bl_msg_update_channel_cfg("CN".ptr);

    if (bl_send_me_chan_config_req(&_bl_hw) != 0)
    {
        uart0_puts("wifi: bl_send_me_chan_config_req FAILED\n");
        return false;
    }

    if (bl_send_start(&_bl_hw) != 0)
    {
        uart0_puts("wifi: bl_send_start FAILED\n");
        return false;
    }

    _bl_hw.is_up = 1;
    return true;
}

void wifi_hw_close(ubyte port)
{
    import urt.driver.bl618.irq : irq_clear_enable, irq_clear_pending, irq_set_handler;

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

    irq_clear_enable(70);
    irq_clear_enable(79);
    irq_clear_pending(70);
    irq_clear_pending(79);
    irq_set_handler(70, null);
    irq_set_handler(79, null);
    ipc_emb2app_unmask_set(0);
    ipc_emb2app_ack_clear(0xFFFFFFFF);
    if (_bl_hw.ipc_env !is null)
    {
        bl_ops_free(_bl_hw.ipc_env);
        _bl_hw.ipc_env = null;
    }
    wifi_hosal_pm_deinit();
    ap_auth_reset();

    _bl_hw.is_up = 0;
    _event_cb = null;
    _rx_cb = null;
    _raw_rx_cb = null;
    _wifi_evt_head = 0;
    _wifi_evt_tail = 0;
    _sta_ap_idx = ubyte.max;
    _sta_pending_pmk[] = 0;
    _sta_pending_pmk_hex[] = 0;
    _sta_pending_pmk_hex_len = 0;
    _sta_pending_tk_len = 0;
    _sta_pending_gtk_len = 0;
    _sta_pending_pair_rsc_len = 0;
    _sta_pending_group_rsc_len = 0;
    _sta_pending_keys = false;
    _sta_pending_auth = false;
    _sta_pending_auth_reason = 0;
}

bool wifi_hw_set_mode(ubyte port, WifiMode mode)
{
    final switch (mode)
    {
        case WifiMode.none:
            return tear_down_vif_ap() && tear_down_vif_sta();
        case WifiMode.monitor:
            return wifi_set_monitor_mode(true);
        case WifiMode.sta:
            return ensure_vif_sta() && tear_down_vif_ap();
        case WifiMode.ap:
            return ensure_vif_ap() && tear_down_vif_sta();
        case WifiMode.apsta:
            if (_apsta_unsupported)
                return false;
            if (ensure_vif_sta() && ensure_vif_ap())
                return true;
            _apsta_unsupported = true;
            return false;
    }
}

bool wifi_hw_sta_configure(ubyte port, ref const WifiStaConfig cfg)
{
    _sta_last_auth_reason = 0;
    _sta_status_message = null;
    if (cfg.pmf_required)
    {
        _sta_last_auth_reason = cast(ushort)WpaHandshakeReason.pmf_required_unsupported;
        _sta_status_message = wpa_handshake_reason_message(_sta_last_auth_reason);
        return false;
    }
    if (cfg.ssid.length > _sta_cfg_ssid_buf.length)
    {
        _sta_status_message = "STA SSID is too long";
        return false;
    }
    if (cfg.password.length > _sta_cfg_pw_buf.length)
    {
        _sta_status_message = "STA password is too long";
        return false;
    }
    bool same_psk = _sta_cfg_ssid_len == cfg.ssid.length &&
        _sta_cfg_pw_len == cfg.password.length;
    if (same_psk)
    {
        foreach (i; 0 .. cfg.ssid.length)
            if (_sta_cfg_ssid_buf[i] != cast(ubyte)cfg.ssid[i])
                same_psk = false;
        foreach (i; 0 .. cfg.password.length)
            if (_sta_cfg_pw_buf[i] != cast(ubyte)cfg.password[i])
                same_psk = false;
    }
    _sta_cfg_ssid_buf[0 .. cfg.ssid.length] = cast(ubyte[])cfg.ssid;
    _sta_cfg_ssid_len = cast(ubyte)cfg.ssid.length;
    _sta_cfg_pw_buf[0 .. cfg.password.length] = cast(ubyte[])cfg.password;
    _sta_cfg_pw_len = cast(ubyte)cfg.password.length;
    _sta_cfg_bssid = cfg.bssid;
    _sta_cfg_band = cfg.band;
    _sta_cfg_pmf  = cfg.pmf_required;
    if (!same_psk)
    {
        _sta_pending_pmk_hex_len = 0;
        _sta_candidate_channel = 0;
    }
    return true;
}

const(char)[] wifi_hw_sta_status_message(ubyte port)
{
    if (_sta_status_message.length != 0)
        return _sta_status_message;
    if (_sta_last_auth_reason != 0)
        return wpa_handshake_reason_message(_sta_last_auth_reason);
    return null;
}

bool wifi_hw_sta_connect(ubyte port)
{
    if (!ensure_vif_sta())
        return false;

    if (_sta_pending_pmk_hex_len == 0)
    {
        _sta_pending_pmk[] = 0;
        _sta_pending_pmk_hex[] = 0;
    }
    if (_sta_cfg_pw_len >= 8 && _sta_pending_pmk_hex_len == 0)
    {
        import urt.crypto.pbkdf2 : wpa2_psk_to_pmk;
        auto pw = cast(const(char)[])_sta_cfg_pw_buf[0 .. _sta_cfg_pw_len];
        auto ss = cast(const(char)[])_sta_cfg_ssid_buf[0 .. _sta_cfg_ssid_len];
        if (wpa2_psk_to_pmk(pw, ss, _sta_pending_pmk).succeeded)
        {
            static immutable string hexdig = "0123456789abcdef";
            foreach (i; 0 .. 32)
            {
                _sta_pending_pmk_hex[i*2 + 0] = cast(ubyte)hexdig[_sta_pending_pmk[i] >> 4];
                _sta_pending_pmk_hex[i*2 + 1] = cast(ubyte)hexdig[_sta_pending_pmk[i] & 0xF];
            }
            _sta_pending_pmk_hex_len = 64;
        }
    }

    ubyte* bssid;
    foreach (b; _sta_cfg_bssid)
    {
        if (b) { bssid = _sta_cfg_bssid.ptr; break; }
    }
    ushort freq = 0;
    enum NL80211_AUTHTYPE_AUTOMATIC = 8;

    int r = bl_shim_sta_connect(
        &_bl_hw,
        _sta_cfg_ssid_buf.ptr, _sta_cfg_ssid_len,
        bssid,
        cast(char*)_sta_cfg_pw_buf.ptr, _sta_cfg_pw_len,
        _sta_pending_pmk_hex.ptr, _sta_pending_pmk_hex_len,
        NL80211_AUTHTYPE_AUTOMATIC, freq,
    );
    if (r != 0)
    {
        queue_event(WifiEvent.sta_disconnected, null);
        return false;
    }
    return true;
}

bool wifi_hw_sta_disconnect(ubyte port)
{
    return bl_send_sm_disconnect_req(&_bl_hw) == 0;
}

bool wifi_hw_ap_configure(ubyte port, ref const WifiApConfig cfg)
{
    if (!ensure_vif_ap())
        return false;

    if (cfg.ssid.length >= _ap_ssid_buf.length)
        return false;
    if (cfg.password.length >= _ap_pw_buf.length)
        return false;
    _ap_ssid_buf[0 .. cfg.ssid.length] = cast(ubyte[])cfg.ssid;
    _ap_ssid_buf[cfg.ssid.length] = 0;
    bool ap_open = cfg.auth == WifiAuth.open || cfg.password.length == 0;
    if (!ap_open && cfg.max_clients > 1)
        return false;
    if (ap_open)
        _ap_pw_buf[0] = 0;
    else
    {
        _ap_pw_buf[0 .. cfg.password.length] = cast(ubyte[])cfg.password;
        _ap_pw_buf[cfg.password.length] = 0;
    }
    ap_auth_reset();

    apm_start_cfm cfm;
    ubyte ap_max_clients = ap_open ? cfg.max_clients : 1;
    if (ap_max_clients != 0 && !wifi_hw_ap_set_max_clients(port, ap_max_clients))
        return false;

    int r = bl_send_apm_start_req(
        &_bl_hw, &cfm,
        cast(char*)_ap_ssid_buf.ptr,
        cast(char*)_ap_pw_buf.ptr,
        cfg.channel == 0 ? 4 : cfg.channel,
        cast(ubyte)_bl_hw.vif_index_ap,
        cfg.hidden ? 1 : 0,
        100,
    );
    if (r != 0 || cfm.status != 0)
        return false;
    _bl_hw.ap_bcmc_idx = cfm.bcmc_idx;
    if (cfm.vif_idx < _bl_hw.vif_table.length)
        _bl_hw.vif_table[cfm.vif_idx].variant.ap.bcmc_index = cfm.bcmc_idx;

    queue_event(WifiEvent.ap_started, null);
    return true;
}

bool wifi_hw_ap_set_max_clients(ubyte port, ubyte max_clients)
{
    if (port != 0 || !_bl_hw.is_up)
        return false;
    if (_ap_pw_buf[0] != 0 && max_clients > 1)
        return false;

    ubyte max_sta = max_clients == 0 || max_clients > NX_REMOTE_STA_MAX
        ? cast(ubyte)NX_REMOTE_STA_MAX
        : max_clients;
    int r = bl_send_apm_conf_max_sta_req(&_bl_hw, max_sta);
    return r == 0;
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
    if (port != 0 || data.length < 14 || data.length > 1614 || _bl_hw.ipc_env is null)
        return false;

    int fw_vif = fw_vif_index(vif);
    if (fw_vif < 0)
        return false;

    tx_slot* slot;
    foreach (ref candidate; _tx_slots)
    {
        if (!candidate.used)
        {
            candidate.used = true;
            slot = &candidate;
            break;
        }
    }
    if (slot is null)
        return false;

    txdesc_host* txdesc = ipc_host_txdesc_get(_bl_hw.ipc_env);
    if (txdesc is null)
    {
        slot.used = false;
        return false;
    }

    auto payload_len = data.length - 14;
    if (payload_len > txdesc.eth_packet.sizeof)
    {
        slot.used = false;
        return false;
    }

    ubyte* dst = cast(ubyte*)txdesc.eth_packet.ptr;
    foreach (i; 0 .. payload_len)
        dst[i] = data[14 + i];

    hostdesc host = hostdesc.init;
    host.pbuf_addr = cast(uint)cast(size_t)&slot.pb;
    host.packet_addr = 0x1111_1111;
    host.packet_len = cast(ushort)payload_len;
    host.status_addr = cast(uint)cast(size_t)&slot.hdr.status;
    host.eth_dest_addr.array_[] = data[0 .. 6];
    host.eth_src_addr.array_[] = data[6 .. 12];
    host.ethertype = cast(ushort)(cast(ushort)data[12] | (cast(ushort)data[13] << 8));
    host.tid = 0;
    host.vif_idx = cast(ubyte)(vif == WifiVif.sta ? 1 : 0);
    int fw_staid = vif == WifiVif.sta
        ? (_bl_hw.sta_idx >= 0 ? _bl_hw.sta_idx : cast(int)_sta_ap_idx)
        : bl_utils_idx_lookup(&_bl_hw, cast(ubyte*)data.ptr);
    if (fw_staid < 0 || fw_staid > ubyte.max)
    {
        slot.used = false;
        return false;
    }
    host.staid = cast(ubyte)fw_staid;
    host.flags = 0;
    host.pbuf_chained_ptr[0] = cast(uint)cast(size_t)txdesc.eth_packet.ptr;
    host.pbuf_chained_len[0] = cast(uint)payload_len;

    slot.pb = pbuf.init;
    slot.pb.payload = &slot.hdr;
    slot.pb.tot_len = cast(ushort)data.length;
    slot.pb.len = cast(ushort)data.length;
    slot.pb.ref_ = 1;

    slot.hdr = bl_txhdr.init;
    slot.hdr.status = 0;
    slot.hdr.p = cast(uint*)&slot.pb;
    slot.hdr.host = host;

    txdesc.ready = 0;
    txdesc.host = host;

    ipc_host_txdesc_push(_bl_hw.ipc_env, &slot.pb);
    return true;
}

void wifi_hw_set_rx_callback(ubyte port, WifiRxCallback cb)
{
    _rx_cb = cb;
}

bool wifi_hw_raw_tx(ubyte port, const(ubyte)[] frame)
{
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

bool wifi_hw_set_channel(ubyte port, ubyte primary)
{
    // No live channel switch on BL808 - the LMAC owns its channel state
    // via the active VIF (STA's connected BSS or APM's configured channel).
    // Leaving unimplemented; channel changes go through the iface restart
    // path on this platform.
    return false;
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
    dispatch_queued_events();
    ap_auth_tick();
}



package:

// ====================================================================
// Module state
// ====================================================================

__gshared WifiRxCallback     _rx_cb;
__gshared WifiRawRxCallback  _raw_rx_cb;
__gshared WifiEventCallback  _event_cb;

struct WifiQueuedEvent
{
    WifiEvent event;
    ubyte[6] mac;
    bool has_mac;
}
enum size_t wifi_evt_cap = 16;
__gshared WifiQueuedEvent[wifi_evt_cap] _wifi_evt_queue;
__gshared uint _wifi_evt_head;
__gshared uint _wifi_evt_tail;

@section(".sram_data.wifi") __gshared bl_hw _bl_hw;

__gshared ubyte[6] _default_mac  = [0xC0, 0x49, 0xEF, 0x00, 0x00, 0x01];
__gshared ubyte[6] _vif_mac_sta;
__gshared ubyte[6] _vif_mac_ap;
__gshared ubyte    _wifi_dummy_netif;

__gshared ubyte[32] _sta_cfg_ssid_buf;
__gshared ubyte     _sta_cfg_ssid_len;
__gshared ubyte[64] _sta_cfg_pw_buf;
__gshared ubyte     _sta_cfg_pw_len;
__gshared ubyte[6]  _sta_cfg_bssid;
__gshared WifiBand  _sta_cfg_band;
__gshared bool      _sta_cfg_pmf;
__gshared ubyte     _sta_ap_idx = ubyte.max;
__gshared ubyte     _sta_candidate_channel;
__gshared ubyte     _configured_channel;

__gshared ubyte[32] _sta_pending_pmk;
// The vendor STA connect struct expects the PMK as 64 ASCII hex bytes.
__gshared ubyte[64] _sta_pending_pmk_hex;
__gshared ubyte     _sta_pending_pmk_hex_len;
__gshared ubyte[16] _sta_pending_tk;
__gshared ubyte[32] _sta_pending_gtk;
__gshared ubyte[6]  _sta_pending_pair_rsc;
__gshared ubyte[6]  _sta_pending_group_rsc;
__gshared ubyte     _sta_pending_tk_len;
__gshared ubyte     _sta_pending_gtk_len;
__gshared ubyte     _sta_pending_pair_rsc_len;
__gshared ubyte     _sta_pending_group_rsc_len;
__gshared ubyte     _sta_pending_gtk_idx;
__gshared bool      _sta_pending_keys;
__gshared bool      _sta_pending_auth;
__gshared ushort    _sta_pending_auth_reason;
__gshared ushort    _sta_last_auth_reason;
__gshared const(char)[] _sta_status_message;

__gshared ubyte[33] _ap_ssid_buf;
__gshared ubyte[65] _ap_pw_buf;

__gshared bool _scan_in_progress;
__gshared WifiScanResult[16] _scan_results;
__gshared size_t _scan_results_count;
__gshared ushort[1] _scan_channel_one;

__gshared ubyte _current_channel;


package:

// ====================================================================
// Blob callback surface
// ====================================================================

extern(C) int bl_utils_idx_lookup(bl_hw* hw, ubyte* mac)
{
    foreach (i; 0 .. STA_TABLE_LEN)
    {
        if (!hw.sta_table[i].is_used)
            continue;
        if (hw.sta_table[i].sta_addr.array_[] == mac[0..6])
            return cast(int)i;
    }
    return hw.ap_bcmc_idx;
}

extern(C) void bl_utils_dump() {}

extern(C) void bl_main_event_handle()
{
    bl_irq_bottomhalf(&_bl_hw);
}

extern(C) int  bl_supplicant_init(void* arg) { return 0; }

extern(C) int  bl_sleep_check(void* arg)
{
    __gshared uint call_count;
    if (++call_count == 1)
    {
        import urt.driver.bl808_m0.bl_ops : wifi_main_in_main_loop;
        wifi_main_in_main_loop = true;
    }
    return 0;
}

extern(C) ubyte bl_radarind(void* pthis, void* hostid)   { return 1; }

extern(C) ubyte bl_msgackind(void* pthis, void* hostid)
{
    auto hw  = cast(bl_hw*)pthis;
    auto cmd = cast(bl_cmd*)hostid;
    if (hw is null || cmd is null)
        return 0;
    hw.cmd_mgr.llind(&hw.cmd_mgr, cmd);
    return 0;
}

extern(C) ubyte bl_dbgind(void* pthis, void* hostid)     { return 1; }
extern(C) int   bl_txdatacfm(void* pthis, void* host_id)
{
    release_tx_slot(host_id);
    return 1;
}
extern(C) void  bl_prim_tbtt_ind(void* pthis)            {}
extern(C) void  bl_sec_tbtt_ind(void* pthis)             {}


// ====================================================================
// C ABI callbacks: IPC, IRQ, TX confirmation, and RX
// ====================================================================

extern(C) void bl_rx_e2a_handler(void* arg)
{
    ipc_e2a_msg* msg = cast(ipc_e2a_msg*)arg;
    uint task = MSG_T(msg.id);
    uint idx  = MSG_I(msg.id);

    msg_cb_fct cb;
    if (task < msg_hdlrs.length && idx < msg_hdlrs[task].length)
        cb = msg_hdlrs[task][idx];

    _bl_hw.cmd_mgr.msgind(&_bl_hw.cmd_mgr, msg, cb);
}

extern(C) void mac_irq();
extern(C) void bl_irq_handler();

extern(C) void phy_powroffset_set(byte* power_offset);
extern(C) void bl_tpc_update_power_rate_11b(byte* power_rate_table);
extern(C) void bl_tpc_update_power_rate_11g(byte* power_rate_table);
extern(C) void bl_tpc_update_power_rate_11n(byte* power_rate_table);
void _wifi_mac_irq_thunk(uint /+irq+/) @nogc nothrow
{
    mac_irq();
    wifi_signal_ready();
}
void _wifi_ipc_irq_thunk(uint /+irq+/) @nogc nothrow
{
    bl_irq_handler();
    wifi_signal_ready();
}

extern(C) void bl_tx_resend()
{
}

private void release_tx_slot(void* host_id)
{
    if (host_id is null)
        return;

    foreach (ref slot; _tx_slots)
    {
        if (cast(void*)&slot.pb == host_id)
        {
            bool sta_eapol = slot.hdr.host.ethertype == 0x8e88;
            slot.used = false;
            if (sta_eapol)
                sta_flush_pending_auth();
            return;
        }
    }
}

struct wifi_pkt
{
    uint[4] pkt;
    void*[4] pbuf;
    ushort[4] len;
}

extern(C) int tcpip_stack_input(void* swdesc, ubyte status, void* hwhdr, uint msdu_offset, void* pkt, ubyte extra_status)
{
    import urt.driver.wifi : Wifi, WifiVif;

    auto wp = cast(wifi_pkt*)pkt;

    const(ubyte)* eth = null;
    uint eth_len = 0;
    ushort ethertype = 0;
    uint rx_flags = hwhdr is null ? 0xFFFF_FFFF : *cast(uint*)cast(size_t)(cast(ubyte*)hwhdr + 64);
    uint rx_payl_offset = hwhdr is null ? 0 : *cast(uint*)cast(size_t)(cast(ubyte*)hwhdr + 72);
    ubyte rx_vif_idx = cast(ubyte)((rx_flags >> 8) & 0xff);
    ubyte rx_sta_idx = cast(ubyte)((rx_flags >> 16) & 0xff);
    WifiVif rx_vif = rx_vif_idx == 0xff && _bl_hw.vif_index_ap < 0 && _bl_hw.vif_index_sta >= 0
        ? WifiVif.sta
        : wifi_vif_from_fw_index(rx_vif_idx);

    if (wp && wp.pkt[0] != 0 && wp.len[0] >= msdu_offset + 14)
    {
        eth = cast(const(ubyte)*)(cast(size_t)wp.pkt[0] + msdu_offset);
        eth_len = cast(uint)wp.len[0] - msdu_offset;
        ethertype = cast(ushort)((cast(ushort)eth[12] << 8) | eth[13]);
        if (ethertype != eth_p_eapol &&
            rx_payl_offset != msdu_offset &&
            wp.len[0] >= rx_payl_offset + 14)
        {
            auto alt = cast(const(ubyte)*)(cast(size_t)wp.pkt[0] + rx_payl_offset);
            ushort alt_ethertype = cast(ushort)((cast(ushort)alt[12] << 8) | alt[13]);
            if (alt_ethertype == eth_p_eapol)
            {
                eth = alt;
                eth_len = cast(uint)wp.len[0] - rx_payl_offset;
                ethertype = alt_ethertype;
                msdu_offset = rx_payl_offset;
            }
        }

        if (ethertype == eth_p_eapol && sta_wpa_owns_eapol_key(rx_vif, eth, eth_len))
        {
            _wpa_sta_rx_eapol_real(cast(ubyte*)(eth + 6), cast(ubyte*)(eth + 14), eth_len - 14);
        }
        else if (_rx_cb !is null && eth_len <= 1518)
        {
            _rx_cb(Wifi(0), rx_vif, eth[0 .. eth_len]);
        }
    }

    return -1;
}

struct crc32_stream_ctx { uint state; }
extern(C) void utils_crc32_stream_init(crc32_stream_ctx* ctx)
{
    if (ctx) ctx.state = 0;
}
extern(C) void utils_crc32_stream_feed_block(crc32_stream_ctx* ctx, const(ubyte)* data, uint len) {}
extern(C) uint utils_crc32_stream_results(crc32_stream_ctx* ctx)            { return 0; }

// ====================================================================
@section(".sram_data.wifi") __gshared msg_cb_fct[MM_MAX_IDX]    mm_hdlrs;
@fast_data __gshared msg_cb_fct[SCANU_MAX_IDX] scanu_hdlrs;
@fast_data __gshared msg_cb_fct[ME_MAX_IDX]    me_hdlrs;
@fast_data __gshared msg_cb_fct[SM_MAX_IDX]    sm_hdlrs;
@fast_data __gshared msg_cb_fct[APM_MAX_IDX]   apm_hdlrs;
@section(".sram_data.wifi") __gshared msg_cb_fct[CFG_MAX_IDX]   cfg_hdlrs;


// ====================================================================
// LMAC message dispatch
// ====================================================================

@section(".sram_data.wifi") __gshared msg_cb_fct[][9] msg_hdlrs;

private void install_msg_hdlrs()
{
    sm_hdlrs[MSG_I(SM_CONNECT_IND)]       = &on_sm_connect_ind;
    sm_hdlrs[MSG_I(SM_DISCONNECT_IND)]    = &on_sm_disconnect_ind;
    scanu_hdlrs[MSG_I(SCANU_START_CFM)]   = &on_scanu_start_cfm;
    scanu_hdlrs[MSG_I(SCANU_RESULT_IND)]  = &on_scanu_result_ind;
    apm_hdlrs[MSG_I(APM_STA_ADD_IND)]              = &on_apm_sta_add_ind;
    apm_hdlrs[MSG_I(APM_STA_DEL_IND)]              = &on_apm_sta_del_ind;
    apm_hdlrs[MSG_I(APM_STA_CONNECT_TIMEOUT_IND)]  = &on_apm_sta_connect_timeout_ind;

    msg_hdlrs[TASK_MM]    = mm_hdlrs[];
    msg_hdlrs[TASK_SCANU] = scanu_hdlrs[];
    msg_hdlrs[TASK_ME]    = me_hdlrs[];
    msg_hdlrs[TASK_SM]    = sm_hdlrs[];
    msg_hdlrs[TASK_APM]   = apm_hdlrs[];
    msg_hdlrs[TASK_CFG]   = cfg_hdlrs[];
}


package void queue_event(WifiEvent event, const(void)* data)
{
    if (_wifi_evt_head - _wifi_evt_tail >= wifi_evt_cap)
        _wifi_evt_tail++;
    auto slot = &_wifi_evt_queue[_wifi_evt_head & (wifi_evt_cap - 1)];
    slot.event = event;
    slot.has_mac = data !is null &&
        (event == WifiEvent.ap_sta_connected || event == WifiEvent.ap_sta_disconnected);
    if (slot.has_mac)
        slot.mac[] = (cast(const(ubyte)*)data)[0 .. 6];
    _wifi_evt_head++;
}

private void dispatch_queued_events()
{
    if (_event_cb is null)
        return;

    Wifi w = Wifi(0);
    while (_wifi_evt_head != _wifi_evt_tail)
    {
        auto slot = &_wifi_evt_queue[_wifi_evt_tail & (wifi_evt_cap - 1)];
        _wifi_evt_tail++;
        _event_cb(w, slot.event, slot.has_mac ? slot.mac.ptr : null);
    }
}

private int fw_vif_index(WifiVif vif)
{
    return vif == WifiVif.sta ? _bl_hw.vif_index_sta : _bl_hw.vif_index_ap;
}

private WifiVif wifi_vif_from_fw_index(ubyte fw_vif_idx)
{
    if (fw_vif_idx == cast(ubyte)_bl_hw.vif_index_sta)
        return WifiVif.sta;
    return WifiVif.ap;
}

private void sta_table_bind_ap(bl_hw* hw, const(sm_connect_ind_body)* body_)
{
    _sta_ap_idx = body_.ap_idx;
    hw.sta_idx = body_.ap_idx;
    if (body_.ap_idx < hw.sta_table.length)
    {
        auto sta = &hw.sta_table[body_.ap_idx];
        sta.sta_addr.array_ = body_.bssid;
        sta.is_used = 1;
        sta.sta_idx = body_.ap_idx;
        sta.vif_idx = body_.vif_idx;
        sta.vlan_idx = body_.vif_idx;
        sta.qos = cast(ubyte)body_.qos;
    }
    if (body_.vif_idx < hw.vif_table.length && body_.ap_idx < hw.sta_table.length)
        hw.vif_table[body_.vif_idx].variant.sta.ap = &hw.sta_table[body_.ap_idx];
}

private void sta_table_unbind_ap(bl_hw* hw, ubyte vif_idx)
{
    if (_sta_ap_idx < hw.sta_table.length)
        hw.sta_table[_sta_ap_idx].is_used = 0;
    if (vif_idx < hw.vif_table.length)
        hw.vif_table[vif_idx].variant.sta.ap = null;
    _sta_ap_idx = ubyte.max;
    hw.sta_idx = -1;
}

extern (C) int on_sm_connect_ind(bl_hw* hw, bl_cmd* cmd, ipc_e2a_msg* msg)
{
    auto body_ = cast(sm_connect_ind_body*)&msg.param[0];
    if (body_.status_code == 0)
    {
        if (body_.ap_idx >= hw.sta_table.length)
        {
            return 0;
        }

        ushort freq = *cast(ushort*)(cast(ubyte*)&msg.param[0] + sm_connect_ind_body.sizeof + 800 + 4);
        _current_channel = freq_to_channel(freq);
        if (_current_channel == 0 && body_.ch_idx != 0xff)
            _current_channel = cast(ubyte)(body_.ch_idx + 1);
        sta_table_bind_ap(hw, body_);
        queue_event(WifiEvent.sta_connected, body_);
    }
    else
    {
        sta_table_unbind_ap(hw, body_.vif_idx);
        queue_event(WifiEvent.sta_disconnected, body_);
    }
    return 0;
}

extern (C) int on_sm_disconnect_ind(bl_hw* hw, bl_cmd* cmd, ipc_e2a_msg* msg)
{
    auto body_ = cast(sm_disconnect_ind_body*)&msg.param[0];
    sta_table_unbind_ap(hw, body_.vif_idx);
    queue_event(WifiEvent.sta_disconnected, body_);
    return 0;
}

extern (C) int on_scanu_result_ind(bl_hw* hw, bl_cmd* cmd, ipc_e2a_msg* msg)
{
    auto body_ = cast(scanu_result_ind_body*)&msg.param[0];

    // Payload follows the body and contains the raw 802.11 frame starting
    // at the MAC header. Beacon and probe-response have the same fixed
    // layout: 24-byte MAC hdr + 8 ts + 2 bcn_int + 2 cap + IE list.
    enum size_t HDR_FIXED = 24 + 12;
    ubyte* p = cast(ubyte*)body_ + scanu_result_ind_body.sizeof;
    int frame_len = body_.length;

    const(ubyte)[] ssid;
    if (frame_len > HDR_FIXED + 2)
    {
        ubyte* ies = p + HDR_FIXED;
        int ie_room = frame_len - cast(int)HDR_FIXED;
        // SSID IE has id=0 and is conventionally first.
        if (ie_room >= 2 && ies[0] == 0)
        {
            ubyte ssid_len = ies[1];
            if (ssid_len + 2 <= ie_room)
                ssid = ies[2 .. 2 + ssid_len];
        }
    }

    if (_scan_results_count >= _scan_results.length)
        return 0;   // buffer full -- silently drop

    auto r = &_scan_results[_scan_results_count++];
    r.bssid     = body_.sa;
    r.rssi      = body_.rssi;
    r.channel   = freq_to_channel(body_.center_freq);
    r.band      = body_.band == 0 ? WifiBand.band_2g4 : WifiBand.band_5g;
    r.bandwidth = WifiBandwidth.bw_20mhz;
    r.auth      = WifiAuth.open;
    r.ssid_len  = ssid.length > r.ssid_buf.length ? cast(ubyte)r.ssid_buf.length : cast(ubyte)ssid.length;
    if (r.ssid_len)
        r.ssid_buf[0 .. r.ssid_len] = cast(char[])ssid[0 .. r.ssid_len];
    if (ssid.length != 0 &&
        bytes_equal(ssid, _sta_cfg_ssid_buf[0 .. _sta_cfg_ssid_len]) &&
        r.channel != 0)
    {
        _sta_candidate_channel = r.channel;
    }

    return 0;
}

extern (C) int on_scanu_start_cfm(bl_hw* hw, bl_cmd* cmd, ipc_e2a_msg* msg)
{
    _scan_in_progress = false;
    queue_event(WifiEvent.scan_done, null);
    return 0;
}

extern (C) int on_apm_sta_add_ind(bl_hw* hw, bl_cmd* cmd, ipc_e2a_msg* msg)
{
    auto body_ = cast(apm_sta_add_ind_body*)&msg.param[0];
    if (body_.sta_idx < hw.sta_table.length)
    {
        auto sta = &hw.sta_table[body_.sta_idx];
        sta.sta_addr.array_ = body_.sta_addr;
        sta.is_used = 1;
        sta.sta_idx = body_.sta_idx;
        sta.vif_idx = body_.vif_idx;
        sta.vlan_idx = body_.vif_idx;
        sta.qos = cast(ubyte)((body_.flags & 1) != 0);
        sta.rssi = body_.rssi;
        sta.data_rate = body_.data_rate;
        sta.tsflo = body_.tsflo;
        sta.tsfhi = body_.tsfhi;
    }

    if (!ap_auth_has_pmk())
        bl_wifi_auth_done_internal(body_.sta_idx, 0);
    queue_event(WifiEvent.ap_sta_connected, body_.sta_addr.ptr);
    return 0;
}

extern (C) int on_apm_sta_del_ind(bl_hw* hw, bl_cmd* cmd, ipc_e2a_msg* msg)
{
    auto body_ = cast(apm_sta_del_ind_body*)&msg.param[0];
    ubyte[6] sta_mac = 0;
    bool have_sta_mac = false;
    if (body_.sta_idx < _bl_hw.sta_table.length)
    {
        sta_mac = _bl_hw.sta_table[body_.sta_idx].sta_addr.array_;
        have_sta_mac = _bl_hw.sta_table[body_.sta_idx].is_used != 0;
        _bl_hw.sta_table[body_.sta_idx].is_used = 0;
    }
    // DEL_IND body has no MAC, so copy it out of sta_table before clearing.
    queue_event(WifiEvent.ap_sta_disconnected, have_sta_mac ? sta_mac.ptr : null);
    return 0;
}

extern (C) int on_apm_sta_connect_timeout_ind(bl_hw* hw, bl_cmd* cmd, ipc_e2a_msg* msg)
{
    return 0;
}

private ubyte freq_to_channel(ushort mhz) pure
{
    if (mhz == 2484)
        return 14;
    if (mhz >= 2412 && mhz <= 2472)
        return cast(ubyte)((mhz - 2412) / 5 + 1);
    if (mhz >= 5180 && mhz <= 5825)
        return cast(ubyte)((mhz - 5180) / 5 + 36);
    return 0;
}

package bool bytes_equal(const(ubyte)[] a, const(ubyte)[] b) pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
        if (a[i] != b[i])
            return false;
    return true;
}

// ====================================================================
// VIF lifecycle helpers
// ====================================================================

// Linux nl80211_iftype values used by bl_send_add_if.
private enum NL80211_IFTYPE_STATION = 2;
private enum NL80211_IFTYPE_AP      = 3;
private enum NL80211_IFTYPE_MONITOR = 6;
private __gshared bool _apsta_unsupported;

private bool ensure_vif_sta()
{
    if (_bl_hw.vif_index_sta >= 0)
        return true;
    mm_add_if_cfm cfm;
    _vif_mac_sta = _default_mac;
    int r = bl_send_add_if(&_bl_hw, _vif_mac_sta.ptr, NL80211_IFTYPE_STATION, false, &cfm);
    if (r != 0 || cfm.status != 0)
        return false;
    _bl_hw.vif_index_sta = cfm.inst_nbr;
    _bl_hw.vif_table[cfm.inst_nbr].dev = &_wifi_dummy_netif;
    _bl_hw.vif_table[cfm.inst_nbr].up = true;
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
    int r = bl_send_add_if(&_bl_hw, _vif_mac_ap.ptr, NL80211_IFTYPE_AP, false, &cfm);
    if (r != 0 || cfm.status != 0)
        return false;
    _bl_hw.vif_index_ap = cfm.inst_nbr;
    _bl_hw.vif_table[cfm.inst_nbr].dev = &_wifi_dummy_netif;
    _bl_hw.vif_table[cfm.inst_nbr].up = true;
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
