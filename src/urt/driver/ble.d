module urt.driver.ble;

import urt.result : Result, InternalResult;
import urt.uuid : GUID;

version (Windows)
    public import urt.driver.windows.ble;
else version (Espressif)
    public import urt.driver.esp32.ble;
else
    enum uint num_ble = 0;

nothrow @nogc:


// ====================================================================
// Types
// ====================================================================

enum BLEError : ubyte
{
    none,
    not_found,      // device not found / unreachable
    auth_failed,    // pairing or encryption failure
    timeout,        // operation timed out
    protocol,       // ATT/GATT protocol error
    access_denied,  // insufficient permissions
    internal,       // platform-specific internal error
}

enum BLERole : ubyte
{
    central,       // scan + connect to peripherals
    peripheral,    // advertise + accept connections
    observer,      // scan only (no connections)
    broadcaster,   // advertise only (no connections)
}

enum BLEAdvType : ubyte
{
    connectable,         // ADV_IND: connectable, scannable, undirected
    connectable_direct,  // ADV_DIRECT_IND: connectable, directed
    scannable,           // ADV_SCAN_IND: scannable, not connectable
    nonconnectable,      // ADV_NONCONN_IND: not connectable, not scannable
}

enum BLEAddrType : ubyte
{
    public_       = 0x00,
    random_static = 0x01,
    rpa_public    = 0x02,  // resolvable private, public identity
    rpa_random    = 0x03,  // resolvable private, random identity
}

enum BLEPhy : ubyte
{
    phy_1m    = 0x01,  // mandatory, 1 Mbit/s
    phy_2m    = 0x02,  // optional, 2 Mbit/s
    phy_coded = 0x03,  // long range
}

enum GattCharProps : ushort
{
    none                    = 0x0000,
    broadcast               = 0x0001,
    read                    = 0x0002,
    write_without_response  = 0x0004,
    write                   = 0x0008,
    notify                  = 0x0010,
    indicate                = 0x0020,
    authenticated_writes    = 0x0040,
    extended_properties     = 0x0080,
    reliable_write          = 0x0100,
}


// --- Configuration structs ---

struct BLEConfig
{
    byte tx_power;          // dBm (0 = platform default)
    BLEPhy preferred_phy;   // preferred PHY (0 = platform default)
}

struct BLEScanConfig
{
    bool active = true;         // active scan (send SCAN_REQ for extra data)
    ushort interval_ms = 100;   // scan interval
    ushort window_ms = 50;      // scan window, <= interval
    bool filter_duplicates;     // suppress repeated advertisements
}

struct BLEAdvConfig
{
    BLEAdvType adv_type;
    ushort interval_ms = 100;   // advertising interval
    byte tx_power;              // dBm (0 = default)
    const(ubyte)[] adv_data;    // raw AD structures (max 31 bytes)
    const(ubyte)[] scan_rsp;    // scan response data (max 31 bytes)
}

struct BLEConnConfig
{
    ushort interval_min_ms = 7;    // connection interval range
    ushort interval_max_ms = 30;
    ushort latency;                // slave latency (number of skippable events)
    ushort timeout_ms = 5000;      // supervision timeout
}

// Discovered advertisement report from scanning.
struct BLEAdvReport
{
    ubyte[6] addr;
    BLEAddrType addr_type;
    BLEAdvType adv_type;
    byte rssi;             // dBm (-128 = unknown)
    byte tx_power;         // dBm (-128 = not present)
    ubyte data_len;
    ubyte[62] data_buf;    // adv_data + scan_rsp combined (max 31+31)

    const(ubyte)[] data() const pure nothrow @nogc
        => data_buf[0 .. data_len];
}

// A discovered GATT characteristic on a connected device.
struct BLEGattChar
{
    ushort handle;         // ATT handle for read/write
    ushort cccd_handle;    // Client Characteristic Config descriptor (0 = none)
    GUID service_uuid;     // owning service UUID
    GUID char_uuid;        // characteristic UUID
    GattCharProps properties;
}


// --- Handles ---

struct BLE
{
    ubyte port = ubyte.max;
}

bool is_open(ref const BLE ble)
{
    return ble.port != ubyte.max;
}

// Opaque connection handle. Lifetime: from connect callback (success)
// until disconnect callback fires. Do not use after disconnect.
struct BLEConn
{
    ubyte id = ubyte.max;
}

