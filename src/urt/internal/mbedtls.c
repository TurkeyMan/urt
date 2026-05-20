// C wrappers for mbedtls - sizeof() for opaque types, and wrappers for
// functions that access internal struct layouts D cannot safely replicate.

#if !defined(_WIN32)

#include <stddef.h>
#include <string.h>
#include <mbedtls/version.h>

// mbedtls 4.x reorganised around PSA-Crypto. It moved a lot of classic
// primitive headers into <mbedtls/private/...> (still callable but upstream-
// unstable) and deleted entropy/ctr_drbg/ssl_conf_rng entirely from IDF's
// build -- only PSA RNG is exposed there. We hide the divergence here so D
// only sees one urt_* API across all mbedtls versions.
#if MBEDTLS_VERSION_MAJOR >= 4
#include <psa/crypto.h>
#include <mbedtls/private/bignum.h>
#include <mbedtls/private/ecp.h>
#include <mbedtls/private/gcm.h>
#include <mbedtls/private/ecdh.h>
#include <mbedtls/private/aes.h>
#else
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/bignum.h>
#include <mbedtls/ecp.h>
#include <mbedtls/gcm.h>
#include <mbedtls/ecdh.h>
#include <mbedtls/aes.h>
#endif
#include <mbedtls/pk.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/ssl.h>


// =====================================================================
// sizeof() for opaque types -- D-side allocates these via urt_*_new/delete
// =====================================================================

size_t urt_sizeof_x509_crt(void)    { return sizeof(mbedtls_x509_crt); }
size_t urt_sizeof_ssl_context(void) { return sizeof(mbedtls_ssl_context); }
size_t urt_sizeof_ssl_config(void)  { return sizeof(mbedtls_ssl_config); }


// =====================================================================
// RNG layer -- unified across 2.x/3.x/4.x
//
// 4.x: PSA owns the RNG (psa_crypto_init + psa_generate_random).
// <4 : classic entropy + CTR-DRBG, held module-static and lazily seeded.
//
// urt_rng_callback has the (void*, unsigned char*, size_t) shape that
// classic mbedtls APIs (ecdh_compute_shared, etc.) expect as f_rng; the
// p_rng parameter is unused and may be NULL.
// =====================================================================

#if MBEDTLS_VERSION_MAJOR >= 4

int urt_rng_init(void)
{
    static int initialised = 0;
    if (initialised)
        return 0;
    psa_status_t s = psa_crypto_init();
    if (s != PSA_SUCCESS)
        return (int)s;
    initialised = 1;
    return 0;
}

int urt_rng_random(unsigned char *out, size_t len)
{
    int ret = urt_rng_init();
    if (ret != 0)
        return ret;
    psa_status_t s = psa_generate_random(out, len);
    return (s == PSA_SUCCESS) ? 0 : (int)s;
}

int urt_rng_callback(void *p_rng, unsigned char *out, size_t len)
{
    (void)p_rng;
    return urt_rng_random(out, len);
}

void urt_ssl_attach_rng(mbedtls_ssl_config *conf)
{
    // 4.x SSL pulls RNG from PSA internally -- nothing to wire.
    (void)conf;
}

#else

static mbedtls_entropy_context  _urt_entropy;
static mbedtls_ctr_drbg_context _urt_ctr_drbg;
static int _urt_rng_seeded = 0;

/* When MBEDTLS_NO_PLATFORM_ENTROPY is set (embedded configs that strip the
 * /dev/urandom/Windows-RNG auto-poll), mbedtls_entropy_init adds no sources
 * and seed will fail with ENTROPY_SOURCE_FAILED. The platform must supply
 * its own poll function -- on Bouffalo that's the SEC_ENG TRNG driver in
 * urt.driver.bl_common.trng (declared extern(C) urt_platform_entropy_poll). */
#if defined(MBEDTLS_NO_PLATFORM_ENTROPY)
extern int urt_platform_entropy_poll(void *data, unsigned char *output,
                                     size_t len, size_t *olen);
#endif

int urt_rng_init(void)
{
    if (_urt_rng_seeded)
        return 0;
    mbedtls_entropy_init(&_urt_entropy);
#if defined(MBEDTLS_NO_PLATFORM_ENTROPY)
    int es = mbedtls_entropy_add_source(&_urt_entropy, urt_platform_entropy_poll,
                                        NULL, 32, MBEDTLS_ENTROPY_SOURCE_STRONG);
    if (es != 0)
    {
        mbedtls_entropy_free(&_urt_entropy);
        return es;
    }
#endif
    mbedtls_ctr_drbg_init(&_urt_ctr_drbg);
    int ret = mbedtls_ctr_drbg_seed(&_urt_ctr_drbg, mbedtls_entropy_func,
                                     &_urt_entropy, NULL, 0);
    if (ret != 0)
    {
        mbedtls_ctr_drbg_free(&_urt_ctr_drbg);
        mbedtls_entropy_free(&_urt_entropy);
        return ret;
    }
    _urt_rng_seeded = 1;
    return 0;
}

