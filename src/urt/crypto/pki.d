module urt.crypto.pki;

import urt.array;
import urt.encoding;
import urt.log;
import urt.mem;
import urt.string;
import urt.time;

nothrow @nogc:

//version = DebugPKI;

enum KeyType
{
    rsa2048,
    ecdsa_p256,
}

struct KeyPair
{
nothrow @nogc:
    version (Windows)
    {
        // CAPI handles (RSA)
        HCRYPTPROV hprov;
        HCRYPTKEY hkey;
        // CNG handles (ECDSA)
        BCRYPT_ALG_HANDLE halg;
        BCRYPT_KEY_HANDLE hcng;
    }

    KeyType type;

    bool valid() const pure
    {
        version (Windows)
            return hprov != 0 || hcng !is null;
        else
            return false;
    }
}

struct CertRef
{
nothrow @nogc:
    version (Windows)
    {
        PCCERT_CONTEXT context;
        HCERTSTORE store;
    }

    bool valid() const pure
    {
        version (Windows)
            return context !is null;
        else
            return false;
    }
}


bool generate_keypair(ref KeyPair kp, KeyType type)
{
    version (Windows)
    {
        DWORD prov_type;
        ALG_ID alg;
        DWORD flags;

        final switch (type)
        {
            case KeyType.rsa2048:
                prov_type = PROV_RSA_AES;
                alg = AT_KEYEXCHANGE;
                flags = (2048 << 16) | CRYPT_EXPORTABLE;
                break;

            case KeyType.ecdsa_p256:
                return generate_ecdsa_p256(kp);
        }

        // Use a named container (not CRYPT_VERIFYCONTEXT) so private key is
        // accessible for signing operations like CSR generation.
        if (!CryptAcquireContextA(&kp.hprov, "openwatt".ptr, null, prov_type, CRYPT_NEWKEYSET))
        {
            // Container already exists, open it
            if (!CryptAcquireContextA(&kp.hprov, "openwatt".ptr, null, prov_type, 0))
            {
                writeError("CryptAcquireContext failed");
                return false;
            }
        }

        if (!CryptGenKey(kp.hprov, alg, flags, &kp.hkey))
        {
            writeError("CryptGenKey failed");
            CryptReleaseContext(kp.hprov, 0);
            kp.hprov = 0;
            return false;
        }

        kp.type = KeyType.rsa2048;
        return true;
    }
    else
    {
        writeError("generate_keypair: not implemented on this platform");
        return false;
    }
}

void free_keypair(ref KeyPair kp)
{
    version (Windows)
    {
        if (kp.hkey != 0)
            CryptDestroyKey(kp.hkey);
        if (kp.hprov != 0)
            CryptReleaseContext(kp.hprov, 0);
        if (kp.hcng !is null)
            BCryptDestroyKey(kp.hcng);
        if (kp.halg !is null)
            BCryptCloseAlgorithmProvider(kp.halg, 0);
        kp.hkey = 0;
        kp.hprov = 0;
        kp.hcng = null;
        kp.halg = null;
    }
}

