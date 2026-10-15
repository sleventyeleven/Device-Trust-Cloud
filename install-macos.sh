#!/bin/bash
# Device Trust Certificate Installation Script for macOS
# This script automates the installation of scepclient and requests a device trust certificate

set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SCEP_SERVER_URL="${SCEP_SERVER_URL:-https://step-ca.example.com}"
SCEP_PROVISIONER="${SCEP_PROVISIONER:-poc_devicetrust}"
SCEP_CHALLENGE="${SCEP_CHALLENGE:-your-secret-challenge}"
CERT_COUNTRY="${CERT_COUNTRY:-US}"
CERT_ORGANIZATION="${CERT_ORGANIZATION:-DeviceTrust}"
CERT_OU="${CERT_OU:-DeviceTrust}"
# Either a URL to fetch the root/intermediate CA from, or a path to an
# already-downloaded local copy (e.g.
# `terraform output -raw root_ca_certificate > root-ca.crt`).
ROOT_CA_URL="${ROOT_CA_URL:-}"
ROOT_CA_FILE_SRC="${ROOT_CA_FILE_SRC:-}"
INTERMEDIATE_CA_URL="${INTERMEDIATE_CA_URL:-}"
INTERMEDIATE_CA_FILE_SRC="${INTERMEDIATE_CA_FILE_SRC:-}"
# Optional: if set, a real mTLS request is made against this URL after
# installation using the just-issued cert, mirroring install-windows.ps1's
# own PASS/FAIL test.
MTLS_GATEWAY_URL="${MTLS_GATEWAY_URL:-}"

# Per-device SCEP challenges (optional, needs the webhook in webhook/README.md;
# leave all four unset and this script behaves exactly as it always has,
# sending the single static SCEP_CHALLENGE to SCEP_PROVISIONER):
#   SCEP_PHRASE             The current enrollment phrase. The challenge sent is
#                           then computed from this Mac's serial number:
#                           base64(HMAC-SHA256(phrase, "device-trust-scep-challenge-v1\n" + SERIAL)).
#   SCEP_RENEW_PROVISIONER  The renewal provisioner (device-trust-scep-renew with
#                           the Terraform webhook). When this is set and the key
#                           from the last run is still on disk (KEY_PROTECTION=
#                           RestrictPermissions), the run renews with that same
#                           key and needs no phrase.
#   SCEP_ATTEMPTS           How often a failed scepclient call is tried (default 3).
#                           scepclient occasionally fails on its own signature
#                           before the request reaches step-ca; a retry works and
#                           retrying a refused request is harmless.
SCEP_PHRASE="${SCEP_PHRASE:-}"
SCEP_RENEW_PROVISIONER="${SCEP_RENEW_PROVISIONER:-}"
SCEP_ATTEMPTS="${SCEP_ATTEMPTS:-3}"
# What to do with the loose private key once it is in the keychain (the same two
# modes as install-windows.ps1 -KeyProtection):
#   Delete               Remove the key, certificate and cached CSR files after the
#                        import. The key then lives only in the keychain
#                        (non-exportable) and the next run is a full re-enrollment
#                        with a new key.
#   RestrictPermissions  Keep the key (mode 600) so the next run can renew with the
#                        same key. On macOS this does NOT hide the key from the
#                        logged-in user: scepclient has to run as that user so it
#                        can see the CA trust settings in their keychain, which
#                        means the key must stay readable by them. Prefer Delete
#                        for devices whose users you do not fully trust.
# Unset (the default) leaves the files exactly as this script always has: the key
# and certificate stay in $CERT_DIR with their default permissions.
KEY_PROTECTION="${KEY_PROTECTION:-}"
# Testing / air-gapped use: reuse scepclient and step already installed in
# $INSTALL_DIR instead of downloading the latest releases every run.
SKIP_TOOL_DOWNLOAD="${SKIP_TOOL_DOWNLOAD:-}"
case "$KEY_PROTECTION" in
    ""|Delete|RestrictPermissions) ;;
    *) printf "${RED}Error: KEY_PROTECTION must be Delete or RestrictPermissions, or unset (got '%s')${NC}\n" "$KEY_PROTECTION"; exit 1 ;;
esac

# This script needs root (via sudo -E) to write to /usr/local/bin, but the
# root/intermediate CA trust settings, the device certificate/key, and the
# scepclient process that requests them all need to run as the *actual
# invoking user*, not root - root has no login keychain of its own, and
# critically, scepclient's own TLS verification of the gateway's certificate
# consults whichever keychain belongs to the process's *current* user, so it
# has to run as the person who actually owns the trust settings we just
# installed, not as root. $SUDO_USER is set automatically by sudo to the
# invoking user.
TARGET_USER="${SUDO_USER:-$(whoami)}"
TARGET_HOME=$(eval echo "~${TARGET_USER}")
if [ "$TARGET_USER" = "root" ]; then
    printf "${YELLOW}Warning: could not determine the invoking (non-root) user - run this script via 'sudo -E', not as root directly, so the certificate can be installed into the right person's login keychain.${NC}\n"
fi
LOGIN_KEYCHAIN=$(sudo -u "$TARGET_USER" security default-keychain -d user 2>/dev/null | tr -d ' "')
if [ -z "$LOGIN_KEYCHAIN" ]; then
    LOGIN_KEYCHAIN="${TARGET_HOME}/Library/Keychains/login.keychain-db"
fi

# Installation Paths
INSTALL_DIR="/usr/local/bin"
# A per-user directory, not /etc - scepclient has to run as $TARGET_USER
# (see above), so it needs to be able to write its own key/cert files here
# without needing root for every run.
CERT_DIR="${TARGET_HOME}/.device-trust"
ROOT_CA_FILE="${CERT_DIR}/root-ca.crt"
INTERMEDIATE_CA_FILE="${CERT_DIR}/intermediate-ca.crt"
PRIVATE_KEY_FILE="${CERT_DIR}/client.key"
CERT_FILE="${CERT_DIR}/client.crt"
FULL_CHAIN_FILE="${CERT_DIR}/full-chain.pem"

