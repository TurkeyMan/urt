// minimal D bindings for mbedtls - only what pki.d and tls.d need
module urt.internal.mbedtls;

version (MbedTLS):

// Host posix builds link against system mbedtls. Embedded targets (esp%)
// inherit mbedtls from their platform SDK -- no pragma(lib) needed.
version (Posix)
{
    pragma(lib, "mbedtls");
    pragma(lib, "mbedx509");
    pragma(lib, "mbedcrypto");
}

nothrow @nogc:
extern(C):


// --- RNG (from urt/internal/mbedtls.c) ---
//
// Unified wrapper for the version-fragile entropy + CTR-DRBG / PSA dance.
// 4.x: backed by psa_generate_random; <4: classic entropy + CTR-DRBG seeded
// once and held module-static. Always idempotent and lazily initialised --
// callers may invoke urt_rng_init() up front or simply call urt_rng_random()
// which inits on demand.
int urt_rng_init();
int urt_rng_random(ubyte* output, size_t len);
int urt_rng_callback(void* p_rng, ubyte* output, size_t len);  // f_rng-shaped, p_rng ignored


// --- PK (public key abstraction) ---

struct mbedtls_pk_info_t; // opaque

struct mbedtls_pk_context
{
    const(mbedtls_pk_info_t)* pk_info;
    void* pk_ctx;
}

void mbedtls_pk_init(mbedtls_pk_context* ctx);
void mbedtls_pk_free(mbedtls_pk_context* ctx);


// --- PK ECDSA P-256 helpers (from urt/internal/mbedtls.c) ---
//
// These wrap operations whose signatures or internal struct access patterns
// shift across mbedtls 2.x/3.x/4.x. The shim absorbs the divergence and
// drives RNG internally via urt_rng_*, so the D side never passes f_rng/p_rng.

int urt_pk_gen_ec_p256_key(mbedtls_pk_context* pk);
int urt_pk_sign(mbedtls_pk_context* ctx, const(ubyte)* hash, size_t hash_len,
                ubyte* sig, size_t sig_size, size_t* sig_len);
int urt_pk_import_ec_p256_key(mbedtls_pk_context* pk,
                              const(ubyte)* d, size_t d_len,
                              const(ubyte)* xy, size_t xy_len);
int urt_pk_export_privkey_d(mbedtls_pk_context* pk, ubyte* buf, size_t buflen, size_t* olen);
int urt_pk_export_pubkey_xy(mbedtls_pk_context* pk, ubyte* buf, size_t buflen, size_t* olen);


// --- ECDH P-256 (from urt/internal/mbedtls.c) ---

int urt_ecdh_p256_compute_shared(const(ubyte)* priv_d, size_t priv_len,
                                  const(ubyte)* peer_xy, size_t peer_xy_len,
                                  ubyte* shared_x_out);


// --- AES-GCM one-shot (from urt/internal/mbedtls.c) ---

int urt_gcm_encrypt(const(ubyte)* key, size_t key_len,
                    const(ubyte)* iv, size_t iv_len,
                    const(ubyte)* aad, size_t aad_len,
                    const(ubyte)* plaintext, size_t pt_len,
                    ubyte* ciphertext,
                    ubyte* tag, size_t tag_len);

int urt_gcm_decrypt(const(ubyte)* key, size_t key_len,
                    const(ubyte)* iv, size_t iv_len,
                    const(ubyte)* aad, size_t aad_len,
                    const(ubyte)* ciphertext, size_t ct_len,
                    const(ubyte)* tag, size_t tag_len,
                    ubyte* plaintext);


// --- AES single-block ECB (RFC 3394 key-wrap building blocks) ---

int urt_aes_ecb_decrypt(const(ubyte)* key, size_t key_len,
                        const(ubyte)* cipher_block,
                        ubyte* plain_block);
int urt_aes_ecb_encrypt(const(ubyte)* key, size_t key_len,
                        const(ubyte)* plain_block,
                        ubyte* cipher_block);


// --- X.509 certificate ---

// mbedtls_x509_crt is complex (~200+ bytes). We only use it through pointers
// allocated via urt/internal/mbedtls.c (urt_x509_crt_new/delete).
struct mbedtls_x509_crt;

void mbedtls_x509_crt_init(mbedtls_x509_crt* crt);
void mbedtls_x509_crt_free(mbedtls_x509_crt* crt);
int mbedtls_x509_crt_parse_der(mbedtls_x509_crt* chain, const(ubyte)* buf, size_t buflen);
int mbedtls_x509_crt_parse(mbedtls_x509_crt* chain, const(ubyte)* buf, size_t buflen);


// --- SSL/TLS ---

struct mbedtls_ssl_context;
struct mbedtls_ssl_config;