bool create_self_signed(ref CertRef cert, ref KeyPair key, const(char)[] cn, uint validity_days = 365)
{
    version (Windows)
    {
        if (!key.valid)
        {
            writeError("create_self_signed: invalid key pair");
            return false;
        }

        // Encode "CN=<cn>" as X.500 distinguished name
        char[256] cn_buf = void;
        if (cn.length + 3 >= cn_buf.length)
        {
            writeError("create_self_signed: CN too long");
            return false;
        }
        cn_buf[0 .. 3] = "CN=";
        cn_buf[3 .. 3 + cn.length] = cn[];
        cn_buf[3 + cn.length] = 0;

        ubyte[256] name_buf = void;
        DWORD name_size = name_buf.sizeof;
        if (!CertStrToNameA(X509_ASN_ENCODING, cn_buf.ptr, CERT_X500_NAME_STR, null, name_buf.ptr, &name_size, null))
        {
            writeError("CertStrToName failed");
            return false;
        }

        CERT_NAME_BLOB subject_blob;
        subject_blob.cbData = name_size;
        subject_blob.pbData = name_buf.ptr;

        // Set up key provider info
        CRYPT_KEY_PROV_INFO key_prov_info;
        // Using CRYPT_VERIFYCONTEXT, so container name is null
        key_prov_info.pwszContainerName = null;
        key_prov_info.pwszProvName = null;
        key_prov_info.dwProvType = PROV_RSA_AES;
        key_prov_info.dwKeySpec = AT_KEYEXCHANGE;

        // Compute start/end times
        SYSTEMTIME start_time = void, end_time = void;
        GetSystemTime(&start_time);
        end_time = start_time;

        // Add validity_days worth of time
        // Use FILETIME arithmetic for correctness
        FILETIME ft_start = void;
        SystemTimeToFileTime(&start_time, &ft_start);
        ulong ticks = *cast(ulong*)&ft_start;
        ticks += cast(ulong)validity_days * 24 * 60 * 60 * 10_000_000; // 100ns ticks per day
        FILETIME ft_end = *cast(FILETIME*)&ticks;
        FileTimeToSystemTime(&ft_end, &end_time);

        PCCERT_CONTEXT ctx = CertCreateSelfSignCertificate(
            key.hprov,
            &subject_blob,
            0, // dwFlags
            &key_prov_info,
            null, // default signature algorithm (SHA1withRSA)
            &start_time,
            &end_time,
            null  // no extensions
        );

        if (ctx is null)
        {
            writeError("CertCreateSelfSignCertificate failed");
            return false;
        }

        cert.context = ctx;
        return true;
    }
    else
    {
        writeError("create_self_signed: not implemented on this platform");
        return false;
    }
}

bool load_certificate(ref CertRef cert, const(ubyte)[] cert_data)
{
    version (Windows)
    {
        if (cert_data.length == 0)
        {
            writeError("load_certificate: empty certificate data");
            return false;
        }

        const(ubyte)[] der = cert_data;
        Array!ubyte decoded;

        // Check for PEM encoding
        if (is_pem(cert_data))
        {
            decoded = decode_pem(cert_data);
            if (decoded.length == 0)
            {
                writeError("load_certificate: PEM decode failed");
                return false;
            }
            der = decoded[];
        }

        // Open in-memory cert store
        cert.store = CertOpenStore(
            CERT_STORE_PROV_MEMORY,
            0, // encoding
            0, // hCryptProv
            0, // flags
            null
        );
        if (cert.store is null)
        {
            writeError("CertOpenStore failed");
            return false;
        }

        // Add the DER-encoded certificate
        if (!CertAddEncodedCertificateToStore(
            cert.store,
            X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            der.ptr,
            cast(DWORD)der.length,
            CERT_STORE_ADD_REPLACE_EXISTING,
            cast(PCCERT_CONTEXT*)&cert.context))
        {
            writeError("CertAddEncodedCertificateToStore failed");
            CertCloseStore(cert.store, 0);
            cert.store = null;
            return false;
        }

        return true;
    }
    else
    {
        writeError("load_certificate: not implemented on this platform");
        return false;
    }
}

