#!/usr/bin/env bash
# run-enclave.sh — Launch the appchain INSIDE an AMD SEV-SNP confidential VM (real TEE),
# instead of bare-metal. The katana sequencer runs in the enclave with `--tee sev-snp`,
# settling to Starknet via embedded settlement against the REAL on-chain AMDTeeRegistry
# (not the mock). The enclave's launch measurement + per-block `report_data` are
# hardware-attested (AMD SEV-SNP) and verifiable on-chain. See TEE.md.
#
# Run by the enclave-mode systemd unit (host/enclave.service.tpl, rendered per combo by
# scripts/deploy.sh) as root — needs KVM + /dev/sev*. Also runnable standalone for
# debugging. Config from /etc/<unit>/env (written by scripts/deploy.sh):
#   KATANA_TEE_VERSION  TEE-VM image release tag (default below; appchain.conf pins it)
#   APPCHAIN_PORT       host RPC port forwarded to the guest's :5050 (default 5071 — the
#                       mock bare-katana node keeps :5070, so both coexist on one host)
#   METRICS_PORT        host loopback port forwarded to the guest katana metrics :9100
#                       (empty ⇒ not forwarded; deploy.sh sets it per combo)
#   BASE                on-host root (/var/lib/<unit>; required — the unit env always sets it)
# Derived: IMAGE_DIR=$BASE/vm-image/$KATANA_TEE_VERSION (OVMF/vmlinuz/initrd — the prebuilt
# enclave image, keyed by tag so a version bump refetches and rollback is a version flip),
# CHAIN_DIR=$BASE/chain-config (config.toml carries [settlement.runtime]; mounted
# read-only in the guest and passed to katana as --chain), DATA_DISK=$BASE/data.img
# (ext4; the guest's persistent /dev/sda — unsealed; see TEE.md for sealed mode).
set -euo pipefail

KATANA_TEE_VERSION="${KATANA_TEE_VERSION:-tee-vm-v0.3.0+katana-v1.8.0-rc.8}"
APPCHAIN_PORT="${APPCHAIN_PORT:-5071}"
METRICS_PORT="${METRICS_PORT:-}"
# 10G: headroom for the appchain + SP1 executor (a Controller-enabled ~18 MB genesis
# OOM-kills katana at the image default 512M). RAM size is NOT a launch-measurement input,
# so it doesn't change the attestation.
MEMORY="${MEMORY:-10G}"
# Match the guest vCPU count to the host CPU count (single-core bottlenecks katana). vCPU
# count IS a launch-measurement input, so this changes the measurement — still verifies
# on-chain (the registry doesn't pin a measurement). Override VCPU_COUNT for headroom.
VCPU_COUNT="${VCPU_COUNT:-$(nproc)}"
BASE="${BASE:?error: BASE unset — run via the systemd unit env, or export BASE=/var/lib/<unit>}"
# Keyed by release tag: the download step below skips when the image files exist, so a
# flat dir would silently keep serving the old image after a version bump.
IMAGE_DIR="${IMAGE_DIR:-$BASE/vm-image/$KATANA_TEE_VERSION}"
CHAIN_DIR="${CHAIN_DIR:-$BASE/chain-config}"
DATA_DISK="${DATA_DISK:-$BASE/data.img}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="${LAUNCHER:-$REPO_DIR/host/amdsev/start-vm.sh}"

[[ -f "$CHAIN_DIR/config.toml" ]] || { echo "error: no rollup config at $CHAIN_DIR — run scripts/init.sh + deploy first" >&2; exit 1; }
[[ -x "$LAUNCHER" ]] || { echo "error: enclave launcher missing: $LAUNCHER" >&2; exit 1; }

# 1. Ensure the reproducible TEE-VM image (OVMF + kernel + initrd-with-katana) is present.
#    It ships PREBUILT from the katana release; its launch measurement is published
#    alongside (see TEE.md) — we do NOT build it. The image is self-sufficient for embedded
#    settlement: from tee-vm-v0.1.3+katana-v1.8.0-rc.8 the initrd bakes in the SP1 v6.1.0
#    katana, a tmpfs /dev/shm (SP1 executor) + IPv4 preference (qemu SLIRP has no IPv6), and
#    the CA bundle at both openssl (/usr/local/ssl/cert.pem, for AMD KDS) and rustls
#    (/etc/ssl/certs/ca-certificates.crt, …, for the Starknet settlement RPC + messaging)
#    trust stores — so outbound HTTPS works with NO host-side initrd patching. From
#    tee-vm-v0.2.0 the initrd additionally bundles the paymaster-service + vrf-server
#    sidecars at /bin (plus libssl3 and the CA bundle at the system-openssl path
#    /usr/lib/ssl/cert.pem that paymaster-service reads) — enabling the Controller/VRF
#    flags below. From tee-vm-v0.3.0 the embedded katana is the CAIRO-NATIVE release
#    build and the initrd bundles /bin/ld + the -lc link inputs cairo-native needs to
#    AOT-link contract classes at runtime — enabling --enable-native-compilation below.
#    We boot the published initrd.img directly, so the running measurement matches the
#    release's.
if [[ ! -f "$IMAGE_DIR/OVMF.fd" || ! -f "$IMAGE_DIR/vmlinuz" || ! -f "$IMAGE_DIR/initrd.img" ]]; then
  echo "→ fetching TEE-VM image $KATANA_TEE_VERSION…"
  mkdir -p "$IMAGE_DIR"
  url="https://github.com/dojoengine/katana/releases/download/${KATANA_TEE_VERSION}/katana-tee-vm-${KATANA_TEE_VERSION}.tar.gz"
  curl -sSL --max-time 300 -o "$IMAGE_DIR/vm.tgz" "$url"
  tar xzf "$IMAGE_DIR/vm.tgz" -C "$IMAGE_DIR" && rm -f "$IMAGE_DIR/vm.tgz"
