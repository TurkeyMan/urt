// ESP32 WiFi driver -- D wrapper over C shim + direct ESP-IDF calls
//
// The C shim (ow_shim.c) handles:
//   - ow_wifi_init/deinit: WIFI_INIT_CONFIG_DEFAULT macro, netif creation,
//     event handler registration
//   - ow_wifi_sta_config/ap_config: wifi_config_t struct construction
//   - ow_wifi_set_rx_callback: RX trampolines that forward to D AND to
//     esp_netif_receive (so lwIP still works)
//
// Everything else (mode, connect, disconnect, tx, mac, channel, power)
// calls ESP-IDF directly.
//
// ESP32 has one WiFi port (port 0).
module urt.driver.esp32.wifi;

import urt.driver.wifi;

nothrow @nogc:


version (ESP32)         enum uint num_wifi = 1;
else version (ESP32_S2) enum uint num_wifi = 1;
else version (ESP32_S3) enum uint num_wifi = 1;
else version (ESP32_C2) enum uint num_wifi = 1;
else version (ESP32_C3) enum uint num_wifi = 1;
else version (ESP32_C5) enum uint num_wifi = 1;
else version (ESP32_C6) enum uint num_wifi = 1;
else                    enum uint num_wifi = 0; // H2 (BT/802.15.4 only), P4 (needs external)

enum ubyte wifi_max_ap_clients = 10;


static if (num_wifi > 0):


bool wifi_hw_open(uint port, ref const WifiConfig cfg)
{
    if (_opened)
        return false;

    if (ow_wifi_init() != 0)
        return false;

    ow_wifi_set_sta_callback(&sta_event_trampoline);
    ow_wifi_set_ap_callback(&ap_event_trampoline);

    if (cfg.tx_power != 0)
        esp_wifi_set_max_tx_power(cfg.tx_power);

    if (esp_wifi_start() != ESP_OK)
    {
        ow_wifi_deinit();
        return false;
    }

    _opened = true;
    return true;
}

void wifi_hw_close(uint port)
{
    if (!_opened)
        return;
    ow_wifi_set_rx_callback(null);
    ow_wifi_set_sta_callback(null);
    ow_wifi_set_ap_callback(null);
    esp_wifi_stop();
    ow_wifi_deinit();
    _opened = false;
    _event_cb = null;
    _rx_cb = null;
    _raw_rx_cb = null;
    _wifi_evt_head = 0;
    _wifi_evt_tail = 0;
}

bool wifi_hw_set_mode(uint port, WifiMode mode)
{
    // ESP-IDF treats promiscuous as a flag orthogonal to STA/AP, so monitor
    // here means "STA mode (radio on, channel controllable) with promiscuous
    // enabled later via wifi_hw_set_raw_rx_callback". The driver brings the
    // radio up in STA so esp_wifi_set_channel is accepted; without STA, the
    // channel setter rejects the call with WIFI_NOT_INIT_OR_NOT_STARTED.
    int hw_mode = mode == WifiMode.monitor
        ? 1   // STA -- minimum mode that lets us set channel + enable promisc
        : (mode == WifiMode.none   ? 0
        :  mode == WifiMode.sta    ? 1
        :  mode == WifiMode.ap     ? 2
        :                            3);  // apsta
    return esp_wifi_set_mode(hw_mode) == ESP_OK;
}

bool wifi_hw_sta_configure(uint port, ref const WifiStaConfig cfg)
{
    _sta_status_message = null;

    if (cfg.ssid.length > 32)
    {
        _sta_status_message = "STA SSID is too long";
        return false;
    }
    if (cfg.password.length > 64)
    {
        _sta_status_message = "STA password is too long";
        return false;
    }
    if (cfg.pmf_required)
    {
        _sta_status_message = "STA PMF required is not supported";
        return false;
    }

    // Stack buffers for null-termination (SSID max 32, password max 64)
    char[33] ssid_z = 0;
    char[65] pw_z = 0;

    if (cfg.ssid.length > 0 && cfg.ssid.length <= 32)
        ssid_z[0 .. cfg.ssid.length] = cfg.ssid[];
    if (cfg.password.length > 0 && cfg.password.length <= 64)
        pw_z[0 .. cfg.password.length] = cfg.password[];

    bool has_bssid = cfg.bssid != typeof(cfg.bssid).init;

    if (ow_wifi_sta_config(
        cfg.ssid.length > 0 ? ssid_z.ptr : null,
        cfg.password.length > 0 ? pw_z.ptr : null,
        has_bssid ? cfg.bssid.ptr : null) == 0)
    {
        _sta_status_message = "STA config rejected by ESP-IDF";
        return false;
    }

    return true;
}

