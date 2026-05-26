// Windows BLE driver -- WinRT Bluetooth LE APIs
//
// Uses Windows.Devices.Bluetooth.* WinRT classes via COM vtable calls.
// All WinRT async operations are polled from ble_hw_poll(). WinRT
// callbacks (advertisements, notifications, connection status) fire on
// thread pool threads and are buffered into thread-safe queues,
// then delivered from ble_hw_poll() on the main loop.
//
// Windows has one BLE radio (port 0). Multiple radios are not
// distinguished by WinRT -- it uses the system default adapter.
module urt.driver.windows.ble;

version (Windows):

import urt.atomic : atomicFetchAdd, atomicFetchSub, atomicLoad, atomicStore;
import urt.log;
import urt.mem.allocator : defaultAllocator;
import urt.sync.mpmc : ThreadSafeQueue;
import urt.uuid : GUID;

import urt.driver.ble;

nothrow @nogc:

alias log = Log!"ble";

enum uint num_ble = 1;


// ════════════════════════════════════════════════════════════════════
// Driver API implementation
// ════════════════════════════════════════════════════════════════════

bool ble_hw_open(uint port, ref const BLEConfig cfg)
{
    if (_opened)
        return true;

    if (!g_winrt.initialized && !g_winrt.init())
    {
        log.error("WinRT initialization failed");
        return false;
    }

    _opened = true;
    return true;
}

void ble_hw_close(uint port)
{
    if (!_opened)
        return;

    ble_hw_scan_stop(port);
    stop_all_publishers();

    // disconnect all sessions
    foreach (ref s; _sessions[0 .. _num_sessions])
    {
        if (s.active)
            release_session(&s);
    }
    _num_sessions = 0;

    cleanup_connect();

    _opened = false;
    _scan_cb = null;
    _conn_cb = null;
    _discover_cb = null;
    _read_cb = null;
    _write_cb = null;
    _notify_cb = null;
}

// --- Scanning ---

bool ble_hw_scan_start(uint port, ref const BLEScanConfig cfg)
{
    if (_watcher !is null)
        return true; // already scanning

    _watcher = g_winrt.activate!IBluetoothLEAdvertisementWatcher(
        "Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher"w,
        &IID_IBluetoothLEAdvertisementWatcher);

    if (_watcher is null)
    {
        log.error("failed to create advertisement watcher");
        return false;
    }

    _watcher.put_ScanningMode(cfg.active ? BluetoothLEScanningMode.active : BluetoothLEScanningMode.passive);

    _adv_handler = defaultAllocator().allocT!AdvertisementReceivedHandler;
    _adv_handler.callback = &on_advertisement_received;

    EventRegistrationToken token;
    if (_watcher.add_Received(cast(IUnknown)_adv_handler, &token) < 0)
    {
        log.error("failed to subscribe to advertisements");
        return false;
    }
    _received_token = token;

    // register Stopped handler to detect unexpected watcher shutdown
    atomicStore(_watcher_stopped, 0u);
    _stopped_handler = defaultAllocator().allocT!WatcherStoppedHandler;
    _stopped_handler.flag = &_watcher_stopped;
    EventRegistrationToken stopped_token;
    _watcher.add_Stopped(cast(IUnknown)_stopped_handler, &stopped_token);
    _stopped_token = stopped_token;

    if (_watcher.Start() < 0)
    {
        log.error("failed to start scanner");
        return false;
    }

    return true;
}

void ble_hw_scan_stop(uint port)
{
    if (_watcher !is null)
    {
        _watcher.Stop();
        _watcher.remove_Received(_received_token);
        _watcher.remove_Stopped(_stopped_token);
        _watcher.Release();
        _watcher = null;
    }
    if (_adv_handler !is null)
    {
        defaultAllocator().freeT(_adv_handler);
        _adv_handler = null;
    }
    if (_stopped_handler !is null)
    {
        defaultAllocator().freeT(_stopped_handler);
        _stopped_handler = null;
    }
    atomicStore(_watcher_stopped, 0u);
}

// --- Advertising ---

BLEAdv ble_hw_adv_start(uint port, ref const BLEAdvConfig cfg)
{
    if (_num_publishers >= max_publishers)
        return BLEAdv.init;

    auto publisher = g_winrt.activate!IBluetoothLEAdvertisementPublisher(
        "Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementPublisher"w,
        &IID_IBluetoothLEAdvertisementPublisher);

    if (publisher is null)
    {
        log.error("failed to create advertisement publisher");
        return BLEAdv.init;
    }

    IBluetoothLEAdvertisement adv;
    publisher.get_Advertisement(&adv);

    if (adv !is null)
    {
        set_adv_data_from_raw(adv, cfg.adv_data);
        adv.Release();
    }

    if (publisher.Start() < 0)
    {
        log.error("failed to start advertising");
        publisher.Release();
        return BLEAdv.init;
    }

    ubyte id = _next_adv_id++;
    _publishers[_num_publishers++] = AdvSlot(id, publisher);
    return BLEAdv(id);
}

void ble_hw_adv_stop(uint port, BLEAdv adv)
{
    foreach (i, ref slot; _publishers[0 .. _num_publishers])
    {
        if (slot.id == adv.id)
        {
            slot.publisher.Stop();
            slot.publisher.Release();
            _publishers[i] = _publishers[_num_publishers - 1];
            _num_publishers--;
            return;
        }
    }
}

// --- Connection ---

bool ble_hw_connect(uint port, ref const ubyte[6] peer_addr, BLEAddrType addr_type, ref const BLEConnConfig cfg)
{
    if (_pending_connect.async_op !is null)
    {
        log.warning("connection already in progress");
        return false;
    }

    if (_device_statics is null)
    {
        _device_statics = g_winrt.get_factory!IBluetoothLEDeviceStatics(
            "Windows.Devices.Bluetooth.BluetoothLEDevice"w,
            &IID_IBluetoothLEDeviceStatics);

        if (_device_statics is null)
        {
            log.error("failed to get BluetoothLEDevice statics");
            return false;
        }
    }

    ulong ble_addr = mac_to_ble_addr(peer_addr);

    IInspectable async_op;
    if (_device_statics.FromBluetoothAddressAsync(ble_addr, &async_op) < 0 || async_op is null)
    {
        log.error("FromBluetoothAddressAsync failed");
        return false;
    }

    _pending_connect.async_op = async_op;
    _pending_connect.peer_addr = peer_addr;
    return true;
}

void ble_hw_connect_cancel(uint port)
{
    cleanup_connect();
}

bool ble_hw_disconnect(uint port, BLEConn conn)
{
    auto s = find_session(conn.id);
    if (s is null)
        return false;

    release_session(s);
    remove_session(conn.id);
    return true;
}

// --- GATT discovery ---

bool ble_hw_gatt_discover(uint port, BLEConn conn)
{
    auto s = find_session(conn.id);
    if (s is null || s.device3 is null)
        return false;

    IInspectable gatt_op;
    s.device3.GetGattServicesWithCacheModeAsync(1, &gatt_op); // 1 = Uncached
    if (gatt_op is null)
        return false;

    _pending_discover.async_op = gatt_op;
    _pending_discover.conn_id = conn.id;
    _pending_discover.phase = DiscoverPhase.services;
    s.num_chars = 0;

    return true;
}

// --- GATT read/write ---

bool ble_hw_gatt_read(uint port, BLEConn conn, ushort handle)
{
    if (_num_pending_gatt >= max_gatt_ops)
        return false;

    auto s = find_session(conn.id);
    if (s is null)
        return false;

    auto gc = find_session_char(s, handle);
    if (gc is null || gc.characteristic is null)
        return false;

    IInspectable async_op;
    gc.characteristic.ReadValueWithCacheModeAsync(1, &async_op); // Uncached
    if (async_op is null)
        return false;

    _pending_gatt[_num_pending_gatt++] = PendingGattOp(
        async_op, conn.id, handle, GattOpType.read);
    return true;
}