# Detect hostname for DNS name
HOSTNAME=$(hostname -s)

# Owned by the target user from creation, not root, since everything written
# into it from here on (scepclient's own output included) needs to be
# readable/writable by that user, not just root.
sudo -u "$TARGET_USER" mkdir -p "$CERT_DIR"

# This script is safe to re-run: scepclient reuses the existing private key
# file if present, so a second run is a same-key renewal, not a fresh
# identity. It also always re-fetches the latest scepclient release, so the
# client binary stays current on every run. Determined before the banner
# below prints, since it's referenced there.
IS_RENEWAL=0
if [ -f "$CERT_FILE" ]; then
    IS_RENEWAL=1
fi
# Is the key from the last run still here? Only then can this run reuse it
# (KEY_PROTECTION=Delete removes it, so every run starts a new key).
HAVE_KEY=0
if [ -f "$PRIVATE_KEY_FILE" ] && [ -f "$CERT_FILE" ]; then
    HAVE_KEY=1
fi

echo "========================================"
echo "Device Trust Certificate Installation"
echo "========================================"
echo ""
if [ "$HAVE_KEY" -eq 1 ]; then
    printf "${YELLOW}Existing device certificate and key found - this run will renew it (same key).${NC}\n"
elif [ "$IS_RENEWAL" -eq 1 ]; then
    printf "${YELLOW}Existing device certificate found but no key to reuse - this run enrolls with a new key.${NC}\n"
else
    printf "${YELLOW}No existing device certificate found - this is a first-time enrollment.${NC}\n"
fi
echo ""

# Detect CPU architecture. Anything that isn't explicitly Intel is treated as
# Apple Silicon (arm64) rather than assumed to be amd64 - Apple Silicon is
# the forward-looking default, and Rosetta 2 (needed to run an amd64 binary
# on arm64) isn't installed by default on new Macs, so guessing amd64 wrong
# fails hard ("Bad CPU type in executable") rather than just being slow.
case "$(uname -m)" in
    x86_64) SCEP_ARCH="amd64" ;;
    *) SCEP_ARCH="arm64" ;;
esac

echo "Configuration:"
echo "- SCEP Server: $SCEP_SERVER_URL"
echo "- Provisioner: $SCEP_PROVISIONER"
[ -n "$SCEP_RENEW_PROVISIONER" ] && echo "- Renewal provisioner: $SCEP_RENEW_PROVISIONER"
[ -n "$KEY_PROTECTION" ] && echo "- Key protection: $KEY_PROTECTION"
echo "- Hostname: $HOSTNAME"
echo "- Architecture: $(uname -m) (using scepclient-darwin-${SCEP_ARCH})"
echo "- Target user: $TARGET_USER"
echo "- Cert Directory: $CERT_DIR"
echo ""

if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
    printf "${RED}Error: neither curl nor wget is installed${NC}\n"
    exit 1
fi

fetch_url() {
    # fetch_url <url> <output-path>
    if command -v curl &> /dev/null; then
        curl -sL -o "$2" "$1"
    else
        wget -q -O "$2" "$1"
    fi
}

# Download scepclient for macOS. Releases ship as a versioned zip
# (scepclient-darwin-<arch>-vX.Y.Z.zip) containing the scepclient-darwin-<arch>
# binary, so the asset must be discovered via the GitHub API rather than a
# fixed URL (no unversioned asset exists to link directly).
if [ -n "$SKIP_TOOL_DOWNLOAD" ] && [ -x "$INSTALL_DIR/scepclient" ] && [ -x "$INSTALL_DIR/step" ]; then
    echo "SKIP_TOOL_DOWNLOAD is set: using the scepclient and step already in $INSTALL_DIR."
    STEP_TOOL="$INSTALL_DIR/step"
else
    echo "Downloading scepclient for macOS (${SCEP_ARCH})..."

    RELEASE_JSON=$(curl -sL "https://api.github.com/repos/micromdm/scep/releases/latest" 2>/dev/null || wget -qO- "https://api.github.com/repos/micromdm/scep/releases/latest")
    ASSET_URL=$(echo "$RELEASE_JSON" | grep -o "\"browser_download_url\": *\"[^\"]*scepclient-darwin-${SCEP_ARCH}-[^\"]*\.zip\"" | head -1 | grep -o 'https://[^"]*')

    if [ -z "$ASSET_URL" ]; then
        printf "${RED}Error: could not find a scepclient-darwin-${SCEP_ARCH} release asset${NC}\n"
        exit 1
    fi

    # A directory template, not "prefix.XXXXXX.zip" - macOS's BSD mktemp
    # doesn't reliably substitute the X's when followed by a literal suffix
    # (confirmed live elsewhere in this script - see the PKCS#12 packaging
    # section below), silently reusing the same fixed path across runs.
    TMP_DL_DIR=$(mktemp -d -t scepclient-dl.XXXXXX)
    TMP_ZIP="${TMP_DL_DIR}/scepclient.zip"
    fetch_url "$ASSET_URL" "$TMP_ZIP"
    unzip -o -q "$TMP_ZIP" -d "$INSTALL_DIR"
    mv "$INSTALL_DIR/scepclient-darwin-${SCEP_ARCH}" "$INSTALL_DIR/scepclient"
    rm -rf "$TMP_DL_DIR"
    chmod +x "$INSTALL_DIR/scepclient"

    printf "${GREEN}scepclient downloaded successfully${NC}\n"
    echo ""

    # Download step CLI (smallstep's own tool). Used purely for its
    # "certificate p12" subcommand, to combine scepclient's PEM cert+key(+chain)
    # into a PKCS#12 bundle that `security import` can load into the keychain -
    # same reasoning as the Windows script's use of step for its PFX packaging.
    echo "Downloading step CLI (${SCEP_ARCH})..."
    STEP_TOOL="$INSTALL_DIR/step"
    TMP_STEP_DIR=$(mktemp -d -t step-extract.XXXXXX)
    TMP_TAR="${TMP_STEP_DIR}/step.tar.gz"
    fetch_url "https://dl.smallstep.com/cli/docs-cli-install/latest/step_darwin_${SCEP_ARCH}.tar.gz" "$TMP_TAR"
    tar -xzf "$TMP_TAR" -C "$TMP_STEP_DIR"
    STEP_BIN_PATH=$(find "$TMP_STEP_DIR" -type f -name step -perm -u+x | head -1)
    if [ -z "$STEP_BIN_PATH" ]; then
        STEP_BIN_PATH=$(find "$TMP_STEP_DIR" -type f -name step | head -1)
    fi
    cp "$STEP_BIN_PATH" "$STEP_TOOL"
    chmod +x "$STEP_TOOL"
    rm -rf "$TMP_TAR" "$TMP_STEP_DIR"

    printf "${GREEN}step CLI downloaded successfully${NC}\n"
    echo ""
