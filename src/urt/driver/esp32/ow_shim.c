// OpenWatt ESP-IDF shim -- the single C bridge between D and ESP-IDF.
// Wraps FreeRTOS macros, UART HAL inlines, and anything else that
// needs C headers or static-inline access.

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "hal/uart_hal.h"
#include "hal/uart_types.h"
#include "hal/uart_periph.h"
#include "esp_rom_gpio.h"
#include "esp_rom_serial_output.h"
#ifdef OW_USE_LWIP
#include "lwip/netdb.h"
#endif

// ESP32-C3 ROM exports uart_tx_one_char but not esp_rom_uart_putc.
// Provide the missing symbol so the D object links.
#if defined(CONFIG_IDF_TARGET_ESP32C3) && !defined(esp_rom_uart_putc)
void esp_rom_uart_putc(char c) { esp_rom_output_tx_one_char(c); }
#endif

// -- errno accessor (picolibc uses _Thread_local errno, incompatible with emulated-TLS) --

#include <errno.h>

int *ow_errno_location(void)
{
    return &errno;
}

// -- WFI shim --
// Single-instruction inline asm; bound from D as ow_irq_wait. The
// surrounding portENTER_CRITICAL pair is handled D-side via direct
// vPortEnterCritical/vPortExitCritical bindings -- no C wrapper needed.

void ow_irq_wait(void)
{
#if CONFIG_IDF_TARGET_ARCH_XTENSA
    __asm__ volatile("waiti 0");
#elif CONFIG_IDF_TARGET_ARCH_RISCV
    __asm__ volatile("wfi");
#endif
}

// -- GPIO wrappers (software GPIO; peripheral function routing goes
//    through ESP-IDF's signal matrix on a per-peripheral basis, not
//    through this module).

#include "driver/gpio.h"
#include "soc/gpio_num.h"

// pull: 0=none, 1=up, 2=down (matches D Pull enum encoding)
static gpio_pull_mode_t ow_pull_to_idf(int pull)
{
    return (pull == 1) ? GPIO_PULLUP_ONLY :
           (pull == 2) ? GPIO_PULLDOWN_ONLY : GPIO_FLOATING;
}

void ow_gpio_output_init(int pin, int initial)
{
    gpio_reset_pin((gpio_num_t)pin);
    gpio_set_direction((gpio_num_t)pin, GPIO_MODE_OUTPUT);
    gpio_set_level((gpio_num_t)pin, initial);
}

void ow_gpio_input_init(int pin, int pull)
{
    gpio_reset_pin((gpio_num_t)pin);
    gpio_set_direction((gpio_num_t)pin, GPIO_MODE_INPUT);
    gpio_set_pull_mode((gpio_num_t)pin, ow_pull_to_idf(pull));
}

void ow_gpio_output_set(int pin, int value)
{
    gpio_set_level((gpio_num_t)pin, value);
}

int ow_gpio_input_read(int pin)
{
    return gpio_get_level((gpio_num_t)pin);
}

void ow_gpio_set_pull(int pin, int pull)
{
    gpio_set_pull_mode((gpio_num_t)pin, ow_pull_to_idf(pull));
}

void ow_gpio_release(int pin)
{
    gpio_reset_pin((gpio_num_t)pin);
}

uint32_t ow_gpio_count(void)
{
    return SOC_GPIO_PIN_COUNT;
}


// -- UART HAL wrappers --

#include "soc/soc_caps.h"
#include "hal/uart_ll.h"
#include "esp_private/periph_ctrl.h"
#define NUM_UARTS SOC_UART_NUM

static uart_hal_context_t uart_ctx[NUM_UARTS];
static bool uart_initialized[NUM_UARTS];

// D enums: StopBits { half=0, one=1, one_point_five=2, two=3 }
//          Parity   { none=0, even=1, odd=2, mark=3, space=4 }
// HAL enums: UART_STOP_BITS_1=1, _1_5=2, _2=3
//            UART_PARITY_DISABLE=0, _EVEN=2, _ODD=3
static const uart_stop_bits_t stop_bits_map[] = {
    UART_STOP_BITS_1, UART_STOP_BITS_1, UART_STOP_BITS_1_5, UART_STOP_BITS_2
};
static const uart_parity_t parity_map[] = {
    UART_PARITY_DISABLE, UART_PARITY_EVEN, UART_PARITY_ODD,
    UART_PARITY_DISABLE, UART_PARITY_DISABLE
};