bool ble_hw_gatt_write(uint port, BLEConn conn, ushort handle, const(ubyte)[] data, bool with_response)
{
    if (_num_pending_gatt >= max_gatt_ops)
        return false;

    auto s = find_session(conn.id);
    if (s is null)
        return false;

    auto gc = find_session_char(s, handle);
    if (gc is null || gc.characteristic is null)
        return false;

    auto buf = defaultAllocator().allocT!MemoryBuffer;
    if (buf is null)
        return false;

    // clone data -- packet payload may be freed before async completes
    ubyte* data_copy = cast(ubyte*)defaultAllocator().alloc(data.length).ptr;
    if (data_copy is null && data.length > 0)
    {
        defaultAllocator().freeT(buf);
        return false;
    }
    data_copy[0 .. data.length] = data[];
    buf.set(data_copy[0 .. data.length]);

    IInspectable async_op;
    if (with_response)
        gc.characteristic.WriteValueAsync(cast(IBuffer)buf, &async_op);
    else
        gc.characteristic.WriteValueWithOptionAsync(cast(IBuffer)buf, 1, &async_op); // WriteWithoutResponse

    if (async_op is null)
    {
        buf.Release(); // frees both MemoryBuffer and data_copy
        return false;
    }

    _pending_gatt[_num_pending_gatt++] = PendingGattOp(
        async_op, conn.id, handle,
        with_response ? GattOpType.write : GattOpType.write_no_response);
    return true;
}

// --- Notifications ---

bool ble_hw_gatt_subscribe(uint port, BLEConn conn, ushort handle, bool enable)
{
    auto s = find_session(conn.id);
    if (s is null)
        return false;

    auto gc = find_session_char(s, handle);
    if (gc is null || gc.characteristic is null)
        return false;

    if (enable)
    {
        if (gc.notify_handler !is null)
            return true; // already subscribed

        auto handler = defaultAllocator().allocT!GattValueChangedHandler;
        handler.conn_id = conn.id;
        handler.attr_handle = handle;
        handler.callback = &on_gatt_notification;

        EventRegistrationToken token;
        if (gc.characteristic.add_ValueChanged(cast(IUnknown)handler, &token) < 0)
        {
            defaultAllocator().freeT(handler);
            return false;
        }
        gc.notify_handler = handler;
        gc.notify_token = token;

        // write CCCD
        GattCharacteristicProperties props;
        gc.characteristic.get_CharacteristicProperties(&props);

        auto cccd_value = (props & GattCharacteristicProperties.notify) != 0
            ? GattClientCharacteristicConfigurationDescriptorValue.notify
            : GattClientCharacteristicConfigurationDescriptorValue.indicate;

        IInspectable async_op;
        gc.characteristic.WriteClientCharacteristicConfigurationDescriptorAsync(cccd_value, &async_op);
        if (async_op !is null)
            (cast(IUnknown)async_op).Release(); // fire and forget
    }
    else
    {
        if (gc.notify_handler is null)
            return true; // not subscribed

        gc.characteristic.remove_ValueChanged(gc.notify_token);
        defaultAllocator().freeT(gc.notify_handler);
        gc.notify_handler = null;

        // write CCCD to disable
        IInspectable async_op;
        gc.characteristic.WriteClientCharacteristicConfigurationDescriptorAsync(
            GattClientCharacteristicConfigurationDescriptorValue.none, &async_op);
        if (async_op !is null)
            (cast(IUnknown)async_op).Release(); // fire and forget
    }

    return true;
}

// --- Queries ---

bool ble_hw_get_mac(uint port, ref ubyte[6] mac)
{
    // WinRT doesn't easily expose the local adapter MAC.
    // Return a placeholder; the interface layer can override.
    mac = [0, 0, 0, 0, 0, 0];
    return false;
}

byte ble_hw_get_rssi(uint port, BLEConn conn)
{
    // WinRT doesn't provide per-connection RSSI queries
    return -128;
}

// --- Callbacks ---

void ble_hw_set_scan_callback(uint port, BLEScanCallback cb)       { _scan_cb = cb; }
void ble_hw_set_conn_callback(uint port, BLEConnCallback cb)       { _conn_cb = cb; }
void ble_hw_set_discover_callback(uint port, BLEDiscoverCallback cb) { _discover_cb = cb; }
void ble_hw_set_read_callback(uint port, BLEReadCallback cb)       { _read_cb = cb; }
void ble_hw_set_write_callback(uint port, BLEWriteCallback cb)     { _write_cb = cb; }
void ble_hw_set_notify_callback(uint port, BLENotifyCallback cb)   { _notify_cb = cb; }

// --- Poll ---

void ble_hw_poll(uint port)
{
    auto ble = BLE(0);

    // check if watcher stopped unexpectedly (e.g. radio disabled)
    if (atomicLoad(_watcher_stopped) != 0)
    {
        log.warning("BLE scanner stopped unexpectedly");
        atomicStore(_watcher_stopped, 0u);
    }

    // drain scan results
    BLEAdvReport report = void;
    while (_scan_ring.dequeue(&report))
    {
        if (_scan_cb !is null)
            _scan_cb(ble, report);
    }

    // poll pending connection
    poll_connect(ble);

    // poll GATT discovery
    poll_discover(ble);

    // poll GATT read/write ops
    poll_gatt(ble);

    // drain notification events
    NotifyEvent evt = void;
    while (_notify_ring.dequeue(&evt))
    {
        if (_notify_cb !is null)
            _notify_cb(ble, BLEConn(evt.conn_id), evt.handle, evt.data[0 .. evt.data_len]);
    }

    // drain disconnection events
    ubyte conn_id = void;
    while (_disconn_ring.dequeue(&conn_id))
    {
        auto s = find_session(conn_id);
        if (s !is null)
        {
            if (_conn_cb !is null)
                _conn_cb(ble, BLEConn(conn_id), false, BLEError.none);
            release_session(s);
            remove_session(conn_id);
        }
    }
}


// ════════════════════════════════════════════════════════════════════
// Internal state
// ════════════════════════════════════════════════════════════════════

private:

enum max_sessions = 8;
enum max_chars_per_session = 32;
enum max_gatt_ops = 8;
enum max_publishers = 8;

struct AdvSlot
{
    ubyte id;
    IBluetoothLEAdvertisementPublisher publisher;
}

enum GattOpType : ubyte { read, write, write_no_response }
enum DiscoverPhase : ubyte { idle, services, chars }

struct SessionChar
{
    ushort handle;
    GUID service_uuid;
    GUID char_uuid;
    GattCharacteristicProperties properties;
    IGattCharacteristic characteristic;
    GattValueChangedHandler notify_handler;
    EventRegistrationToken notify_token;
}

struct WinSession
{
    bool active;
    ubyte id;
    IBluetoothLEDevice device;
    IBluetoothLEDevice3 device3;
    ConnectionStatusHandler conn_handler;
    EventRegistrationToken conn_status_token;
    SessionChar[max_chars_per_session] chars;
    ubyte num_chars;
}

struct PendingConnect
{
    IInspectable async_op;
    ubyte[6] peer_addr;
}

struct PendingDiscover
{
    IInspectable async_op;
    IVectorView_IInspectable services;
    uint service_count;
    uint current_service;
    GUID current_service_uuid;
    ubyte conn_id;
    DiscoverPhase phase;
}

struct PendingGattOp
{
    IInspectable async_op;
    ubyte conn_id;
    ushort handle;
    GattOpType op_type;
}

struct NotifyEvent
{
    ubyte conn_id;
    ushort handle;
    ubyte data_len;
    ubyte[247] data;
}

// --- module-level state ---

__gshared bool _opened;
__gshared ubyte _next_conn_id;

// sessions
__gshared WinSession[max_sessions] _sessions;
__gshared ubyte _num_sessions;

// callbacks
__gshared BLEScanCallback _scan_cb;
__gshared BLEConnCallback _conn_cb;
__gshared BLEDiscoverCallback _discover_cb;
__gshared BLEReadCallback _read_cb;
__gshared BLEWriteCallback _write_cb;
__gshared BLENotifyCallback _notify_cb;

// scanner
__gshared IBluetoothLEAdvertisementWatcher _watcher;
__gshared AdvertisementReceivedHandler _adv_handler;
__gshared EventRegistrationToken _received_token;
__gshared WatcherStoppedHandler _stopped_handler;
__gshared EventRegistrationToken _stopped_token;
shared uint _watcher_stopped;

