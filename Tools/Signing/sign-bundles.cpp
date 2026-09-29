#include "common.h"
#include "bundle.h"
#include "openssl.h"
#include "fs.h"
#include <cstdio>
#include <list>
#include <memory>
#include <openssl/pem.h>

// Use zsign's multi-profile traversal with a distinct requested entitlement
// plist for each bundle. The stock CLI shares one -e file across all profiles.
int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--adhoc") == 0) {
        std::list<ZSignAsset> assets(1);
        if (!assets.front().Init(nullptr, nullptr, "", "", true, true, false)) {
            return 1;
        }
        ZBundle bundle;
        return bundle.SignFolder(&assets, argv[2], "", "", "", {}, {}, true, false, false, false) ? 0 : 1;
    }
    if (argc < 7 || (argc - 4) % 3 != 0) {
        std::fprintf(stderr, "Usage: xtool-sign-bundles APP CERT.der KEY.pem PROFILE ENTITLEMENTS DIGESTS ...\n"
                             "       xtool-sign-bundles --adhoc APP\n");
        return 2;
    }
    using BIOPtr = std::unique_ptr<BIO, decltype(&BIO_free)>;
    using CertPtr = std::unique_ptr<X509, decltype(&X509_free)>;
    using KeyPtr = std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)>;
    BIOPtr certInput(BIO_new_file(argv[2], "rb"), BIO_free);
    BIOPtr keyInput(BIO_new_file(argv[3], "rb"), BIO_free);
    if (!certInput || !keyInput) {
        std::fprintf(stderr, "Cannot open certificate/private key\n");
        return 1;
    }
    CertPtr cert(d2i_X509_bio(certInput.get(), nullptr), X509_free);
    KeyPtr key(PEM_read_bio_PrivateKey(keyInput.get(), nullptr, nullptr, nullptr), EVP_PKEY_free);
    if (!cert || !key || X509_check_private_key(cert.get(), key.get()) != 1) {
        std::fprintf(stderr, "Invalid certificate/private key pair\n");
        return 1;
    }
    std::list<ZSignAsset> assets;
    for (int index = 4; index < argc; index += 3) {
        std::string profile;
        std::string entitlements;
        if (!ZFile::ReadFile(argv[index], profile) || !ZFile::ReadFile(argv[index + 1], entitlements)) {
            std::fprintf(stderr, "Cannot read profile or entitlement file\n");
            return 1;
        }
        assets.emplace_back();
        auto &asset = assets.back();
        const bool sha256Only = strcmp(argv[index + 2], "sha256") == 0;
        if (!sha256Only && strcmp(argv[index + 2], "sha1,sha256") != 0) {
            std::fprintf(stderr, "Expected sha256 or sha1,sha256 digest selection\n");
            return 2;
        }
        if (!asset.Init(cert.get(), key.get(), profile, entitlements, false, sha256Only, false)) {
            std::fprintf(stderr, "Cannot initialize distribution identity\n");
            return 1;
        }
        jvalue requested;
        if (!requested.read_plist(entitlements) ||
            requested["application-identifier"].as_string() != asset.m_strApplicationId ||
            requested["com.apple.developer.team-identifier"].as_string() != asset.m_strTeamId ||
            requested["get-task-allow"].as_bool()) {
            std::fprintf(stderr, "Distribution entitlements do not match the profile\n");
            return 1;
        }
    }
    ZBundle bundle;
    return bundle.SignFolder(&assets, argv[1], "", "", "", {}, {}, true, false, false, false) ? 0 : 1;
}