bool is_valid(ref const BLEConn conn)
{
    return conn.id != ubyte.max;
}

// Opaque advertising handle. Returned by ble_adv_start, used to stop
// a specific advertisement. Invalid after ble_adv_stop.
struct BLEAdv
{
    ubyte id = ubyte.max;
}

bool is_valid(ref const BLEAdv adv)
{
    return adv.id != ubyte.max;
}


// --- Callbacks ---

// Scan result received. Called once per advertisement/scan response.
// The report is only valid for the duration of the callback.
alias BLEScanCallback = void function(BLE ble, ref const BLEAdvReport report) nothrow @nogc;

// Connection state change. On success: conn is valid, error is .none.
// On failure or disconnect: conn becomes invalid after callback returns.
alias BLEConnCallback = void function(BLE ble, BLEConn conn, bool connected, BLEError error) nothrow @nogc;

// GATT service discovery complete. chars is only valid during callback.
// On error: chars.length == 0 and error != .none.
alias BLEDiscoverCallback = void function(BLE ble, BLEConn conn, const(BLEGattChar)[] chars, BLEError error) nothrow @nogc;

// GATT read complete. data is only valid during callback.
alias BLEReadCallback = void function(BLE ble, BLEConn conn, ushort handle, const(ubyte)[] data, BLEError error) nothrow @nogc;

// GATT write complete.
alias BLEWriteCallback = void function(BLE ble, BLEConn conn, ushort handle, BLEError error) nothrow @nogc;

// Notification or indication received from a connected peripheral.
// data is only valid during callback.
alias BLENotifyCallback = void function(BLE ble, BLEConn conn, ushort handle, const(ubyte)[] data) nothrow @nogc;


// ====================================================================
// Error type
// ====================================================================

BLEError ble_result(Result result)
{
    return cast(BLEError)result.system_code;
}


// ====================================================================
// Implementation
// ====================================================================

// --- Lifecycle ---

void ble_init()
{
    if (_init_refcount++ == 0)
    {
        // TODO: enable clocks/power for BLE peripheral block
    }
}

void ble_deinit()
{
    assert(_init_refcount > 0);
    if (--_init_refcount == 0)
    {
        // TODO: disable clocks/power for BLE peripheral block
    }
}

Result ble_open(ref BLE ble, ubyte port, ref const BLEConfig cfg)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
    {
        if (port >= num_ble)
            return InternalResult.invalid_parameter;

        if (!ble_hw_open(port, cfg))
            return InternalResult.failed;

        ble.port = port;
        return Result.success;
    }
}

void ble_close(ref BLE ble)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
        ble_hw_close(ble.port);
    ble.port = ubyte.max;
}

// --- Scanning (central/observer role) ---

// Start scanning for advertisements. Reports are delivered via the
// scan callback set with ble_set_scan_callback(). Scanning continues
// until ble_scan_stop() is called or the radio is closed.
Result ble_scan_start(ref BLE ble, ref const BLEScanConfig cfg)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
    {
        if (!ble_hw_scan_start(ble.port, cfg))
            return InternalResult.failed;
        return Result.success;
    }
}

void ble_scan_stop(ref BLE ble)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
        ble_hw_scan_stop(ble.port);
}

// --- Advertising (peripheral/broadcaster role) ---

// Start advertising. Returns an opaque handle on success that can be
// passed to ble_adv_stop. Multiple advertisements may be active
// concurrently (platform permitting). For connectable advertisements,
// incoming connections are delivered via the connection callback.
BLEAdv ble_adv_start(ref BLE ble, ref const BLEAdvConfig cfg)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
        return ble_hw_adv_start(ble.port, cfg);
}

// Stop a specific advertisement. Pass the handle returned by
// ble_adv_start. The handle is invalid after this call.
void ble_adv_stop(ref BLE ble, BLEAdv adv)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
        ble_hw_adv_stop(ble.port, adv);
}

// --- Connection (central role) ---

// Initiate a connection to a peripheral. Completion (success or failure)
// is delivered via the connection callback. Only one connect may be
// pending at a time per radio.
Result ble_connect(ref BLE ble, ref const ubyte[6] peer_addr, BLEAddrType addr_type, ref const BLEConnConfig cfg)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
    {
        if (!ble_hw_connect(ble.port, peer_addr, addr_type, cfg))
            return InternalResult.failed;
        return Result.success;
    }
}