bool load_private_key(ref KeyPair kp, const(ubyte)[] key_data)
{
    version (Windows)
    {
        if (key_data.length == 0)
        {
            writeError("load_private_key: empty key data");
            return false;
        }

        const(ubyte)[] der = key_data;
        Array!ubyte decoded;

        if (is_pem(key_data))
        {
            decoded = decode_pem(key_data);
            if (decoded.length == 0)
            {
                writeError("load_private_key: PEM decode failed");
                return false;
            }
            der = decoded[];
        }

        // Decode the PKCS#8 or RSA private key DER into a CAPI key blob
        DWORD blob_size = 0;
        // Try PKCS#8 first, then raw RSA
        if (!CryptDecodeObjectEx(
            X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            PKCS_RSA_PRIVATE_KEY,
            der.ptr,
            cast(DWORD)der.length,
            0,
            null,
            null,
            &blob_size))
        {
            // Try PKCS#8 wrapper
            if (!CryptDecodeObjectEx(
                X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
                PKCS_PRIVATE_KEY_INFO,
                der.ptr,
                cast(DWORD)der.length,
                0,
                null,
                null,
                &blob_size))
            {
                writeError("CryptDecodeObjectEx: unsupported key format");
                return false;
            }
        }

        auto blob_buf = Array!ubyte(Alloc, blob_size);
        if (!CryptDecodeObjectEx(
            X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            PKCS_RSA_PRIVATE_KEY,
            der.ptr,
            cast(DWORD)der.length,
            0,
            null,
            blob_buf.ptr,
            &blob_size))
        {
            writeError("CryptDecodeObjectEx: decode failed");
            return false;
        }

        // Acquire a crypto provider with named container for signing support
        if (!CryptAcquireContextA(&kp.hprov, "openwatt".ptr, null, PROV_RSA_AES, CRYPT_NEWKEYSET))
        {
            if (!CryptAcquireContextA(&kp.hprov, "openwatt".ptr, null, PROV_RSA_AES, 0))
            {
                writeError("CryptAcquireContext failed for key import");
                return false;
            }
        }

        // Import the key blob
        if (!CryptImportKey(kp.hprov, blob_buf.ptr, blob_size, 0, CRYPT_EXPORTABLE, &kp.hkey))
        {
            writeError("CryptImportKey failed");
            CryptReleaseContext(kp.hprov, 0);
            kp.hprov = 0;
            return false;
        }

        return true;
    }
    else
    {
        writeError("load_private_key: not implemented on this platform");
        return false;
    }
}

bool associate_key(ref CertRef cert, ref KeyPair key)
{
    version (Windows)
    {
        if (!cert.valid || !key.valid)
        {
            writeError("associate_key: invalid cert or key");
            return false;
        }

        CRYPT_KEY_PROV_INFO key_prov_info;
        key_prov_info.pwszContainerName = null;
        key_prov_info.pwszProvName = null;
        key_prov_info.dwProvType = PROV_RSA_AES;
        key_prov_info.dwKeySpec = AT_KEYEXCHANGE;

        if (!CertSetCertificateContextProperty(
            cert.context,
            CERT_KEY_PROV_INFO_PROP_ID,
            0,
            &key_prov_info))
        {
            writeError("CertSetCertificateContextProperty failed");
            return false;
        }

        return true;
    }
    else
    {
        writeError("associate_key: not implemented on this platform");
        return false;
    }
}

void free_cert(ref CertRef cert)
{
    version (Windows)
    {
        if (cert.context !is null)
            CertFreeCertificateContext(cert.context);
        if (cert.store !is null)
            CertCloseStore(cert.store, 0);
        cert.context = null;
        cert.store = null;
    }
}

SysTime cert_expiry(ref const CertRef cert)
{
    version (Windows)
    {
        if (cert.context is null || cert.context.pCertInfo is null)
            return SysTime();
        return SysTime(*cast(ulong*)&cert.context.pCertInfo.NotAfter);
    }
    else
        return SysTime();
}

void* native_cert_context(ref CertRef cert)
{
    version (Windows)
        return cast(void*)cert.context;
    else
        return null;
}


