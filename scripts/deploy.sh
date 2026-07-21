#!/usr/bin/env bash
# deploy.sh — deploy an appchain combo to the host. Idempotent.
#
# Two dimensions (defaults NETWORK=sepolia, MODE=enclave):
#   NETWORK ∈ {sepolia, mainnet}  — settlement network
#   MODE    ∈ {enclave, mock}     — enclave: katana in an AMD SEV-SNP VM (--tee sev-snp, real
#                                   SP1 Groth16 proofs); mock: bare katana --tee mock (software
#                                   attestation, mock TEE registry).
# Each (network,mode) is its own systemd unit / state dir / env file / port, all coexisting.
# The unit name, ports, and registry derive from appchain.conf via scripts/lib/config.sh
# (unit ${CHAIN_NAME}-${network}-${mode}, rpc BASE_PORT+idx, metrics METRICS_BASE_PORT+idx).
# Enclave units run as root (need /dev/kvm + /dev/sev*). No host katana binary in enclave mode
# (the enclave boots the self-contained TEE-VM image); mock mode installs the pinned binary.
# nginx: the host-level $APPCHAIN_DOMAIN router installs when MODE=mock or INSTALL_NGINX=1
# (host-level, deployment-independent).
#
# Usage:  [NETWORK=… MODE=…] scripts/deploy.sh <user@host>
# Env (all appchain.conf-derived defaults overridable):
#   NETWORK / MODE                   see above
#   SETTLEMENT_ADDRESS / SETTLEMENT_PRIVATE_KEY  settlement account (embedded-settlement runtime) — required
#   PROVER_KEY                       SP1 prover-network key → real Groth16 (enclave; absent ⇒ Mock)
#   TEE_REGISTRY_ADDRESS             on-chain TEE registry (per-combo default)
#   KATANA_VERSION                   katana binary release to install (mock mode; conf pin)
#   KATANA_TEE_VERSION               TEE-VM image tag (enclave mode; conf pin)
#   APPCHAIN_PORT / METRICS_PORT     host ports (per-combo default; must be unique)
#   VCPU_COUNT / MEMORY              enclave VM resources (optional; forwarded to run-enclave.sh)
#   INSTALL_NGINX                    force (re)install the host nginx router (also runs for MODE=mock)
#   CERTBOT_EMAIL                    optional ACME account email
#   RENDER_ONLY                      render templates + print the plan, no ssh (dry run)
#   SETTLEMENT_BATCH_SIZE            blocks per update_state batch (fixed default 120). One
#                                    SP1 proof + one update_state covers the whole batch and
#                                    their cost is ~independent of batch size, so a bigger
#                                    batch divides PROVE + STRK cost per block ~linearly;
#                                    the price is settlement latency.
#   IDLE_FLUSH_SECS                  settle a partial batch after this long (default 600 =
#                                    10 min). katana resets the idle deadline after each
#                                    SETTLE (not on new blocks), so this is the maximum time
#                                    between settlements on a slow chain.
#   BLOCK_TIME_MS                    appchain block time (conf default). Written to the unit
#                                    env, where the runners pass it to katana as --block-time.
#                                    All three applied idempotently — redeploys update the
#                                    existing lines in the host chain config.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"
validate_config

SSH_TARGET="${1:-}"
[[ -n "$SSH_TARGET" || -n "${RENDER_ONLY:-}" ]] || { echo "usage: deploy.sh <user@host>" >&2; exit 2; }
NETWORK="${NETWORK:-sepolia}"
MODE="${MODE:-enclave}"
resolve_combo "$NETWORK" "$MODE"
UNIT="$COMBO_UNIT"
CHAIN_CONFIG_SRC="$COMBO_CHAIN_CONFIG_DIR"
BASE="$COMBO_BASE"
ENVDIR="$COMBO_ENVDIR"
APPCHAIN_PORT="${APPCHAIN_PORT:-$COMBO_RPC_PORT}"
# katana Prometheus metrics port (loopback; scraped by host/monitoring). Mock binds it directly;
# the enclave binds guest :9100 and start-vm.sh forwards it to this host loopback port.
METRICS_PORT="${METRICS_PORT:-$COMBO_METRICS_PORT}"
TEE_REGISTRY_ADDRESS="${TEE_REGISTRY_ADDRESS:-$COMBO_REGISTRY}"
SETTLEMENT_BATCH_SIZE="${SETTLEMENT_BATCH_SIZE:-120}"
IDLE_FLUSH_SECS="${IDLE_FLUSH_SECS:-600}"
[[ "$BLOCK_TIME_MS" =~ ^[1-9][0-9]*$ ]] || { echo "error: BLOCK_TIME_MS must be a positive integer (got '$BLOCK_TIME_MS')" >&2; exit 2; }
[[ "$SETTLEMENT_BATCH_SIZE" =~ ^[1-9][0-9]*$ ]] || { echo "error: SETTLEMENT_BATCH_SIZE must be a positive integer (got '$SETTLEMENT_BATCH_SIZE')" >&2; exit 2; }
[[ "$IDLE_FLUSH_SECS" =~ ^[1-9][0-9]*$ ]] || { echo "error: IDLE_FLUSH_SECS must be a positive integer (got '$IDLE_FLUSH_SECS')" >&2; exit 2; }