const(char)[] wifi_hw_sta_status_message(uint port)
{
    if (_sta_status_message.length != 0)
        return _sta_status_message;
    return esp_wifi_sta_reason_message(_sta_disconnect_reason);
}

bool wifi_hw_sta_connect(uint port)
{
    _sta_status_message = null;
    _sta_disconnect_reason = 0;
    auto rc = esp_wifi_connect();
    if (rc == ESP_OK)
        return true;
    _sta_status_message = esp_wifi_error_message(rc);
    return false;
}

bool wifi_hw_sta_disconnect(uint port)
{
    return esp_wifi_disconnect() == ESP_OK;
}

bool wifi_hw_ap_configure(uint port, ref const WifiApConfig cfg)
{
    char[33] ssid_z = 0;
    char[65] pw_z = 0;

    if (cfg.ssid.length > 0 && cfg.ssid.length <= 32)
        ssid_z[0 .. cfg.ssid.length] = cfg.ssid[];
    if (cfg.password.length > 0 && cfg.password.length <= 64)
        pw_z[0 .. cfg.password.length] = cfg.password[];

    return ow_wifi_ap_config(
        cfg.ssid.length > 0 ? ssid_z.ptr : null,
        cfg.password.length > 0 ? pw_z.ptr : null,
        cfg.channel, cfg.max_clients, cfg.hidden ? 1 : 0) != 0;
}

bool wifi_hw_ap_set_max_clients(uint port, ubyte max_clients)
{
    if (port != 0 || max_clients > wifi_max_ap_clients)
        return false;
    return ow_wifi_ap_set_max_clients(max_clients) != 0;
}

size_t wifi_hw_ap_get_clients(uint port, WifiStaInfo[] buf)
{
    // TODO: esp_wifi_ap_get_sta_list
    return 0;
}

// Scanning

bool wifi_hw_scan_start(uint port, ref const WifiScanConfig cfg)
{
    // TODO: esp_wifi_scan_start
    return false;
}

void wifi_hw_scan_stop(uint port)
{
    // TODO: esp_wifi_scan_stop
}

size_t wifi_hw_scan_get_results(uint port, WifiScanResult[] buf)
{
    // TODO: esp_wifi_scan_get_ap_records
    return 0;
}

// Frame TX/RX

bool wifi_hw_tx(uint port, WifiVif vif, const(ubyte)[] data)
{
    if (data.length == 0)
        return false;
    return esp_wifi_internal_tx(cast(int)vif, cast(void*)data.ptr, cast(ushort)data.length) == ESP_OK;
}

void wifi_hw_set_rx_callback(uint port, WifiRxCallback cb)
{
    _rx_cb = cb;
    ow_wifi_set_rx_callback(cb !is null ? &rx_trampoline : null);
}

// Raw 802.11 TX/RX

bool wifi_hw_raw_tx(uint port, const(ubyte)[] frame)
{
    if (frame.length == 0 || frame.length > 1500)
        return false;
    // ifx = 0 (WIFI_IF_STA): always present in our monitor + sta + ap modes.
    // en_sys_seq = 1: let the MAC fill the sequence number so injected frames
    // don't collide with the radio's own outgoing sequence space.
    return ow_wifi_raw_tx(0, frame.ptr, cast(int)frame.length, 1) != 0;
}

void wifi_hw_set_raw_rx_callback(uint port, WifiRawRxCallback cb)
{
    _raw_rx_cb = cb;

    if (cb is null)
    {
        ow_wifi_set_promiscuous(0, 0);
        ow_wifi_set_promiscuous_callback(null);
        return;
    }

    ow_wifi_set_promiscuous_callback(&promisc_trampoline);
    // Filter: management + data + control + misc + FCS-fail. The FCSFAIL
    // bit is what lets us see corrupted frames -- the discriminator we need
    // for "is the antenna seeing anything at all" vs "frames are framing
    // correctly but content is wrong".
    enum uint WIFI_PROMIS_FILTER_MASK_ALL_WITH_FCSFAIL = 0xE00000FF;
    ow_wifi_set_promiscuous(1, WIFI_PROMIS_FILTER_MASK_ALL_WITH_FCSFAIL);
}

bool wifi_hw_set_channel(uint port, ubyte primary)
{
    // secondary=0 -> HT20 (no 40 MHz extension). The vast majority of 2.4GHz
    // deployments are HT20; if we ever want HT40 we extend this signature.
    return ow_wifi_set_channel(primary, 0) != 0;
}