bool sign_hash(ref KeyPair kp, const(ubyte)[] hash, ref Array!ubyte signature)
{
    version (Windows)
    {
        if (kp.hcng is null)
        {
            writeError("sign_hash: no CNG key (ECDSA only)");
            return false;
        }

        // Get signature size
        ULONG sig_size = 0;
        NTSTATUS status = BCryptSignHash(kp.hcng, null,
            cast(PUCHAR)hash.ptr, cast(ULONG)hash.length,
            null, 0, &sig_size, 0);
        if (status != 0)
        {
            writeError("BCryptSignHash (size query) failed");
            return false;
        }

        signature = Array!ubyte(Alloc, sig_size);
        status = BCryptSignHash(kp.hcng, null,
            cast(PUCHAR)hash.ptr, cast(ULONG)hash.length,
            signature.ptr, sig_size, &sig_size, 0);
        if (status != 0)
        {
            writeError("BCryptSignHash failed");
            signature = Array!ubyte();
            return false;
        }

        signature.resize(sig_size);
        return true;
    }
    else
    {
        writeError("sign_hash: not implemented on this platform");
        return false;
    }
}

// Export the public key from an ECDSA key pair as raw X,Y coordinates.
// Returns 32 bytes of X followed by 32 bytes of Y (64 bytes total for P-256).
bool export_public_key_raw(ref KeyPair kp, ref Array!ubyte x, ref Array!ubyte y)
{
    version (Windows)
    {
        if (kp.hcng is null)
        {
            writeError("export_public_key_raw: no CNG key");
            return false;
        }

        // Get blob size
        ULONG blob_size = 0;
        NTSTATUS status = BCryptExportKey(kp.hcng, null, BCRYPT_ECCPUBLIC_BLOB.ptr,
            null, 0, &blob_size, 0);
        if (status != 0)
        {
            writeError("BCryptExportKey (size query) failed");
            return false;
        }

        auto blob = Array!ubyte(Alloc, blob_size);
        status = BCryptExportKey(kp.hcng, null, BCRYPT_ECCPUBLIC_BLOB.ptr,
            blob.ptr, blob_size, &blob_size, 0);
        if (status != 0)
        {
            writeError("BCryptExportKey failed");
            return false;
        }

        // BCRYPT_ECCKEY_BLOB header: dwMagic(4) + cbKey(4), then X(cbKey) + Y(cbKey)
        if (blob_size < 8)
        {
            writeError("export_public_key_raw: blob too small");
            return false;
        }

        auto hdr = cast(BCRYPT_ECCKEY_BLOB*)blob.ptr;
        ULONG key_len = hdr.cbKey;
        if (blob_size < 8 + 2 * key_len)
        {
            writeError("export_public_key_raw: blob size mismatch");
            return false;
        }

        x = blob[8 .. 8 + key_len];
        y = blob[8 + key_len .. 8 + 2 * key_len];
        return true;
    }
    else
    {
        writeError("export_public_key_raw: not implemented on this platform");
        return false;
    }
}