int ow_uart_open(unsigned port, uint32_t baud_rate, uint8_t data_bits,
                 uint8_t stop_bits, uint8_t parity,
                 int8_t tx_gpio, int8_t rx_gpio)
{
    if (port >= NUM_UARTS)
        return 0;

    // Enable peripheral clock before touching any registers
    PERIPH_RCC_ATOMIC()
    {
        uart_ll_enable_bus_clock(port, true);
        uart_ll_reset_register(port);
    }

    // Set device pointer before calling hal_init (v6 API expects it pre-set)
    uart_ctx[port].dev = UART_LL_GET_HW(port);
    uart_hal_init(&uart_ctx[port], port);

    int __DECLARE_RCC_ATOMIC_ENV __attribute__((unused));
    uart_ll_set_sclk(uart_ctx[port].dev, UART_SCLK_DEFAULT);
    uart_ll_set_baudrate(uart_ctx[port].dev, baud_rate, 80000000);
    uart_ll_set_data_bit_num(uart_ctx[port].dev, data_bits - 5);
    uart_ll_set_stop_bits(uart_ctx[port].dev, stop_bits < sizeof(stop_bits_map) ? stop_bits_map[stop_bits] : 1);
    uart_ll_set_parity(uart_ctx[port].dev, parity < sizeof(parity_map)/sizeof(parity_map[0]) ? parity_map[parity] : UART_PARITY_DISABLE);

    uart_hal_rxfifo_rst(&uart_ctx[port]);
    uart_hal_txfifo_rst(&uart_ctx[port]);

    // GPIO pin routing -- UART0 defaults (TX=43, RX=44) set by bootloader.
    // For non-default pins or UART1/2, route via GPIO matrix.
    if (tx_gpio >= 0)
    {
        esp_rom_gpio_pad_select_gpio(tx_gpio);
        esp_rom_gpio_connect_out_signal(tx_gpio,
            uart_periph_signal[port].pins[SOC_UART_PERIPH_SIGNAL_TX].signal, false, false);
    }
    if (rx_gpio >= 0)
    {
        esp_rom_gpio_pad_select_gpio(rx_gpio);
        esp_rom_gpio_pad_pullup_only(rx_gpio);
        esp_rom_gpio_connect_in_signal(rx_gpio,
            uart_periph_signal[port].pins[SOC_UART_PERIPH_SIGNAL_RX].signal, false);
    }

    uart_initialized[port] = true;
    return 1;
}

void ow_uart_close(unsigned port)
{
    if (port >= NUM_UARTS || !uart_initialized[port])
        return;
    uart_hal_txfifo_rst(&uart_ctx[port]);
    uart_hal_rxfifo_rst(&uart_ctx[port]);
    PERIPH_RCC_ATOMIC()
    {
        uart_ll_enable_bus_clock(port, false);
    }
    uart_initialized[port] = false;
}

int32_t ow_uart_read(unsigned port, uint8_t *buf, int32_t len)
{
    if (port >= NUM_UARTS || !uart_initialized[port])
        return 0;
    int rd_len = (int)len;
    uart_hal_read_rxfifo(&uart_ctx[port], buf, &rd_len);
    return rd_len;
}

int32_t ow_uart_write(unsigned port, const uint8_t *buf, int32_t len)
{
    if (port >= NUM_UARTS || !uart_initialized[port])
        return 0;
    uint32_t written = 0;
    uart_hal_write_txfifo(&uart_ctx[port], buf, (uint32_t)len, &written);
    return (int32_t)written;
}

int32_t ow_uart_rx_pending(unsigned port)
{
    if (port >= NUM_UARTS || !uart_initialized[port])
        return 0;
    return (int32_t)uart_ll_get_rxfifo_len(uart_ctx[port].dev);
}

int ow_uart_tx_idle(unsigned port)
{
    if (port >= NUM_UARTS || !uart_initialized[port])
        return 1;
    return uart_ll_is_tx_idle(uart_ctx[port].dev) ? 1 : 0;
}

int32_t ow_uart_flush(unsigned port)
{
    if (port >= NUM_UARTS || !uart_initialized[port])
        return 0;
    while (!uart_ll_is_tx_idle(uart_ctx[port].dev))
    {}
    return 0;
}

// -- WiFi wrappers --

#if CONFIG_ESP_WIFI_ENABLED
#include "esp_wifi.h"
#include "esp_private/wifi.h"
#include "esp_event.h"
#include "esp_mac.h"

static int ow_wifi_refcount;

#ifdef OW_USE_LWIP
#include "esp_netif.h"

