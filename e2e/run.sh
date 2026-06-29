#!/usr/bin/env bash
set -Eeuo pipefail

# Bring up a local dstack e2e stack: KMS + Gateway + VMM + N app CVMs.
# Runtime state is kept under build/e2e by default (ignored by git).

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

COMMAND="${1:-up}"
if [[ $# -gt 0 ]]; then
  shift
fi

WORK_DIR="${E2E_WORK_DIR:-$REPO_ROOT/build/e2e}"
IMAGE_DIR="${E2E_IMAGE_DIR:-$REPO_ROOT/build/images}"
IMAGE_NAME="${E2E_IMAGE:-}"
APP_COUNT="${E2E_APP_COUNT:-2}"
APP_VCPU="${E2E_APP_VCPU:-2}"
APP_MEMORY="${E2E_APP_MEMORY:-2048}"
APP_MEMORY_EXPLICIT=0
APP_DISK="${E2E_APP_DISK:-20}"
APP_IMAGE="${E2E_APP_IMAGE:-busybox:1.36}"
APP_KMS="${E2E_APP_KMS:-1}"
APP_GATEWAY="${E2E_APP_GATEWAY:-1}"
NO_TEE="${E2E_NO_TEE:-0}"
TEE_PLATFORM="${E2E_TEE_PLATFORM:-auto}"
KMS_IMAGE_VERIFY="${E2E_KMS_IMAGE_VERIFY:-0}"
KMS_STRICT_NO_QEMU="${E2E_KMS_STRICT_NO_QEMU:-0}"
TDX_ATTESTATION_VARIANT="${E2E_TDX_ATTESTATION_VARIANT:-legacy}"
QEMU_PATH="${E2E_QEMU_PATH:-}"
PCCS_URL="${E2E_PCCS_URL:-}"
AMD_KDS_BASE_URL="${E2E_AMD_KDS_BASE_URL:-}"
BUILD_HOST="${E2E_BUILD_HOST:-0}"
FORCE="${E2E_FORCE:-0}"
CLEANUP_AFTER_TEST="${E2E_CLEANUP:-0}"
GATEWAY_PUBLIC_DOMAIN="${E2E_GATEWAY_PUBLIC_DOMAIN:-e2e.dstack.local}"
KMS_DOMAIN="${E2E_KMS_DOMAIN:-kms.1022.dstack.org}"
GATEWAY_DOMAIN="${E2E_GATEWAY_DOMAIN:-gateway.1022.dstack.org}"
STARTUP_TIMEOUT="${E2E_STARTUP_TIMEOUT:-120}"
APP_TIMEOUT="${E2E_APP_TIMEOUT:-900}"
RUST_LOG_VALUE="${RUST_LOG:-info}"

STATE_FILE="$WORK_DIR/state.env"
PORTS_FILE="$WORK_DIR/ports.env"
CONFIG_DIR="$WORK_DIR/config"
CERTS_DIR="$WORK_DIR/certs"
RUN_DIR="$WORK_DIR/run"
LOG_DIR="$WORK_DIR/logs"
PIDS_DIR="$WORK_DIR/pids"
APPS_DIR="$WORK_DIR/apps"

KMS_BIN="${E2E_KMS_BIN:-}"
GATEWAY_BIN="${E2E_GATEWAY_BIN:-}"
VMM_BIN="${E2E_VMM_BIN:-}"
SUPERVISOR_BIN="${E2E_SUPERVISOR_BIN:-}"
VMM_CLI="${E2E_VMM_CLI:-$REPO_ROOT/dstack/vmm/src/vmm-cli.py}"

usage() {
  cat <<USAGE
Usage: e2e/run.sh [command] [options]

Commands:
  up        Generate configs, start KMS/Gateway/VMM, deploy app CVMs, run smoke checks (default)
  smoke     Re-run smoke checks against an existing e2e stack
  status    Show process and VM status
  logs      Tail service logs (pass --service kms|gateway|vmm|all; default all)
  down      Remove e2e VMs and stop services; logs/state are kept
  clean     down + remove the e2e work directory
  help      Show this help

Options / env overrides:
  --work-dir DIR            Runtime directory (default: build/e2e)
  --image-dir DIR           Guest image directory (default: build/images)
  --image NAME              Guest image name. Auto-detects latest non-nvidia dstack image if omitted
  --apps N                  Number of app CVMs to deploy (default: 2)
  --app-image IMAGE         Container image used by the smoke app (default: busybox:1.36)
  --vcpu N                  vCPU per app CVM (default: 2)
  --memory MB              Memory per app CVM in MB (default: 2048; --kms-no-qemu supports 2048 or >=2816)
  --disk GB                 Disk per app CVM in GB (default: 20)
  --no-tee                  Deploy app CVMs with VMM --no-tee (for infra debugging only)
  --no-app-kms              Do not enable KMS in app-compose (useful with --no-tee)
  --no-app-gateway          Do not enable gateway in app-compose (useful with --no-tee)
  --tee-platform VALUE      VMM cvm.platform: auto|tdx|amd-sev-snp (default: auto)
  --kms-image-verify        Enable KMS OS image verification
  --kms-no-qemu             Use TDX lite vm_config mode and start KMS without dstack-acpi-tables in PATH
  --tdx-attestation-variant legacy|lite
                            TDX app attestation/hash scheme (default: legacy)
  --qemu PATH               QEMU binary path override
  --pccs-url URL            PCCS URL passed to VMM/KMS verification config
  --build-host              Run ./build.sh host if host binaries are missing
  --force                   If a stack already exists, tear it down before up
  --cleanup                 For command 'up', tear down after successful smoke checks
  -h, --help                Show this help

Examples:
  ./e2e/run.sh up --image dstack-0.6.0 --apps 3
  E2E_BUILD_HOST=1 ./e2e/run.sh up
  ./e2e/run.sh smoke
  ./e2e/run.sh down

Notes:
  - Gateway needs CAP_NET_ADMIN/root for WireGuard. If not root, this script uses passwordless sudo when available.
  - The guest reaches host services through *.1022.dstack.org, which resolves to QEMU's 10.0.2.2 host address.
USAGE
}

log() { printf '[e2e] %s\n' "$*"; }
warn() { printf '[e2e][warn] %s\n' "$*" >&2; }
fatal() { printf '[e2e][error] %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir) WORK_DIR=$(realpath -m "$2"); shift 2 ;;
    --image-dir) IMAGE_DIR=$(realpath -m "$2"); shift 2 ;;
    --image) IMAGE_NAME="$2"; shift 2 ;;
    --apps) APP_COUNT="$2"; shift 2 ;;
    --app-image) APP_IMAGE="$2"; shift 2 ;;
    --vcpu) APP_VCPU="$2"; shift 2 ;;
    --memory) APP_MEMORY="$2"; APP_MEMORY_EXPLICIT=1; shift 2 ;;
    --disk) APP_DISK="$2"; shift 2 ;;
    --no-tee) NO_TEE=1; shift ;;
    --no-app-kms) APP_KMS=0; shift ;;
    --no-app-gateway) APP_GATEWAY=0; shift ;;
    --tee-platform) TEE_PLATFORM="$2"; shift 2 ;;
    --kms-image-verify) KMS_IMAGE_VERIFY=1; shift ;;
    --kms-no-qemu) KMS_STRICT_NO_QEMU=1; TDX_ATTESTATION_VARIANT=lite; shift ;;
    --tdx-attestation-variant) TDX_ATTESTATION_VARIANT="$2"; shift 2 ;;
    --qemu) QEMU_PATH=$(realpath -m "$2"); shift 2 ;;
    --pccs-url) PCCS_URL="$2"; shift 2 ;;
    --build-host) BUILD_HOST=1; shift ;;
    --force) FORCE=1; shift ;;
    --cleanup) CLEANUP_AFTER_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fatal "unknown option: $1" ;;
  esac
