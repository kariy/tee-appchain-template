#!/usr/bin/env bash
# init.sh — ONE-TIME rollup bootstrap. Deploys the piltover settlement core on the settlement
# network and generates the rollup chain-config (config.toml + genesis.json). Run once per
# (network, mode); the output is committed under chain-config-<network>-<mode>/ (the Init
# workflow opens a PR).
#
# Real gas + needs the settlement account key — prefer running via the Init GitHub workflow
# (secrets) over locally.
#
# Two dimensions (defaults NETWORK=sepolia, MODE=enclave) — they select the settlement RPC,
# the TEE registry piltover is wired to, and the output dir (see scripts/lib/config.sh +
# appchain.conf):
#   NETWORK ∈ {sepolia, mainnet}
#   MODE    ∈ {enclave, mock}   enclave → the REAL on-chain AMDTeeRegistry; mock → the mock
#                               registry (accepts --tee mock's software attestation).
# Env (override any appchain.conf-derived default):
#   SETTLEMENT_RPC_URL    settlement RPC (default: SETTLEMENT_RPC_* for NETWORK)
#   SETTLEMENT_ADDRESS_<NET> / SETTLEMENT_PRIVATE_KEY_<NET>
#                         settlement account for NETWORK (<NET> = SEPOLIA | MAINNET): the
#                         piltover operator / sole update_state caller + its key. Unsuffixed
#                         SETTLEMENT_ADDRESS / SETTLEMENT_PRIVATE_KEY override when set.
#   TEE_REGISTRY_ADDRESS  registry piltover's fact-registry is wired to (per-combo default)
#   CHAIN_ID              rollup id (default: CHAIN_ID_TESTNET / CHAIN_ID_MAINNET per network)
#   KATANA                katana binary for `init rollup` (match appchain.conf KATANA_VERSION).
#                         Its init has a declare->deploy race that can revert the piltover deploy
#                         ("class not declared"); the fix is to run it again, which this script
#                         does automatically (see the retry loop / INIT_ATTEMPTS).
#   INIT_ATTEMPTS         how many times to retry `init rollup` on the race (default 3)
#   OUT                   output dir (default: chain-config-<network>-<mode>)
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

NETWORK="${NETWORK:-sepolia}"
MODE="${MODE:-enclave}"
resolve_combo "$NETWORK" "$MODE"
SETTLEMENT_RPC_URL="${SETTLEMENT_RPC_URL:-$COMBO_SETTLEMENT_RPC}"
TEE_REGISTRY_ADDRESS="${TEE_REGISTRY_ADDRESS:-$COMBO_REGISTRY}"
CHAIN_ID="${CHAIN_ID:-$COMBO_CHAIN_ID}"
KATANA="${KATANA:-katana}"
OUT="${OUT:-$COMBO_CHAIN_CONFIG_DIR}"

resolve_settlement_account "$NETWORK"
for v in SETTLEMENT_ADDRESS SETTLEMENT_PRIVATE_KEY; do
  [[ -n "${!v:-}" ]] || { echo "error: set ${v}_$(echo "$NETWORK" | tr '[:lower:]' '[:upper:]') (or $v)" >&2; exit 2; }
done
command -v "$KATANA" >/dev/null 2>&1 || { echo "error: katana not found: $KATANA" >&2; exit 2; }

echo "→ init rollup network=$NETWORK mode=$MODE id=$CHAIN_ID registry=$TEE_REGISTRY_ADDRESS"
echo "  settlement=$SETTLEMENT_RPC_URL (deploys piltover — REAL gas) → $OUT/"
echo "  katana: $("$KATANA" --version 2>/dev/null | head -1)"
tmp="$(mktemp -d)"

# `init rollup` declares the piltover class then deploys it in the same run, and can lose the
# race to the declare's confirmation — reverting the deploy with `Class … is not declared`. The
# remedy is simply to run it again: the (now-confirmed) class makes the declare a no-op and the
# deploy lands. So retry a few times; a failed attempt deploys no piltover (the deploy reverted),
# so retrying can't leave duplicate instances. Override the count with INIT_ATTEMPTS.
attempts="${INIT_ATTEMPTS:-3}"
for i in $(seq 1 "$attempts"); do
  echo "→ init rollup attempt $i/$attempts…"
  rm -rf "$tmp"; mkdir -p "$tmp"
  if "$KATANA" init rollup \
      --id "$CHAIN_ID" \
      --settlement-chain "$SETTLEMENT_RPC_URL" \
      --settlement-account-address "$SETTLEMENT_ADDRESS" \
      --settlement-account-private-key "$SETTLEMENT_PRIVATE_KEY" \
      --tee \
      --tee-registry-address "$TEE_REGISTRY_ADDRESS" \
      --output-path "$tmp"; then
    break
  fi
  [[ "$i" -lt "$attempts" ]] || { echo "error: init rollup failed after $attempts attempts" >&2; exit 1; }
  echo "  attempt $i failed (likely the declare->deploy race) — retrying…" >&2
  sleep 5
done

mkdir -p "$OUT"
cp "$tmp/genesis.json" "$OUT/genesis.json"
# Strip any [settlement.runtime] (it carries the saya key) before committing — deploy.sh
# re-injects it on the host from the secret. (init rollup output normally lacks it.)
awk '/^\[settlement.runtime\]/{exit} {print}' "$tmp/config.toml" > "$OUT/config.toml"
rm -rf "$tmp"

pilt=$(grep -oE 'core_contract = "0x[0-9a-fA-F]+"' "$OUT/config.toml" | grep -oE '0x[0-9a-fA-F]+' | head -1)
echo "→ done. piltover=$pilt — chain-config written to $OUT/ (commit it; no secrets inside)."