fi

# Install root CA certificate
echo "Installing root CA certificate..."
set +e  # Don't exit on error for certificate installation

if [ -n "$ROOT_CA_FILE_SRC" ] && [ -f "$ROOT_CA_FILE_SRC" ]; then
    echo "Using local root CA file: $ROOT_CA_FILE_SRC"
    cp "$ROOT_CA_FILE_SRC" "$ROOT_CA_FILE"
elif [ -n "$ROOT_CA_URL" ]; then
    echo "Downloading root CA from: $ROOT_CA_URL"
    fetch_url "$ROOT_CA_URL" "$ROOT_CA_FILE"
else
    printf "${YELLOW}Note: neither ROOT_CA_FILE_SRC nor ROOT_CA_URL is set${NC}\n"
    echo "The root CA certificate must be manually installed."
fi
# Written by this (root) process into the user's own $CERT_DIR - fix
# ownership so $TARGET_USER can read it later (e.g. for the PKCS#12 --ca
# bundle step, which runs as that user).
[ -f "$ROOT_CA_FILE" ] && chown "$TARGET_USER" "$ROOT_CA_FILE"

# Fetch the intermediate CA too - needed to bundle the full chain into the
# device cert's PKCS#12 below (so the keychain doesn't have to rely on AIA
# fetching to build the chain during ClientAuth). If not explicitly
# provided, derive it automatically from the SCEP server's own GetCACert
# response - the same operation scepclient itself calls first, already
# public (no additional trust needed to fetch it), and returns the full
# chain (this deployment's step-ca returns both the SCEP decrypter cert and
# the intermediate CA cert as a "certs-only" PKCS#7 bundle).
if [ -n "$INTERMEDIATE_CA_FILE_SRC" ] && [ -f "$INTERMEDIATE_CA_FILE_SRC" ]; then
    echo "Using local intermediate CA file: $INTERMEDIATE_CA_FILE_SRC"
    cp "$INTERMEDIATE_CA_FILE_SRC" "$INTERMEDIATE_CA_FILE"
elif [ -n "$INTERMEDIATE_CA_URL" ]; then
    echo "Downloading intermediate CA from: $INTERMEDIATE_CA_URL"
    fetch_url "$INTERMEDIATE_CA_URL" "$INTERMEDIATE_CA_FILE"
else
    echo "No INTERMEDIATE_CA_FILE_SRC/INTERMEDIATE_CA_URL set - deriving the intermediate CA automatically from the SCEP server's GetCACert response..."
    GETCACERT_URL="${SCEP_SERVER_URL}/scep/${SCEP_PROVISIONER}?operation=GetCACert"
    TMP_CACERT_SPLIT_DIR=$(mktemp -d -t getcacert.XXXXXX)
    TMP_CACERT_DER="${TMP_CACERT_SPLIT_DIR}/getcacert.der"
    TMP_CACERT_BUNDLE="${TMP_CACERT_SPLIT_DIR}/getcacert-bundle.pem"
    # -k: the gateway's own TLS certificate isn't trusted yet at this point
    # (that's what we're bootstrapping) - this is the same "chicken and egg"
    # bypass scepclient's own internal client makes for this one operation.
    curl -sk -o "$TMP_CACERT_DER" "$GETCACERT_URL"
    if openssl pkcs7 -inform DER -in "$TMP_CACERT_DER" -print_certs -out "$TMP_CACERT_BUNDLE" 2>/dev/null; then
        awk -v dir="$TMP_CACERT_SPLIT_DIR" '/-----BEGIN CERTIFICATE-----/{n++} {print > (dir "/cert-" n ".pem")}' "$TMP_CACERT_BUNDLE"
        for CERT_CANDIDATE in "$TMP_CACERT_SPLIT_DIR"/cert-*.pem; do
            if openssl x509 -in "$CERT_CANDIDATE" -noout -text 2>/dev/null | grep -q "CA:TRUE"; then
                cp "$CERT_CANDIDATE" "$INTERMEDIATE_CA_FILE"
                printf "${GREEN}Derived intermediate CA automatically from GetCACert${NC}\n"
                break
            fi
        done
        if [ ! -f "$INTERMEDIATE_CA_FILE" ]; then
            printf "${YELLOW}GetCACert response didn't contain a certificate with CA:TRUE - could not derive the intermediate CA automatically.${NC}\n"
        fi
    else
        printf "${YELLOW}Failed to parse the GetCACert response - could not derive the intermediate CA automatically.${NC}\n"
    fi
    rm -rf "$TMP_CACERT_DER" "$TMP_CACERT_BUNDLE" "$TMP_CACERT_SPLIT_DIR"