done

case "$TDX_ATTESTATION_VARIANT" in
  legacy|lite) ;;
  *) fatal "invalid TDX attestation variant: $TDX_ATTESTATION_VARIANT (expected legacy|lite)" ;;
esac
if [[ "$KMS_STRICT_NO_QEMU" == "1" && "$NO_TEE" != "1" && "$TDX_ATTESTATION_VARIANT" == "lite" ]]; then
  # The no-image-download verifier uses the build-time QEMU-patched kernel
  # Authenticode hash. QEMU produces the same patched kernel at exactly 2 GiB
  # and at/above its high-memory initrd placement threshold
  # (0xB0000000 = 2816 MiB). Other low-memory sizes are memory-dependent.
  if (( APP_MEMORY != 2048 && APP_MEMORY < 2816 )); then
    if (( APP_MEMORY_EXPLICIT == 1 )); then
      fatal "--kms-no-qemu requires --memory 2048 or --memory >= 2816 for TDX lite verification without image download"
    fi
    APP_MEMORY=2048
  fi
fi

# Recompute derived paths if --work-dir was passed.
STATE_FILE="$WORK_DIR/state.env"
PORTS_FILE="$WORK_DIR/ports.env"
CONFIG_DIR="$WORK_DIR/config"
CERTS_DIR="$WORK_DIR/certs"
RUN_DIR="$WORK_DIR/run"
LOG_DIR="$WORK_DIR/logs"
PIDS_DIR="$WORK_DIR/pids"
APPS_DIR="$WORK_DIR/apps"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "missing required command: $1"
}

is_pid_alive() {
  local pid="$1"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1 || ps -p "$pid" >/dev/null 2>&1
}

pid_file_alive() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local pid
  pid=$(cat "$file" 2>/dev/null || true)
  is_pid_alive "$pid"
}

have_live_stack() {
  [[ -f "$STATE_FILE" ]] || return 1
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  pid_file_alive "${PIDS_DIR}/vmm.pid" || pid_file_alive "${PIDS_DIR}/kms.pid" || pid_file_alive "${PIDS_DIR}/gateway.pid"
}

find_bin() {
  local var_value="$1"
  local name="$2"
  shift 2
  if [[ -n "$var_value" ]]; then
    [[ -x "$var_value" ]] || fatal "$name binary is not executable: $var_value"
    printf '%s\n' "$var_value"
    return
  fi
  local c
  for c in "$@"; do
    if [[ -x "$c" ]]; then
      printf '%s\n' "$c"
      return
    fi
  done
  return 1
}

maybe_build_host_bins() {
  if [[ "$BUILD_HOST" != "1" ]]; then
    return 0
  fi
  log "building host binaries via ./build.sh host"
  (cd "$REPO_ROOT" && ./build.sh host)
}

resolve_binaries() {
  maybe_build_host_bins
  if ! KMS_BIN=$(find_bin "$KMS_BIN" dstack-kms \
      "$REPO_ROOT/dstack-kms" \
      "$REPO_ROOT/dstack/target/release/dstack-kms" \
      "$REPO_ROOT/dstack/target/debug/dstack-kms" 2>/dev/null); then
    KMS_BIN=$(find_bin "${E2E_KMS_BIN:-}" dstack-kms \
      "$REPO_ROOT/dstack-kms" \
      "$REPO_ROOT/dstack/target/release/dstack-kms" \
      "$REPO_ROOT/dstack/target/debug/dstack-kms") || \
      fatal "dstack-kms not found. Run './build.sh host' or pass E2E_BUILD_HOST=1."
  fi
  GATEWAY_BIN=$(find_bin "$GATEWAY_BIN" dstack-gateway \
    "$REPO_ROOT/dstack-gateway" \
    "$REPO_ROOT/dstack/target/release/dstack-gateway" \
    "$REPO_ROOT/dstack/target/debug/dstack-gateway") || \
    fatal "dstack-gateway not found. Run './build.sh host' or pass E2E_GATEWAY_BIN."
  VMM_BIN=$(find_bin "$VMM_BIN" dstack-vmm \
    "$REPO_ROOT/dstack-vmm" \
    "$REPO_ROOT/dstack/target/release/dstack-vmm" \
    "$REPO_ROOT/dstack/target/debug/dstack-vmm") || \
    fatal "dstack-vmm not found. Run './build.sh host' or pass E2E_VMM_BIN."
  SUPERVISOR_BIN=$(find_bin "$SUPERVISOR_BIN" supervisor \
    "$REPO_ROOT/supervisor" \
    "$REPO_ROOT/dstack/target/release/supervisor" \
    "$REPO_ROOT/dstack/target/debug/supervisor") || \
    fatal "supervisor not found. Run './build.sh host' or pass E2E_SUPERVISOR_BIN."
  [[ -f "$VMM_CLI" ]] || fatal "vmm-cli.py not found: $VMM_CLI"
}

vmm_cli() {
  python3 "$VMM_CLI" --url "$VMM_URL" "$@"
}

