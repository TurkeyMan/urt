// ESP32 BLE driver -- D wrapper over NimBLE via C shim + direct calls
//
// The C shim (ow_shim.c) handles:
//   - ow_ble_init/deinit: NimBLE host config struct, port init, host task
//   - ow_ble_set_gap_callback: GAP event dispatch trampoline to D
//
// Everything else (scan, connect, GATT) calls NimBLE C API directly.
//
// BLE controller count per chip (ESP-IDF v6.0):
//   ESP32, S3, C2, C3, C5, C6, H2: 1    S2, P4: 0
module urt.driver.esp32.ble;

import urt.driver.ble;

import urt.uuid : GUID;

nothrow @nogc:


version (ESP32)         enum uint num_ble = 1;
else version (ESP32_S3) enum uint num_ble = 1;
else version (ESP32_C2) enum uint num_ble = 1;
else version (ESP32_C3) enum uint num_ble = 1;
else version (ESP32_C5) enum uint num_ble = 1;
else version (ESP32_C6) enum uint num_ble = 1;
else version (ESP32_H2) enum uint num_ble = 1;
else                    enum uint num_ble = 0; // S2, P4


static if (num_ble > 0):


bool ble_hw_open(uint port, ref const BLEConfig cfg)
{
    if (port >= num_ble)
        return false;
    if (_opened)
        return true;

    if (ow_ble_init() != 0)
        return false;

    ow_ble_set_gap_callback(&gap_event_trampoline);

    _opened = true;
    return true;
}

void ble_hw_close(uint port)
{
    if (!_opened)
        return;

    ble_hw_scan_stop(port);
    ble_hw_adv_stop(port, BLEAdv.init);

    // disconnect all active connections
    foreach (ref s; _sessions)
    {
        if (s.active)
            ble_gap_terminate(s.nimble_handle, 0x13); // Remote User Terminated
    }

    ow_ble_set_gap_callback(null);
    ow_ble_deinit();

    _opened = false;
    _scan_cb = null;
    _conn_cb = null;
    _discover_cb = null;
    _read_cb = null;
    _write_cb = null;
    _notify_cb = null;
    _num_sessions = 0;
}

// --- Scanning ---

bool ble_hw_scan_start(uint port, ref const BLEScanConfig cfg)
{
    ble_gap_disc_params params;
    params.itvl = cast(ushort)(cfg.interval_ms * 1000 / 625); // BLE units of 0.625ms
    params.window = cast(ushort)(cfg.window_ms * 1000 / 625);
    if (!cfg.active)
        params.flags |= 0x02; // passive
    if (cfg.filter_duplicates)
        params.flags |= 0x04; // filter_duplicates

    if (ble_gap_disc(0, 0, &params, &gap_event_trampoline, null) != 0)
        return false;
    return true;
}

void ble_hw_scan_stop(uint port)
{
    ble_gap_disc_cancel();
}

// --- Advertising ---

BLEAdv ble_hw_adv_start(uint port, ref const BLEAdvConfig cfg)
{
    if (cfg.adv_data.length > 0 && cfg.adv_data.length <= 31)
    {
        if (ble_gap_adv_set_data(cfg.adv_data.ptr, cast(int)cfg.adv_data.length) != 0)
            return BLEAdv.init;
    }

    if (cfg.scan_rsp.length > 0 && cfg.scan_rsp.length <= 31)
    {
        if (ble_gap_adv_rsp_set_data(cfg.scan_rsp.ptr, cast(int)cfg.scan_rsp.length) != 0)
            return BLEAdv.init;
    }

    ble_gap_adv_params params;
    params.conn_mode = cfg.adv_type == BLEAdvType.connectable ? 2 : 0; // BLE_GAP_CONN_MODE_UND : NON
    params.disc_mode = 2; // BLE_GAP_DISC_MODE_GEN
    params.itvl_min = cast(ushort)(cfg.interval_ms * 1000 / 625);
    params.itvl_max = params.itvl_min;

    if (ble_gap_adv_start(0, null, 0, &params, &gap_event_trampoline, null) != 0)
        return BLEAdv.init;
    return BLEAdv(0);
}