// Cancel a pending connection attempt.
void ble_connect_cancel(ref BLE ble)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
        ble_hw_connect_cancel(ble.port);
}

// Disconnect an established connection. The disconnect callback fires
// when teardown is complete.
Result ble_disconnect(ref BLE ble, BLEConn conn)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
    {
        if (!ble_hw_disconnect(ble.port, conn))
            return InternalResult.failed;
        return Result.success;
    }
}

// --- GATT discovery ---

// Discover all services and characteristics on a connected device.
// Results are delivered via the discover callback. Only one discovery
// may be active per connection at a time.
Result ble_gatt_discover(ref BLE ble, BLEConn conn)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
    {
        if (!ble_hw_gatt_discover(ble.port, conn))
            return InternalResult.failed;
        return Result.success;
    }
}

// --- GATT read/write ---

// Read a characteristic value by handle. Result is delivered via the
// read callback. Multiple reads may be in flight concurrently (up to
// a platform-defined limit).
Result ble_gatt_read(ref BLE ble, BLEConn conn, ushort handle)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
    {
        if (!ble_hw_gatt_read(ble.port, conn, handle))
            return InternalResult.failed;
        return Result.success;
    }
}

// Write a characteristic value. If with_response is true, the write
// callback fires on completion; otherwise the write is fire-and-forget
// (Write Without Response / Write Command).
Result ble_gatt_write(ref BLE ble, BLEConn conn, ushort handle, const(ubyte)[] data, bool with_response = true)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
    {
        if (!ble_hw_gatt_write(ble.port, conn, handle, data, with_response))
            return InternalResult.failed;
        return Result.success;
    }
}

// --- Notifications / Indications ---

// Enable or disable notifications/indications on a characteristic.
// Writes the CCCD descriptor on the remote device. Incoming notifications
// are delivered via the notify callback.
Result ble_gatt_subscribe(ref BLE ble, BLEConn conn, ushort handle, bool enable)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
    {
        if (!ble_hw_gatt_subscribe(ble.port, conn, handle, enable))
            return InternalResult.failed;
        return Result.success;
    }
}

// --- Queries ---

Result ble_get_mac(ref BLE ble, ref ubyte[6] mac)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
    {
        if (!ble_hw_get_mac(ble.port, mac))
            return InternalResult.failed;
        return Result.success;
    }
}

byte ble_get_rssi(ref BLE ble, BLEConn conn)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
        return ble_hw_get_rssi(ble.port, conn);
}

// --- Callbacks ---

void ble_set_scan_callback(ref BLE ble, BLEScanCallback cb)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
        ble_hw_set_scan_callback(ble.port, cb);
}

void ble_set_conn_callback(ref BLE ble, BLEConnCallback cb)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
        ble_hw_set_conn_callback(ble.port, cb);
}

void ble_set_discover_callback(ref BLE ble, BLEDiscoverCallback cb)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
        ble_hw_set_discover_callback(ble.port, cb);
}

void ble_set_read_callback(ref BLE ble, BLEReadCallback cb)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
        ble_hw_set_read_callback(ble.port, cb);
}

void ble_set_write_callback(ref BLE ble, BLEWriteCallback cb)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
        ble_hw_set_write_callback(ble.port, cb);
}

void ble_set_notify_callback(ref BLE ble, BLENotifyCallback cb)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
        ble_hw_set_notify_callback(ble.port, cb);
}

// --- Poll ---

// Drive completions for platforms that don't deliver events natively.
// Must be called periodically from the main loop.
void ble_poll(ref BLE ble)
{
    static if (num_ble == 0)
        assert(false, "no BLE on this platform");
    else
        ble_hw_poll(ble.port);
}


// ====================================================================
// Tests
// ====================================================================

unittest
{
    static if (num_ble > 0)
    {
        BLE b;
        BLEConfig cfg;

        ble_init();

        // Out-of-range port
        auto r = ble_open(b, cast(ubyte)num_ble, cfg);
        assert(!r);
        assert(!b.is_open);

        // Open/close each valid port
        foreach (p; 0 .. num_ble)
        {
            BLE port;
            auto r2 = ble_open(port, cast(ubyte)p, cfg);
            assert(r2, "ble_open failed");
            assert(port.is_open);
            assert(port.port == p);

            ble_poll(port);

            ble_close(port);
            assert(!port.is_open);
        }

        ble_deinit();
    }
}


private:

__gshared ubyte _init_refcount;