allocate_ports() {
  mkdir -p "$WORK_DIR"
  python3 - "$APP_COUNT" >"$PORTS_FILE" <<'PY'
import random
import socket
import sys

app_count = int(sys.argv[1])
for _ in range(500):
    base = random.randint(20000, 50000)
    ports = {
        "BASE_PORT": base,
        "KMS_RPC_PORT": base + 1,
        "GATEWAY_RPC_PORT": base + 2,
        "GATEWAY_WG_PORT": base + 3,
        "GATEWAY_SERVE_PORT": base + 4,
        "VMM_RPC_PORT": base + 5,
        "HOST_API_PORT": base + 6,
        "KEY_PROVIDER_PORT": base + 7,
        "APP_HOST_PORT_BASE": base + 20,
    }
    tcp_ports = [
        ports["KMS_RPC_PORT"],
        ports["GATEWAY_RPC_PORT"],
        ports["GATEWAY_SERVE_PORT"],
        ports["VMM_RPC_PORT"],
        ports["KEY_PROVIDER_PORT"],
        *[ports["APP_HOST_PORT_BASE"] + i for i in range(app_count)],
    ]
    if max(tcp_ports + [ports["GATEWAY_WG_PORT"]]) > 65000:
        continue
    sockets = []
    try:
        for port in tcp_ports:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.bind(("127.0.0.1", port))
            sockets.append(s)
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.bind(("0.0.0.0", ports["GATEWAY_WG_PORT"]))
        sockets.append(u)
    except OSError:
        for s in sockets:
            s.close()
        continue
    for s in sockets:
        s.close()
    cid_pool_start = random.randint(20, 900) * 1000
    subnet_index = random.randint(10, 249)
    for key, value in ports.items():
        print(f"{key}={value}")
    print(f"CID_POOL_START={cid_pool_start}")
    print("CID_POOL_SIZE=1000")
    print(f"SUBNET_INDEX={subnet_index}")
    raise SystemExit(0)
raise SystemExit("failed to allocate a free e2e port range")
PY
}

detect_image() {
  if [[ -n "$IMAGE_NAME" ]]; then
    [[ -f "$IMAGE_DIR/$IMAGE_NAME/metadata.json" ]] || fatal "image not found or missing metadata.json: $IMAGE_DIR/$IMAGE_NAME"
    return
  fi
  [[ -d "$IMAGE_DIR" ]] || fatal "image directory not found: $IMAGE_DIR"
  IMAGE_NAME=$(python3 - "$IMAGE_DIR" <<'PY'
import os
import sys
from pathlib import Path
root = Path(sys.argv[1])
all_images = [p for p in root.iterdir() if p.is_dir() and (p / "metadata.json").is_file()]
preferred = [p for p in all_images if p.name.startswith("dstack-") and not p.name.startswith("dstack-nvidia")]
images = preferred or all_images
if not images:
    raise SystemExit(1)
images.sort(key=lambda p: (p.stat().st_mtime, p.name), reverse=True)
print(images[0].name)
PY
) || fatal "no usable image found in $IMAGE_DIR"
  log "auto-detected image: $IMAGE_NAME"
}

write_self_signed_cert() {
  local cert="$1"
  local key="$2"
  local cn="$3"
  local san="$4"
  if [[ -s "$cert" && -s "$key" ]]; then
    return
  fi
  mkdir -p "$(dirname "$cert")" "$(dirname "$key")"
  openssl req -x509 -newkey rsa:2048 -nodes -days 14 \
    -subj "/CN=${cn}" \
    -addext "subjectAltName=${san}" \
    -keyout "$key" \
    -out "$cert" >/dev/null 2>&1
  chmod 600 "$key"
}

prepare_dirs() {
  mkdir -p "$CONFIG_DIR" "$CERTS_DIR" "$RUN_DIR" "$LOG_DIR" "$PIDS_DIR" "$APPS_DIR"
}

prepare_wireguard_key() {
  if [[ ! -s "$CERTS_DIR/gateway.wg.key" ]]; then
    (umask 077 && wg genkey >"$CERTS_DIR/gateway.wg.key")
  fi
  wg pubkey <"$CERTS_DIR/gateway.wg.key" >"$CERTS_DIR/gateway.wg.pub"
}

prepare_kms_certs() {
  # Local e2e KMS runs outside a CVM, so it cannot RA-attest itself while
  # bootstrapping. Generate dev-only KMS material with the same file layout and
  # the `kms:rpc` certificate-usage extension expected by dstack-util.
  if [[ -s "$CERTS_DIR/root-ca.crt" && -s "$CERTS_DIR/root-ca.key" && \
        -s "$CERTS_DIR/tmp-ca.crt" && -s "$CERTS_DIR/tmp-ca.key" && \
        -s "$CERTS_DIR/rpc.crt" && -s "$CERTS_DIR/rpc.key" && \
        -s "$CERTS_DIR/root-k256.key" ]]; then
    return
  fi
  log "generating dev KMS certificates"
  python3 - "$CERTS_DIR" "$KMS_DOMAIN" <<'PY'
import ipaddress
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID, ObjectIdentifier

out = Path(sys.argv[1])
domain = sys.argv[2]
out.mkdir(parents=True, exist_ok=True)

now = datetime.now(timezone.utc) - timedelta(minutes=5)
not_after = now + timedelta(days=3650)


def der_octet_string(data: bytes) -> bytes:
    n = len(data)
    if n < 128:
        return b"\x04" + bytes([n]) + data
    length = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return b"\x04" + bytes([0x80 | len(length)]) + length + data


def write_pem_key(path: Path, key) -> None:
    path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    path.chmod(0o600)


def write_cert(path: Path, cert: x509.Certificate) -> None:
    path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))


def name(cn: str) -> x509.Name:
    return x509.Name(
        [
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Dstack e2e"),
            x509.NameAttribute(NameOID.COMMON_NAME, cn),
        ]
    )


def new_ca(cn: str, path_len: int):
    key = ec.generate_private_key(ec.SECP256R1())
    subject = name(cn)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(not_after)
        .add_extension(x509.BasicConstraints(ca=True, path_length=path_len), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .sign(key, hashes.SHA256())
    )
    return key, cert


tmp_key, tmp_cert = new_ca("Dstack Client Temp CA", 0)
root_key, root_cert = new_ca("Dstack KMS CA", 1)

rpc_key = ec.generate_private_key(ec.SECP256R1())
try:
    san_value = x509.IPAddress(ipaddress.ip_address(domain))
except ValueError:
    san_value = x509.DNSName(domain)

rpc_cert = (
    x509.CertificateBuilder()
    .subject_name(name(domain))
    .issuer_name(root_cert.subject)
    .public_key(rpc_key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(now)
    .not_valid_after(not_after)
    .add_extension(x509.SubjectAlternativeName([san_value]), critical=False)
    .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
    .add_extension(
        x509.KeyUsage(
            digital_signature=True,
            content_commitment=False,
            key_encipherment=False,
            data_encipherment=False,
            key_agreement=False,
            key_cert_sign=False,
            crl_sign=False,
            encipher_only=False,
            decipher_only=False,
        ),
        critical=True,
    )
    .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
    .add_extension(
        x509.UnrecognizedExtension(
            ObjectIdentifier("1.3.6.1.4.1.62397.1.4"),
            der_octet_string(b"kms:rpc"),
        ),
        critical=False,
    )
    .sign(root_key, hashes.SHA256())
)

write_pem_key(out / "tmp-ca.key", tmp_key)
write_cert(out / "tmp-ca.crt", tmp_cert)
write_pem_key(out / "root-ca.key", root_key)
write_cert(out / "root-ca.crt", root_cert)
write_pem_key(out / "rpc.key", rpc_key)
write_cert(out / "rpc.crt", rpc_cert)
(out / "rpc-domain").write_text(domain)

k256_key = ec.generate_private_key(ec.SECP256K1())
k256_scalar = k256_key.private_numbers().private_value.to_bytes(32, "big")
(out / "root-k256.key").write_bytes(k256_scalar)
(out / "root-k256.key").chmod(0o600)
PY
}