REPO_DIR="$APPCHAIN_ROOT"
say() { echo "→ $*"; }

# Render the host templates for this combo (systemd unit + nginx router) on the controller —
# the host only ever sees final files.
RENDER_DIR="$(mktemp -d)"
export UNIT DEPLOY_USER APPCHAIN_DOMAIN CHAIN_NAME
export_combo_matrix
if [ "$MODE" = enclave ]; then
  render_template "$REPO_DIR/host/enclave.service.tpl" "$RENDER_DIR/$UNIT.service"
else
  render_template "$REPO_DIR/host/appchain.service.tpl" "$RENDER_DIR/$UNIT.service"
fi
render_template "$REPO_DIR/host/appchain.nginx.tpl" "$RENDER_DIR/appchain.nginx"

say "network=$NETWORK mode=$MODE unit=$UNIT port=$APPCHAIN_PORT registry=$TEE_REGISTRY_ADDRESS"
if [ -n "${RENDER_ONLY:-}" ]; then
  print_combo_map
  say "RENDER_ONLY — rendered templates in $RENDER_DIR, no ssh:"
  ls -l "$RENDER_DIR"
  exit 0
fi

for v in SETTLEMENT_ADDRESS SETTLEMENT_PRIVATE_KEY; do [[ -n "${!v:-}" ]] || { echo "error: set $v" >&2; exit 2; }; done
# SP1 prover key (enclave real proving) — normalize to 0x-prefixed hex; ignored in mock mode.
[[ -n "${PROVER_KEY:-}" && "${PROVER_KEY}" != 0x* ]] && PROVER_KEY="0x${PROVER_KEY}"
[[ "$MODE" = enclave && -z "${PROVER_KEY:-}" ]] && echo "→ warning: PROVER_KEY unset — enclave will run TeeProver::Mock (no real SP1 proofs)" >&2

SHA="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || date -u +%Y%m%d%H%M%S)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET")

# 1. (mock only) install the pinned katana binary. Enclave mode boots the self-contained
#    TEE-VM image instead (run-enclave.sh fetches it) — no host binary.
if [ "$MODE" = mock ]; then
  say "ensuring katana $KATANA_VERSION on the host…"
  "${SSH[@]}" KATANA_VERSION="$KATANA_VERSION" 'bash -s' <<'EOF'
set -e
want="${KATANA_VERSION#v}"
if ! /usr/local/bin/katana --version 2>/dev/null | head -1 | grep -q "$want"; then
  cd /tmp && rm -rf katinst && mkdir katinst && cd katinst
  url="https://github.com/dojoengine/katana/releases/download/${KATANA_VERSION}/katana_${KATANA_VERSION}_linux_amd64_native.tar.gz"
  curl -sSL --max-time 180 -o k.tgz "$url"; tar xzf k.tgz
  sudo install -m755 "$(find . -type f -name katana | head -1)" /usr/local/bin/katana
  cd / && rm -rf /tmp/katinst
fi
/usr/local/bin/katana --version | head -1
EOF
fi

# 2. rsync repo (incl. the combo's chain-config + this combo's rendered templates)
#    → versioned dir + swap `current`.
say "rsync repo → $BASE/versions/$SHA…"
"${SSH[@]}" "sudo mkdir -p $BASE/versions/$SHA && sudo chown -R \$(id -un): $BASE"
rsync -az --delete -e ssh --exclude '.git' \
  "$REPO_DIR/scripts" "$REPO_DIR/host" "$REPO_DIR/$CHAIN_CONFIG_SRC" "$REPO_DIR/.tool-versions" \
  "$SSH_TARGET:$BASE/versions/$SHA/"