static esp_netif_t *ow_wifi_netif_sta;
static esp_netif_t *ow_wifi_netif_ap;
#endif

typedef void (*ow_wifi_event_cb_t)(int event_id, void *data, int data_len);

static ow_wifi_event_cb_t ow_wifi_sta_cb;
static ow_wifi_event_cb_t ow_wifi_ap_cb;

static void ow_wifi_event_handler(void *arg, esp_event_base_t base, int32_t event_id, void *event_data)
{
    if (base == WIFI_EVENT)
    {
        switch (event_id)
        {
        case WIFI_EVENT_STA_CONNECTED:
        case WIFI_EVENT_STA_DISCONNECTED:
        case WIFI_EVENT_STA_START:
        case WIFI_EVENT_STA_STOP:
            if (ow_wifi_sta_cb)
                ow_wifi_sta_cb(event_id, event_data, 0);
            break;

        case WIFI_EVENT_AP_START:
        case WIFI_EVENT_AP_STOP:
        case WIFI_EVENT_AP_STACONNECTED:
        case WIFI_EVENT_AP_STADISCONNECTED:
            if (ow_wifi_ap_cb)
                ow_wifi_ap_cb(event_id, event_data, 0);
            break;
        }
    }
#ifdef OW_USE_LWIP
    else if (base == IP_EVENT)
    {
        if (event_id == IP_EVENT_STA_GOT_IP && ow_wifi_sta_cb)
            ow_wifi_sta_cb(event_id, event_data, 0);
    }
#endif
}

int ow_wifi_init(void)
{
    if (ow_wifi_refcount++ > 0)
        return 0;

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_err_t err = esp_wifi_init(&cfg);
    if (err != ESP_OK)
    {
        ow_wifi_refcount--;
        return (int)err;
    }

    esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &ow_wifi_event_handler, NULL);

#ifdef OW_USE_LWIP
    // Create netifs before RX callbacks fire, so esp_netif_receive() has valid targets.
    if (!ow_wifi_netif_sta)
        ow_wifi_netif_sta = esp_netif_create_default_wifi_sta();
    if (!ow_wifi_netif_ap)
        ow_wifi_netif_ap = esp_netif_create_default_wifi_ap();
    esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &ow_wifi_event_handler, NULL);
#endif

    return 0;
}

void ow_wifi_deinit(void)
{
    if (--ow_wifi_refcount > 0)
        return;

    esp_wifi_stop();
    esp_wifi_deinit();

#ifdef OW_USE_LWIP
    if (ow_wifi_netif_sta)
    {
        esp_netif_destroy(ow_wifi_netif_sta);
        ow_wifi_netif_sta = NULL;
    }
    if (ow_wifi_netif_ap)
    {
        esp_netif_destroy(ow_wifi_netif_ap);
        ow_wifi_netif_ap = NULL;
    }
#endif
}

int ow_wifi_sta_config(const char *ssid, const char *password, const uint8_t *bssid)
{
    wifi_config_t cfg = {0};
    if (ssid)
    {
        size_t len = strlen(ssid);
        if (len > sizeof(cfg.sta.ssid) - 1) len = sizeof(cfg.sta.ssid) - 1;
        memcpy(cfg.sta.ssid, ssid, len);
    }
    if (password)
    {
        size_t len = strlen(password);
        if (len > sizeof(cfg.sta.password) - 1) len = sizeof(cfg.sta.password) - 1;
        memcpy(cfg.sta.password, password, len);
    }
    if (bssid)
    {
        memcpy(cfg.sta.bssid, bssid, 6);
        cfg.sta.bssid_set = true;
    }

    return esp_wifi_set_config(WIFI_IF_STA, &cfg) == ESP_OK ? 1 : 0;
}

int ow_wifi_ap_config(const char *ssid, const char *password, uint8_t channel, uint8_t max_conn, uint8_t hidden)
{
    wifi_config_t cfg = {0};
    if (ssid)
    {
        size_t len = strlen(ssid);
        if (len > sizeof(cfg.ap.ssid) - 1) len = sizeof(cfg.ap.ssid) - 1;
        memcpy(cfg.ap.ssid, ssid, len);
        cfg.ap.ssid_len = (uint8_t)len;
    }
    if (password)
    {
        size_t len = strlen(password);
        if (len > sizeof(cfg.ap.password) - 1) len = sizeof(cfg.ap.password) - 1;
        memcpy(cfg.ap.password, password, len);
        cfg.ap.authmode = (len > 0) ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;
    }
    else
        cfg.ap.authmode = WIFI_AUTH_OPEN;

    cfg.ap.channel = channel;
    cfg.ap.max_connection = max_conn > 0 ? max_conn : 4;
    cfg.ap.ssid_hidden = hidden;

    return esp_wifi_set_config(WIFI_IF_AP, &cfg) == ESP_OK ? 1 : 0;
}