write_configs() {
  # shellcheck disable=SC1090
  source "$PORTS_FILE"
  local kms_image_verify_toml=false
  if [[ "$KMS_IMAGE_VERIFY" == "1" ]]; then
    kms_image_verify_toml=true
  fi
  VMM_URL="http://127.0.0.1:${VMM_RPC_PORT}"
  KMS_URL_HOST="https://127.0.0.1:${KMS_RPC_PORT}"
  KMS_URL_GUEST="https://${KMS_DOMAIN}:${KMS_RPC_PORT}"
  GATEWAY_URL_GUEST="https://${GATEWAY_DOMAIN}:${GATEWAY_RPC_PORT}"
  GATEWAY_WG_INTERFACE="dgw-e2e-$(printf '%x' "$BASE_PORT")"
  GATEWAY_WG_IP="10.${SUBNET_INDEX}.3.1"
  GATEWAY_WG_KEY=$(cat "$CERTS_DIR/gateway.wg.key")
  GATEWAY_WG_PUBKEY=$(cat "$CERTS_DIR/gateway.wg.pub")

  write_self_signed_cert \
    "$CERTS_DIR/gateway-rpc.crt" \
    "$CERTS_DIR/gateway-rpc.key" \
    "$GATEWAY_DOMAIN" \
    "DNS:${GATEWAY_DOMAIN},DNS:localhost,IP:127.0.0.1"
  cp "$CERTS_DIR/gateway-rpc.crt" "$CERTS_DIR/gateway-ca.crt"

  write_self_signed_cert \
    "$CERTS_DIR/gateway-proxy.crt" \
    "$CERTS_DIR/gateway-proxy.key" \
    "*.${GATEWAY_PUBLIC_DOMAIN}" \
    "DNS:*.${GATEWAY_PUBLIC_DOMAIN},DNS:${GATEWAY_PUBLIC_DOMAIN},DNS:localhost,IP:127.0.0.1"
  prepare_kms_certs

  cat >"$CONFIG_DIR/kms.toml" <<EOF_KMS
workers = 4
max_blocking = 32
ident = "DStack KMS e2e"
temp_dir = "$RUN_DIR/tmp"
keep_alive = 10
log_level = "info"

[rpc]
address = "127.0.0.1"
port = $KMS_RPC_PORT

[rpc.tls]
key = "$CERTS_DIR/rpc.key"
certs = "$CERTS_DIR/rpc.crt"

[rpc.tls.mutual]
ca_certs = "$CERTS_DIR/tmp-ca.crt"
mandatory = false

[core]
cert_dir = "$CERTS_DIR"
admin_token_hash = ""
site_name = "dstack-e2e"
enforce_self_authorization = false
sev_snp_key_release = false
amd_kds_base_url = "$AMD_KDS_BASE_URL"
EOF_KMS
  if [[ -n "$PCCS_URL" ]]; then
    cat >>"$CONFIG_DIR/kms.toml" <<EOF_KMS_PCCS
pccs_url = "$PCCS_URL"
EOF_KMS_PCCS
  fi
  cat >>"$CONFIG_DIR/kms.toml" <<EOF_KMS_REST

[core.image]
verify = $kms_image_verify_toml
cache_dir = "$RUN_DIR/kms-cache"
download_url = "http://127.0.0.1:${KMS_RPC_PORT}/{OS_IMAGE_HASH}.tar.gz"
download_timeout = "2m"

[core.metrics]
enabled = true

[core.auth_api]
type = "dev"

[core.auth_api.dev]
gateway_app_id = "any"

[core.onboard]
enabled = true
auto_bootstrap_domain = "$KMS_DOMAIN"
address = "127.0.0.1"
port = $KMS_RPC_PORT
EOF_KMS_REST

  cat >"$CONFIG_DIR/gateway.toml" <<EOF_GATEWAY
workers = 4
max_blocking = 32
ident = "dstack Gateway e2e"
temp_dir = "$RUN_DIR/tmp"
keep_alive = 10
log_level = "info"
address = "127.0.0.1"
port = $GATEWAY_RPC_PORT

[tls]
key = "$CERTS_DIR/gateway-rpc.key"
certs = "$CERTS_DIR/gateway-rpc.crt"

[tls.mutual]
# App CVMs authenticate to the gateway with client certificates ultimately
# rooted at the KMS root CA (SignCert returns app cert -> app CA -> KMS root).
# Trust that root here; otherwise the TLS handshake is rejected before
# RegisterCvm reaches Rocket.
ca_certs = "$CERTS_DIR/root-ca.crt"
mandatory = false

[core]
kms_url = "$KMS_URL_HOST"
rpc_domain = ""
set_ulimit = false
EOF_GATEWAY
  if [[ -n "$PCCS_URL" ]]; then
    cat >>"$CONFIG_DIR/gateway.toml" <<EOF_GATEWAY_PCCS
pccs_url = "$PCCS_URL"
EOF_GATEWAY_PCCS
  fi
  cat >>"$CONFIG_DIR/gateway.toml" <<EOF_GATEWAY_REST

[core.auth]
enabled = false
url = "http://localhost/app-auth"
timeout = "5s"

[core.admin]
enabled = false
address = "127.0.0.1:$((GATEWAY_RPC_PORT + 1000))"
admin_token = ""
insecure_no_auth = false

[core.debug]
insecure_enable_debug_rpc = false
insecure_skip_attestation = true
key_file = ""
address = "127.0.0.1:$((GATEWAY_RPC_PORT + 1001))"

[core.wg]
private_key = "$GATEWAY_WG_KEY"
public_key = "$GATEWAY_WG_PUBKEY"
listen_port = $GATEWAY_WG_PORT
ip = "$GATEWAY_WG_IP/24"
reserved_net = ["$GATEWAY_WG_IP/31"]
client_ip_range = "$GATEWAY_WG_IP/24"
config_path = "$RUN_DIR/gateway-wg.conf"
interface = "$GATEWAY_WG_INTERFACE"
endpoint = "10.0.2.2:$GATEWAY_WG_PORT"

[core.proxy]
cert_chain = "$CERTS_DIR/gateway-proxy.crt"
cert_key = "$CERTS_DIR/gateway-proxy.key"
base_domain = "$GATEWAY_PUBLIC_DOMAIN"
listen_addr = "127.0.0.1"
listen_port = $GATEWAY_SERVE_PORT
external_port = $GATEWAY_SERVE_PORT
agent_port = 8090
localhost_enabled = false
app_address_ns_prefix = "_tapp-address"
app_address_ns_compat = true

[core.recycle]
enabled = true
interval = "5m"
timeout = "10h"
node_timeout = "10m"

[core.sync]
enabled = false
node_id = 1
my_url = "https://127.0.0.1:$GATEWAY_RPC_PORT"
interval = "1m"
timeout = "30s"
bootnode = ""
data_dir = "$RUN_DIR/gateway-data"
persist_interval = "5m"
sync_connections_enabled = false
sync_connections_interval = "30s"
EOF_GATEWAY_REST

  cat >"$CONFIG_DIR/vmm.toml" <<EOF_VMM
workers = 4
max_blocking = 32
ident = "dstack VMM e2e"
temp_dir = "$RUN_DIR/tmp"
keep_alive = 10
log_level = "info"
address = "127.0.0.1"
port = $VMM_RPC_PORT
reuse = true
kms_url = "$KMS_URL_HOST"
event_buffer_size = 50
node_name = "e2e"
run_path = "$RUN_DIR/vm"

[image]
path = "$IMAGE_DIR"
registry = ""

[cvm]
platform = "$TEE_PLATFORM"
qemu_path = "$QEMU_PATH"
kms_urls = ["$KMS_URL_GUEST"]
gateway_urls = ["$GATEWAY_URL_GUEST"]
pccs_url = "$PCCS_URL"
docker_registry = ""
cid_start = $CID_POOL_START
cid_pool_size = $CID_POOL_SIZE
max_allocable_vcpu = 256
max_allocable_memory_in_mb = 1048576
qmp_socket = false
user = ""
use_mrconfigid = true
qemu_pci_hole64_size = 0
qemu_hotplug_off = false
tdx_attestation_variant = "$TDX_ATTESTATION_VARIANT"
host_share_mode = "9p"
qgs_port = 4050

[cvm.networking]
mode = "user"
net = "10.0.2.0/24"
dhcp_start = "10.0.2.10"
restrict = false

[cvm.port_mapping]
enabled = true
address = "127.0.0.1"
range = [
  { protocol = "tcp", from = 1, to = 65535 },
  { protocol = "udp", from = 1, to = 65535 },
]

[cvm.auto_restart]
enabled = true
interval = 20

[cvm.gpu]
enabled = false
listing = []
exclude = []
include = []
allow_attach_all = false

[gateway]
base_domain = "$GATEWAY_PUBLIC_DOMAIN"
port = $GATEWAY_SERVE_PORT
agent_port = 8090

[auth]
enabled = false
tokens = []

[supervisor]
exe = "$SUPERVISOR_BIN"
sock = "$RUN_DIR/supervisor.sock"
pid_file = "$RUN_DIR/supervisor.pid"
log_file = "$LOG_DIR/supervisor.log"
detached = false
auto_start = true

[host_api]
ident = "dstack VMM e2e"
address = "vsock:2"
port = $HOST_API_PORT

[key_provider]
enabled = true
address = "127.0.0.1"
port = $KEY_PROVIDER_PORT
EOF_VMM

  cat >"$STATE_FILE" <<EOF_STATE
# Generated by e2e/run.sh. Safe to source from shell.
REPO_ROOT=$(printf '%q' "$REPO_ROOT")
WORK_DIR=$(printf '%q' "$WORK_DIR")
IMAGE_DIR=$(printf '%q' "$IMAGE_DIR")
IMAGE_NAME=$(printf '%q' "$IMAGE_NAME")
APP_COUNT=$(printf '%q' "$APP_COUNT")
APP_IMAGE=$(printf '%q' "$APP_IMAGE")
APP_KMS=$(printf '%q' "$APP_KMS")
APP_GATEWAY=$(printf '%q' "$APP_GATEWAY")
NO_TEE=$(printf '%q' "$NO_TEE")
TEE_PLATFORM=$(printf '%q' "$TEE_PLATFORM")
KMS_IMAGE_VERIFY=$(printf '%q' "$KMS_IMAGE_VERIFY")
KMS_STRICT_NO_QEMU=$(printf '%q' "$KMS_STRICT_NO_QEMU")
TDX_ATTESTATION_VARIANT=$(printf '%q' "$TDX_ATTESTATION_VARIANT")
VMM_URL=$(printf '%q' "$VMM_URL")
KMS_URL_HOST=$(printf '%q' "$KMS_URL_HOST")
KMS_URL_GUEST=$(printf '%q' "$KMS_URL_GUEST")
GATEWAY_URL_GUEST=$(printf '%q' "$GATEWAY_URL_GUEST")
GATEWAY_PUBLIC_DOMAIN=$(printf '%q' "$GATEWAY_PUBLIC_DOMAIN")
KMS_DOMAIN=$(printf '%q' "$KMS_DOMAIN")
GATEWAY_DOMAIN=$(printf '%q' "$GATEWAY_DOMAIN")
GATEWAY_WG_INTERFACE=$(printf '%q' "$GATEWAY_WG_INTERFACE")
KMS_RPC_PORT=$(printf '%q' "$KMS_RPC_PORT")
GATEWAY_RPC_PORT=$(printf '%q' "$GATEWAY_RPC_PORT")
GATEWAY_WG_PORT=$(printf '%q' "$GATEWAY_WG_PORT")
GATEWAY_SERVE_PORT=$(printf '%q' "$GATEWAY_SERVE_PORT")
VMM_RPC_PORT=$(printf '%q' "$VMM_RPC_PORT")
APP_HOST_PORT_BASE=$(printf '%q' "$APP_HOST_PORT_BASE")
CONFIG_DIR=$(printf '%q' "$CONFIG_DIR")
CERTS_DIR=$(printf '%q' "$CERTS_DIR")
RUN_DIR=$(printf '%q' "$RUN_DIR")
LOG_DIR=$(printf '%q' "$LOG_DIR")
PIDS_DIR=$(printf '%q' "$PIDS_DIR")
APPS_DIR=$(printf '%q' "$APPS_DIR")
KMS_BIN=$(printf '%q' "$KMS_BIN")
GATEWAY_BIN=$(printf '%q' "$GATEWAY_BIN")
VMM_BIN=$(printf '%q' "$VMM_BIN")
SUPERVISOR_BIN=$(printf '%q' "$SUPERVISOR_BIN")
VMM_CLI=$(printf '%q' "$VMM_CLI")
EOF_STATE
}