rsync -az -e ssh "$RENDER_DIR/" "$SSH_TARGET:$BASE/versions/$SHA/rendered/"
"${SSH[@]}" "ln -sfn $BASE/versions/$SHA $BASE/current"

# 3. Persistent chain-config (first deploy) + inject [settlement.runtime] from secrets: saya key
#    + tee-registry (+ prover-key for enclave real proving). chmod 600; never committed.
say "chain-config + embedded-settlement runtime (registry${PROVER_KEY:+ + prover-key})…"
"${SSH[@]}" BASE="$BASE" CHAIN_CONFIG_SRC="$CHAIN_CONFIG_SRC" MODE="$MODE" \
  SETTLEMENT_ADDRESS="$SETTLEMENT_ADDRESS" SETTLEMENT_PRIVATE_KEY="$SETTLEMENT_PRIVATE_KEY" \
  PROVER_KEY="${PROVER_KEY:-}" TEE_REGISTRY_ADDRESS="$TEE_REGISTRY_ADDRESS" \
  SETTLEMENT_BATCH_SIZE="$SETTLEMENT_BATCH_SIZE" IDLE_FLUSH_SECS="$IDLE_FLUSH_SECS" 'bash -s' <<'EOF'
set -e
if [ ! -f "$BASE/chain-config/config.toml" ]; then
  mkdir -p "$BASE/chain-config"
  cp "$BASE/current/$CHAIN_CONFIG_SRC/config.toml" "$BASE/current/$CHAIN_CONFIG_SRC/genesis.json" "$BASE/chain-config/"
fi
if ! grep -q '^\[settlement.runtime\]' "$BASE/chain-config/config.toml"; then
  {
    printf '\n[settlement.runtime]\n'
    printf 'account-address = "%s"\n' "$SETTLEMENT_ADDRESS"
    printf 'account-private-key = "%s"\n' "$SETTLEMENT_PRIVATE_KEY"
    printf 'tee-registry = "%s"\n' "$TEE_REGISTRY_ADDRESS"
    [ "$MODE" = enclave ] && [ -n "$PROVER_KEY" ] && printf 'prover-key = "%s"\n' "$PROVER_KEY"
    printf 'batch-size = %s\n' "$SETTLEMENT_BATCH_SIZE"
    printf 'idle-flush-secs = %s\n' "$IDLE_FLUSH_SECS"
  } >> "$BASE/chain-config/config.toml"
fi
# batch-size + idle-flush-secs are operator-tunable across redeploys: the create
# branch above only runs on first deploy, so update the existing lines in place
# here. The [settlement.runtime] section is the file's last (appended above), so
# the append fallback for a legacy config without a key still lands in it.
if grep -qE '^batch-size *= ' "$BASE/chain-config/config.toml"; then
  sed -i -E "s/^batch-size *=.*/batch-size = $SETTLEMENT_BATCH_SIZE/" "$BASE/chain-config/config.toml"
else
  printf 'batch-size = %s\n' "$SETTLEMENT_BATCH_SIZE" >> "$BASE/chain-config/config.toml"
fi
if grep -qE '^idle-flush-secs *= ' "$BASE/chain-config/config.toml"; then
  sed -i -E "s/^idle-flush-secs *=.*/idle-flush-secs = $IDLE_FLUSH_SECS/" "$BASE/chain-config/config.toml"
else
  printf 'idle-flush-secs = %s\n' "$IDLE_FLUSH_SECS" >> "$BASE/chain-config/config.toml"
fi
chmod 600 "$BASE/chain-config/config.toml"
EOF

# 4. env file + systemd unit. enclave → run-enclave.sh (KATANA_TEE_VERSION image); mock →
#    run-appchain.sh (KATANA binary). The unit file was rendered for this combo in step 0
#    (host/{enclave,appchain}.service.tpl) and rsync'd to current/rendered/.
say "env + systemd unit ($UNIT)…"
"${SSH[@]}" BASE="$BASE" ENVDIR="$ENVDIR" UNIT="$UNIT" APPCHAIN_PORT="$APPCHAIN_PORT" MODE="$MODE" \
  METRICS_PORT="$METRICS_PORT" BLOCK_TIME_MS="$BLOCK_TIME_MS" \
  KATANA_TEE_VERSION="$KATANA_TEE_VERSION" VCPU_COUNT="${VCPU_COUNT:-}" MEMORY="${MEMORY:-}" 'bash -s' <<'EOF'