// Generate a DER-encoded PKCS#10 Certificate Signing Request.
Array!ubyte generate_csr(ref KeyPair kp, const(char)[] cn)
{
    version (Windows)
    {
        if (!kp.valid)
        {
            writeError("generate_csr: invalid key pair");
            return Array!ubyte();
        }

        // Encode "CN=<cn>" as X.500 distinguished name
        char[256] cn_buf = void;
        if (cn.length + 3 >= cn_buf.length)
        {
            writeError("generate_csr: CN too long");
            return Array!ubyte();
        }
        cn_buf[0 .. 3] = "CN=";
        cn_buf[3 .. 3 + cn.length] = cn[];
        cn_buf[3 + cn.length] = 0;

        ubyte[256] name_buf = void;
        DWORD name_size = name_buf.sizeof;
        if (!CertStrToNameA(X509_ASN_ENCODING, cn_buf.ptr, CERT_X500_NAME_STR, null, name_buf.ptr, &name_size, null))
        {
            writeError("generate_csr: CertStrToName failed");
            return Array!ubyte();
        }

        CERT_NAME_BLOB subject_blob;
        subject_blob.cbData = name_size;
        subject_blob.pbData = name_buf.ptr;

        // Build CSR info
        CERT_REQUEST_INFO req_info;
        req_info.dwVersion = CERT_REQUEST_V1;
        req_info.Subject = subject_blob;

        // Get public key info from the crypto provider
        DWORD pub_info_size = 0;
        if (!CryptExportPublicKeyInfo(kp.hprov, AT_KEYEXCHANGE, X509_ASN_ENCODING, null, &pub_info_size))
        {
            writeErrorf("generate_csr: CryptExportPublicKeyInfo size query failed, err={0,08x}", GetLastError());
            return Array!ubyte();
        }
        auto pub_info_buf = Array!ubyte(Alloc, pub_info_size);
        if (!CryptExportPublicKeyInfo(kp.hprov, AT_KEYEXCHANGE, X509_ASN_ENCODING,
            cast(CERT_PUBLIC_KEY_INFO*)pub_info_buf.ptr, &pub_info_size))
        {
            writeErrorf("generate_csr: CryptExportPublicKeyInfo failed, err={0,08x}", GetLastError());
            return Array!ubyte();
        }
        req_info.SubjectPublicKeyInfo = *cast(CERT_PUBLIC_KEY_INFO*)pub_info_buf.ptr;

        // Sign the CSR
        CRYPT_ALGORITHM_IDENTIFIER sig_alg;
        sig_alg.pszObjId = cast(LPSTR)szOID_RSA_SHA256RSA.ptr;

        DWORD csr_size = 0;
        if (!CryptSignAndEncodeCertificate(kp.hprov, AT_KEYEXCHANGE,
            X509_ASN_ENCODING, X509_CERT_REQUEST_TO_BE_SIGNED,
            &req_info, &sig_alg, null, null, &csr_size))
        {
            writeErrorf("generate_csr: CryptSignAndEncodeCertificate size query failed, err={0,08x}", GetLastError());
            return Array!ubyte();
        }

        auto csr = Array!ubyte(Alloc, csr_size);
        if (!CryptSignAndEncodeCertificate(kp.hprov, AT_KEYEXCHANGE,
            X509_ASN_ENCODING, X509_CERT_REQUEST_TO_BE_SIGNED,
            &req_info, &sig_alg, null, csr.ptr, &csr_size))
        {
            writeErrorf("generate_csr: CryptSignAndEncodeCertificate failed, err={0,08x}", GetLastError());
            return Array!ubyte();
        }

        csr.resize(csr_size);
        return csr;
    }
    else
    {
        writeError("generate_csr: not implemented on this platform");
        return Array!ubyte();
    }
}


/// Export the private key from a key pair as DER-encoded PKCS#1 bytes.
/// Only supports RSA keys (CAPI path).
bool export_private_key(ref KeyPair kp, ref Array!ubyte der_out)
{
    version (Windows)
    {
        if (kp.hkey == 0)
        {
            writeError("export_private_key: no CAPI key (RSA only)");
            return false;
        }

        // Export the key as a Microsoft private key blob
        DWORD blob_size = 0;
        if (!CryptExportKey(kp.hkey, 0, PRIVATEKEYBLOB, 0, null, &blob_size))
        {
            writeError("export_private_key: CryptExportKey size query failed");
            return false;
        }

        auto blob = Array!ubyte(Alloc, blob_size);
        if (!CryptExportKey(kp.hkey, 0, PRIVATEKEYBLOB, 0, blob.ptr, &blob_size))
        {
            writeError("export_private_key: CryptExportKey failed");
            return false;
        }

        // Encode the Microsoft blob as standard PKCS#1 DER
        DWORD der_size = 0;
        if (!CryptEncodeObjectEx(
            X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            PKCS_RSA_PRIVATE_KEY,
            blob.ptr,
            0,
            null,
            null,
            &der_size))
        {
            writeError("export_private_key: CryptEncodeObjectEx size query failed");
            return false;
        }

        der_out = Array!ubyte(Alloc, der_size);
        if (!CryptEncodeObjectEx(
            X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            PKCS_RSA_PRIVATE_KEY,
            blob.ptr,
            0,
            null,
            der_out.ptr,
            &der_size))
        {
            writeError("export_private_key: CryptEncodeObjectEx failed");
            der_out = Array!ubyte();
            return false;
        }

        der_out.resize(der_size);
        return true;
    }
    else
    {
        writeError("export_private_key: not implemented on this platform");
        return false;
    }
}