// advertisers
__gshared AdvSlot[max_publishers] _publishers;
__gshared ubyte _num_publishers;
__gshared ubyte _next_adv_id;

// device factory
__gshared IBluetoothLEDeviceStatics _device_statics;

// pending connect
__gshared PendingConnect _pending_connect;

// pending discover
__gshared PendingDiscover _pending_discover;

// pending GATT ops
__gshared PendingGattOp[max_gatt_ops] _pending_gatt;
__gshared ubyte _num_pending_gatt;

// thread-safe event queues (written from WinRT threads, read from main)
__gshared ThreadSafeQueue!(32, BLEAdvReport) _scan_ring;
__gshared ThreadSafeQueue!(32, NotifyEvent) _notify_ring;
__gshared ThreadSafeQueue!(8, ubyte) _disconn_ring;


// ════════════════════════════════════════════════════════════════════
// Session management
// ════════════════════════════════════════════════════════════════════

WinSession* find_session(ubyte id)
{
    foreach (ref s; _sessions[0 .. _num_sessions])
    {
        if (s.active && s.id == id)
            return &s;
    }
    return null;
}

SessionChar* find_session_char(WinSession* s, ushort handle)
{
    foreach (ref c; s.chars[0 .. s.num_chars])
    {
        if (c.handle == handle)
            return &c;
    }
    return null;
}