fi
[ -f "$INTERMEDIATE_CA_FILE" ] && chown "$TARGET_USER" "$INTERMEDIATE_CA_FILE"

# Trust the root and intermediate CAs in the *user's* login keychain, not
# the System keychain. Trusting either system-wide requires
# SecTrustSettingsSetTrustSettings at the admin/system domain, which needs
# an interactive authorization prompt that a script running under sudo/SSH
# has no session to display ("the authorization was denied since no user
# interaction was possible"). Trust settings on a user's own login keychain
# are scoped to that user and don't need the same elevated authorization -
# and it's the login keychain (not System.keychain) that Safari/Chrome
# consult when responding to a TLS ClientAuth challenge on that user's
# behalf anyway, so this is also just the more correct target for what these
# certs are actually for. Run as the invoking user (not root) so it's
# *their* login keychain, and without the admin-domain "-d" flag.
#
# Confirmed on a real Mac: this still prompts interactively for the user's
# password or Touch ID (expected - see Known Limitations in Readme.md -
# there is no fully unattended path for keychain trust changes), but it no
# longer hits the hard, headless "no user interaction was possible" failure
# that trusting the System keychain does.
#
# The root gets trustRoot (it's self-signed); the intermediate gets
# trustAsRoot (the correct policy for a CA cert that isn't itself
# self-signed but should still be trusted directly, rather than only
# validated by chaining to something else) - installing it explicitly here,
# not just bundling it into the device cert's PKCS#12 below, gives a
# cleaner trust indicator in Keychain Access / browsers instead of relying
# on chain-building alone.
#
# Checked first via `security verify-cert`, which evaluates whether a given
# cert is *already* trusted (locally, no network/LDAP via -l) rather than
# blindly re-adding it - the whole point of this being a script you can
# safely rerun for renewals is defeated if every renewal re-triggers the
# same two password/Touch ID prompts for CAs that haven't changed.
if [ -f "$ROOT_CA_FILE" ]; then
    if sudo -u "$TARGET_USER" security verify-cert -l -c "$ROOT_CA_FILE" -k "$LOGIN_KEYCHAIN" &>/dev/null; then
        echo "Root CA already trusted in ${TARGET_USER}'s login keychain - skipping."
    else
        printf "${YELLOW}macOS will now ask for your password or Touch ID to trust the ROOT CA in your login keychain - look for the prompt in a moment...${NC}\n"
        sleep 2
        sudo -u "$TARGET_USER" security add-trusted-cert -r trustRoot -k "$LOGIN_KEYCHAIN" "$ROOT_CA_FILE"
        if [ $? -eq 0 ]; then
            printf "${GREEN}Root CA trusted in ${TARGET_USER}'s login keychain${NC}\n"
        else
            printf "${RED}Failed to trust the root CA in ${TARGET_USER}'s login keychain${NC}\n"
        fi
    fi
else
    printf "${YELLOW}Root CA certificate not found, but continuing...${NC}\n"
fi
if [ -f "$INTERMEDIATE_CA_FILE" ]; then
    if sudo -u "$TARGET_USER" security verify-cert -l -c "$INTERMEDIATE_CA_FILE" -k "$LOGIN_KEYCHAIN" &>/dev/null; then
        echo "Intermediate CA already trusted in ${TARGET_USER}'s login keychain - skipping."
    else
        printf "${YELLOW}macOS will now ask for your password or Touch ID again, this time to trust the INTERMEDIATE CA - a separate prompt from the one above...${NC}\n"
        sleep 2
        sudo -u "$TARGET_USER" security add-trusted-cert -r trustAsRoot -k "$LOGIN_KEYCHAIN" "$INTERMEDIATE_CA_FILE"
        if [ $? -eq 0 ]; then
            printf "${GREEN}Intermediate CA trusted in ${TARGET_USER}'s login keychain${NC}\n"
        else
            printf "${RED}Failed to trust the intermediate CA in ${TARGET_USER}'s login keychain${NC}\n"
        fi
    fi
else
    printf "${YELLOW}Intermediate CA certificate not found, but continuing...${NC}\n"
fi
set -e

echo ""

# Request device trust certificate
echo "========================================"
echo "Requesting Device Trust Certificate"
echo "========================================"
echo ""

# Build scepclient command
SCEPTOOL="$INSTALL_DIR/scepclient"
DNS_NAME="$HOSTNAME"
COMMON_NAME="$HOSTNAME"

# This Mac's serial number, as the server's allowlist records it: trimmed and
# upper-cased. DEVICE_SERIAL overrides the hardware lookup (virtual machines
# and test rigs that have no IOPlatformSerialNumber).
device_serial() {
    if [ -n "${DEVICE_SERIAL:-}" ]; then
        printf '%s' "$DEVICE_SERIAL"
    else
        ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformSerialNumber/{print $4}'
    fi
}
normalized_serial() {
    device_serial | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]'
}
phrase_challenge() {
    local serial
    serial=$(normalized_serial)
    if [ -z "$serial" ]; then
        printf "${RED}Error: could not read this Mac's serial number to build the per-device challenge${NC}\n" >&2
        return 1
    fi
    printf 'device-trust-scep-challenge-v1\n%s' "$serial" | openssl dgst -sha256 -hmac "$SCEP_PHRASE" -binary | openssl base64 -A
}

# Renew with the key from the last run when we can (webhook mode); otherwise
# enroll. Without SCEP_PHRASE and SCEP_RENEW_PROVISIONER this is the original
# behaviour: one provisioner, the static challenge.
ACTION=enroll
ACTIVE_PROVISIONER="$SCEP_PROVISIONER"
ACTIVE_CHALLENGE="$SCEP_CHALLENGE"
CHALLENGE_NOTE="static SCEP_CHALLENGE (per-device challenges are not in use)"
if [ -n "$SCEP_RENEW_PROVISIONER" ] && [ "$HAVE_KEY" -eq 1 ]; then
    ACTION=renew
    ACTIVE_PROVISIONER="$SCEP_RENEW_PROVISIONER"
    ACTIVE_CHALLENGE="not-used-for-renewal"      # the renewal path ignores it
    CHALLENGE_NOTE="renewal with the key from the last run; no phrase or challenge is sent, the server checks the key against the one pinned at enrollment"