/// Encode DER bytes as PEM with the given label (e.g., "RSA PRIVATE KEY").
Array!ubyte encode_pem(const(ubyte)[] der, const(char)[] label)
{
    import urt.encoding : base64_encode, base64_encode_length;

    Array!ubyte result;

    // Header
    result.concat(cast(const(ubyte)[])"-----BEGIN ");
    result.concat(cast(const(ubyte)[])label);
    result.concat(cast(const(ubyte)[])"-----\n");

    // Base64 body in 64-char lines
    size_t enc_len = base64_encode_length(der.length);
    auto b64 = Array!char(Alloc, enc_len);
    base64_encode(der, b64[0 .. enc_len]);

    size_t pos = 0;
    while (pos < enc_len)
    {
        size_t line_len = enc_len - pos;
        if (line_len > 64)
            line_len = 64;
        result.concat(cast(const(ubyte)[])b64[pos .. pos + line_len]);
        result.concat(cast(const(ubyte)[])"\n");
        pos += line_len;
    }

    // Footer
    result.concat(cast(const(ubyte)[])"-----END ");
    result.concat(cast(const(ubyte)[])label);
    result.concat(cast(const(ubyte)[])"-----\n");

    return result;
}

/// Export ECDSA P-256 private key as a raw BCRYPT_ECCPRIVATE_BLOB.
bool export_ecdsa_private_key(ref KeyPair kp, ref Array!ubyte blob_out)
{
    version (Windows)
    {
        if (kp.hcng is null)
        {
            writeError("export_ecdsa_private_key: no CNG key");
            return false;
        }

        ULONG blob_size = 0;
        NTSTATUS status = BCryptExportKey(kp.hcng, null, BCRYPT_ECCPRIVATE_BLOB.ptr,
            null, 0, &blob_size, 0);
        if (status != 0)
        {
            writeError("export_ecdsa_private_key: BCryptExportKey size query failed");
            return false;
        }

        blob_out = Array!ubyte(Alloc, blob_size);
        status = BCryptExportKey(kp.hcng, null, BCRYPT_ECCPRIVATE_BLOB.ptr,
            blob_out.ptr, blob_size, &blob_size, 0);
        if (status != 0)
        {
            writeError("export_ecdsa_private_key: BCryptExportKey failed");
            blob_out.clear();
            return false;
        }

        blob_out.resize(blob_size);
        return true;
    }
    else
    {
        writeError("export_ecdsa_private_key: not implemented on this platform");
        return false;
    }
}

/// Import ECDSA P-256 private key from a raw BCRYPT_ECCPRIVATE_BLOB.
bool import_ecdsa_private_key(ref KeyPair kp, const(ubyte)[] blob_data)
{
    version (Windows)
    {
        NTSTATUS status = BCryptOpenAlgorithmProvider(&kp.halg, BCRYPT_ECDSA_P256_ALGORITHM.ptr, null, 0);
        if (status != 0)
        {
            writeError("import_ecdsa_private_key: BCryptOpenAlgorithmProvider failed");
            return false;
        }

        status = BCryptImportKeyPair(kp.halg, null, BCRYPT_ECCPRIVATE_BLOB.ptr,
            &kp.hcng, cast(ubyte*)blob_data.ptr, cast(ULONG)blob_data.length, 0);
        if (status != 0)
        {
            writeError("import_ecdsa_private_key: BCryptImportKeyPair failed");
            BCryptCloseAlgorithmProvider(kp.halg, 0);
            kp.halg = null;
            return false;
        }

        kp.type = KeyType.ecdsa_p256;
        return true;
    }
    else
    {
        writeError("import_ecdsa_private_key: not implemented on this platform");
        return false;
    }
}