WinSession* alloc_session()
{
    if (_num_sessions >= max_sessions)
        return null;

    // find an ID not currently in use
    ubyte id = _next_conn_id;
    outer: foreach (_; 0 .. 256)
    {
        foreach (ref s; _sessions[0 .. _num_sessions])
            if (s.id == id)
            {
                id++;
                continue outer;
            }
        break;
    }
    _next_conn_id = cast(ubyte)(id + 1);

    auto s = &_sessions[_num_sessions++];
    s.active = true;
    s.id = id;
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

void release_session(WinSession* s)
{
    if (s.device !is null && s.conn_handler !is null)
    {
        s.device.remove_ConnectionStatusChanged(s.conn_status_token);
        defaultAllocator().freeT(s.conn_handler);
        s.conn_handler = null;
    }

    foreach (ref gc; s.chars[0 .. s.num_chars])
    {
        if (gc.notify_handler !is null)
        {
            gc.characteristic.remove_ValueChanged(gc.notify_token);
            defaultAllocator().freeT(gc.notify_handler);
            gc.notify_handler = null;
        }
        if (gc.characteristic !is null)
        {
            gc.characteristic.Release();
            gc.characteristic = null;
        }
    }

    if (s.device3 !is null)
    {
        s.device3.Release();
        s.device3 = null;
    }
    if (s.device !is null)
    {
        s.device.Release();
        s.device = null;
    }
    s.active = false;
}

void stop_all_publishers()
{
    foreach (ref slot; _publishers[0 .. _num_publishers])
    {
        slot.publisher.Stop();
        slot.publisher.Release();
    }
    _num_publishers = 0;
}

void cleanup_connect()
{
    if (_pending_connect.async_op !is null)
    {
        _pending_connect.async_op.Release();
        _pending_connect.async_op = null;
    }
}


// ════════════════════════════════════════════════════════════════════
// Async polling (main thread)
// ════════════════════════════════════════════════════════════════════

void poll_connect(BLE ble)
{
    if (_pending_connect.async_op is null)
        return;

    auto async_info = qi!IAsyncInfo(_pending_connect.async_op, &IID_IAsyncInfo);
    if (async_info is null)
        return;
    scope(exit) async_info.Release();

    AsyncStatus status;
    async_info.get_Status(&status);

    if (status == AsyncStatus.started)
        return;

    if (status != AsyncStatus.completed)
    {
        cleanup_connect();
        if (_conn_cb !is null)
            _conn_cb(ble, BLEConn(ubyte.max), false, BLEError.not_found);
        return;
    }

    auto async_op = cast(IAsyncOperation_BluetoothLEDevice)cast(void*)_pending_connect.async_op;
    IBluetoothLEDevice device;
    async_op.GetResults(&device);

    auto peer_addr = _pending_connect.peer_addr;
    cleanup_connect();

    if (device is null)
    {
        if (_conn_cb !is null)
            _conn_cb(ble, BLEConn(ubyte.max), false, BLEError.not_found);
        return;
    }

    auto s = alloc_session();
    if (s is null)
    {
        device.Release();
        if (_conn_cb !is null)
            _conn_cb(ble, BLEConn(ubyte.max), false, BLEError.internal);
        return;
    }

    s.device = device;
    s.device3 = qi!IBluetoothLEDevice3(device, &IID_IBluetoothLEDevice3);

    // register connection status handler
    auto handler = defaultAllocator().allocT!ConnectionStatusHandler;
    handler.conn_id = s.id;
    handler.callback = &on_connection_status_changed;
    s.device.add_ConnectionStatusChanged(cast(IUnknown)handler, &s.conn_status_token);
    s.conn_handler = handler;

    log.info("connected to ", peer_addr);

    if (_conn_cb !is null)
        _conn_cb(ble, BLEConn(s.id), true, BLEError.none);
}

void poll_discover(BLE ble)
{
    if (_pending_discover.phase == DiscoverPhase.idle)
        return;
    if (_pending_discover.async_op is null && _pending_discover.services is null)
        return;
    if (_pending_discover.async_op is null)
        return;

    auto async_info = qi!IAsyncInfo(_pending_discover.async_op, &IID_IAsyncInfo);
    if (async_info is null)
        return;
    scope(exit) async_info.Release();

    AsyncStatus status;
    async_info.get_Status(&status);

    if (status == AsyncStatus.started)
        return;

    IInspectable result_raw;
    if (status == AsyncStatus.completed)
    {
        if (_pending_discover.services is null)
        {
            auto async_op = cast(IAsyncOperation_GattDeviceServicesResult)cast(void*)_pending_discover.async_op;
            IGattDeviceServicesResult svc_result;
            async_op.GetResults(&svc_result);
            result_raw = cast(IInspectable)cast(void*)svc_result;
        }
        else
        {
            auto async_op = cast(IAsyncOperation_GattCharacteristicsResult)cast(void*)_pending_discover.async_op;
            IGattCharacteristicsResult chr_result;
            async_op.GetResults(&chr_result);
            result_raw = cast(IInspectable)cast(void*)chr_result;
        }
    }

    // release async op
    _pending_discover.async_op.Release();
    _pending_discover.async_op = null;

    auto conn_id = _pending_discover.conn_id;
    auto s = find_session(conn_id);

    if (_pending_discover.services is null)
    {
        // phase 1: service list
        if (result_raw is null)
        {
            finish_discover(ble, conn_id, BLEError.protocol);
            return;
        }

        auto svc_result = cast(IGattDeviceServicesResult)cast(void*)result_raw;
        GattCommunicationStatus gatt_status;
        svc_result.get_Status(&gatt_status);

        if (gatt_status != GattCommunicationStatus.success)
        {
            result_raw.Release();
            finish_discover(ble, conn_id, BLEError.protocol);
            return;
        }

        IInspectable services_raw;
        svc_result.get_Services(&services_raw);
        result_raw.Release();

        if (services_raw is null)
        {
            finish_discover(ble, conn_id, BLEError.none);
            return;
        }

        auto services = cast(IVectorView_IInspectable)cast(void*)services_raw;
        uint count;
        services.get_Size(&count);

        _pending_discover.services = services;
        _pending_discover.service_count = count;
        _pending_discover.current_service = 0;
        _pending_discover.phase = DiscoverPhase.chars;

        discover_next_service();
    }
    else
    {
        // phase 2: characteristics for a service
        if (result_raw !is null && s !is null)
        {
            auto chars_result = cast(IGattCharacteristicsResult)cast(void*)result_raw;
            GattCommunicationStatus gatt_status;
            chars_result.get_Status(&gatt_status);

            if (gatt_status == GattCommunicationStatus.success)
            {
                IInspectable chars_raw;
                chars_result.get_Characteristics(&chars_raw);
                if (chars_raw !is null)
                {
                    auto chars = cast(IVectorView_IInspectable)cast(void*)chars_raw;
                    uint count;
                    chars.get_Size(&count);

                    foreach (j; 0 .. count)
                    {
                        IInspectable char_raw;
                        chars.GetAt(j, &char_raw);
                        if (char_raw is null)
                            continue;

                        auto chr = cast(IGattCharacteristic)cast(void*)char_raw;
                        if (s.num_chars < max_chars_per_session)
                        {
                            auto ci = &s.chars[s.num_chars++];
                            chr.get_AttributeHandle(&ci.handle);
                            ci.service_uuid = _pending_discover.current_service_uuid;
                            chr.get_Uuid(&ci.char_uuid);
                            chr.get_CharacteristicProperties(&ci.properties);
                            ci.characteristic = chr;
                        }
                        else
                            (cast(IUnknown)chr).Release();
                    }
                    chars_raw.Release();
                }
            }
            result_raw.Release();
        }

        _pending_discover.current_service++;
        if (!discover_next_service())
            finish_discover(ble, conn_id, BLEError.none);
    }
}

bool discover_next_service()
{
    auto services = _pending_discover.services;
    while (_pending_discover.current_service < _pending_discover.service_count)
    {
        IInspectable svc_raw;
        services.GetAt(_pending_discover.current_service, &svc_raw);
        if (svc_raw is null)
        {
            _pending_discover.current_service++;
            continue;
        }

        auto svc = cast(IGattDeviceService)cast(void*)svc_raw;
        svc.get_Uuid(&_pending_discover.current_service_uuid);

        auto svc3 = qi!IGattDeviceService3(svc_raw, &IID_IGattDeviceService3);
        svc_raw.Release();

        if (svc3 is null)
        {
            _pending_discover.current_service++;
            continue;
        }

        IInspectable chars_op;
        svc3.GetCharacteristicsAsync(&chars_op);
        svc3.Release();

        if (chars_op is null)
        {
            _pending_discover.current_service++;
            continue;
        }

        _pending_discover.async_op = chars_op;
        return true;
    }

    // all done
    if (_pending_discover.services !is null)
    {
        (cast(IUnknown)_pending_discover.services).Release();
        _pending_discover.services = null;
    }
    return false;
}

void finish_discover(BLE ble, ubyte conn_id, BLEError error)
{
    if (_pending_discover.services !is null)
    {
        (cast(IUnknown)_pending_discover.services).Release();
        _pending_discover.services = null;
    }
    _pending_discover.phase = DiscoverPhase.idle;

    if (_discover_cb !is null)
    {
        auto s = find_session(conn_id);
        if (s !is null && error == BLEError.none)
        {
            BLEGattChar[max_chars_per_session] chars = void;
            foreach (i; 0 .. s.num_chars)
            {
                chars[i].handle = s.chars[i].handle;
                chars[i].cccd_handle = 0; // WinRT handles CCCD internally
                chars[i].service_uuid = s.chars[i].service_uuid;
                chars[i].char_uuid = s.chars[i].char_uuid;
                chars[i].properties = cast(GattCharProps)s.chars[i].properties;
            }
            _discover_cb(ble, BLEConn(conn_id), chars[0 .. s.num_chars], BLEError.none);
        }
        else
            _discover_cb(ble, BLEConn(conn_id), null, error);
    }
}

void poll_gatt(BLE ble)
{
    uint i = 0;
    while (i < _num_pending_gatt)
    {
        auto pg = &_pending_gatt[i];

        auto async_info = qi!IAsyncInfo(pg.async_op, &IID_IAsyncInfo);
        if (async_info is null)
        {
            i++;
            continue;
        }

        AsyncStatus status;
        async_info.get_Status(&status);
        async_info.Release();

        if (status == AsyncStatus.started)
        {
            i++;
            continue;
        }

        auto conn = BLEConn(pg.conn_id);
        bool success = false;
        const(ubyte)[] data;
        IBuffer value_buf;

        if (status == AsyncStatus.completed)
        {
            if (pg.op_type == GattOpType.read)
            {
                auto async_op = cast(IAsyncOperation_GattReadResult)cast(void*)pg.async_op;
                IGattReadResult read_result;
                async_op.GetResults(&read_result);

                if (read_result !is null)
                {
                    GattCommunicationStatus gatt_status;
                    read_result.get_Status(&gatt_status);
                    if (gatt_status == GattCommunicationStatus.success)
                    {
                        read_result.get_Value(&value_buf);
                        data = get_buffer_bytes(value_buf);
                        success = true;
                    }
                    read_result.Release();
                }
            }
            else
            {
                auto async_op = cast(IAsyncOperation_GattCommunicationStatus)cast(void*)pg.async_op;
                GattCommunicationStatus gatt_status;
                async_op.GetResults(&gatt_status);
                success = gatt_status == GattCommunicationStatus.success;
            }
        }

        // fire callback
        if (pg.op_type == GattOpType.read)
        {
            if (_read_cb !is null)
                _read_cb(ble, conn, pg.handle, data, success ? BLEError.none : BLEError.protocol);
        }
        else
        {
            if (_write_cb !is null)
                _write_cb(ble, conn, pg.handle, success ? BLEError.none : BLEError.protocol);
        }

        if (value_buf !is null)
            value_buf.Release();
        pg.async_op.Release();

        // compact array
        --_num_pending_gatt;
        if (i < _num_pending_gatt)
            _pending_gatt[i] = _pending_gatt[_num_pending_gatt];
        // don't increment i -- swapped element needs checking
    }
}


// ════════════════════════════════════════════════════════════════════
// WinRT thread callbacks (fire on thread pool)
// ════════════════════════════════════════════════════════════════════

void on_advertisement_received(ubyte[6] addr, byte rssi, bool connectable, bool is_scan_response, const(ubyte)[] ad_payload)
{
    BLEAdvReport report = void;
    report.addr = addr;
    report.addr_type = BLEAddrType.public_;
    report.adv_type = connectable ? BLEAdvType.connectable : BLEAdvType.nonconnectable;
    report.rssi = rssi;
    report.tx_power = -128;
    ubyte len = ad_payload.length > 62 ? 62 : cast(ubyte)ad_payload.length;
    report.data_len = len;
    if (len > 0)
        report.data_buf[0 .. len] = cast(const(ubyte)[])ad_payload[0 .. len];
    _scan_ring.enqueue(report);
}

void on_gatt_notification(ubyte conn_id, ushort attr_handle, const(ubyte)[] data)
{
    NotifyEvent evt = void;
    evt.conn_id = conn_id;
    evt.handle = attr_handle;
    ubyte len = data.length > 247 ? 247 : cast(ubyte)data.length;
    evt.data_len = len;
    if (len > 0)
        evt.data[0 .. len] = cast(const(ubyte)[])data[0 .. len];
    _notify_ring.enqueue(evt);
}

void on_connection_status_changed(ubyte conn_id, int status)
{
    if (status == 0) // Disconnected
        _disconn_ring.enqueue(conn_id);
}


// ════════════════════════════════════════════════════════════════════
// Helpers
// ════════════════════════════════════════════════════════════════════

T qi(T)(IUnknown obj, const(GUID)* iid)
{
    if (obj is null)
        return null;
    void* result;
    HRESULT hr = obj.QueryInterface(iid, &result);
    if (hr < 0)
        return null;
    return cast(T)cast(void*)result;
}

ulong mac_to_ble_addr(ref const ubyte[6] mac)
{
    return (cast(ulong)mac[0] << 40) | (cast(ulong)mac[1] << 32) |
           (cast(ulong)mac[2] << 24) | (cast(ulong)mac[3] << 16) |
           (cast(ulong)mac[4] << 8)  | mac[5];
}

void ble_addr_to_mac(ulong addr, ref ubyte[6] mac)
{
    mac[0] = cast(ubyte)(addr >> 40);
    mac[1] = cast(ubyte)(addr >> 32);
    mac[2] = cast(ubyte)(addr >> 24);
    mac[3] = cast(ubyte)(addr >> 16);
    mac[4] = cast(ubyte)(addr >> 8);
    mac[5] = cast(ubyte)(addr);
}

const(ubyte)[] get_buffer_bytes(IBuffer buf)
{
    if (buf is null)
        return null;

    uint len;
    if (buf.get_Length(&len) < 0)
        return null;
    if (len == 0)
        return null;

    auto access = qi!IBufferByteAccess(buf, &IID_IBufferByteAccess);
    if (access is null)
        return null;
    scope(exit) access.Release();

    ubyte* ptr;
    if (access.Buffer(&ptr) < 0 || ptr is null)
        return null;

    return ptr[0 .. len];
}

void set_adv_data_from_raw(IBluetoothLEAdvertisement adv, const(ubyte)[] raw)
{
    uint offset = 0;
    while (offset < raw.length)
    {
        if (offset + 1 >= raw.length)
            break;
        ubyte len = raw[offset++];
        if (len == 0 || offset + len > raw.length)
            break;
        ubyte ad_type = raw[offset];
        const(ubyte)[] ad_data = raw[offset + 1 .. offset + len];
        offset += len;

        // set local name if present
        if (ad_type == 0x09 || ad_type == 0x08) // complete/shortened local name
        {
            wchar[64] wname = void;
            uint wlen = cast(uint)ad_data.length;
            if (wlen > 64) wlen = 64;
            foreach (i; 0 .. wlen)
                wname[i] = ad_data[i];
            HSTRING hname = g_winrt.make_string(wname[0 .. wlen]);
            if (hname !is null)
            {
                adv.put_LocalName(hname);
                g_winrt.WindowsDeleteString(hname);
            }
        }
    }
}


// ════════════════════════════════════════════════════════════════════
// WinRT bootstrap
// ════════════════════════════════════════════════════════════════════

struct WinRT
{
nothrow @nogc:
    bool initialized;

    import urt.internal.sys.windows.windef : HMODULE;
    private HMODULE _lib;

    extern(Windows) HRESULT function(uint initType) RoInitialize;
    extern(Windows) HRESULT function(HSTRING classId, IInspectable* instance) RoActivateInstance;
    extern(Windows) HRESULT function(HSTRING classId, const(GUID)* iid, void** factory) RoGetActivationFactory;
    extern(Windows) HRESULT function(const(wchar)* str, uint len, HSTRING* out_) WindowsCreateString;
    extern(Windows) HRESULT function(HSTRING str) WindowsDeleteString;
    extern(Windows) const(wchar)* function(HSTRING str, uint* len) WindowsGetStringRawBuffer;

    bool init()
    {
        import urt.internal.sys.windows.winbase : LoadLibrary, FreeLibrary, GetProcAddress;

        auto lib = LoadLibrary("combase.dll");
        if (!lib)
        {
            log.error("failed to load combase.dll");
            return false;
        }

        RoInitialize            = cast(typeof(RoInitialize))            GetProcAddress(lib, "RoInitialize");
        RoActivateInstance      = cast(typeof(RoActivateInstance))      GetProcAddress(lib, "RoActivateInstance");
        RoGetActivationFactory  = cast(typeof(RoGetActivationFactory))  GetProcAddress(lib, "RoGetActivationFactory");
        WindowsCreateString     = cast(typeof(WindowsCreateString))     GetProcAddress(lib, "WindowsCreateString");
        WindowsDeleteString     = cast(typeof(WindowsDeleteString))     GetProcAddress(lib, "WindowsDeleteString");
        WindowsGetStringRawBuffer = cast(typeof(WindowsGetStringRawBuffer)) GetProcAddress(lib, "WindowsGetStringRawBuffer");

        if (!RoInitialize || !RoActivateInstance || !RoGetActivationFactory ||
            !WindowsCreateString || !WindowsDeleteString || !WindowsGetStringRawBuffer)
        {
            log.error("failed to resolve WinRT functions from combase.dll");
            FreeLibrary(lib);
            return false;
        }

        HRESULT hr = RoInitialize(1); // RO_INIT_MULTITHREADED
        if (hr < 0 && hr != cast(HRESULT)0x80010106) // RPC_E_CHANGED_MODE is ok
        {
            log.error("RoInitialize failed: ", hr);
            FreeLibrary(lib);
            return false;
        }

        _lib = lib;
        initialized = true;
        log.info("WinRT initialized");
        return true;
    }

    HSTRING make_string(const(wchar)[] s)
    {
        HSTRING h;
        if (WindowsCreateString(s.ptr, cast(uint)s.length, &h) < 0)
            return null;
        return h;
    }

    T activate(T : IInspectable)(const(wchar)[] className, const(GUID)* iid)
    {
        HSTRING cls = make_string(className);
        if (!cls)
            return null;
        scope(exit) WindowsDeleteString(cls);

        IInspectable inspectable;
        if (RoActivateInstance(cls, &inspectable) < 0 || inspectable is null)
            return null;
        scope(exit) inspectable.Release();

        void* result;
        if (inspectable.QueryInterface(iid, &result) < 0)
            return null;
        return cast(T)cast(void*)result;
    }

    T get_factory(T)(const(wchar)[] className, const(GUID)* iid)
    {
        HSTRING cls = make_string(className);
        if (!cls)
            return null;
        scope(exit) WindowsDeleteString(cls);

        void* result;
        if (RoGetActivationFactory(cls, iid, &result) < 0)
            return null;
        return cast(T)cast(void*)result;
    }
}

__gshared WinRT g_winrt;


// ════════════════════════════════════════════════════════════════════
// COM/WinRT types and interfaces
// ════════════════════════════════════════════════════════════════════

alias HRESULT = int;
alias ULONG = uint;
alias BOOL = int;
alias HSTRING = void*;

struct EventRegistrationToken { long value; }

enum AsyncStatus : int { started = 0, completed = 1, canceled = 2, error = 3 }
enum BluetoothLEScanningMode : int { passive = 0, active = 1 }
enum GattCommunicationStatus : int { success = 0, unreachable = 1, protocol_error = 2, access_denied = 3 }

enum GattCharacteristicProperties : uint
{
    none = 0, broadcast = 0x0001, read = 0x0002, write_without_response = 0x0004,
    write = 0x0008, notify = 0x0010, indicate = 0x0020,
    authenticated_signed_writes = 0x0040, extended_properties = 0x0080,
    reliable_write = 0x0100, writable_auxiliaries = 0x0200,
}

enum GattClientCharacteristicConfigurationDescriptorValue : int { none = 0, notify = 1, indicate = 2 }

// GUIDs
static immutable IID_IUnknown                       = GUID(0x00000000, 0x0000, 0x0000, [0xC0,0x00,0x00,0x00,0x00,0x00,0x00,0x46]);
static immutable IID_IInspectable                   = GUID(0xAF86E2E0, 0xB12D, 0x4C6A, [0x9C,0x5A,0xD7,0xAA,0x65,0x10,0x1E,0x90]);
static immutable IID_IAgileObject                   = GUID(0x94EA2B94, 0xE9CC, 0x49E0, [0xC0,0xFF,0xEE,0x64,0xCA,0x8F,0x5B,0x90]);
static immutable IID_IAsyncInfo                     = GUID(0x00000036, 0x0000, 0x0000, [0xC0,0x00,0x00,0x00,0x00,0x00,0x00,0x46]);

static immutable IID_IBluetoothLEAdvertisementWatcher            = GUID(0xA6AC336F, 0xF3D3, 0x4297, [0x8D,0x6C,0xC8,0x1E,0xA6,0x62,0x3F,0x40]);
static immutable IID_IBluetoothLEAdvertisementReceivedEventArgs  = GUID(0x27987DDF, 0xE596, 0x41BE, [0x8D,0x43,0x9E,0x67,0x31,0xD4,0xA9,0x13]);
static immutable IID_IBluetoothLEAdvertisementReceivedEventArgs2 = GUID(0x12D9C87B, 0x0399, 0x5F0E, [0xA3,0x48,0x53,0xB0,0x2B,0x6B,0x16,0x2E]);
static immutable IID_IBluetoothLEAdvertisement                   = GUID(0x066FB2B7, 0x33D1, 0x4E7D, [0x83,0x67,0xCF,0x81,0xD0,0xF7,0x96,0x53]);
static immutable IID_IBluetoothLEDevice                          = GUID(0xB5EE2F7B, 0x4AD8, 0x4642, [0xAC,0x48,0x80,0xA0,0xB5,0x00,0xE8,0x87]);
static immutable IID_IBluetoothLEDeviceStatics                   = GUID(0xC8CF1A19, 0xF0B6, 0x4BF0, [0x86,0x89,0x41,0x30,0x3D,0xE2,0xD9,0xF4]);
static immutable IID_IBluetoothLEDevice3                         = GUID(0xAEE9E493, 0x44AC, 0x40DC, [0xAF,0x33,0xB2,0xC1,0x3C,0x01,0xCA,0x46]);
static immutable IID_IGattDeviceServicesResult                   = GUID(0x171DD3EE, 0x016D, 0x419D, [0x83,0x8A,0x57,0x6C,0xF4,0x75,0xA3,0xD8]);
static immutable IID_IGattDeviceService3                         = GUID(0xB293A950, 0x0C53, 0x437C, [0xA9,0xB3,0x5C,0x32,0x10,0xC6,0xE5,0x69]);
static immutable IID_IGattCharacteristic                         = GUID(0x59CB50C1, 0x5934, 0x4F68, [0xA1,0x98,0xEB,0x86,0x4F,0xA4,0x4E,0x6B]);
static immutable IID_IGattReadResult                             = GUID(0x63A66F08, 0x1AEA, 0x4C4C, [0xA5,0x0F,0x97,0xBA,0xE4,0x74,0xB3,0x48]);
static immutable IID_IBluetoothLEAdvertisementPublisher          = GUID(0xCDE820F9, 0xD9FA, 0x43D6, [0xA2,0x64,0xDD,0xD8,0xB7,0xDA,0x8B,0x78]);
static immutable IID_IBufferByteAccess                           = GUID(0x905A0FEF, 0xBC53, 0x11DF, [0x8C,0x49,0x00,0x1E,0x4F,0xC6,0x86,0xDA]);
static immutable IID_TypedEventHandler_Watcher_Received          = GUID(0x90EB4ECA, 0xD465, 0x5EA0, [0xA6,0x1C,0x03,0x3C,0x8C,0x5E,0xCE,0xF2]);
static immutable IID_TypedEventHandler_Gatt_ValueChanged         = GUID(0xC1F420F6, 0x6292, 0x5760, [0xA2,0xC9,0x9D,0xDF,0x98,0x68,0x3C,0xFC]);
static immutable IID_TypedEventHandler_Device_ConnectionStatus   = GUID(0x24A901AD, 0x910F, 0x5C29, [0xB2,0x36,0x80,0x3C,0xC0,0x30,0x60,0xFE]);
static immutable IID_TypedEventHandler_Watcher_Stopped           = GUID(0x9936A4DB, 0xDC99, 0x55C3, [0x9E,0x9B,0xBF,0x48,0x54,0xBD,0x9F,0x0B]);


// --- COM interfaces ---

extern(Windows):

interface IUnknown
{
nothrow @nogc:
    HRESULT QueryInterface(const(GUID)* riid, void** ppv);
    ULONG AddRef();
    ULONG Release();
}

interface IInspectable : IUnknown
{
nothrow @nogc:
    HRESULT GetIids(uint* count, GUID** iids);
    HRESULT GetRuntimeClassName(HSTRING* name);
    HRESULT GetTrustLevel(int* level);
}

interface IAsyncInfo : IInspectable
{
nothrow @nogc:
    HRESULT get_Id(uint* id);
    HRESULT get_Status(AsyncStatus* status);
    HRESULT get_ErrorCode(HRESULT* code);
    HRESULT Cancel();
    HRESULT Close();
}

interface IAsyncOperation_BluetoothLEDevice : IInspectable
{
nothrow @nogc:
    HRESULT put_Completed(IUnknown handler);
    HRESULT get_Completed(IUnknown* handler);
    HRESULT GetResults(IBluetoothLEDevice* result);
}

interface IAsyncOperation_GattDeviceServicesResult : IInspectable
{
nothrow @nogc:
    HRESULT put_Completed(IUnknown handler);
    HRESULT get_Completed(IUnknown* handler);
    HRESULT GetResults(IGattDeviceServicesResult* result);
}

interface IAsyncOperation_GattCharacteristicsResult : IInspectable
{
nothrow @nogc:
    HRESULT put_Completed(IUnknown handler);
    HRESULT get_Completed(IUnknown* handler);
    HRESULT GetResults(IGattCharacteristicsResult* result);
}

interface IAsyncOperation_GattReadResult : IInspectable
{
nothrow @nogc:
    HRESULT put_Completed(IUnknown handler);
    HRESULT get_Completed(IUnknown* handler);
    HRESULT GetResults(IGattReadResult* result);
}

interface IAsyncOperation_GattCommunicationStatus : IInspectable
{
nothrow @nogc:
    HRESULT put_Completed(IUnknown handler);
    HRESULT get_Completed(IUnknown* handler);
    HRESULT GetResults(GattCommunicationStatus* result);
}

interface IBluetoothLEAdvertisementWatcher : IInspectable
{
nothrow @nogc:
    HRESULT get_MinSamplingInterval(long* value);
    HRESULT get_MaxSamplingInterval(long* value);
    HRESULT get_MinOutOfRangeTimeout(long* value);
    HRESULT get_MaxOutOfRangeTimeout(long* value);
    HRESULT get_Status(int* value);
    HRESULT get_ScanningMode(BluetoothLEScanningMode* value);
    HRESULT put_ScanningMode(BluetoothLEScanningMode value);
    HRESULT get_SignalStrengthFilter(IInspectable* value);
    HRESULT put_SignalStrengthFilter(IInspectable value);
    HRESULT get_AdvertisementFilter(IInspectable* value);
    HRESULT put_AdvertisementFilter(IInspectable value);
    HRESULT Start();
    HRESULT Stop();
    HRESULT add_Received(IUnknown handler, EventRegistrationToken* token);
    HRESULT remove_Received(EventRegistrationToken token);
    HRESULT add_Stopped(IUnknown handler, EventRegistrationToken* token);
    HRESULT remove_Stopped(EventRegistrationToken token);
}

interface IBluetoothLEAdvertisementReceivedEventArgs : IInspectable
{
nothrow @nogc:
    HRESULT get_RawSignalStrengthInDBm(short* value);
    HRESULT get_BluetoothAddress(ulong* value);
    HRESULT get_AdvertisementType(int* value);
    HRESULT get_Timestamp(long* value);
    HRESULT get_Advertisement(IBluetoothLEAdvertisement* value);
}

interface IBluetoothLEAdvertisementReceivedEventArgs2 : IInspectable
{
nothrow @nogc:
    HRESULT get_BluetoothAddressType(int* value);
    HRESULT get_TransmitPowerLevelInDBm(IInspectable* value);
    HRESULT get_IsAnonymous(BOOL* value);
    HRESULT get_IsConnectable(BOOL* value);
    HRESULT get_IsScannable(BOOL* value);
    HRESULT get_IsDirected(BOOL* value);
    HRESULT get_IsScanResponse(BOOL* value);
}

interface IBluetoothLEAdvertisement : IInspectable
{
nothrow @nogc:
    HRESULT get_Flags(IInspectable* value);
    HRESULT put_Flags(IInspectable value);
    HRESULT get_LocalName(HSTRING* value);
    HRESULT put_LocalName(HSTRING value);
    HRESULT get_ServiceUuids(IInspectable* value);
    HRESULT get_ManufacturerData(IInspectable* value);
    HRESULT get_DataSections(IInspectable* value);
    HRESULT GetManufacturerDataByCompanyId(ushort companyId, IInspectable* dataList);
    HRESULT GetSectionsByType(ubyte type_, IInspectable* sectionList);
}

interface IVectorView_IInspectable : IInspectable
{
nothrow @nogc:
    HRESULT GetAt(uint index, IInspectable* item);
    HRESULT get_Size(uint* size);
    HRESULT IndexOf(IInspectable value, uint* index, BOOL* found);
    HRESULT GetMany(uint startIndex, uint capacity, IInspectable* items, uint* actual);
}

interface IBuffer : IInspectable
{
nothrow @nogc:
    HRESULT get_Capacity(uint* value);
    HRESULT get_Length(uint* value);
    HRESULT put_Length(uint value);
}

interface IBufferByteAccess : IUnknown
{
nothrow @nogc:
    HRESULT Buffer(ubyte** value);
}

interface IGattDeviceServicesResult : IInspectable
{
nothrow @nogc:
    HRESULT get_Status(GattCommunicationStatus* value);
    HRESULT get_ProtocolError(IInspectable* value);
    HRESULT get_Services(IInspectable* value);
}

interface IGattDeviceService : IInspectable
{
nothrow @nogc:
    HRESULT GetCharacteristics(GUID characteristicUuid, IInspectable* value);
    HRESULT GetIncludedServices(GUID serviceUuid, IInspectable* value);
    HRESULT get_DeviceId(HSTRING* value);
    HRESULT get_Uuid(GUID* value);
    HRESULT get_AttributeHandle(ushort* value);
}

interface IGattDeviceService3 : IInspectable
{
nothrow @nogc:
    HRESULT get_DeviceAccessInformation(IInspectable* value);
    HRESULT get_Session(IInspectable* value);
    HRESULT get_SharingMode(int* value);
    HRESULT RequestAccessAsync(IInspectable* operation);
    HRESULT OpenAsync(int sharingMode, IInspectable* operation);
    HRESULT GetCharacteristicsAsync(IInspectable* operation);
    HRESULT GetCharacteristicsWithCacheModeAsync(int cacheMode, IInspectable* operation);
    HRESULT GetCharacteristicsForUuidAsync(GUID uuid, IInspectable* operation);
    HRESULT GetCharacteristicsForUuidWithCacheModeAsync(GUID uuid, int cacheMode, IInspectable* operation);
    HRESULT GetIncludedServicesAsync(IInspectable* operation);
    HRESULT GetIncludedServicesWithCacheModeAsync(int cacheMode, IInspectable* operation);
}

interface IGattCharacteristicsResult : IInspectable
{
nothrow @nogc:
    HRESULT get_Status(GattCommunicationStatus* value);
    HRESULT get_ProtocolError(IInspectable* value);
    HRESULT get_Characteristics(IInspectable* value);
}

interface IGattCharacteristic : IInspectable
{
nothrow @nogc:
    HRESULT GetDescriptors(GUID descriptorUuid, IInspectable* value);
    HRESULT get_CharacteristicProperties(GattCharacteristicProperties* value);
    HRESULT get_ProtectionLevel(int* value);
    HRESULT put_ProtectionLevel(int value);
    HRESULT get_UserDescription(HSTRING* value);
    HRESULT get_Uuid(GUID* value);
    HRESULT get_AttributeHandle(ushort* value);
    HRESULT get_PresentationFormats(IInspectable* value);
    HRESULT ReadValueAsync(IInspectable* operation);
    HRESULT ReadValueWithCacheModeAsync(int cacheMode, IInspectable* operation);
    HRESULT WriteValueAsync(IBuffer value, IInspectable* operation);
    HRESULT WriteValueWithOptionAsync(IBuffer value, int writeOption, IInspectable* operation);
    HRESULT ReadClientCharacteristicConfigurationDescriptorAsync(IInspectable* operation);
    HRESULT WriteClientCharacteristicConfigurationDescriptorAsync(GattClientCharacteristicConfigurationDescriptorValue value, IInspectable* operation);
    HRESULT add_ValueChanged(IUnknown handler, EventRegistrationToken* token);
    HRESULT remove_ValueChanged(EventRegistrationToken token);
}

interface IGattReadResult : IInspectable
{
nothrow @nogc:
    HRESULT get_Status(GattCommunicationStatus* value);
    HRESULT get_Value(IBuffer* value);
}

interface IGattValueChangedEventArgs : IInspectable
{
nothrow @nogc:
    HRESULT get_CharacteristicValue(IBuffer* value);
    HRESULT get_Timestamp(long* value);
}

interface IBluetoothLEAdvertisementPublisher : IInspectable
{
nothrow @nogc:
    HRESULT get_Status(int* value);
    HRESULT get_Advertisement(IBluetoothLEAdvertisement* value);
    HRESULT Start();
    HRESULT Stop();
    HRESULT add_StatusChanged(IUnknown handler, EventRegistrationToken* token);
    HRESULT remove_StatusChanged(EventRegistrationToken token);
}

interface IBluetoothLEDeviceStatics : IInspectable
{
nothrow @nogc:
    HRESULT FromIdAsync(HSTRING deviceId, IInspectable* operation);
    HRESULT FromBluetoothAddressAsync(ulong bluetoothAddress, IInspectable* operation);
    HRESULT GetDeviceSelector(HSTRING* selector);
}

interface IBluetoothLEDevice : IInspectable
{
nothrow @nogc:
    HRESULT get_DeviceId(HSTRING* value);
    HRESULT get_Name(HSTRING* value);
    HRESULT get_GattServices(IInspectable* value);
    HRESULT get_ConnectionStatus(int* value);
    HRESULT get_BluetoothAddress(ulong* value);
    HRESULT GetGattService(GUID serviceUuid, IInspectable* service);
    HRESULT add_NameChanged(IUnknown handler, EventRegistrationToken* token);
    HRESULT remove_NameChanged(EventRegistrationToken token);
    HRESULT add_GattServicesChanged(IUnknown handler, EventRegistrationToken* token);
    HRESULT remove_GattServicesChanged(EventRegistrationToken token);
    HRESULT add_ConnectionStatusChanged(IUnknown handler, EventRegistrationToken* token);
    HRESULT remove_ConnectionStatusChanged(EventRegistrationToken token);
}

interface IBluetoothLEDevice3 : IInspectable
{
nothrow @nogc:
    HRESULT get_DeviceAccessInformation(IInspectable* value);
    HRESULT RequestAccessAsync(IInspectable* operation);
    HRESULT GetGattServicesAsync(IInspectable* operation);
    HRESULT GetGattServicesWithCacheModeAsync(int cacheMode, IInspectable* operation);
    HRESULT GetGattServicesForUuidAsync(GUID serviceUuid, IInspectable* operation);
    HRESULT GetGattServicesForUuidWithCacheModeAsync(GUID serviceUuid, int cacheMode, IInspectable* operation);
}

// Handler interfaces
interface IAdvertisementReceivedHandler : IUnknown { nothrow @nogc: HRESULT Invoke(IInspectable sender, IInspectable args); }
interface IGattValueChangedHandler : IUnknown { nothrow @nogc: HRESULT Invoke(IInspectable sender, IInspectable args); }
interface IConnectionStatusHandler : IUnknown { nothrow @nogc: HRESULT Invoke(IInspectable sender, IInspectable args); }
interface IWatcherStoppedHandler : IUnknown { nothrow @nogc: HRESULT Invoke(IInspectable sender, IInspectable args); }


// ════════════════════════════════════════════════════════════════════
// COM implementation classes
// ════════════════════════════════════════════════════════════════════

class ComObject : IInspectable
{
nothrow @nogc:
    protected shared uint _ref_count = 1;

    HRESULT QueryInterface(const(GUID)* riid, void** ppv)
    {
        if (*riid == IID_IUnknown || *riid == IID_IInspectable || *riid == IID_IAgileObject)
        {
            *ppv = cast(void*)cast(IUnknown)this;
            AddRef();
            return 0;
        }
        *ppv = null;
        return 0x80004002; // E_NOINTERFACE
    }

    ULONG AddRef() { return atomicFetchAdd(_ref_count, 1) + 1; }
    ULONG Release()
    {
        auto prev = atomicFetchSub(_ref_count, 1);
        if (prev == 1)
        {
            defaultAllocator().freeT(this);
            return 0;
        }
        return prev - 1;
    }

    HRESULT GetIids(uint* count, GUID** iids) { *count = 0; *iids = null; return 0; }
    HRESULT GetRuntimeClassName(HSTRING* name) { *name = null; return 0; }
    HRESULT GetTrustLevel(int* level) { *level = 0; return 0; }
}


class MemoryBuffer : ComObject, IBuffer, IBufferByteAccess
{
nothrow @nogc:
    private ubyte* _data;
    private uint _length;
    private uint _capacity;

    void set(const(ubyte)[] data)
    {
        _data = cast(ubyte*)data.ptr;
        _length = cast(uint)data.length;
        _capacity = cast(uint)data.length;
    }

    override ULONG Release()
    {
        auto prev = atomicFetchSub(_ref_count, 1);
        if (prev == 1)
        {
            if (_data !is null)
                defaultAllocator().free(_data[0 .. _capacity]);
            defaultAllocator().freeT(this);
            return 0;
        }
        return prev - 1;
    }

    override HRESULT QueryInterface(const(GUID)* riid, void** ppv)
    {
        if (*riid == IID_IBufferByteAccess)
        {
            *ppv = cast(void*)cast(IBufferByteAccess)this;
            AddRef();
            return 0;
        }
        return super.QueryInterface(riid, ppv);
    }

    HRESULT get_Capacity(uint* value) { *value = _capacity; return 0; }
    HRESULT get_Length(uint* value) { *value = _length; return 0; }
    HRESULT put_Length(uint value) { _length = value; return 0; }
    HRESULT Buffer(ubyte** value) { *value = _data; return 0; }
}


class AdvertisementReceivedHandler : ComObject, IAdvertisementReceivedHandler
{
nothrow @nogc:
    extern(D) void function(ubyte[6] addr, byte rssi, bool connectable, bool is_scan_response, const(ubyte)[] ad_payload) nothrow @nogc callback;

    override HRESULT QueryInterface(const(GUID)* riid, void** ppv)
    {
        if (*riid == IID_TypedEventHandler_Watcher_Received)
        {
            *ppv = cast(void*)cast(IUnknown)this;
            AddRef();
            return 0;
        }
        return super.QueryInterface(riid, ppv);
    }

    HRESULT Invoke(IInspectable sender, IInspectable args_raw)
    {
        if (!callback)
            return 0;

        auto args = qi!IBluetoothLEAdvertisementReceivedEventArgs(args_raw, &IID_IBluetoothLEAdvertisementReceivedEventArgs);
        if (args is null)
            return 0;
        scope(exit) args.Release();

        ulong addr;
        short rssi;
        IBluetoothLEAdvertisement adv;
        args.get_BluetoothAddress(&addr);
        args.get_RawSignalStrengthInDBm(&rssi);
        args.get_Advertisement(&adv);

        bool connectable = false;
        bool is_scan_response = false;
        auto args2 = qi!IBluetoothLEAdvertisementReceivedEventArgs2(args_raw, &IID_IBluetoothLEAdvertisementReceivedEventArgs2);
        if (args2 !is null)
        {
            BOOL conn, scan_rsp;
            args2.get_IsConnectable(&conn);
            args2.get_IsScanResponse(&scan_rsp);
            connectable = conn != 0;
            is_scan_response = scan_rsp != 0;
            args2.Release();
        }

        ubyte[6] mac;
        ble_addr_to_mac(addr, mac);

        // serialize AD sections to raw bytes
        ubyte[62] payload = void;
        uint payload_len = serialize_adv(adv, payload[]);
        if (adv !is null)
            adv.Release();

        callback(mac, cast(byte)rssi, connectable, is_scan_response, payload[0 .. payload_len]);
        return 0;
    }
}


class ConnectionStatusHandler : ComObject, IConnectionStatusHandler
{
nothrow @nogc:
    extern(D) void function(ubyte conn_id, int status) nothrow @nogc callback;
    ubyte conn_id;

    override HRESULT QueryInterface(const(GUID)* riid, void** ppv)
    {
        if (*riid == IID_TypedEventHandler_Device_ConnectionStatus)
        {
            *ppv = cast(void*)cast(IUnknown)this;
            AddRef();
            return 0;
        }
        return super.QueryInterface(riid, ppv);
    }

    HRESULT Invoke(IInspectable sender, IInspectable args)
    {
        if (!callback)
            return 0;

        // query connection status from sender (IBluetoothLEDevice)
        auto dev = qi!IBluetoothLEDevice(sender, &IID_IBluetoothLEDevice);
        if (dev !is null)
        {
            int conn_status;
            dev.get_ConnectionStatus(&conn_status);
            dev.Release();
            callback(conn_id, conn_status);
        }
        return 0;
    }
}


class GattValueChangedHandler : ComObject, IGattValueChangedHandler
{
nothrow @nogc:
    extern(D) void function(ubyte conn_id, ushort attr_handle, const(ubyte)[] data) nothrow @nogc callback;
    ubyte conn_id;
    ushort attr_handle;

    override HRESULT QueryInterface(const(GUID)* riid, void** ppv)
    {
        if (*riid == IID_TypedEventHandler_Gatt_ValueChanged)
        {
            *ppv = cast(void*)cast(IUnknown)this;
            AddRef();
            return 0;
        }
        return super.QueryInterface(riid, ppv);
    }

    HRESULT Invoke(IInspectable sender, IInspectable args_raw)
    {
        if (!callback)
            return 0;

        auto args = cast(IGattValueChangedEventArgs)cast(void*)args_raw;
        if (args is null)
            return 0;

        IBuffer value_buf;
        args.get_CharacteristicValue(&value_buf);
        const(ubyte)[] data = get_buffer_bytes(value_buf);

        callback(conn_id, attr_handle, data);

        if (value_buf !is null)
            value_buf.Release();
        return 0;
    }
}


class WatcherStoppedHandler : ComObject, IWatcherStoppedHandler
{
nothrow @nogc:
    shared(uint)* flag;

    override HRESULT QueryInterface(const(GUID)* riid, void** ppv)
    {
        if (*riid == IID_TypedEventHandler_Watcher_Stopped)
        {
            *ppv = cast(void*)cast(IUnknown)this;
            AddRef();
            return 0;
        }
        return super.QueryInterface(riid, ppv);
    }

    HRESULT Invoke(IInspectable sender, IInspectable args)
    {
        if (flag !is null)
            atomicStore(*flag, 1u);
        return 0;
    }
}


// serialize WinRT advertisement to raw AD bytes [len][type][data]...
uint serialize_adv(IBluetoothLEAdvertisement adv, ubyte[] buf)
{
    if (adv is null)
        return 0;

    uint offset = 0;

    // local name
    HSTRING hname;
    adv.get_LocalName(&hname);
    if (hname !is null)
    {
        uint len;
        const(wchar)* raw = g_winrt.WindowsGetStringRawBuffer(hname, &len);
        if (raw && len > 0)
        {
            uint copy_len = len < 64 ? len : 64;
            ubyte name_len = cast(ubyte)(copy_len + 1);
            if (offset + 1 + name_len <= buf.length)
            {
                buf[offset++] = name_len;
                buf[offset++] = 0x09; // complete local name
                foreach (i; 0 .. copy_len)
                    buf[offset++] = cast(ubyte)raw[i];
            }
        }
        g_winrt.WindowsDeleteString(hname);
    }

    // AD data sections
    IInspectable sections_raw;
    adv.get_DataSections(&sections_raw);
    if (sections_raw !is null)
    {
        auto sections = cast(IVectorView_IInspectable)cast(void*)sections_raw;
        uint count;
        sections.get_Size(&count);

        foreach (i; 0 .. count)
        {
            IInspectable item;
            sections.GetAt(i, &item);
            if (item is null)
                continue;

            auto section = cast(IBluetoothLEAdvertisementDataSection)cast(void*)item;
            ubyte dt;
            section.get_DataType(&dt);

            IBuffer dbuf;
            section.get_Data(&dbuf);
            const(ubyte)[] data = get_buffer_bytes(dbuf);

            if (data.length > 0)
            {
                ubyte sec_len = cast(ubyte)(data.length + 1);
                if (offset + 1 + sec_len <= buf.length)
                {
                    buf[offset++] = sec_len;
                    buf[offset++] = dt;
                    buf[offset .. offset + data.length] = cast(const(ubyte)[])data[];
                    offset += cast(uint)data.length;
                }
            }

            if (dbuf !is null)
                dbuf.Release();
            item.Release();
        }
        sections_raw.Release();
    }

    return offset;
}

interface IBluetoothLEAdvertisementDataSection : IInspectable
{
nothrow @nogc:
    HRESULT get_DataType(ubyte* value);
    HRESULT put_DataType(ubyte value);
    HRESULT get_Data(IBuffer* value);
    HRESULT put_Data(IBuffer value);
}