// Queries

bool wifi_hw_get_mac(uint port, WifiVif vif, ref ubyte[6] mac)
{
    // ESP_MAC_WIFI_STA=0, ESP_MAC_WIFI_SOFTAP=1
    return esp_read_mac(mac.ptr, cast(int)vif) == ESP_OK;
}

ubyte wifi_hw_get_channel(uint port)
{
    ubyte primary = void;
    int second = void;
    if (esp_wifi_get_channel(&primary, &second) != ESP_OK)
        return 0;
    return primary;
}

byte wifi_hw_get_rssi(uint port)
{
    // TODO: esp_wifi_sta_get_ap_info -> rssi
    return -127;
}

bool wifi_hw_set_tx_power(uint port, byte power_dbm)
{
    return esp_wifi_set_max_tx_power(power_dbm) == ESP_OK;
}

// Events

void wifi_hw_set_event_callback(uint port, WifiEventCallback cb)
{
    _event_cb = cb;
}

void wifi_hw_poll(uint port)
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


private:

enum int ESP_OK = 0;

// ESP-IDF event IDs (from esp_wifi_types.h)
enum : int
{
    WIFI_EVENT_STA_START          = 2,
    WIFI_EVENT_STA_STOP           = 3,
    WIFI_EVENT_STA_CONNECTED      = 4,
    WIFI_EVENT_STA_DISCONNECTED   = 5,
    WIFI_EVENT_AP_START           = 12,
    WIFI_EVENT_AP_STOP            = 13,
    WIFI_EVENT_AP_STACONNECTED    = 14,
    WIFI_EVENT_AP_STADISCONNECTED = 15,
}

__gshared bool _opened;
__gshared WifiEventCallback _event_cb;
__gshared WifiRxCallback _rx_cb;
__gshared WifiRawRxCallback _raw_rx_cb;
__gshared int _sta_disconnect_reason;
__gshared const(char)[] _sta_status_message;

struct WifiQueuedEvent
{
    WifiEvent event;
    ubyte[6] mac;
    bool has_mac;
}
enum size_t wifi_evt_cap = 8;
__gshared WifiQueuedEvent[wifi_evt_cap] _wifi_evt_queue;
__gshared uint _wifi_evt_head;
__gshared uint _wifi_evt_tail;

void push_wifi_evt(WifiEvent event, const ubyte* mac = null) nothrow @nogc
{
    if (_wifi_evt_head - _wifi_evt_tail >= wifi_evt_cap)
        _wifi_evt_tail++;
    auto slot = &_wifi_evt_queue[_wifi_evt_head & (wifi_evt_cap - 1)];
    slot.event = event;
    slot.has_mac = mac !is null;
    if (mac !is null)
        slot.mac[] = mac[0 .. 6];
    _wifi_evt_head++;
}

extern(C) void sta_event_trampoline(int event_id, void*, int data_len) nothrow @nogc
{
    if (event_id == WIFI_EVENT_STA_CONNECTED)
    {
        _sta_status_message = null;
        _sta_disconnect_reason = 0;
        push_wifi_evt(WifiEvent.sta_connected);
    }
    else if (event_id == WIFI_EVENT_STA_DISCONNECTED)
    {
        _sta_disconnect_reason = data_len;
        _sta_status_message = null;
        push_wifi_evt(WifiEvent.sta_disconnected);
    }
}

const(char)[] esp_wifi_error_message(int rc) nothrow @nogc
{
    switch (rc)
    {
        case ESP_OK:
            return null;
        default:
            return "ESP-IDF rejected STA request";
    }
}

const(char)[] esp_wifi_sta_reason_message(int reason) nothrow @nogc
{
    switch (reason)
    {
        case 0:
            return null;
        case 1:
            return "Disconnected: unspecified reason";
        case 2:
            return "Authentication expired";
        case 4:
            return "Association expired";
        case 5:
            return "AP has too many clients";
        case 6:
            return "Not authenticated";
        case 7:
            return "Not associated";
        case 8:
            return "Association left";
        case 9:
            return "Association requires authentication";
        case 13:
            return "Invalid 802.11 information element";
        case 14:
            return "WPA MIC failure";
        case 15:
            return "WPA 4-way handshake timed out";
        case 16:
            return "WPA group key update timed out";
        case 17:
            return "WPA information element changed during handshake";
        case 18:
            return "WPA group cipher is invalid";
        case 19:
            return "WPA pairwise cipher is invalid";
        case 20:
            return "WPA AKM suite is invalid";
        case 21:
            return "Unsupported RSN information element version";
        case 22:
            return "Invalid RSN capabilities";
        case 23:
            return "802.1X authentication failed";
        case 24:
            return "Cipher suite rejected";
        case 200:
            return "AP beacon timed out";
        case 201:
            return "Target AP not found";
        case 202:
            return "Authentication failed";
        case 203:
            return "Association failed";
        case 204:
            return "WPA handshake timed out";
        case 205:
            return "Connection failed";
        case 207:
            return "Roaming";
        default:
            return "Disconnected by WiFi driver";
    }
}