elif [ -n "$SCEP_PHRASE" ]; then
    ACTIVE_CHALLENGE=$(phrase_challenge)
    CHALLENGE_NOTE="per-device challenge from this Mac's serial number $(normalized_serial) (HMAC-SHA256 keyed by the phrase; the phrase and the challenge are not shown)"
fi

# scepclient caches its CSR - challenge included - next to the key and silently
# resends it, ignoring a new -challenge. run_scepclient therefore clears it
# before every request.
# scepclient also keeps a self-signed signer certificate (self.pem) next to the
# key and signs every request with it; a new key signed against an old self.pem
# fails with "crypto/rsa: verification error", so it goes whenever the key does.
# Remember whether a key existed, so a failed first
# enrollment can remove the key it just made instead of leaving it behind.
KEY_BEFORE_RUN=0
if [ -f "$PRIVATE_KEY_FILE" ]; then
    KEY_BEFORE_RUN=1
fi

# One scepclient attempt, run as $TARGET_USER (see the long comment further
# down). Retries a failed call: scepclient signs each request with a throwaway
# certificate whose validity starts "now", and step-ca occasionally rejects a
# signing time that lands just outside it before the request reaches the
# webhook. Retrying a request that really was refused is harmless; only an
# allowed request uses up a phrase.
# usage: run_scepclient <key-file> <cert-file> <provisioner> <challenge>
run_scepclient() {
    local attempt=1 rc
    while :; do
        rm -f "$(dirname "$1")/csr.pem"
        [ -f "$1" ] || rm -f "$(dirname "$1")/self.pem"
        sudo -u "$TARGET_USER" "$SCEPTOOL" -private-key "$1" -certificate "$2" -server-url "${SCEP_SERVER_URL}/scep/$3" -challenge "$4" -dnsname "$DNS_NAME" -cn "$COMMON_NAME" -country "$CERT_COUNTRY" -organization "$CERT_ORGANIZATION" -ou "$CERT_OU"
        rc=$?
        [ $rc -eq 0 ] && return 0
        [ "$attempt" -ge "$SCEP_ATTEMPTS" ] && return $rc
        printf "${YELLOW}scepclient attempt %s of %s failed - retrying in 2 seconds${NC}\n" "$attempt" "$SCEP_ATTEMPTS" >&2
        attempt=$((attempt + 1))
        sleep 2
    done
}

echo "Action: $ACTION via provisioner $ACTIVE_PROVISIONER (the challenge itself is not printed)"
echo "Challenge: $CHALLENGE_NOTE"
echo "Command:"
echo "$SCEPTOOL" -private-key "$PRIVATE_KEY_FILE" -certificate "$CERT_FILE" -server-url "${SCEP_SERVER_URL}/scep/${ACTIVE_PROVISIONER}" -challenge "<redacted>" -dnsname "$DNS_NAME" -cn "$COMMON_NAME" -country "$CERT_COUNTRY" -organization "$CERT_ORGANIZATION" -ou "$CERT_OU"

echo ""

# On renewal, back up the current cert (not the private key - scepclient
# needs to find it in place to reuse it) so a failed renewal doesn't leave
# the device with no valid certificate at all.
BACKUP_CERT_FILE="${CERT_FILE}.bak"
if [ "$IS_RENEWAL" -eq 1 ]; then
    cp "$CERT_FILE" "$BACKUP_CERT_FILE"
fi

# Execute scepclient as $TARGET_USER, not root. scepclient's own TLS
# verification of the gateway's certificate consults whichever keychain
# belongs to the *calling process's* user - running it as root means it
# checks root's (nonexistent) trust settings instead of the ones we just
# installed in $TARGET_USER's login keychain, failing with "certificate
# signed by unknown authority" even though the CA is correctly trusted.
# $CERT_DIR is owned by $TARGET_USER (see above) specifically so this can
# write client.key/client.crt there without needing root for every run.
set +e
run_scepclient "$PRIVATE_KEY_FILE" "$CERT_FILE" "$ACTIVE_PROVISIONER" "$ACTIVE_CHALLENGE"
SCEP_EXIT=$?

# A refused renewal (for example an administrator cleared this Mac's pin, or the
# Mac was replaced) falls back to enrolling with a brand-new key, if a phrase
# is available. It runs in a scratch directory so the current key and
# certificate stay untouched until the new ones have actually been issued.
if [ $SCEP_EXIT -ne 0 ] && [ "$ACTION" = "renew" ] && [ -n "$SCEP_PHRASE" ]; then
    printf "${YELLOW}Renewal was refused - enrolling with a new key and the phrase instead.${NC}\n"
    ACTION=enroll
    ACTIVE_PROVISIONER="$SCEP_PROVISIONER"
    CHALLENGE_NOTE="per-device challenge from this Mac's serial number $(normalized_serial) (fallback after the renewal was refused)"
    FALLBACK_DIR=$(sudo -u "$TARGET_USER" mktemp -d "${CERT_DIR}/enroll-work.XXXXXX")
    FALLBACK_CHALLENGE=$(phrase_challenge)
    run_scepclient "$FALLBACK_DIR/client.key" "$FALLBACK_DIR/client.crt" "$SCEP_PROVISIONER" "$FALLBACK_CHALLENGE"
    SCEP_EXIT=$?
    if [ $SCEP_EXIT -eq 0 ] && [ -s "$FALLBACK_DIR/client.crt" ]; then
        mv -f "$FALLBACK_DIR/client.key" "$PRIVATE_KEY_FILE"
        mv -f "$FALLBACK_DIR/client.crt" "$CERT_FILE"
        rm -f "${CERT_DIR}/csr.pem"
        chown "$TARGET_USER" "$PRIVATE_KEY_FILE" "$CERT_FILE"
    fi
    rm -rf "$FALLBACK_DIR"