int urt_rng_random(unsigned char *out, size_t len)
{
    int ret = urt_rng_init();
    if (ret != 0)
        return ret;
    return mbedtls_ctr_drbg_random(&_urt_ctr_drbg, out, len);
}

int urt_rng_callback(void *p_rng, unsigned char *out, size_t len)
{
    (void)p_rng;
    return mbedtls_ctr_drbg_random(&_urt_ctr_drbg, out, len);
}

void urt_ssl_attach_rng(mbedtls_ssl_config *conf)
{
    mbedtls_ssl_conf_rng(conf, mbedtls_ctr_drbg_random, &_urt_ctr_drbg);
}

#endif


// =====================================================================
// PK -- ECDSA P-256 generate / sign / import / export
//
// 4.x routes through PSA key handles bridged to mbedtls_pk_context via
// mbedtls_pk_copy_from_psa / mbedtls_pk_import_into_psa.
// <4 pokes mbedtls_ecp_keypair internals directly.
// =====================================================================

#if MBEDTLS_VERSION_MAJOR >= 4

// Build the standard P-256 ECDSA-SHA256 attributes used by all our keys.
static void _urt_p256_attr(psa_key_attributes_t *attr)
{
    *attr = psa_key_attributes_init();
    psa_set_key_type(attr, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
    psa_set_key_bits(attr, 256);
    psa_set_key_usage_flags(attr, PSA_KEY_USAGE_SIGN_HASH
                                | PSA_KEY_USAGE_VERIFY_HASH
                                | PSA_KEY_USAGE_EXPORT);
    psa_set_key_algorithm(attr, PSA_ALG_ECDSA(PSA_ALG_SHA_256));
}

int urt_pk_gen_ec_p256_key(mbedtls_pk_context *pk)
{
    int ret = urt_rng_init();
    if (ret != 0)
        return ret;

    psa_key_attributes_t attr;
    _urt_p256_attr(&attr);

    mbedtls_svc_key_id_t key_id = MBEDTLS_SVC_KEY_ID_INIT;
    psa_status_t s = psa_generate_key(&attr, &key_id);
    if (s != PSA_SUCCESS)
        return (int)s;

    ret = mbedtls_pk_copy_from_psa(key_id, pk);
    // pk_copy_from_psa copies the material; the source PSA key is now redundant.
    psa_destroy_key(key_id);
    return ret;
}

int urt_pk_sign(mbedtls_pk_context *ctx,
                const unsigned char *hash, size_t hash_len,
                unsigned char *sig, size_t sig_size, size_t *sig_len)
{
    return mbedtls_pk_sign(ctx, MBEDTLS_MD_SHA256,
                            hash, hash_len, sig, sig_size, sig_len);
}

int urt_pk_import_ec_p256_key(mbedtls_pk_context *pk,
                               const unsigned char *d, size_t d_len,
                               const unsigned char *xy, size_t xy_len)
{
    // P-256 private key is the 32-byte big-endian d. xy is recomputable.
    (void)xy; (void)xy_len;
    if (d_len != 32)
        return MBEDTLS_ERR_PK_BAD_INPUT_DATA;

    int ret = urt_rng_init();
    if (ret != 0)
        return ret;

    psa_key_attributes_t attr;
    _urt_p256_attr(&attr);

    mbedtls_svc_key_id_t key_id = MBEDTLS_SVC_KEY_ID_INIT;
    psa_status_t s = psa_import_key(&attr, d, d_len, &key_id);
    if (s != PSA_SUCCESS)
        return (int)s;

    ret = mbedtls_pk_copy_from_psa(key_id, pk);
    psa_destroy_key(key_id);
    return ret;
}

int urt_pk_export_privkey_d(mbedtls_pk_context *pk,
                             unsigned char *buf, size_t buflen,
                             size_t *olen)
{
    if (buflen < 32)
        return MBEDTLS_ERR_ECP_BUFFER_TOO_SMALL;

    // Pull the key material out of pk into a fresh PSA handle, export, drop.
    psa_key_attributes_t attr = psa_key_attributes_init();
    psa_set_key_usage_flags(&attr, PSA_KEY_USAGE_EXPORT);
    mbedtls_svc_key_id_t key_id = MBEDTLS_SVC_KEY_ID_INIT;
    int ret = mbedtls_pk_import_into_psa(pk, &attr, &key_id);
    if (ret != 0)
        return ret;

    psa_status_t s = psa_export_key(key_id, buf, buflen, olen);
    psa_destroy_key(key_id);
    return (s == PSA_SUCCESS) ? 0 : (int)s;
}

#else

// Generate an ECDSA P-256 key into a pk context.
// Handles pk_setup + ecp_gen_key internally so D never needs to access
// mbedtls_ecp_keypair or mbedtls_ecp_group, whose layouts are version-dependent.
int urt_pk_gen_ec_p256_key(mbedtls_pk_context *pk)
{
    int ret = urt_rng_init();
    if (ret != 0)
        return ret;
    ret = mbedtls_pk_setup(pk, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY));
    if (ret != 0)
        return ret;
    // mbedtls_pk_ec() is deprecated in 3.1+ but present in all 2.x and 3.x.
    return mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(*pk),
                                urt_rng_callback, NULL);
}