void ble_hw_adv_stop(uint port, BLEAdv)
{
    ble_gap_adv_stop();
}

// --- Connection ---

bool ble_hw_connect(uint port, ref const ubyte[6] peer_addr, BLEAddrType addr_type, ref const BLEConnConfig cfg)
{
    if (_pending_connect)
        return false;

    ble_addr_t addr;
    addr.type = cast(ubyte)addr_type;
    // NimBLE uses LSB-first byte order
    foreach (i; 0 .. 6)
        addr.val[i] = peer_addr[5 - i];

    ble_gap_conn_params params;
    params.itvl_min = cast(ushort)(cfg.interval_min_ms * 1000 / 1250); // units of 1.25ms
    params.itvl_max = cast(ushort)(cfg.interval_max_ms * 1000 / 1250);
    params.latency = cfg.latency;
    params.supervision_timeout = cast(ushort)(cfg.timeout_ms / 10); // units of 10ms
    params.min_ce_len = 0;
    params.max_ce_len = 0;

    _pending_connect = true;
    if (ble_gap_connect(0, &addr, 30_000, &params, &gap_event_trampoline, null) != 0)
    {
        _pending_connect = false;
        return false;
    }
    return true;
}

void ble_hw_connect_cancel(uint port)
{
    ble_gap_conn_cancel();
    _pending_connect = false;
}

bool ble_hw_disconnect(uint port, BLEConn conn)
{
    auto s = find_session(conn.id);
    if (s is null)
        return false;

    if (ble_gap_terminate(s.nimble_handle, 0x13) != 0)
        return false;
    return true;
}

// --- GATT discovery ---

bool ble_hw_gatt_discover(uint port, BLEConn conn)
{
    auto s = find_session(conn.id);
    if (s is null)
        return false;

    _discovering_conn = conn.id;
    _discover_phase = DiscoverPhase.services;
    s.num_chars = 0;

    if (ble_gattc_disc_all_svcs(s.nimble_handle, &svc_discover_cb, null) != 0)
        return false;
    return true;
}

// --- GATT read/write ---

bool ble_hw_gatt_read(uint port, BLEConn conn, ushort handle)
{
    auto s = find_session(conn.id);
    if (s is null)
        return false;

    if (ble_gattc_read(s.nimble_handle, handle, &gatt_read_cb, cast(void*)cast(size_t)conn.id) != 0)
        return false;
    return true;
}

bool ble_hw_gatt_write(uint port, BLEConn conn, ushort handle, const(ubyte)[] data, bool with_response)
{
    auto s = find_session(conn.id);
    if (s is null)
        return false;

    if (with_response)
    {
        if (ble_gattc_write_flat(s.nimble_handle, handle, data.ptr,
            cast(ushort)data.length, &gatt_write_cb, cast(void*)cast(size_t)conn.id) != 0)
            return false;
    }
    else
    {
        if (ble_gattc_write_no_rsp_flat(s.nimble_handle, handle,
            data.ptr, cast(ushort)data.length) != 0)
            return false;
    }
    return true;
}

// --- Notifications ---

bool ble_hw_gatt_subscribe(uint port, BLEConn conn, ushort handle, bool enable)
{
    auto s = find_session(conn.id);
    if (s is null)
        return false;

    // find CCCD handle (handle + 1 by convention for standard GATT)
    ushort cccd_handle = cast(ushort)(handle + 1);

    ubyte[2] cccd_value;
    if (enable)
        cccd_value[0] = 0x01; // enable notifications

    if (ble_gattc_write_flat(s.nimble_handle, cccd_handle,
        cccd_value.ptr, 2, null, null) != 0)
        return false;
    return true;
}