private:

bool generate_ecdsa_p256(ref KeyPair kp)
{
    version (Windows)
    {
        NTSTATUS status = BCryptOpenAlgorithmProvider(&kp.halg, BCRYPT_ECDSA_P256_ALGORITHM.ptr, null, 0);
        if (status != 0)
        {
            writeError("BCryptOpenAlgorithmProvider(ECDSA_P256) failed");
            return false;
        }

        status = BCryptGenerateKeyPair(kp.halg, &kp.hcng, 256, 0);
        if (status != 0)
        {
            writeError("BCryptGenerateKeyPair failed");
            BCryptCloseAlgorithmProvider(kp.halg, 0);
            kp.halg = null;
            return false;
        }

        status = BCryptFinalizeKeyPair(kp.hcng, 0);
        if (status != 0)
        {
            writeError("BCryptFinalizeKeyPair failed");
            BCryptDestroyKey(kp.hcng);
            kp.hcng = null;
            BCryptCloseAlgorithmProvider(kp.halg, 0);
            kp.halg = null;
            return false;
        }

        kp.type = KeyType.ecdsa_p256;
        return true;
    }
    else
    {
        writeError("generate_ecdsa_p256: not implemented on this platform");
        return false;
    }
}

bool is_pem(const(ubyte)[] data)
{
    return data.length >= 11 && (cast(const(char)[])data[0 .. 11]) == "-----BEGIN ";
}

Array!ubyte decode_pem(const(ubyte)[] data)
{
    auto text = cast(const(char)[])data;

    // Find end of first line (header)
    size_t start = 0;
    while (start < text.length && text[start] != '\n')
        ++start;
    if (start < text.length)
        ++start; // skip \n

    // Find "-----END" marker
    size_t end = start;
    while (end + 5 < text.length)
    {
        if (text[end .. end + 5] == "-----")
            break;
        ++end;
    }

    if (end <= start)
        return Array!ubyte();

    // Strip whitespace and decode base64
    // First pass: count non-whitespace characters
    size_t b64_len = 0;
    for (size_t i = start; i < end; ++i)
    {
        if (text[i] != '\r' && text[i] != '\n' && text[i] != ' ')
            ++b64_len;
    }

    // Second pass: copy to contiguous buffer and decode
    auto b64_buf = Array!char(Alloc, b64_len);
    size_t j = 0;
    for (size_t i = start; i < end; ++i)
    {
        if (text[i] != '\r' && text[i] != '\n' && text[i] != ' ')
            b64_buf.ptr[j++] = text[i];
    }

    // Decode
    auto result = Array!ubyte(Alloc, base64_decode_length(b64_len));
    ptrdiff_t decoded_len = base64_decode(b64_buf[], result[]);
    if (decoded_len < 0)
        return Array!ubyte();

    result.resize(decoded_len);
    return result;
}