prepopulate_kms_image_cache() {
  if [[ "$KMS_IMAGE_VERIFY" != "1" ]]; then
    return 0
  fi
  if [[ "$KMS_STRICT_NO_QEMU" == "1" && "$TDX_ATTESTATION_VARIANT" == "lite" ]]; then
    log "skipping KMS image cache pre-population for no-QEMU lite verification"
    return 0
  fi
  local src_dir="$IMAGE_DIR/$IMAGE_NAME"
  local cache_dir="$RUN_DIR/kms-cache/images"
  local hashes=()
  mkdir -p "$cache_dir"

  if [[ -s "$src_dir/digest.txt" ]]; then
    hashes+=("$(tr -d '[:space:]' <"$src_dir/digest.txt")")
  fi
  if [[ -s "$src_dir/measurement.json" ]]; then
    while IFS= read -r hash; do
      [[ -n "$hash" ]] && hashes+=("$hash")
    done < <(python3 - "$src_dir/measurement.json" <<'PY'
import json
import sys
from pathlib import Path

doc = json.loads(Path(sys.argv[1]).read_text())
for section in ("tdx", "snp"):
    item = doc.get(section) or {}
    value = item.get("h") or item.get("os_image_hash")
    if value:
        print(value)
PY
    )
  fi

  if [[ ${#hashes[@]} -eq 0 ]]; then
    fatal "KMS image verification requested, but no digest.txt/measurement.json hash found in $src_dir"
  fi

  local hash dst count=0
  for hash in "${hashes[@]}"; do
    if [[ ! "$hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
      warn "skipping invalid image hash for KMS cache: $hash"
      continue
    fi
    dst="$cache_dir/${hash,,}"
    rm -rf "$dst"
    ln -s "$src_dir" "$dst"
    count=$((count + 1))
  done
  log "pre-populated KMS image cache with $count hash alias(es)"
}

start_user_process() {
  local name="$1"
  local bin="$2"
  local config="$3"
  local pidfile="$PIDS_DIR/${name}.pid"
  local logfile="$LOG_DIR/${name}.log"
  if pid_file_alive "$pidfile"; then
    log "$name already running (pid $(cat "$pidfile"))"
    return
  fi
  log "starting $name"
  local env_args=(RUST_LOG="$RUST_LOG_VALUE")
  if [[ "$name" == "kms" && "$KMS_STRICT_NO_QEMU" == "1" ]]; then
    env_args+=(PATH="/usr/sbin:/usr/bin:/sbin:/bin")
  fi
  # shellcheck disable=SC2016
  setsid nohup env "${env_args[@]}" sh -c 'echo $$ > "$1"; exec "$2" -c "$3"' sh "$pidfile" "$bin" "$config" \
    >>"$logfile" 2>&1 </dev/null &
}

can_sudo_nopass() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] && return 0
  sudo -n true >/dev/null 2>&1
}

start_gateway_process() {
  local pidfile="$PIDS_DIR/gateway.pid"
  local logfile="$LOG_DIR/gateway.log"
  if pid_file_alive "$pidfile"; then
    log "gateway already running (pid $(cat "$pidfile"))"
    return
  fi
  log "starting gateway (requires CAP_NET_ADMIN/root for WireGuard)"
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    # shellcheck disable=SC2016
    setsid nohup env RUST_LOG="$RUST_LOG_VALUE" sh -c 'echo $$ > "$1"; exec "$2" -c "$3"' sh "$pidfile" "$GATEWAY_BIN" "$CONFIG_DIR/gateway.toml" \
      >>"$logfile" 2>&1 </dev/null &
  elif sudo -n true >/dev/null 2>&1; then
    # Redirection is intentionally done by the caller so logs stay writable by the invoking user.
    # shellcheck disable=SC2016,SC2024
    setsid nohup sudo -n env RUST_LOG="$RUST_LOG_VALUE" sh -c 'echo $$ > "$1"; exec "$2" -c "$3"' sh "$pidfile" "$GATEWAY_BIN" "$CONFIG_DIR/gateway.toml" \
      >>"$logfile" 2>&1 </dev/null &
  else
    fatal "gateway requires root/CAP_NET_ADMIN and passwordless sudo is not available. Run this script with sudo -E or enable sudo -n."
  fi
}

wait_for_url() {
  local name="$1"
  local url="$2"
  local timeout="$3"
  local curl_extra=()
  shift 3
  curl_extra=("$@")
  local start now status
  start=$(date +%s)
  while true; do
    status=$(curl --noproxy '*' -ksS -o /dev/null -w '%{http_code}' --max-time 5 "${curl_extra[@]}" "$url" 2>/dev/null || true)
    if [[ "$status" =~ ^2|3|4 ]]; then
      log "$name is reachable ($status)"
      return 0
    fi
    now=$(date +%s)
    if (( now - start >= timeout )); then
      fatal "timeout waiting for $name at $url; see $LOG_DIR"
    fi
    sleep 2
  done
}

wait_for_vmm() {
  local start now
  start=$(date +%s)
  while true; do
    if vmm_cli lsimage --json >/dev/null 2>>"$LOG_DIR/vmm-cli.log"; then
      log "vmm is ready"
      return 0
    fi
    now=$(date +%s)
    if (( now - start >= STARTUP_TIMEOUT )); then
      fatal "timeout waiting for vmm; see $LOG_DIR/vmm.log and $LOG_DIR/vmm-cli.log"
    fi
    sleep 2
  done
}

start_services() {
  start_user_process kms "$KMS_BIN" "$CONFIG_DIR/kms.toml"
  wait_for_url kms "https://127.0.0.1:${KMS_RPC_PORT}/metrics" "$STARTUP_TIMEOUT"

  start_gateway_process
  wait_for_url gateway "https://127.0.0.1:${GATEWAY_RPC_PORT}/" "$STARTUP_TIMEOUT"

  start_user_process vmm "$VMM_BIN" "$CONFIG_DIR/vmm.toml"
  wait_for_vmm
}

write_app_compose_yaml() {
  local app_dir="$1"
  local index="$2"
  cat >"$app_dir/docker-compose.yaml" <<EOF_APP
version: "3.8"
services:
  web:
    image: "$APP_IMAGE"
    command:
      - sh
      - -c
      - |
        mkdir -p /www
        echo "dstack-e2e app ${index} OK" > /www/index.html
        httpd -f -p 8080 -h /www
    ports:
      - "8080:8080"
    restart: unless-stopped
EOF_APP
}

compose_app() {
  local app_dir="$1"
  local app_name="$2"
  local args=(compose --name "$app_name" --docker-compose "$app_dir/docker-compose.yaml" --public-logs --public-sysinfo --output "$app_dir/app-compose.json")
  if [[ "$APP_KMS" == "1" ]]; then
    args+=(--kms)
  fi
  if [[ "$APP_GATEWAY" == "1" ]]; then
    args+=(--gateway)
  fi
  vmm_cli "${args[@]}" >"$app_dir/compose.out" 2>&1
}

calc_app_id() {
  local compose_file="$1"
  python3 - "$compose_file" <<'PY'
import hashlib
import sys
print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest()[:40])
PY
}

deploy_apps() {
  local i app_dir app_name host_port app_id vm_id out deploy_args gateway_host
  : >"$LOG_DIR/deploy.log"
  for ((i = 1; i <= APP_COUNT; i++)); do
    app_name="e2e-app-${i}"
    app_dir="$APPS_DIR/$app_name"
    mkdir -p "$app_dir"
    host_port=$((APP_HOST_PORT_BASE + i - 1))
    write_app_compose_yaml "$app_dir" "$i"
    log "creating app-compose for $app_name"
    compose_app "$app_dir" "$app_name"
    app_id=$(calc_app_id "$app_dir/app-compose.json")
    gateway_host="${app_id}-8080.${GATEWAY_PUBLIC_DOMAIN}"

    deploy_args=(deploy --name "$app_name" --image "$IMAGE_NAME" --compose "$app_dir/app-compose.json" \
      --vcpu "$APP_VCPU" --memory "$APP_MEMORY" --disk "$APP_DISK" \
      --port "tcp:127.0.0.1:${host_port}:8080" \
      --kms-url "$KMS_URL_GUEST" --gateway-url "$GATEWAY_URL_GUEST")
    if [[ "$NO_TEE" == "1" ]]; then
      deploy_args+=(--no-tee)
    fi

    log "deploying $app_name (host port $host_port, app_id $app_id)"
    if ! out=$(vmm_cli "${deploy_args[@]}" 2>&1); then
      printf '%s\n' "$out" | tee -a "$LOG_DIR/deploy.log" >&2
      fatal "failed to deploy $app_name"
    fi
    printf '%s\n' "$out" >>"$LOG_DIR/deploy.log"
    vm_id=$(printf '%s\n' "$out" | awk '/Created VM with ID:/ {print $NF; exit}')
    [[ -n "$vm_id" ]] || fatal "could not parse VM id from deploy output for $app_name"

    cat >>"$STATE_FILE" <<EOF_APP_STATE
APP_${i}_NAME=$(printf '%q' "$app_name")
APP_${i}_DIR=$(printf '%q' "$app_dir")
APP_${i}_VM_ID=$(printf '%q' "$vm_id")
APP_${i}_APP_ID=$(printf '%q' "$app_id")
APP_${i}_HOST_PORT=$(printf '%q' "$host_port")
APP_${i}_GATEWAY_HOST=$(printf '%q' "$gateway_host")
EOF_APP_STATE
  done
}

wait_for_body() {
  local name="$1"
  local url="$2"
  local expected="$3"
  local timeout="$4"
  shift 4
  local curl_extra=("$@")
  local start now body
  start=$(date +%s)
  while true; do
    body=$(curl --noproxy '*' -fsS --max-time 5 "${curl_extra[@]}" "$url" 2>/dev/null || true)
    if [[ "$body" == *"$expected"* ]]; then
      log "$name OK"
      return 0
    fi
    now=$(date +%s)
    if (( now - start >= timeout )); then
      warn "last response from $name: ${body:-<empty>}"
      fatal "timeout waiting for $name at $url; see VM logs via './e2e/run.sh logs'"
    fi
    sleep 5
  done
}

smoke_apps() {
  [[ -f "$STATE_FILE" ]] || fatal "state file not found: $STATE_FILE"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  local i name host_port gateway_host expected
  for ((i = 1; i <= APP_COUNT; i++)); do
    eval "name=\${APP_${i}_NAME:-}"
    eval "host_port=\${APP_${i}_HOST_PORT:-}"
    eval "gateway_host=\${APP_${i}_GATEWAY_HOST:-}"
    [[ -n "$name" && -n "$host_port" ]] || fatal "missing state for app $i"
    expected="dstack-e2e app ${i} OK"
    wait_for_body "$name host-port" "http://127.0.0.1:${host_port}/" "$expected" "$APP_TIMEOUT"
    if [[ "$APP_GATEWAY" == "1" && -n "$gateway_host" ]]; then
      wait_for_body "$name gateway" "https://${gateway_host}:${GATEWAY_SERVE_PORT}/" "$expected" "$APP_TIMEOUT" \
        -k --resolve "${gateway_host}:${GATEWAY_SERVE_PORT}:127.0.0.1"
    fi
  done
}

print_summary() {
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  cat <<EOF_SUMMARY

[e2e] Stack is up.
  Work dir:        $WORK_DIR
  Image:           $IMAGE_NAME
  VMM API:         $VMM_URL
  KMS guest URL:   $KMS_URL_GUEST
  Gateway RPC:     $GATEWAY_URL_GUEST
  Gateway proxy:   https://<app_id>-8080.$GATEWAY_PUBLIC_DOMAIN:$GATEWAY_SERVE_PORT

Apps:
EOF_SUMMARY
  local i name vm_id app_id host_port gateway_host
  for ((i = 1; i <= APP_COUNT; i++)); do
    eval "name=\${APP_${i}_NAME:-}"
    eval "vm_id=\${APP_${i}_VM_ID:-}"
    eval "app_id=\${APP_${i}_APP_ID:-}"
    eval "host_port=\${APP_${i}_HOST_PORT:-}"
    eval "gateway_host=\${APP_${i}_GATEWAY_HOST:-}"
    [[ -n "$name" ]] || continue
    printf '  - %s\n' "$name"
    printf '      vm_id:       %s\n' "$vm_id"
    printf '      app_id:      %s\n' "$app_id"
    printf '      host URL:    http://127.0.0.1:%s/\n' "$host_port"
    if [[ -n "$gateway_host" ]]; then
      printf '      gateway URL: https://%s:%s/  (use curl -k --resolve %s:%s:127.0.0.1)\n' \
        "$gateway_host" "$GATEWAY_SERVE_PORT" "$gateway_host" "$GATEWAY_SERVE_PORT"
    fi
  done
  cat <<EOF_NEXT

Useful commands:
  ./e2e/run.sh status
  ./e2e/run.sh logs
  ./e2e/run.sh smoke
  ./e2e/run.sh down
EOF_NEXT
}

load_state_or_die() {
  [[ -f "$STATE_FILE" ]] || fatal "no e2e state at $STATE_FILE"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

remove_vms() {
  load_state_or_die
  if ! pid_file_alive "$PIDS_DIR/vmm.pid"; then
    warn "vmm is not running; skipping VM removal"
    return 0
  fi
  local i vm_id
  for ((i = 1; i <= APP_COUNT; i++)); do
    eval "vm_id=\${APP_${i}_VM_ID:-}"
    [[ -n "$vm_id" ]] || continue
    log "removing VM $vm_id"
    vmm_cli remove "$vm_id" >>"$LOG_DIR/down.log" 2>&1 || warn "failed to remove VM $vm_id (continuing)"
  done
}

kill_pidfile() {
  local name="$1"
  local pidfile="$PIDS_DIR/${name}.pid"
  [[ -f "$pidfile" ]] || return 0
  local pid
  pid=$(cat "$pidfile" 2>/dev/null || true)
  if ! is_pid_alive "$pid"; then
    rm -f "$pidfile"
    return 0
  fi
  log "stopping $name (pid $pid)"
  if kill "$pid" >/dev/null 2>&1; then
    true
  elif can_sudo_nopass; then
    sudo -n kill "$pid" >/dev/null 2>&1 || true
  fi
  local deadline=$(( $(date +%s) + 20 ))
  while is_pid_alive "$pid" && (( $(date +%s) < deadline )); do
    sleep 1
  done
  if is_pid_alive "$pid"; then
    warn "$name did not stop gracefully; killing"
    if kill -9 "$pid" >/dev/null 2>&1; then
      true
    elif can_sudo_nopass; then
      sudo -n kill -9 "$pid" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$pidfile"
}

cleanup_wireguard() {
  if [[ -z "${GATEWAY_WG_INTERFACE:-}" ]]; then
    return 0
  fi
  [[ "$GATEWAY_WG_INTERFACE" == dgw-e2e-* ]] || {
    warn "refusing to delete non-e2e WireGuard interface: $GATEWAY_WG_INTERFACE"
    return 0
  }
  if ip link show "$GATEWAY_WG_INTERFACE" >/dev/null 2>&1; then
    log "deleting WireGuard interface $GATEWAY_WG_INTERFACE"
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
      ip link del "$GATEWAY_WG_INTERFACE" || true
    elif sudo -n true >/dev/null 2>&1; then
      sudo -n ip link del "$GATEWAY_WG_INTERFACE" || true
    else
      warn "cannot delete $GATEWAY_WG_INTERFACE without sudo"
    fi
  fi
}

cmd_up() {
  require_cmd python3
  require_cmd curl
  require_cmd openssl
  require_cmd wg
  require_cmd ip
  require_cmd setsid
  python3 -c 'import cryptography' >/dev/null 2>&1 || \
    fatal "missing Python package: cryptography (needed to generate dev KMS certificates)"

  if have_live_stack; then
    if [[ "$FORCE" == "1" ]]; then
      warn "existing e2e stack detected; tearing it down because --force was set"
      cmd_down || true
    else
      fatal "existing e2e stack detected at $WORK_DIR. Run './e2e/run.sh down' first or pass --force."
    fi
  fi

  prepare_dirs
  allocate_ports
  detect_image
  resolve_binaries
  prepare_wireguard_key
  write_configs
  prepopulate_kms_image_cache

  log "using work dir: $WORK_DIR"
  log "using image: $IMAGE_NAME"
  start_services
  deploy_apps
  smoke_apps
  print_summary

  if [[ "$CLEANUP_AFTER_TEST" == "1" ]]; then
    log "--cleanup requested; tearing stack down"
    cmd_down
  fi
}

cmd_smoke() {
  require_cmd curl
  load_state_or_die
  smoke_apps
  log "smoke checks passed"
}

cmd_status() {
  load_state_or_die
  local name pidfile pid state
  for name in kms gateway vmm; do
    pidfile="$PIDS_DIR/${name}.pid"
    pid=""
    [[ -f "$pidfile" ]] && pid=$(cat "$pidfile" 2>/dev/null || true)
    if is_pid_alive "$pid"; then state=running; else state=stopped; fi
    printf '%-8s %-8s %s\n' "$name" "$state" "${pid:-'-'}"
  done
  if pid_file_alive "$PIDS_DIR/vmm.pid"; then
    echo
    vmm_cli lsvm || true
  fi
}

cmd_logs() {
  local service=all
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --service) service="$2"; shift 2 ;;
      *) fatal "unknown logs option: $1" ;;
    esac
  done
  load_state_or_die
  case "$service" in
    kms|gateway|vmm|supervisor)
      touch "$LOG_DIR/${service}.log"
      tail -n 200 -f "$LOG_DIR/${service}.log"
      ;;
    all)
      touch "$LOG_DIR/kms.log" "$LOG_DIR/gateway.log" "$LOG_DIR/vmm.log" "$LOG_DIR/supervisor.log"
      tail -n 80 -f "$LOG_DIR/kms.log" "$LOG_DIR/gateway.log" "$LOG_DIR/vmm.log" "$LOG_DIR/supervisor.log"
      ;;
    *) fatal "unknown service: $service" ;;
  esac
}