fi
set -e

if [ $SCEP_EXIT -ne 0 ]; then
    echo ""
    printf "${RED}Error: Certificate request failed!${NC}\n"
    echo "Please check your SCEP server URL, challenge, and root CA installation."
    if [ "$KEY_BEFORE_RUN" -eq 0 ]; then
        # The key was made for this attempt and has no certificate: don't leave it.
        rm -f "$PRIVATE_KEY_FILE" "${CERT_DIR}/csr.pem" "${CERT_DIR}/self.pem"
    fi
    if [ -f "$BACKUP_CERT_FILE" ]; then
        printf "${YELLOW}Restoring previous certificate - it was not replaced.${NC}\n"
        cp "$BACKUP_CERT_FILE" "$CERT_FILE"
        # This cp runs as root - restore $TARGET_USER's ownership so the
        # next run's scepclient (which runs as that user) can still
        # overwrite this file itself.
        chown "$TARGET_USER" "$CERT_FILE"
    fi
    exit 1
fi

printf "${GREEN}SCEP server issued the certificate (action: %s, provisioner: %s)${NC}\n" "$ACTION" "$ACTIVE_PROVISIONER"

# Verify certificate was created
if [ ! -f "$CERT_FILE" ]; then
    printf "${RED}Error: Certificate file not created${NC}\n"
    if [ -f "$BACKUP_CERT_FILE" ]; then
        printf "${YELLOW}Restoring previous certificate - it was not replaced.${NC}\n"
        cp "$BACKUP_CERT_FILE" "$CERT_FILE"
        # This cp runs as root - restore $TARGET_USER's ownership so the
        # next run's scepclient (which runs as that user) can still
        # overwrite this file itself.
        chown "$TARGET_USER" "$CERT_FILE"
    fi
    exit 1
fi

rm -f "$BACKUP_CERT_FILE"

# Save full certificate chain (public data only, informational/for use with
# curl etc. - not what's actually used for ClientAuth, see below)
if [ -f "$FULL_CHAIN_FILE" ]; then
    rm -f "$FULL_CHAIN_FILE"
fi
cat "$ROOT_CA_FILE" > "$FULL_CHAIN_FILE"
if [ -f "$INTERMEDIATE_CA_FILE" ]; then
    cat "$INTERMEDIATE_CA_FILE" >> "$FULL_CHAIN_FILE"
fi
cat "$CERT_FILE" >> "$FULL_CHAIN_FILE"

# Capture the SHA-256 hash of every existing device cert already in the
# keychain (matched by common name, always $HOSTNAME across enrollment and
# every renewal) *before* importing the new one - without this, a renewal
# leaves two (or more) keychain items with the same CN and very similar
# details (different serial/expiration) side by side, confusingly
# indistinguishable at a glance in a browser's ClientAuth certificate
# picker. Removed by exact hash after the new import succeeds (see below),
# not before, so a failed renewal doesn't leave the device with no usable
# certificate at all.
#
# Two earlier attempts at this failed, and a real working example from
# live testing pinned down why: the keychain must be passed as a bare
# trailing argument, NOT via a "-k <keychain>" flag - `-k` appears to be
# silently rejected (or simply not the right flag) for both
# `find-certificate` and `delete-certificate` specifically, unlike
# `verify-cert` above, where `-k` does work. `-a` on `find-certificate`
# actually does return every match (confirmed live: 4 distinct
# "SHA-256 hash:"/"SHA-1 hash:" pairs for 4 existing certs) - the earlier
# "only returns the first match" theory was a wrong diagnosis; the real
# fault was the `-k` flag causing the whole lookup to silently fail. The
# SHA-256 hash (not SHA-1) is used for `-Z` to match the confirmed-working
# example exactly.
OLD_CERT_HASHES=$(sudo -u "$TARGET_USER" security find-certificate -a -Z -c "$HOSTNAME" -p "$LOGIN_KEYCHAIN" 2>/dev/null | grep "SHA-256 hash:" | awk '{print $NF}')
# Public key of the first earlier certificate, so the summary can say whether this
# run kept the key. Empty when there is none.
PREV_KEY_HASH=$(sudo -u "$TARGET_USER" security find-certificate -a -c "$HOSTNAME" -p "$LOGIN_KEYCHAIN" 2>/dev/null | openssl x509 -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $NF}' | cut -c1-16 || true)

# Package the cert+key(+chain) into a PKCS#12 bundle and import it into the
# user's own login keychain - that's what Safari/Chrome actually consult
# when responding to a TLS ClientAuth challenge, not a loose PEM file on
# disk. The bundle needs a real (throwaway) password: `security import`
# doesn't accept an empty one non-interactively, and the password itself
# carries no security weight since the .p12 is shredded immediately after.
echo ""
echo "Installing certificate into ${TARGET_USER}'s login keychain..."

# Created inside $CERT_DIR, not the default $TMPDIR - under sudo -E,
# $TMPDIR is preserved from the invoking user's own per-user temp directory
# (/var/folders/.../T/), but root writing into it and $TARGET_USER reading
# it back both being macOS-sandboxed per-user paths doesn't reliably work
# across that root/user boundary ("Error reading infile ... Permission
# denied" even after chmod 644). $CERT_DIR is a plain directory we already
# own the permissions story for.
#
# Uses mktemp -d + fixed filenames, not a "prefix.XXXXXX.p12"-style
# template - macOS's BSD mktemp doesn't reliably substitute the X's when
# they're followed by a literal suffix like ".p12" in a positional
# template (confirmed live: step's own "saved as" message showed the
# literal, un-substituted "XXXXXX" in the path), silently reusing the same
# fixed name/content across runs and producing a device cert whose PKCS#12
# password didn't match what got passed to `security import` on a rerun -
# "MAC verification failed during PKCS12 import". A directory template
# (already used successfully elsewhere in this script, e.g. for step's own
# extraction) doesn't have this suffix ambiguity.
TMP_P12_DIR=$(mktemp -d "${CERT_DIR}/p12-work.XXXXXX")
P12_FILE="${TMP_P12_DIR}/client.p12"
P12_PASSWORD_FILE="${TMP_P12_DIR}/password.txt"