// Ethernet frame RX callbacks -- one per netif (STA=0, AP=1).
// esp_wifi_internal_reg_rxcb gives us raw Ethernet frames before lwIP,
// so the bridge/routing layer sees all traffic.

typedef void (*ow_wifi_rx_cb_t)(const uint8_t *data, int len, int iface);

static ow_wifi_rx_cb_t ow_wifi_rx_callback;

static esp_err_t ow_wifi_sta_rx(void *buffer, uint16_t len, void *eb)
{
    if (ow_wifi_rx_callback)
        ow_wifi_rx_callback((const uint8_t *)buffer, len, 0);
#ifdef OW_USE_LWIP
    return esp_netif_receive(ow_wifi_netif_sta, buffer, len, eb);
#else
    // Internal stack consumes via ow_wifi_rx_callback; we own the eb buffer
    // (esp_netif_receive normally frees it).
    if (eb)
        esp_wifi_internal_free_rx_buffer(eb);
    return ESP_OK;
#endif
}

static esp_err_t ow_wifi_ap_rx(void *buffer, uint16_t len, void *eb)
{
    if (ow_wifi_rx_callback)
        ow_wifi_rx_callback((const uint8_t *)buffer, len, 1);
#ifdef OW_USE_LWIP
    return esp_netif_receive(ow_wifi_netif_ap, buffer, len, eb);
#else
    if (eb)
        esp_wifi_internal_free_rx_buffer(eb);
    return ESP_OK;
#endif
}

int ow_wifi_set_rx_callback(ow_wifi_rx_cb_t cb)
{
    ow_wifi_rx_callback = cb;
    esp_err_t err;
    err = esp_wifi_internal_reg_rxcb(WIFI_IF_STA, cb ? &ow_wifi_sta_rx : NULL);
    if (err != ESP_OK)
        return 0;
    err = esp_wifi_internal_reg_rxcb(WIFI_IF_AP, cb ? &ow_wifi_ap_rx : NULL);
    return err == ESP_OK ? 1 : 0;
}

void ow_wifi_set_sta_callback(ow_wifi_event_cb_t cb)
{
    ow_wifi_sta_cb = cb;
}

void ow_wifi_set_ap_callback(ow_wifi_event_cb_t cb)
{
    ow_wifi_ap_cb = cb;
}
#else // !CONFIG_ESP_WIFI_ENABLED

typedef void (*ow_wifi_event_cb_t)(int, void *, int);
typedef void (*ow_wifi_rx_cb_t)(const uint8_t *, int, int);

int ow_wifi_init(void) { return -1; }
void ow_wifi_deinit(void) {}
int ow_wifi_sta_config(const char *s, const char *p, const uint8_t *b) { (void)s;(void)p;(void)b; return 0; }
int ow_wifi_ap_config(const char *s, const char *p, uint8_t c, uint8_t m, uint8_t h) { (void)s;(void)p;(void)c;(void)m;(void)h; return 0; }
int ow_wifi_set_rx_callback(ow_wifi_rx_cb_t cb) { (void)cb; return 0; }
void ow_wifi_set_sta_callback(ow_wifi_event_cb_t cb) { (void)cb; }
void ow_wifi_set_ap_callback(ow_wifi_event_cb_t cb) { (void)cb; }

#endif // CONFIG_ESP_WIFI_ENABLED

// -- BLE (NimBLE) wrappers --

#if CONFIG_BT_ENABLED && CONFIG_BT_NIMBLE_ENABLED
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_gap.h"

typedef int (*ow_gap_event_cb_t)(struct ble_gap_event *, void *);
static ow_gap_event_cb_t ow_gap_callback;

static int ow_gap_event_dispatch(struct ble_gap_event *event, void *arg)
{
    if (ow_gap_callback)
        return ow_gap_callback(event, arg);
    return 0;
}