cmd_down() {
  if [[ ! -f "$STATE_FILE" ]]; then
    warn "no e2e state at $STATE_FILE"
    return 0
  fi
  load_state_or_die
  : >"$LOG_DIR/down.log" || true
  remove_vms || true
  kill_pidfile vmm
  kill_pidfile gateway
  kill_pidfile kms
  # Supervisor is usually a child managed by VMM, but stop it if its pidfile exists.
  if [[ -f "$RUN_DIR/supervisor.pid" ]]; then
    local spid
    spid=$(cat "$RUN_DIR/supervisor.pid" 2>/dev/null || true)
    if is_pid_alive "$spid"; then
      log "stopping supervisor (pid $spid)"
      kill "$spid" >/dev/null 2>&1 || sudo -n kill "$spid" >/dev/null 2>&1 || true
    fi
  fi
  cleanup_wireguard
  log "e2e stack stopped; logs kept in $LOG_DIR"
}

cmd_clean() {
  cmd_down || true
  if ! rm -rf "$WORK_DIR" 2>/dev/null; then
    if can_sudo_nopass; then
      sudo -n rm -rf "$WORK_DIR"
    else
      fatal "failed to remove $WORK_DIR (some files may be root-owned); rerun with sudo or remove it manually"
    fi
  fi
  log "removed $WORK_DIR"
}

case "$COMMAND" in
  up|test) cmd_up ;;
  smoke) cmd_smoke ;;
  status) cmd_status ;;
  logs) cmd_logs "$@" ;;
  down) cmd_down ;;
  clean) cmd_clean ;;
  help|-h|--help) usage ;;
  *) usage; fatal "unknown command: $COMMAND" ;;
esac