# --legacy: step's default PKCS#12 encoding uses modern OpenSSL 3.x
# algorithms (AES + a newer MAC) that macOS's own Security framework
# importer doesn't yet support, failing with "SecKeychainItemImport: MAC
# verification failed during PKCS12 import (wrong password?)" - misleading,
# since the password itself is fine. --legacy switches to the traditional
# PBE+SHA1+RC2/3DES encoding macOS actually understands.
#
# Back to a real random password (matching Windows) rather than a fixed
# "0" or empty one - under test, the private-key-prompts-for-a-password
# symptom persisted regardless of which of those we tried, pointing at a
# separate browser/keychain ACL interaction rather than anything about the
# PKCS#12 password's own content. Re-testing with a genuinely random
# password to isolate that. --insecure isn't needed here (only required by
# step for --no-password or a weak/trivial --password-file value, not a
# real one); --legacy still is, independent of password strength - see
# above.
P12_PASSWORD=$(openssl rand -hex 16 2>/dev/null || echo "${RANDOM}${RANDOM}${RANDOM}$$")
printf '%s' "$P12_PASSWORD" > "$P12_PASSWORD_FILE"
STEP_ARGS=(certificate p12 "$P12_FILE" "$CERT_FILE" "$PRIVATE_KEY_FILE" --password-file "$P12_PASSWORD_FILE" --legacy --force)
if [ -f "$INTERMEDIATE_CA_FILE" ]; then
    STEP_ARGS+=(--ca "$INTERMEDIATE_CA_FILE")
fi
"$STEP_TOOL" "${STEP_ARGS[@]}"

# Written by this (root) process into the user's own $CERT_DIR - fix
# ownership on both the scratch directory (mktemp -d creates it mode 700,
# so $TARGET_USER can't even traverse into it as root's own otherwise) and
# the file itself, so $TARGET_USER's own `security import` below can reach
# and read it.
chown "$TARGET_USER" "$TMP_P12_DIR" "$P12_FILE"

printf "${YELLOW}macOS will now ask for your password or Touch ID a third time, to import the device certificate itself...${NC}\n"
sleep 2
set +e
# -T /usr/bin/security (not -A): grants only the security tool itself
# access without a prompt, which is what the import operation needs -
# -A additionally grants every application on the system access to the
# private key without ever warning the user, which is broader than
# necessary and is Apple's own documented definition of an insecure
# access control setting. -x marks the private key non-exportable at the
# keychain level, closing a real gap the prior command left open: without
# it, the "non-exportable" claim made elsewhere in this script wasn't
# actually enforced by the keychain itself, and the raw key could still be
# exported (passphrase-free) via the Keychain Access GUI's own "Export"
# menu item, regardless of any other access control settings.
sudo -u "$TARGET_USER" security import "$P12_FILE" -k "$LOGIN_KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/security -x
IMPORT_EXIT=$?
set -e

rm -rf "$TMP_P12_DIR"

if [ $IMPORT_EXIT -ne 0 ]; then
    printf "${RED}Error: Failed to import certificate into ${TARGET_USER}'s login keychain${NC}\n"
    if [ "$IS_RENEWAL" -eq 1 ]; then
        printf "${YELLOW}The existing certificate in the keychain was not touched.${NC}\n"
    fi
    exit 1
fi

printf "${GREEN}Certificate installed into ${TARGET_USER}'s login keychain${NC}\n"

# Now that the new certificate is confirmed installed, remove the old
# entry/entries it superseded (if this was a renewal) - identified by the
# exact SHA-256 hashes captured before the new import, so this can't
# accidentally remove the certificate we just added even though it shares
# the same CN. Same "-Z <hash> <keychain>" form (no "-k" flag) as the
# capture step above - see the comment there for why that distinction
# matters here.
if [ -n "$OLD_CERT_HASHES" ]; then
    echo "Removing superseded device certificate(s) from ${TARGET_USER}'s login keychain..."
    while IFS= read -r OLD_HASH; do
        [ -z "$OLD_HASH" ] && continue
        sudo -u "$TARGET_USER" security delete-certificate -Z "$OLD_HASH" "$LOGIN_KEYCHAIN" 2>/dev/null \
            && echo "Removed superseded certificate ($OLD_HASH)." \
            || printf "${YELLOW}Could not remove superseded certificate ($OLD_HASH) - you may want to remove it manually in Keychain Access.${NC}\n"
    done <<< "$OLD_CERT_HASHES"
fi