// --- Queries ---

bool ble_hw_get_mac(uint port, ref ubyte[6] mac)
{
    ubyte addr_type;
    if (ble_hs_id_infer_auto(0, &addr_type) != 0)
        return false;
    if (ble_hs_id_copy_addr(addr_type, mac.ptr, null) != 0)
        return false;
    return true;
}

byte ble_hw_get_rssi(uint port, BLEConn conn)
{
    auto s = find_session(conn.id);
    if (s is null)
        return -128;

    byte rssi;
    if (ble_gap_conn_rssi(s.nimble_handle, &rssi) != 0)
        return -128;
    return rssi;
}

// --- Callbacks ---

void ble_hw_set_scan_callback(uint port, BLEScanCallback cb)    { _scan_cb = cb; }
void ble_hw_set_conn_callback(uint port, BLEConnCallback cb)    { _conn_cb = cb; }
void ble_hw_set_discover_callback(uint port, BLEDiscoverCallback cb) { _discover_cb = cb; }
void ble_hw_set_read_callback(uint port, BLEReadCallback cb)    { _read_cb = cb; }
void ble_hw_set_write_callback(uint port, BLEWriteCallback cb)  { _write_cb = cb; }
void ble_hw_set_notify_callback(uint port, BLENotifyCallback cb) { _notify_cb = cb; }

// --- Poll ---

void ble_hw_poll(uint port)
{
    // Drain buffered events from NimBLE host task.
    // Events are queued by GAP/GATT callbacks which run on the NimBLE task.

    auto ble = BLE(0);

    // scan results
    while (_scan_queue.count > 0)
    {
        auto report = &_scan_queue.buf[_scan_queue.tail];
        if (_scan_cb !is null)
            _scan_cb(ble, *report);
        _scan_queue.tail = (_scan_queue.tail + 1) % _scan_queue.buf.length;
        _scan_queue.count--;
    }

    // connection events
    if (_evt_connected)
    {
        _evt_connected = false;
        if (_conn_cb !is null)
            _conn_cb(ble, BLEConn(_evt_conn_id), true, BLEError.none);
    }
    if (_evt_connect_failed)
    {
        _evt_connect_failed = false;
        if (_conn_cb !is null)
            _conn_cb(ble, BLEConn(_evt_conn_id), false, BLEError.timeout);
    }
    if (_evt_disconnected)
    {
        _evt_disconnected = false;
        if (_conn_cb !is null)
            _conn_cb(ble, BLEConn(_evt_disconn_id), false, BLEError.none);
        remove_session(_evt_disconn_id);
    }

    // discovery complete
    if (_evt_discover_done)
    {
        _evt_discover_done = false;
        if (_discover_cb !is null)
        {
            auto s = find_session(_evt_discover_conn);
            if (s !is null)
            {
                BLEGattChar[max_chars_per_session] chars = void;
                foreach (i; 0 .. s.num_chars)
                {
                    chars[i].handle = s.chars[i].handle;
                    chars[i].cccd_handle = s.chars[i].cccd_handle;
                    chars[i].service_uuid = s.chars[i].service_uuid;
                    chars[i].char_uuid = s.chars[i].char_uuid;
                    chars[i].properties = cast(GattCharProps)s.chars[i].properties;
                }
                _discover_cb(ble, BLEConn(_evt_discover_conn), chars[0 .. s.num_chars], BLEError.none);
            }
        }
    }
    if (_evt_discover_failed)
    {
        _evt_discover_failed = false;
        if (_discover_cb !is null)
            _discover_cb(ble, BLEConn(_evt_discover_conn), null, BLEError.protocol);
    }

    // GATT read/write completions
    while (_gatt_queue.count > 0)
    {
        auto evt = &_gatt_queue.buf[_gatt_queue.tail];
        if (evt.is_read && _read_cb !is null)
            _read_cb(ble, BLEConn(evt.conn_id), evt.handle, evt.data[0 .. evt.data_len], evt.error);
        else if (!evt.is_read && _write_cb !is null)
            _write_cb(ble, BLEConn(evt.conn_id), evt.handle, evt.error);
        _gatt_queue.tail = (_gatt_queue.tail + 1) % _gatt_queue.buf.length;
        _gatt_queue.count--;
    }

    // notifications
    while (_notify_queue.count > 0)
    {
        auto evt = &_notify_queue.buf[_notify_queue.tail];
        if (_notify_cb !is null)
            _notify_cb(ble, BLEConn(evt.conn_id), evt.handle, evt.data[0 .. evt.data_len]);
        _notify_queue.tail = (_notify_queue.tail + 1) % _notify_queue.buf.length;
        _notify_queue.count--;
    }
}