extern(C) void ap_event_trampoline(int event_id, void* event_data, int) nothrow @nogc
{
    if (event_id == WIFI_EVENT_AP_START)
        push_wifi_evt(WifiEvent.ap_started);
    else if (event_id == WIFI_EVENT_AP_STOP)
        push_wifi_evt(WifiEvent.ap_stopped);
    else if (event_id == WIFI_EVENT_AP_STACONNECTED && event_data !is null)
        push_wifi_evt(WifiEvent.ap_sta_connected, cast(ubyte*)event_data);
    else if (event_id == WIFI_EVENT_AP_STADISCONNECTED && event_data !is null)
        push_wifi_evt(WifiEvent.ap_sta_disconnected, cast(ubyte*)event_data);
}

// RX trampoline -- called from C shim's esp_wifi_internal_reg_rxcb handler.
// The C shim also forwards to esp_netif_receive so lwIP still gets frames.
extern(C) void rx_trampoline(const(ubyte)* data, int len, int iface) nothrow @nogc
{
    if (_rx_cb !is null && len > 0)
        _rx_cb(Wifi(0), cast(WifiVif)iface, data[0 .. len]);
}

// Promiscuous trampoline -- called from C shim for every 802.11 frame the
// radio decodes (including FCS-fail frames when the filter bit is set).
// rx_state non-zero == FCS failed; we forward unchanged and let the
// subscriber decide what to do with broken frames.
extern(C) void promisc_trampoline(int type, int rssi, int channel,
                                  int rate, int fcs_fail, int len,
                                  const(ubyte)* payload) nothrow @nogc
{
    if (_raw_rx_cb is null || len <= 0 || payload is null)
        return;
    // Drop FCS-fail frames for now -- the raw RX callback signature has no
    // place to surface the bad-FCS flag yet, and forwarding garbage frames
    // confuses subscribers that assume valid framing. The driver-level RX
    // dropped counter is bumped at the iface layer instead.
    if (fcs_fail)
        return;
    _raw_rx_cb(Wifi(0), payload[0 .. len], cast(byte)rssi, cast(ubyte)channel);
}

// C shim functions (ow_shim.c) -- needed for macros, complex structs, netif
extern(C) nothrow @nogc
{
    int ow_wifi_init();
    void ow_wifi_deinit();
    int ow_wifi_sta_config(const(char)* ssid, const(char)* password, const(ubyte)* bssid);
    int ow_wifi_ap_config(const(char)* ssid, const(char)* password, ubyte channel, ubyte max_conn, ubyte hidden);
    int ow_wifi_ap_set_max_clients(ubyte max_conn);
    int ow_wifi_set_rx_callback(void function(const(ubyte)*, int, int) nothrow @nogc cb);
    void ow_wifi_set_sta_callback(void function(int, void*, int) nothrow @nogc);
    void ow_wifi_set_ap_callback(void function(int, void*, int) nothrow @nogc);
    int ow_wifi_set_promiscuous(int enable, uint filter_mask);
    void ow_wifi_set_promiscuous_callback(
        void function(int type, int rssi, int channel,
                      int rate, int fcs_fail, int len,
                      const(ubyte)* payload) nothrow @nogc cb);
    int ow_wifi_set_channel(int primary, int secondary);
    int ow_wifi_raw_tx(int ifx, const(ubyte)* frame, int len, int en_sys_seq);
}

// Direct ESP-IDF calls
extern(C) nothrow @nogc
{
    int esp_wifi_set_mode(int mode);
    int esp_wifi_start();
    int esp_wifi_stop();
    int esp_wifi_connect();
    int esp_wifi_disconnect();
    int esp_wifi_set_max_tx_power(byte power);
    int esp_wifi_get_channel(ubyte* primary, int* second);
    int esp_read_mac(ubyte* mac, int type);
    int esp_wifi_internal_tx(int ifx, void* buffer, ushort len);
}