# Prove the installed certificate actually works for TLS ClientAuth (not
# just that it was issued) by making a real mTLS request against the test
# gateway - mirrors install-windows.ps1's own PASS/FAIL test. Uses the
# loose PEM files directly (same cert/key content that's now also in the
# keychain) rather than referencing the keychain identity, since curl's
# --cert/--key flags work with plain files regardless of TLS backend and
# this is far simpler than keychain-identity curl syntax. -k: the gateway's
# own TLS certificate is self-issued (not a public CA) - this test is
# specifically verifying ClientAuth (our device cert being accepted), not
# the gateway's server identity.
MTLS_TEST_RESULT=""
if [ -n "$MTLS_GATEWAY_URL" ]; then
    echo ""
    echo "========================================"
    echo "Testing mTLS ClientAuth Against Gateway"
    echo "========================================"
    echo ""
    MTLS_RESPONSE=$(curl -k -s -w '\nHTTP_STATUS=%{http_code}' --cert "$CERT_FILE" --key "$PRIVATE_KEY_FILE" "$MTLS_GATEWAY_URL" 2>&1)
    MTLS_STATUS=$(echo "$MTLS_RESPONSE" | grep "HTTP_STATUS=" | sed 's/.*HTTP_STATUS=//')
    MTLS_BODY=$(echo "$MTLS_RESPONSE" | sed '/HTTP_STATUS=/d')
    if [ "$MTLS_STATUS" = "200" ] && echo "$MTLS_BODY" | grep -q "mTLS authentication successful"; then
        printf "${GREEN}PASS: mTLS ClientAuth succeeded against $MTLS_GATEWAY_URL${NC}\n"
        echo "$MTLS_BODY"
        MTLS_TEST_RESULT="PASS"
    else
        printf "${RED}FAIL: Unexpected response from $MTLS_GATEWAY_URL (status $MTLS_STATUS)${NC}\n"
        echo "$MTLS_BODY"
        MTLS_TEST_RESULT="FAIL"
    fi
else
    echo ""
    echo "Skipping mTLS test (MTLS_GATEWAY_URL not set)."
fi

# Apply the chosen key protection to the loose PEM files. This comes after the
# mTLS test because that test uses the PEM files directly.
CERT_SUBJECT=$(openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null | sed 's/subject= *//')
CERT_SERIAL=$(openssl x509 -in "$CERT_FILE" -noout -serial 2>/dev/null | cut -d= -f2)
CERT_NOT_BEFORE=$(openssl x509 -in "$CERT_FILE" -noout -startdate 2>/dev/null | cut -d= -f2)
CERT_NOT_AFTER=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)
CERT_KEY_HASH=$(openssl x509 -in "$CERT_FILE" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $NF}' | cut -c1-16 || true)
if [ -z "$PREV_KEY_HASH" ]; then
    KEY_RELATION="no earlier certificate found in the keychain"
elif [ "$PREV_KEY_HASH" = "$CERT_KEY_HASH" ]; then
    KEY_RELATION="same key as the certificate it replaced"
else
    KEY_RELATION="new key"
fi
if [ -n "$KEY_PROTECTION" ]; then
    echo ""
    echo "Applying key protection mode: $KEY_PROTECTION"
fi
if [ "$KEY_PROTECTION" = "Delete" ]; then
    rm -f "$PRIVATE_KEY_FILE" "$CERT_FILE" "${CERT_DIR}/csr.pem" "${CERT_DIR}/self.pem"
    printf "${GREEN}Deleted the loose private key, certificate and cached CSR. The key now lives only in the keychain (non-exportable); the next run enrolls with a new key.${NC}\n"
elif [ "$KEY_PROTECTION" = "RestrictPermissions" ]; then
    chmod 700 "$CERT_DIR"
    chmod 600 "$PRIVATE_KEY_FILE"
    printf "${GREEN}Kept the key for same-key renewal, mode 600 in a mode 700 directory.${NC}\n"
    printf "${YELLOW}Note: on macOS it stays readable by ${TARGET_USER}. Use KEY_PROTECTION=Delete where that is not acceptable.${NC}\n"
fi

echo ""
echo "========================================"
printf "${GREEN}Installation Successful!${NC}\n"
echo "========================================"
echo ""
echo "Certificate installed in: ${TARGET_USER}'s login keychain (label: $CERT_SUBJECT)"
echo "Full chain (public data): $FULL_CHAIN_FILE"

# What this run actually did, in terms a person can check.
case "$CHALLENGE_NOTE" in
    static*) WEBHOOK_STATE="not used (static challenge)" ;;
    *) WEBHOOK_STATE="used: the server accepted this request through the per-device flow" ;;
esac
if [ "$KEY_PROTECTION" = "Delete" ]; then
    NEXT_RUN="enrolls again with a new key (needs a current phrase when the webhook is in use)"
    KEY_STATE="non-exportable in the login keychain only; the key files were deleted"
elif [ -n "$SCEP_RENEW_PROVISIONER" ]; then
    NEXT_RUN="renews through $SCEP_RENEW_PROVISIONER with no phrase"
else
    NEXT_RUN="enrolls again with the same key (set SCEP_RENEW_PROVISIONER to renew without a phrase)"
fi
if [ "$KEY_PROTECTION" = "RestrictPermissions" ]; then
    KEY_STATE="non-exportable in the login keychain; a copy is kept at $PRIVATE_KEY_FILE (mode 600, readable by ${TARGET_USER})"
elif [ -z "$KEY_PROTECTION" ]; then
    KEY_STATE="in the login keychain; a copy is kept at $PRIVATE_KEY_FILE with its default permissions"
fi
echo ""
echo "What happened"
echo "  Request:      $ACTION through provisioner $ACTIVE_PROVISIONER"
echo "  Challenge:    $CHALLENGE_NOTE"
echo "  Webhook:      $WEBHOOK_STATE"
echo "  Device:       $HOSTNAME"
echo "  Certificate:  serial $CERT_SERIAL, valid $CERT_NOT_BEFORE to $CERT_NOT_AFTER"
echo "  Public key:   sha256 $CERT_KEY_HASH ($KEY_RELATION)"
echo "  Private key:  $KEY_STATE"
echo "  Next run:     $NEXT_RUN"
[ -n "$KEY_PROTECTION" ] && echo "Key protection: $KEY_PROTECTION"
if [ -n "$MTLS_TEST_RESULT" ]; then
    echo "mTLS gateway test: $MTLS_TEST_RESULT"
fi
echo ""
echo "To view certificate details:"
echo "security find-certificate -c \"$HOSTNAME\" -p login.keychain | openssl x509 -noout -text"
echo ""