fi

# 2. Persistent data disk = the guest's /dev/sda. Unsealed mode expects a pre-formatted
#    ext4 fs (it does NOT auto-format); format once if blank. Sealed mode would instead
#    LUKS-format on first boot — a DIFFERENT launch measurement (see TEE.md).
if [[ ! -f "$DATA_DISK" ]]; then
  truncate -s 1G "$DATA_DISK"
  mkfs.ext4 -F -q "$DATA_DISK"
fi

# 3. Katana args delivered to the enclave via fw_cfg (opt/org.katana/args — NOT part of
#    the launch measurement, but bound into the attestation report_data). `--tee sev-snp`
#    selects the real AMD attester. The chain config (genesis + [settlement.runtime] with
#    the saya key + the REAL tee-registry) reaches the guest via --chain-dir (mounted
#    read-only at /run/katana-chain; start-vm.sh passes it to katana as --chain, and owns
#    --chain/--db-*/--data-dir, so we must NOT set those here).
#    --paymaster/--cartridge.*/--vrf: Controller-capable, same as the mock deployment.
#    Works from tee-vm-v0.2.0 because the initrd ships paymaster-service + vrf-server at
#    /bin — katana's sidecar resolution hits them at the $PATH step (guest init exports
#    PATH=/bin), so the enclave-fatal auto-install prompt never runs. Both sidecars bind
#    guest-loopback ephemeral ports and are proxied through katana's cartridge_* RPC on
#    :5050 — no extra port forwarding. The guest-side arg filter only strips
#    --data-dir/--db-*/--chain, so these flags pass through fw_cfg untouched.
#    --enable-native-compilation: cairo-native execution (off by default in katana).
#    Works from tee-vm-v0.3.0: the embedded katana is the native release build and the
#    initrd ships /bin/ld + a generated /lib64/libc.so, which cairo-native's AOT path
#    shells out to for linking each compiled class into a dlopen-able .so. Compilation
#    is async (classes execute on the VM until their native build lands), so enabling
#    it changes performance, not results. An OLDER (pre-v0.3.0) image would kill katana
#    at startup on the unknown flag — bump KATANA_TEE_VERSION and this flag together.
# --metrics on guest 0.0.0.0:9100 (start-vm.sh forwards it to host 127.0.0.1:$METRICS_PORT when set);
# --log.stdout.format json so the serial→journald stream carries structured katana lines for Loki
# (sidecar stdout is plain text and lands unparsed — cosmetic).
# BLOCK_TIME_MS comes from the unit env (written by deploy.sh, which also derives
# the settlement batch size from it) — one source of truth for the block cadence.
BLOCK_TIME_MS="${BLOCK_TIME_MS:-5000}"
KATANA_ARGS="--http.addr,0.0.0.0,--http.port,5050,--tee,sev-snp,--dev,--dev.no-fee,--block-time,${BLOCK_TIME_MS},--http.cors_origins,*,--messaging.enabled,--rpc.max-request-body-size,20000000,--metrics,--metrics.addr,0.0.0.0,--metrics.port,9100,--log.stdout.format,json,--paymaster,--cartridge.paymaster,--cartridge.controllers,--vrf,--enable-native-compilation"

echo "→ appchain — SEV-SNP enclave (host :$APPCHAIN_PORT → guest :5050)"
# start-vm.sh boots qemu, delivers the chain dir + args, sends `start` over the control
# channel, then tails the serial log in the foreground (so systemd keeps the VM alive).
HOST_RPC_PORT="$APPCHAIN_PORT" HOST_METRICS_PORT="$METRICS_PORT" MEMORY="$MEMORY" VCPU_COUNT="$VCPU_COUNT" exec "$LAUNCHER" \
  --ovmf "$IMAGE_DIR/OVMF.fd" --kernel "$IMAGE_DIR/vmlinuz" --initrd "$IMAGE_DIR/initrd.img" \
  --data-disk "$DATA_DISK" \
  --chain-dir "$CHAIN_DIR" \
  --katana-args "$KATANA_ARGS"