set -e
sudo mkdir -p "$ENVDIR"
if [ "$MODE" = enclave ]; then
  {
    printf 'KATANA_TEE_VERSION=%s\nAPPCHAIN_PORT=%s\nMETRICS_PORT=%s\nBASE=%s\n' "$KATANA_TEE_VERSION" "$APPCHAIN_PORT" "$METRICS_PORT" "$BASE"
    printf 'BLOCK_TIME_MS=%s\n' "$BLOCK_TIME_MS"
    [ -n "$VCPU_COUNT" ] && printf 'VCPU_COUNT=%s\n' "$VCPU_COUNT"
    [ -n "$MEMORY" ] && printf 'MEMORY=%s\n' "$MEMORY"
  } | sudo tee "$ENVDIR/env" >/dev/null
else
  printf 'KATANA=/usr/local/bin/katana\nAPPCHAIN_PORT=%s\nMETRICS_PORT=%s\nBASE=%s\nBLOCK_TIME_MS=%s\n' "$APPCHAIN_PORT" "$METRICS_PORT" "$BASE" "$BLOCK_TIME_MS" \
    | sudo tee "$ENVDIR/env" >/dev/null
fi
sudo cp "$BASE/current/rendered/$UNIT.service" "/etc/systemd/system/$UNIT.service"
sudo systemctl daemon-reload
sudo systemctl enable "$UNIT" >/dev/null
EOF

# 5. nginx (host-level router) — install when MODE=mock or INSTALL_NGINX=1. One self-contained
#    TLS vhost: $APPCHAIN_DOMAIN (router → /sepolia /mainnet /sepolia-mock /mainnet-mock).
#    Bootstrap: throwaway http acme vhost → certbot certonly → install the real vhost; if the
#    cert can't issue yet the domain is skipped.
if [ "$MODE" = mock ] || [ -n "${INSTALL_NGINX:-}" ]; then
  say "nginx vhost + TLS ($APPCHAIN_DOMAIN router)…"
  "${SSH[@]}" BASE="$BASE" APPCHAIN_DOMAIN="$APPCHAIN_DOMAIN" CERTBOT_EMAIL="${CERTBOT_EMAIL:-}" 'bash -s' <<'EOF'
set -e
domain="$APPCHAIN_DOMAIN" name=appchain
site="/etc/nginx/sites-available/$name"
sudo ln -sf "$site" "/etc/nginx/sites-enabled/$name"
if [ ! -d "/etc/letsencrypt/live/$domain" ]; then
  sudo mkdir -p /var/www/html
  sudo tee "$site" >/dev/null <<NGINX
server {
    listen 80;
    server_name $domain;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 404; }
}
NGINX
  sudo nginx -t && sudo systemctl reload nginx
  sudo certbot certonly --webroot -w /var/www/html -d "$domain" \
    --non-interactive --agree-tos ${CERTBOT_EMAIL:+-m "$CERTBOT_EMAIL"} \
    --deploy-hook "systemctl reload nginx" \
    || { echo "  ($domain: certbot failed — check DNS/port 80; leaving http-only, no TLS yet)"; exit 0; }
fi
sudo cp "$BASE/current/rendered/appchain.nginx" "$site"
sudo nginx -t && sudo systemctl reload nginx
EOF
fi

# 6. restart + health (enclave boot is slower + fetches the image on first run).
say "restart + health-check…"
"${SSH[@]}" UNIT="$UNIT" APPCHAIN_PORT="$APPCHAIN_PORT" MODE="$MODE" 'bash -s' <<'EOF'
set -e
sudo systemctl restart "$UNIT"
tries=30; [ "$MODE" = enclave ] && tries=120
for i in $(seq 1 $tries); do curl -s -o /dev/null "http://localhost:$APPCHAIN_PORT/" && break; sleep 2; done
echo -n "  chainId: "; curl -s "http://localhost:$APPCHAIN_PORT/" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"starknet_chainId","params":[]}'; echo
journalctl -u "$UNIT" --since "-4min" --no-pager 2>/dev/null \
  | grep -m1 -iE "katana_settlement::service|sev-snp|attestation" >/dev/null \
  && echo "  ✓ settlement active" || echo "  (settlement not logged yet)"
EOF
say "deployed (sha $SHA) — $NETWORK $MODE on :$APPCHAIN_PORT ($UNIT)."