// Always signs with SHA-256. The md_type_t enum values changed between
// mbedtls 2.x and 3.x, so we resolve the correct value here in C.
int urt_pk_sign(mbedtls_pk_context *ctx,
                const unsigned char *hash, size_t hash_len,
                unsigned char *sig, size_t sig_size, size_t *sig_len)
{
#if MBEDTLS_VERSION_MAJOR >= 3
    return mbedtls_pk_sign(ctx, MBEDTLS_MD_SHA256, hash, hash_len,
                            sig, sig_size, sig_len, urt_rng_callback, NULL);
#else
    (void)sig_size;
    return mbedtls_pk_sign(ctx, MBEDTLS_MD_SHA256, hash, hash_len,
                            sig, sig_len, urt_rng_callback, NULL);
#endif
}

// Import raw EC P-256 key components (d, X, Y) into a pk context.
int urt_pk_import_ec_p256_key(mbedtls_pk_context *pk,
                               const unsigned char *d, size_t d_len,
                               const unsigned char *xy, size_t xy_len)
{
    int ret = mbedtls_pk_setup(pk, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY));
    if (ret != 0)
        return ret;

    mbedtls_ecp_keypair *ec = mbedtls_pk_ec(*pk);

#if MBEDTLS_VERSION_MAJOR >= 3
    ret = mbedtls_ecp_group_load(&ec->private_grp, MBEDTLS_ECP_DP_SECP256R1);
    if (ret != 0) return ret;
    ret = mbedtls_mpi_read_binary(&ec->private_d, d, d_len);
    if (ret != 0) return ret;
    // xy is 0x04 || X || Y (65 bytes)
    ret = mbedtls_ecp_point_read_binary(&ec->private_grp, &ec->private_Q, xy, xy_len);
#else
    ret = mbedtls_ecp_group_load(&ec->grp, MBEDTLS_ECP_DP_SECP256R1);
    if (ret != 0) return ret;
    ret = mbedtls_mpi_read_binary(&ec->d, d, d_len);
    if (ret != 0) return ret;
    ret = mbedtls_ecp_point_read_binary(&ec->grp, &ec->Q, xy, xy_len);
#endif
    return ret;
}

// Export the raw private key scalar d (32 bytes for P-256).
int urt_pk_export_privkey_d(mbedtls_pk_context *pk,
                             unsigned char *buf, size_t buflen,
                             size_t *olen)
{
    mbedtls_ecp_keypair *ec = mbedtls_pk_ec(*pk);
#if MBEDTLS_VERSION_MAJOR >= 3
    mbedtls_mpi *d = &ec->private_d;
#else
    mbedtls_mpi *d = &ec->d;
#endif
    size_t len = mbedtls_mpi_size(d);
    if (buflen < len)
        return MBEDTLS_ERR_ECP_BUFFER_TOO_SMALL;
    *olen = len;
    return mbedtls_mpi_write_binary(d, buf, len);
}

#endif


// Export the public key as an uncompressed EC point (0x04 || X || Y).
// mbedtls_pk_write_pubkey_der stays public in 4.x, so this needs no branch.
int urt_pk_export_pubkey_xy(mbedtls_pk_context *pk,
                             unsigned char *buf, size_t buflen,
                             size_t *olen)
{
    unsigned char der[256];
    int len = mbedtls_pk_write_pubkey_der(pk, der, sizeof(der));
    if (len < 0)
        return len;
    // SubjectPublicKeyInfo for P-256 ends with BIT STRING { 04 || X || Y } (65 bytes).
    if (len < 65 || buflen < 65)
        return MBEDTLS_ERR_ECP_BUFFER_TOO_SMALL;
    memcpy(buf, der + sizeof(der) - 65, 65);
    *olen = 65;
    return 0;
}


// =====================================================================
// AES-GCM one-shot encrypt / decrypt
// =====================================================================

