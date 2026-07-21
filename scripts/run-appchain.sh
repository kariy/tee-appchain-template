#!/usr/bin/env bash
# Launch the appchain: a bare katana rollup node that settles to Starknet via katana's
# embedded settlement service. Run by the mock-mode systemd unit (host/appchain.service.tpl,
# rendered per combo by scripts/deploy.sh); also runnable standalone for local debugging.
#
# Config is read from /etc/<unit>/env (written by scripts/deploy.sh):
#   KATANA          path to the katana binary (see appchain.conf KATANA_VERSION)
#   APPCHAIN_PORT   JSON-RPC port (default 5070)
#   METRICS_PORT    Prometheus metrics port, loopback (default 9110; scraped by host/monitoring)
#   BASE            on-host root (/var/lib/<unit>; required — the unit env always sets it)
# Derived: CHAIN_DIR=$BASE/chain-config (config.toml carries [settlement.runtime],
# appended at deploy from the SAYA key), DATA_DIR=$BASE/data, LOG_DIR=$BASE/logs.
set -euo pipefail

KATANA="${KATANA:-/usr/local/bin/katana}"
APPCHAIN_PORT="${APPCHAIN_PORT:-5070}"
METRICS_PORT="${METRICS_PORT:-9110}"
BASE="${BASE:?error: BASE unset — run via the systemd unit env, or export BASE=/var/lib/<unit>}"
CHAIN_DIR="${CHAIN_DIR:-$BASE/chain-config}"
DATA_DIR="${DATA_DIR:-$BASE/data}"
LOG_DIR="${LOG_DIR:-$BASE/logs}"

[[ -x "$KATANA" ]] || { echo "error: katana not found/executable: $KATANA" >&2; exit 1; }
[[ -f "$CHAIN_DIR/config.toml" ]] || { echo "error: no rollup config at $CHAIN_DIR — run scripts/init.sh + deploy first" >&2; exit 1; }
mkdir -p "$DATA_DIR" "$LOG_DIR"

# The block explorer is a build-time feature: the official release tarballs are built
# without it (only the _native build / asdf has it). Include --explorer only when this
# katana actually supports it, so the node still boots on an explorer-less build.
EXPLORER_FLAG=""
"$KATANA" --help 2>/dev/null | grep -q -- '--explorer' && EXPLORER_FLAG="--explorer"

echo "→ appchain (katana $($KATANA --version 2>/dev/null | head -1)) on :$APPCHAIN_PORT"
# --tee mock: exercises the settlement/attestation plumbing against the real settlement
#   network without a real SP1/TEE prover. --block-time: steady cadence so embedded
#   settlement batches rather than bursting a block per action. --rpc.max-request-body-size
#   20MB: allow large contract-class declares (default ~10MB); keep the nginx vhost >= this.
#   --paymaster/--cartridge.*: Controller-capable (paymaster + session + classes at genesis).
#   --vrf: katana bootstraps the on-chain VRF account and spawns the `vrf-server` sidecar
#     (from PATH, :3000 loopback), passing it the derived credentials. Requires the
#     paymaster (the VRF flow uses it as relayer/forwarder) — already on. The vrf-server
#     binary is installed on the host (katana release sidecar); see HOST_SETUP.md.
#   --metrics: Prometheus exporter on 127.0.0.1:$METRICS_PORT (loopback; host/monitoring scrapes it).
#   --log.stdout.format json: structured stdout → journald → promtail/Loki parses fields into labels.
exec "$KATANA" --chain "$CHAIN_DIR" --tee mock --dev --dev.no-fee --block-time "${BLOCK_TIME_MS:-5000}" \
  --data-dir "$DATA_DIR" --http.port "$APPCHAIN_PORT" --http.cors_origins '*' \
  --messaging.enabled $EXPLORER_FLAG \
  --metrics --metrics.addr 127.0.0.1 --metrics.port "$METRICS_PORT" \
  --log.stdout.format json \
  --log.file --log.file.directory "$LOG_DIR" --log.file.max-files 7 \
  --rpc.max-request-body-size 20000000 \
  --paymaster --cartridge.paymaster --cartridge.controllers --vrf