private:

enum int ESP_OK = 0;
enum max_sessions = 4;
enum max_chars_per_session = 32;

// --- Session table ---

struct SessionCharInfo
{
    ushort handle;
    ushort cccd_handle;
    GUID service_uuid;
    GUID char_uuid;
    ushort properties;
}

struct Session
{
    bool active;
    ubyte id;            // our BLEConn.id
    ushort nimble_handle; // NimBLE connection handle
    SessionCharInfo[max_chars_per_session] chars;
    ubyte num_chars;
}

Session* find_session(ubyte id)
{
    foreach (ref s; _sessions[0 .. _num_sessions])
    {
        if (s.active && s.id == id)
            return &s;
    }
    return null;
}

Session* find_session_by_nimble(ushort nimble_handle)
{
    foreach (ref s; _sessions[0 .. _num_sessions])
    {
        if (s.active && s.nimble_handle == nimble_handle)
            return &s;
    }
    return null;
}

Session* alloc_session(ushort nimble_handle)
{
    if (_num_sessions >= max_sessions)
        return null;
    auto s = &_sessions[_num_sessions++];
    s.active = true;
    s.id = _next_conn_id++;
    s.nimble_handle = nimble_handle;
    s.num_chars = 0;
    return s;
}

void remove_session(ubyte id)
{
    foreach (i, ref s; _sessions[0 .. _num_sessions])
    {
        if (s.id == id)
        {
            _sessions[i] = _sessions[_num_sessions - 1];
            _num_sessions--;
            return;
        }
    }
}

// --- Event ring buffers ---

struct RingBuffer(T, uint N)
{
    T[N] buf;
    uint head;
    uint tail;
    uint count;

    T* push() nothrow @nogc
    {
        if (count >= N)
            return null; // drop oldest would be: tail = (tail + 1) % N; count--;
        auto p = &buf[head];
        head = (head + 1) % N;
        count++;
        return p;
    }
}

struct GattCompletionEvent
{
    ubyte conn_id;
    ushort handle;
    bool is_read;
    BLEError error;
    ubyte data_len;
    ubyte[247] data;
}

struct NotifyEvent
{
    ubyte conn_id;
    ushort handle;
    ubyte data_len;
    ubyte[247] data;
}

// --- Module state ---

__gshared bool _opened;
__gshared bool _pending_connect;
__gshared ubyte _next_conn_id;

__gshared Session[max_sessions] _sessions;
__gshared ubyte _num_sessions;

__gshared BLEScanCallback _scan_cb;
__gshared BLEConnCallback _conn_cb;
__gshared BLEDiscoverCallback _discover_cb;
__gshared BLEReadCallback _read_cb;
__gshared BLEWriteCallback _write_cb;
__gshared BLENotifyCallback _notify_cb;

// scan result ring buffer (set from NimBLE task, drained from main loop)
__gshared RingBuffer!(BLEAdvReport, 16) _scan_queue;

// GATT completion ring buffer
__gshared RingBuffer!(GattCompletionEvent, 16) _gatt_queue;

// notification ring buffer
__gshared RingBuffer!(NotifyEvent, 16) _notify_queue;