enum MBEDTLS_SSL_IS_CLIENT = 0;
enum MBEDTLS_SSL_IS_SERVER = 1;
enum MBEDTLS_SSL_TRANSPORT_STREAM = 0;
enum MBEDTLS_SSL_PRESET_DEFAULT = 0;

enum MBEDTLS_ERR_SSL_WANT_READ = -0x6900;
enum MBEDTLS_ERR_SSL_WANT_WRITE = -0x6880;
enum MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY = -0x7880;

void mbedtls_ssl_init(mbedtls_ssl_context* ssl);
void mbedtls_ssl_free(mbedtls_ssl_context* ssl);
int mbedtls_ssl_setup(mbedtls_ssl_context* ssl, const(mbedtls_ssl_config)* conf);
void mbedtls_ssl_set_bio(mbedtls_ssl_context* ssl, void* p_bio, int function(void*, const(ubyte)*, size_t) nothrow @nogc f_send, int function(void*, ubyte*, size_t) nothrow @nogc f_recv, void* f_recv_timeout);
int mbedtls_ssl_handshake(mbedtls_ssl_context* ssl);
int mbedtls_ssl_read(mbedtls_ssl_context* ssl, ubyte* buf, size_t len);
int mbedtls_ssl_write(mbedtls_ssl_context* ssl, const(ubyte)* buf, size_t len);
int mbedtls_ssl_close_notify(mbedtls_ssl_context* ssl);
int mbedtls_ssl_set_hostname(mbedtls_ssl_context* ssl, const(char)* hostname);

void mbedtls_ssl_config_init(mbedtls_ssl_config* conf);
void mbedtls_ssl_config_free(mbedtls_ssl_config* conf);
int mbedtls_ssl_config_defaults(mbedtls_ssl_config* conf, int endpoint, int transport, int preset);
void mbedtls_ssl_conf_ca_chain(mbedtls_ssl_config* conf, mbedtls_x509_crt* ca_chain, void* ca_crl);
int mbedtls_ssl_conf_own_cert(mbedtls_ssl_config* conf, mbedtls_x509_crt* own_cert, mbedtls_pk_context* pk_key);
void mbedtls_ssl_conf_authmode(mbedtls_ssl_config* conf, int authmode);

alias mbedtls_ssl_conf_sni_cb = int function(void* p_info, mbedtls_ssl_context* ssl, const(ubyte)* name, size_t name_len) nothrow @nogc;
void mbedtls_ssl_conf_sni(mbedtls_ssl_config* conf, mbedtls_ssl_conf_sni_cb f_sni, void* p_sni);

// Wires the configured RNG into an SSL config. No-op on 4.x (SSL pulls from
// PSA internally); calls mbedtls_ssl_conf_rng with the module-static CTR-DRBG
// on <4.
void urt_ssl_attach_rng(mbedtls_ssl_config* conf);

enum MBEDTLS_SSL_VERIFY_NONE = 0;
enum MBEDTLS_SSL_VERIFY_OPTIONAL = 1;
enum MBEDTLS_SSL_VERIFY_REQUIRED = 2;


// --- sizeof() from urt/internal/mbedtls.c (opaque types too complex to replicate) ---

size_t urt_sizeof_x509_crt();
size_t urt_sizeof_ssl_context();
size_t urt_sizeof_ssl_config();

import urt.mem.alloc;

mbedtls_x509_crt* urt_x509_crt_new()
{
    auto ctx = cast(mbedtls_x509_crt*)alloc(urt_sizeof_x509_crt()).ptr;
    if (ctx)
        mbedtls_x509_crt_init(ctx);
    return ctx;
}

void urt_x509_crt_delete(mbedtls_x509_crt* crt)
{
    if (crt)
    {
        mbedtls_x509_crt_free(crt);
        free((cast(void*)crt)[0..urt_sizeof_x509_crt()]);
    }
}

mbedtls_ssl_context* urt_ssl_new()
{
    auto ctx = cast(mbedtls_ssl_context*)alloc(urt_sizeof_ssl_context()).ptr;
    if (ctx)
        mbedtls_ssl_init(ctx);
    return ctx;
}

void urt_ssl_delete(mbedtls_ssl_context* ssl)
{
    if (ssl)
    {
        mbedtls_ssl_free(ssl);
        free((cast(void*)ssl)[0..urt_sizeof_ssl_context()]);
    }
}

mbedtls_ssl_config* urt_ssl_config_new()
{
    auto ctx = cast(mbedtls_ssl_config*)alloc(urt_sizeof_ssl_config()).ptr;
    if (ctx)
        mbedtls_ssl_config_init(ctx);
    return ctx;
}

void urt_ssl_config_delete(mbedtls_ssl_config* conf)
{
    if (conf)
    {
        mbedtls_ssl_config_free(conf);
        free((cast(void*)conf)[0..urt_sizeof_ssl_config()]);
    }
}