static void ow_nimble_host_task(void *param)
{
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

int ow_ble_init(void)
{
    int rc = nimble_port_init();
    if (rc != 0)
        return rc;
    nimble_port_freertos_init(ow_nimble_host_task);
    return 0;
}

void ow_ble_deinit(void)
{
    nimble_port_stop();
    nimble_port_deinit();
}

void ow_ble_set_gap_callback(ow_gap_event_cb_t cb)
{
    ow_gap_callback = cb;
}

#else // !BT_NIMBLE

typedef int (*ow_gap_event_cb_t)(void *, void *);

int ow_ble_init(void) { return -1; }
void ow_ble_deinit(void) {}
void ow_ble_set_gap_callback(ow_gap_event_cb_t cb) { (void)cb; }

#endif // CONFIG_BT_NIMBLE_ENABLED

// -- CAN (TWAI) driver --
//
// Only ow_can_open lives here -- it builds the timing/general/filter config
// structs and does install+start.  Everything else is called directly from D
// via the ESP-IDF _v2 handle API.

#include "soc/soc_caps.h"
#if SOC_TWAI_SUPPORTED
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wcpp"
#include "driver/twai.h"
#pragma GCC diagnostic pop

twai_handle_t ow_can_open(unsigned port, uint32_t bitrate, int tx_gpio, int rx_gpio, uint8_t sjw, uint8_t tseg1, uint8_t tseg2, uint16_t brp)
{
    if (port >= SOC_TWAI_CONTROLLER_NUM)
        return NULL;

    twai_timing_config_t timing;
    if (brp > 0)
    {
        memset(&timing, 0, sizeof(timing));
        timing.clk_src = TWAI_CLK_SRC_DEFAULT;
        timing.brp = brp;
        timing.tseg_1 = tseg1;
        timing.tseg_2 = tseg2;
        timing.sjw = sjw;
    }
    else
    {
        switch (bitrate)
        {
        case 1000:    timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_1KBITS();     break;
        case 5000:    timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_5KBITS();     break;
        case 10000:   timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_10KBITS();    break;
        case 12500:   timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_12_5KBITS();  break;
        case 16000:   timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_16KBITS();    break;
        case 20000:   timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_20KBITS();    break;
        case 25000:   timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_25KBITS();    break;
        case 50000:   timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_50KBITS();    break;
        case 100000:  timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_100KBITS();   break;
        case 125000:  timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_125KBITS();   break;
        case 250000:  timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_250KBITS();   break;
        case 500000:  timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_500KBITS();   break;
        case 800000:  timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_800KBITS();   break;
        case 1000000: timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_1MBITS();     break;
        default: return NULL;
        }
    }

    twai_general_config_t general = TWAI_GENERAL_CONFIG_DEFAULT_V2(
        port, tx_gpio, rx_gpio, TWAI_MODE_NORMAL);
    general.alerts_enabled = TWAI_ALERT_BUS_ERROR | TWAI_ALERT_ERR_PASS
        | TWAI_ALERT_ERR_ACTIVE | TWAI_ALERT_BUS_OFF | TWAI_ALERT_ABOVE_ERR_WARN
        | TWAI_ALERT_BELOW_ERR_WARN | TWAI_ALERT_RX_FIFO_OVERRUN
        | TWAI_ALERT_RX_QUEUE_FULL | TWAI_ALERT_ARB_LOST | TWAI_ALERT_TX_FAILED;
    twai_filter_config_t filter = TWAI_FILTER_CONFIG_ACCEPT_ALL();

    twai_handle_t handle = NULL;
    if (twai_driver_install_v2(&general, &timing, &filter, &handle) != ESP_OK)
        return NULL;

    if (twai_start_v2(handle) != ESP_OK)
    {
        twai_driver_uninstall_v2(handle);
        return NULL;
    }

    return handle;
}

#else // !SOC_TWAI_SUPPORTED

typedef struct twai_obj_t *twai_handle_t;

twai_handle_t ow_can_open(unsigned, uint32_t, int, int, uint8_t, uint8_t, uint8_t, uint16_t)
{
    return (twai_handle_t)0;
}

#endif // SOC_TWAI_SUPPORTED

#ifdef OW_USE_LWIP
// -- lwIP netdb wrappers (link-order fix) --
// D object references lwip_getaddrinfo/lwip_freeaddrinfo but the D object
// appears after liblwip.a in the link. These wrappers are in libmain.a
// which is linked with --whole-archive, ensuring they're always present.

int ow_lwip_getaddrinfo(const char *nodename, const char *servname, const struct addrinfo *hints, struct addrinfo **res)
{
    return lwip_getaddrinfo(nodename, servname, hints, res);
}

void ow_lwip_freeaddrinfo(struct addrinfo *ai)
{
    lwip_freeaddrinfo(ai);
}
#endif