// connection event flags (set from NimBLE task)
__gshared bool _evt_connected;
__gshared bool _evt_connect_failed;
__gshared bool _evt_disconnected;
__gshared ubyte _evt_conn_id;
__gshared ubyte _evt_disconn_id;

// discovery state
enum DiscoverPhase : ubyte { idle, services, chars }
__gshared DiscoverPhase _discover_phase;
__gshared ubyte _discovering_conn;
__gshared bool _evt_discover_done;
__gshared bool _evt_discover_failed;
__gshared ubyte _evt_discover_conn;

// service discovery iteration state (used from NimBLE task callbacks)
__gshared ble_gatt_svc[16] _discovered_svcs;
__gshared ubyte _num_discovered_svcs;
__gshared ubyte _current_svc_idx;
__gshared GUID _current_svc_uuid;


// --- GAP event trampoline (called from NimBLE host task) ---

extern(C) int gap_event_trampoline(ble_gap_event* event, void*) nothrow @nogc
{
    if (event is null)
        return 0;

    switch (event.type)
    {
        case BLE_GAP_EVENT_DISC:
            // scan result
            auto report = _scan_queue.push();
            if (report !is null)
            {
                auto disc = &event.disc;
                // NimBLE addr is LSB-first, we want MSB-first
                foreach (i; 0 .. 6)
                    report.addr[i] = disc.addr.val[5 - i];
                report.addr_type = cast(BLEAddrType)disc.addr.type;
                report.rssi = disc.rssi;
                report.tx_power = -128; // not in base event

                ubyte len = disc.length_data > 62 ? 62 : disc.length_data;
                report.data_len = len;
                if (len > 0)
                    report.data_buf[0 .. len] = disc.data[0 .. len];

                report.adv_type = disc.event_type == 0 ? BLEAdvType.connectable : BLEAdvType.nonconnectable;
            }
            return 0;

        case BLE_GAP_EVENT_CONNECT:
            _pending_connect = false;
            if (event.connect.status == 0)
            {
                auto s = alloc_session(event.connect.conn_handle);
                if (s !is null)
                {
                    _evt_conn_id = s.id;
                    _evt_connected = true;
                }
            }
            else
            {
                _evt_conn_id = ubyte.max;
                _evt_connect_failed = true;
            }
            return 0;

        case BLE_GAP_EVENT_DISCONNECT:
            auto s = find_session_by_nimble(event.disconnect.conn.conn_handle);
            if (s !is null)
            {
                _evt_disconn_id = s.id;
                _evt_disconnected = true;
                s.active = false;
            }
            return 0;

        case BLE_GAP_EVENT_NOTIFY_RX:
            auto s = find_session_by_nimble(event.notify_rx.conn_handle);
            if (s !is null)
            {
                auto evt = _notify_queue.push();
                if (evt !is null)
                {
                    evt.conn_id = s.id;
                    evt.handle = event.notify_rx.attr_handle;
                    auto om = event.notify_rx.om;
                    // copy mbuf chain to flat buffer
                    evt.data_len = 0;
                    while (om !is null && evt.data_len < evt.data.length)
                    {
                        ushort copy = om.om_len;
                        if (evt.data_len + copy > evt.data.length)
                            copy = cast(ushort)(evt.data.length - evt.data_len);
                        evt.data[evt.data_len .. evt.data_len + copy] = om.om_data[0 .. copy];
                        evt.data_len += copy;
                        om = om.om_next;
                    }
                }
            }
            return 0;

        default:
            return 0;
    }
}

// --- GATT service discovery callback (NimBLE task) ---