int urt_gcm_encrypt(const unsigned char *key, size_t key_len,
                    const unsigned char *iv, size_t iv_len,
                    const unsigned char *aad, size_t aad_len,
                    const unsigned char *plaintext, size_t pt_len,
                    unsigned char *ciphertext,
                    unsigned char *tag, size_t tag_len)
{
    mbedtls_gcm_context ctx;
    mbedtls_gcm_init(&ctx);
    int ret = mbedtls_gcm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, key, (unsigned)(key_len * 8));
    if (ret == 0)
        ret = mbedtls_gcm_crypt_and_tag(&ctx, MBEDTLS_GCM_ENCRYPT, pt_len, iv, iv_len,
                                        aad, aad_len, plaintext, ciphertext, tag_len, tag);
    mbedtls_gcm_free(&ctx);
    return ret;
}

int urt_gcm_decrypt(const unsigned char *key, size_t key_len,
                    const unsigned char *iv, size_t iv_len,
                    const unsigned char *aad, size_t aad_len,
                    const unsigned char *ciphertext, size_t ct_len,
                    const unsigned char *tag, size_t tag_len,
                    unsigned char *plaintext)
{
    mbedtls_gcm_context ctx;
    mbedtls_gcm_init(&ctx);
    int ret = mbedtls_gcm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, key, (unsigned)(key_len * 8));
    if (ret == 0)
        ret = mbedtls_gcm_auth_decrypt(&ctx, ct_len, iv, iv_len, aad, aad_len,
                                       tag, tag_len, ciphertext, plaintext);
    mbedtls_gcm_free(&ctx);
    return ret;
}


// =====================================================================
// AES ECB single-block primitives (used by RFC 3394 key-wrap for the
// WPA2 4-way handshake GTK decryption).
// =====================================================================

int urt_aes_ecb_decrypt(const unsigned char *key, size_t key_len,
                        const unsigned char *cipher_block,
                        unsigned char *plain_block)
{
    mbedtls_aes_context ctx;
    mbedtls_aes_init(&ctx);
    int ret = mbedtls_aes_setkey_dec(&ctx, key, (unsigned)(key_len * 8));
    if (ret == 0)
        ret = mbedtls_aes_crypt_ecb(&ctx, MBEDTLS_AES_DECRYPT, cipher_block, plain_block);
    mbedtls_aes_free(&ctx);
    return ret;
}

int urt_aes_ecb_encrypt(const unsigned char *key, size_t key_len,
                        const unsigned char *plain_block,
                        unsigned char *cipher_block)
{
    mbedtls_aes_context ctx;
    mbedtls_aes_init(&ctx);
    int ret = mbedtls_aes_setkey_enc(&ctx, key, (unsigned)(key_len * 8));
    if (ret == 0)
        ret = mbedtls_aes_crypt_ecb(&ctx, MBEDTLS_AES_ENCRYPT, plain_block, cipher_block);
    mbedtls_aes_free(&ctx);
    return ret;
}


// =====================================================================
// ECDH P-256 raw shared-secret
// =====================================================================

// priv_d:       32-byte big-endian private scalar.
// peer_xy:      64-byte uncompressed peer point (X || Y, no 0x04 prefix).
// shared_x_out: 32 bytes -- big-endian X coordinate of (priv_d * peer_point).
int urt_ecdh_p256_compute_shared(const unsigned char *priv_d, size_t priv_len,
                                  const unsigned char *peer_xy, size_t peer_xy_len,
                                  unsigned char *shared_x_out)
{
    if (priv_len != 32 || peer_xy_len != 64)
        return MBEDTLS_ERR_ECP_BAD_INPUT_DATA;

    int ret = urt_rng_init();
    if (ret != 0)
        return ret;

    mbedtls_ecp_group grp;
    mbedtls_mpi d, z;
    mbedtls_ecp_point Q;

    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_mpi_init(&z);
    mbedtls_ecp_point_init(&Q);

    ret = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1);
    if (ret == 0)
        ret = mbedtls_mpi_read_binary(&d, priv_d, priv_len);
    if (ret == 0)
    {
        unsigned char point[65];
        point[0] = 0x04;
        memcpy(point + 1, peer_xy, 64);
        ret = mbedtls_ecp_point_read_binary(&grp, &Q, point, sizeof(point));
    }
    if (ret == 0)
        ret = mbedtls_ecdh_compute_shared(&grp, &z, &Q, &d, urt_rng_callback, NULL);
    if (ret == 0)
        ret = mbedtls_mpi_write_binary(&z, shared_x_out, 32);

    mbedtls_ecp_point_free(&Q);
    mbedtls_mpi_free(&z);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_group_free(&grp);
    return ret;
}

#endif