version (Windows)
{
    import core.sys.windows.bcrypt;
    import core.sys.windows.ntdef : NTSTATUS;
    import core.sys.windows.wincrypt;
    import core.sys.windows.windef;
    import core.sys.windows.winbase;

    pragma(lib, "Advapi32");
    pragma(lib, "Bcrypt");
    pragma(lib, "Crypt32");

    // Constants not in D runtime
    enum LPCSTR CERT_STORE_PROV_MEMORY = cast(LPCSTR)2;
    enum DWORD CERT_STORE_ADD_REPLACE_EXISTING = 3;
    enum DWORD CERT_X500_NAME_STR = 3;
    enum DWORD CERT_KEY_PROV_INFO_PROP_ID = 2;
    enum LPCSTR PKCS_RSA_PRIVATE_KEY = cast(LPCSTR)43;
    enum LPCSTR PKCS_PRIVATE_KEY_INFO = cast(LPCSTR)44;

    // Structs not in D runtime
    struct CRYPT_KEY_PROV_INFO
    {
        LPWSTR pwszContainerName;
        LPWSTR pwszProvName;
        DWORD dwProvType;
        DWORD dwFlags;
        DWORD cProvParam;
        void* rgProvParam; // CRYPT_KEY_PROV_PARAM*
        DWORD dwKeySpec;
    }

    // CSR-related structs and constants
    struct CERT_REQUEST_INFO
    {
        DWORD dwVersion;
        CERT_NAME_BLOB Subject;
        CERT_PUBLIC_KEY_INFO SubjectPublicKeyInfo;
        DWORD cAttribute;
        void* rgAttribute; // CRYPT_ATTRIBUTE*
    }

    enum CERT_REQUEST_V1 = 0;
    enum LPCSTR X509_CERT_REQUEST_TO_BE_SIGNED = cast(LPCSTR)4;
    enum szOID_RSA_SHA256RSA = "1.2.840.113549.1.1.11";

    // Functions not in D runtime
    extern (Windows) @nogc nothrow
    {
        BOOL CryptExportPublicKeyInfo(
            HCRYPTPROV hCryptProv,
            DWORD dwKeySpec,
            DWORD dwCertEncodingType,
            CERT_PUBLIC_KEY_INFO* pInfo,
            DWORD* pcbInfo
        );

        BOOL CryptSignAndEncodeCertificate(
            HCRYPTPROV hCryptProv,
            DWORD dwKeySpec,
            DWORD dwCertEncodingType,
            LPCSTR lpszStructType,
            const(void)* pvStructInfo,
            CRYPT_ALGORITHM_IDENTIFIER* pSignatureAlgorithm,
            const(void)* pvHashAuxInfo,
            BYTE* pbEncoded,
            DWORD* pcbEncoded
        );
        PCCERT_CONTEXT CertCreateSelfSignCertificate(
            HCRYPTPROV hCryptProvOrNCryptKey,
            PCERT_NAME_BLOB pSubjectIssuerBlob,
            DWORD dwFlags,
            CRYPT_KEY_PROV_INFO* pKeyProvParam,
            CRYPT_ALGORITHM_IDENTIFIER* pSignatureAlgorithm,
            SYSTEMTIME* pStartTime,
            SYSTEMTIME* pEndTime,
            void* pExtensions // PCERT_EXTENSIONS
        );

        BOOL CertStrToNameA(
            DWORD dwCertEncodingType,
            LPCSTR pszX500,
            DWORD dwStrType,
            void* pvReserved,
            BYTE* pbEncoded,
            DWORD* pcbEncoded,
            LPCSTR* ppszError
        );

        BOOL CertAddEncodedCertificateToStore(
            HCERTSTORE hCertStore,
            DWORD dwCertEncodingType,
            const(BYTE)* pbCertEncoded,
            DWORD cbCertEncoded,
            DWORD dwAddDisposition,
            PCCERT_CONTEXT* ppCertContext
        );

        BOOL CertSetCertificateContextProperty(
            PCCERT_CONTEXT pCertContext,
            DWORD dwPropId,
            DWORD dwFlags,
            const(void)* pvData
        );

        BOOL CryptDecodeObjectEx(
            DWORD dwCertEncodingType,
            LPCSTR lpszStructType,
            const(BYTE)* pbEncoded,
            DWORD cbEncoded,
            DWORD dwFlags,
            void* pDecodePara, // PCRYPT_DECODE_PARA
            void* pvStructInfo,
            DWORD* pcbStructInfo
        );

        BOOL CryptEncodeObjectEx(
            DWORD dwCertEncodingType,
            LPCSTR lpszStructType,
            const(void)* pvStructInfo,
            DWORD dwFlags,
            void* pEncodePara, // PCRYPT_ENCODE_PARA
            void* pvEncoded,
            DWORD* pcbEncoded
        );
    }
}