extern(C) int svc_discover_cb(ushort conn_handle, const(ble_gatt_error)* error,
    const(ble_gatt_svc)* service, void*) nothrow @nogc
{
    if (error !is null && error.status == 0 && service !is null)
    {
        // accumulate services
        if (_num_discovered_svcs < _discovered_svcs.length)
            _discovered_svcs[_num_discovered_svcs++] = *service;
        return 0;
    }

    // discovery complete (error.status != 0 means end of list or actual error)
    if (_num_discovered_svcs == 0)
    {
        _evt_discover_conn = _discovering_conn;
        _evt_discover_done = true;
        _discover_phase = DiscoverPhase.idle;
        return 0;
    }

    // start characteristic discovery for first service
    _current_svc_idx = 0;
    return discover_next_svc_chars(conn_handle);
}

int discover_next_svc_chars(ushort conn_handle) nothrow @nogc
{
    while (_current_svc_idx < _num_discovered_svcs)
    {
        auto svc = &_discovered_svcs[_current_svc_idx];
        _current_svc_uuid = nimble_uuid_to_guid(&svc.uuid);
        _discover_phase = DiscoverPhase.chars;

        if (ble_gattc_disc_all_chrs(conn_handle, svc.start_handle, svc.end_handle,
            &chr_discover_cb, null) == 0)
            return 0;

        _current_svc_idx++;
    }

    // all services done
    _evt_discover_conn = _discovering_conn;
    _evt_discover_done = true;
    _discover_phase = DiscoverPhase.idle;
    _num_discovered_svcs = 0;
    return 0;
}

// --- GATT characteristic discovery callback (NimBLE task) ---

extern(C) int chr_discover_cb(ushort conn_handle, const(ble_gatt_error)* error,
    const(ble_gatt_chr)* chr, void*) nothrow @nogc
{
    if (error !is null && error.status == 0 && chr !is null)
    {
        auto s = find_session_by_nimble(conn_handle);
        if (s !is null && s.num_chars < max_chars_per_session)
        {
            auto ci = &s.chars[s.num_chars++];
            ci.handle = chr.val_handle;
            ci.cccd_handle = 0; // TODO: discover descriptors for CCCD
            ci.service_uuid = _current_svc_uuid;
            ci.char_uuid = nimble_uuid_to_guid(&chr.uuid);
            ci.properties = chr.properties;
        }
        return 0;
    }

    // this service's chars done, move to next
    _current_svc_idx++;
    return discover_next_svc_chars(conn_handle);
}

// --- GATT read callback (NimBLE task) ---

extern(C) int gatt_read_cb(ushort conn_handle, const(ble_gatt_error)* error,
    ble_gatt_attr* attr, void* cb_arg) nothrow @nogc
{
    ubyte conn_id = cast(ubyte)cast(size_t)cb_arg;
    auto evt = _gatt_queue.push();
    if (evt is null)
        return 0;

    evt.conn_id = conn_id;
    evt.is_read = true;

    if (error !is null && error.status == 0 && attr !is null)
    {
        evt.handle = attr.handle;
        evt.error = BLEError.none;
        // copy mbuf to flat buffer
        evt.data_len = 0;
        auto om = attr.om;
        while (om !is null && evt.data_len < evt.data.length)
        {
            ushort copy = om.om_len;
            if (evt.data_len + copy > evt.data.length)
                copy = cast(ushort)(evt.data.length - evt.data_len);
            evt.data[evt.data_len .. evt.data_len + copy] = om.om_data[0 .. copy];
            evt.data_len += copy;
            om = om.om_next;
        }
    }
    else
    {
        evt.handle = attr !is null ? attr.handle : 0;
        evt.error = BLEError.protocol;
        evt.data_len = 0;
    }
    return 0;
}

// --- GATT write callback (NimBLE task) ---

extern(C) int gatt_write_cb(ushort conn_handle, const(ble_gatt_error)* error,
    ble_gatt_attr* attr, void* cb_arg) nothrow @nogc
{
    ubyte conn_id = cast(ubyte)cast(size_t)cb_arg;
    auto evt = _gatt_queue.push();
    if (evt is null)
        return 0;

    evt.conn_id = conn_id;
    evt.handle = attr !is null ? attr.handle : 0;
    evt.is_read = false;
    evt.data_len = 0;
    evt.error = (error !is null && error.status == 0) ? BLEError.none : BLEError.protocol;
    return 0;
}

// --- UUID conversion ---

GUID nimble_uuid_to_guid(const(ble_uuid_any)* uuid) nothrow @nogc
{
    GUID g;
    if (uuid.u.type == 16) // BLE_UUID_TYPE_16
    {
        // BT SIG base: 0000xxxx-0000-1000-8000-00805F9B34FB
        g.data1 = uuid.u16.value;
        g.data3 = 0x1000;
        g.data4 = [0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB];
    }
    else if (uuid.u.type == 32) // BLE_UUID_TYPE_32
    {
        g.data1 = uuid.u32.value;
        g.data3 = 0x1000;
        g.data4 = [0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB];
    }
    else if (uuid.u.type == 128) // BLE_UUID_TYPE_128
    {
        // NimBLE stores 128-bit UUIDs in little-endian byte order
        auto v = uuid.u128.value;
        g.data1 = v[12] | (cast(uint)v[13] << 8) | (cast(uint)v[14] << 16) | (cast(uint)v[15] << 24);
        g.data2 = cast(ushort)(v[10] | (cast(ushort)v[11] << 8));
        g.data3 = cast(ushort)(v[8] | (cast(ushort)v[9] << 8));
        g.data4[0 .. 2] = v[6 .. 8]; // big-endian in GUID
        g.data4[2 .. 8] = v[0 .. 6];
    }
    return g;
}


// ====================================================================
// NimBLE C API declarations
// ====================================================================

struct ble_addr_t
{
    ubyte type;
    ubyte[6] val;
}

struct ble_gap_disc_params
{
    ushort itvl;
    ushort window;
    ubyte filter_policy;
    ubyte flags;  // bit 0: limited, bit 1: passive, bit 2: filter_duplicates, bit 3: disable_observer_mode
}

struct ble_gap_conn_params
{
    ushort scan_itvl;
    ushort scan_window;
    ushort itvl_min;
    ushort itvl_max;
    ushort latency;
    ushort supervision_timeout;
    ushort min_ce_len;
    ushort max_ce_len;
}

struct ble_gap_adv_params
{
    ubyte conn_mode;
    ubyte disc_mode;
    ushort itvl_min;
    ushort itvl_max;
    ubyte channel_map;
    ubyte filter_policy;
    ubyte high_duty_cycle;
}

// NimBLE GAP event structure (simplified)
struct ble_gap_event
{
    ubyte type;
    ubyte[3] _pad;

    struct ConnectData { int status; ushort conn_handle; }
    struct DisconnectData { int reason; ble_gap_conn_desc conn; }
    struct DiscData { ubyte event_type; ubyte length_data; ble_addr_t addr; byte rssi;
                      const(ubyte)* data; ble_addr_t direct_addr; }
    struct NotifyRxData { os_mbuf* om; ushort attr_handle; ushort conn_handle;
                          ubyte indication; }

    union
    {
        ConnectData connect;
        DisconnectData disconnect;
        DiscData disc;
        NotifyRxData notify_rx;
    }
}

struct ble_gap_conn_desc
{
    uint sec_state;
    ble_addr_t our_id_addr;
    ble_addr_t peer_id_addr;
    ble_addr_t our_ota_addr;
    ble_addr_t peer_ota_addr;
    ushort conn_handle;
    ushort conn_itvl;
    ushort conn_latency;
    ushort supervision_timeout;
    ubyte role;
    ubyte master_clock_accuracy;
}

struct ble_gatt_error
{
    ushort status;
    ushort att_handle;
}

struct ble_uuid
{
    ubyte type; // 16, 32, or 128
}

struct ble_uuid16
{
    ble_uuid u;
    ushort value;
}

struct ble_uuid32
{
    ble_uuid u;
    uint value;
}

struct ble_uuid128
{
    ble_uuid u;
    ubyte[16] value;
}

union ble_uuid_any
{
    ble_uuid u;
    ble_uuid16 u16;
    ble_uuid32 u32;
    ble_uuid128 u128;
}

struct ble_gatt_svc
{
    ushort start_handle;
    ushort end_handle;
    ble_uuid_any uuid;
}

struct ble_gatt_chr
{
    ushort def_handle;
    ushort val_handle;
    ubyte properties;
    ble_uuid_any uuid;
}

struct ble_gatt_attr
{
    ushort handle;
    ushort offset;
    os_mbuf* om;
}

// NimBLE mbuf
struct os_mbuf
{
    ubyte* om_data;
    ubyte om_flags;
    ubyte om_pkthdr_len;
    ushort om_len;
    void* om_omp;       // os_mbuf_pool* (opaque)
    os_mbuf* om_next;   // SLIST_ENTRY(os_mbuf) — single ptr in practice
}

// GAP event types
enum : ubyte
{
    BLE_GAP_EVENT_CONNECT       = 0,
    BLE_GAP_EVENT_DISCONNECT    = 1,
    BLE_GAP_EVENT_DISC          = 7,
    BLE_GAP_EVENT_NOTIFY_RX     = 12,
}

// C shim functions
extern(C) nothrow @nogc
{
    int ow_ble_init();
    void ow_ble_deinit();
    void ow_ble_set_gap_callback(int function(ble_gap_event*, void*) nothrow @nogc cb);
}

// Direct NimBLE calls
extern(C) nothrow @nogc
{
    int ble_gap_disc(ubyte own_addr_type, int duration_ms, const(ble_gap_disc_params)* params,
        int function(ble_gap_event*, void*) cb, void* cb_arg);
    int ble_gap_disc_cancel();
    int ble_gap_connect(ubyte own_addr_type, const(ble_addr_t)* peer_addr, int duration_ms,
        const(ble_gap_conn_params)* params, int function(ble_gap_event*, void*) cb, void* cb_arg);
    int ble_gap_conn_cancel();
    int ble_gap_terminate(ushort conn_handle, ubyte hci_reason);
    int ble_gap_conn_rssi(ushort conn_handle, byte* rssi);

    int ble_gap_adv_set_data(const(ubyte)* data, int data_len);
    int ble_gap_adv_rsp_set_data(const(ubyte)* data, int data_len);
    int ble_gap_adv_start(ubyte own_addr_type, const(ble_addr_t)* direct_addr, int duration_ms,
        const(ble_gap_adv_params)* params, int function(ble_gap_event*, void*) cb, void* cb_arg);
    int ble_gap_adv_stop();

    int ble_gattc_disc_all_svcs(ushort conn_handle,
        int function(ushort, const(ble_gatt_error)*, const(ble_gatt_svc)*, void*) cb, void* cb_arg);
    int ble_gattc_disc_all_chrs(ushort conn_handle, ushort start_handle, ushort end_handle,
        int function(ushort, const(ble_gatt_error)*, const(ble_gatt_chr)*, void*) cb, void* cb_arg);
    int ble_gattc_read(ushort conn_handle, ushort attr_handle,
        int function(ushort, const(ble_gatt_error)*, ble_gatt_attr*, void*) cb, void* cb_arg);
    int ble_gattc_write_flat(ushort conn_handle, ushort attr_handle, const(void)* data, ushort data_len,
        int function(ushort, const(ble_gatt_error)*, ble_gatt_attr*, void*) cb, void* cb_arg);
    int ble_gattc_write_no_rsp_flat(ushort conn_handle, ushort attr_handle, const(void)* data, ushort data_len);

    int ble_hs_id_infer_auto(int privacy, ubyte* out_addr_type);
    int ble_hs_id_copy_addr(ubyte addr_type, ubyte* out_addr, int* out_is_nrpa);
}
