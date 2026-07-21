# shellcheck shell=bash
# config.sh — single source of truth for the appchain deployment matrix.
#
# Sourced (never executed) by scripts/deploy.sh, init.sh, appchainctl,
# deploy-monitoring.sh, validate.sh, and the GitHub workflows. Reads appchain.conf
# at the repo root and derives, per (network, mode) combo:
#
#   unit name        ${CHAIN_NAME}-${network}-${mode}      (systemd unit, /var/lib, /etc)
#   deployment label ${network}-${mode}                    (prometheus/promtail/dashboards)
#   rpc port         BASE_PORT + idx        idx: 0 sepolia-mock, 1 sepolia-enclave,
#   metrics port     METRICS_BASE_PORT + idx     2 mainnet-enclave, 3 mainnet-mock
#   registry / chain id / settlement rpc   per network+mode
#
# Callers layer their env overrides on top of the COMBO_* results, e.g.
#   APPCHAIN_PORT="${APPCHAIN_PORT:-$COMBO_RPC_PORT}"
# so the COMBO_* prefix never clobbers a caller-set variable. set -u safe.

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPCHAIN_ROOT="${APPCHAIN_ROOT:-$(cd "$_lib_dir/../.." && pwd)}"

# Caller environment beats appchain.conf (the scripts' documented override contract):
# snapshot any conf var already NON-EMPTY in the environment, source the conf, restore.
# Empty counts as unset so a workflow passing a blank input falls through to the conf pin.
_conf_vars="CHAIN_NAME CHAIN_ID_TESTNET CHAIN_ID_MAINNET APPCHAIN_DOMAIN GRAFANA_DOMAIN \
DEPLOY_USER DEPLOY_HOST BASE_PORT METRICS_BASE_PORT GRAFANA_PORT \
SETTLEMENT_RPC_SEPOLIA SETTLEMENT_RPC_MAINNET \
TEE_REGISTRY_SEPOLIA TEE_REGISTRY_MAINNET TEE_REGISTRY_MOCK \
KATANA_VERSION KATANA_TEE_VERSION BLOCK_TIME_MS MONITORED_COMBOS HOST_LABEL"
_overrides=""
for _v in $_conf_vars; do
  if [[ -n "${!_v:-}" ]]; then _overrides+="$_v=$(printf %q "${!_v}") "; fi
done
# shellcheck source=/dev/null
source "${APPCHAIN_CONF:-$APPCHAIN_ROOT/appchain.conf}"
eval "$_overrides"
unset _conf_vars _overrides _v

# Default-guard every optional conf var (workflows source this under set -u).
DEPLOY_HOST="${DEPLOY_HOST:-}"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
GRAFANA_PORT="${GRAFANA_PORT:-3001}"
MONITORED_COMBOS="${MONITORED_COMBOS:-sepolia-mock sepolia-enclave mainnet-enclave}"
BLOCK_TIME_MS="${BLOCK_TIME_MS:-5000}"
HOST_LABEL="${HOST_LABEL:-$CHAIN_NAME-host}"

ALL_COMBOS="sepolia-mock sepolia-enclave mainnet-enclave mainnet-mock"

validate_config() {
  local err=0
  [[ "$CHAIN_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "error: CHAIN_NAME must be a [a-z0-9-] slug (got '$CHAIN_NAME')" >&2; err=1; }
  local id
  for id in "$CHAIN_ID_TESTNET" "$CHAIN_ID_MAINNET"; do
    [[ -n "$id" && "${#id}" -le 31 ]] || { echo "error: chain id '$id' must be a non-empty felt short-string (<= 31 chars)" >&2; err=1; }
  done
  [[ "$BASE_PORT" =~ ^[0-9]+$ && "$METRICS_BASE_PORT" =~ ^[0-9]+$ && "$GRAFANA_PORT" =~ ^[0-9]+$ ]] \
    || { echo "error: BASE_PORT / METRICS_BASE_PORT / GRAFANA_PORT must be numeric" >&2; err=1; }
  [[ -n "$APPCHAIN_DOMAIN" && -n "$GRAFANA_DOMAIN" ]] || { echo "error: APPCHAIN_DOMAIN / GRAFANA_DOMAIN must be set" >&2; err=1; }
  [[ "$BLOCK_TIME_MS" =~ ^[1-9][0-9]*$ ]] || { echo "error: BLOCK_TIME_MS must be a positive integer" >&2; err=1; }
  local c
  for c in $MONITORED_COMBOS; do
    case " $ALL_COMBOS " in *" $c "*) ;; *) echo "error: MONITORED_COMBOS entry '$c' not in: $ALL_COMBOS" >&2; err=1 ;; esac
  done
  local reg
  for reg in "$TEE_REGISTRY_SEPOLIA" "$TEE_REGISTRY_MAINNET" "$TEE_REGISTRY_MOCK"; do
    [[ "$reg" =~ ^0x[0-9a-fA-F]+$ ]] || { echo "error: TEE registry '$reg' must be 0x-hex" >&2; err=1; }
  done
  return $err
}

# resolve_combo <network> <mode> — sets the COMBO_* variables for one combo.
resolve_combo() {
  local network="$1" mode="$2" idx
  case "$network-$mode" in
    sepolia-mock)    idx=0; COMBO_REGISTRY="$TEE_REGISTRY_MOCK";    COMBO_CHAIN_ID="$CHAIN_ID_TESTNET"; COMBO_SETTLEMENT_RPC="$SETTLEMENT_RPC_SEPOLIA" ;;
    sepolia-enclave) idx=1; COMBO_REGISTRY="$TEE_REGISTRY_SEPOLIA"; COMBO_CHAIN_ID="$CHAIN_ID_TESTNET"; COMBO_SETTLEMENT_RPC="$SETTLEMENT_RPC_SEPOLIA" ;;
    mainnet-enclave) idx=2; COMBO_REGISTRY="$TEE_REGISTRY_MAINNET"; COMBO_CHAIN_ID="$CHAIN_ID_MAINNET"; COMBO_SETTLEMENT_RPC="$SETTLEMENT_RPC_MAINNET" ;;
    mainnet-mock)    idx=3; COMBO_REGISTRY="$TEE_REGISTRY_MOCK";    COMBO_CHAIN_ID="$CHAIN_ID_MAINNET"; COMBO_SETTLEMENT_RPC="$SETTLEMENT_RPC_MAINNET" ;;
    *) echo "error: NETWORK ∈ {sepolia,mainnet}, MODE ∈ {enclave,mock} (got '$network-$mode')" >&2; return 2 ;;
  esac
  COMBO_NETWORK="$network"
  COMBO_MODE="$mode"
  COMBO_DEPLOYMENT="$network-$mode"
  COMBO_UNIT="$CHAIN_NAME-$network-$mode"
  COMBO_RPC_PORT=$((BASE_PORT + idx))
  COMBO_METRICS_PORT=$((METRICS_BASE_PORT + idx))
  COMBO_CHAIN_CONFIG_DIR="chain-config-$network-$mode"
  COMBO_BASE="/var/lib/$COMBO_UNIT"
  COMBO_ENVDIR="/etc/$COMBO_UNIT"
  case "$mode" in
    enclave) COMBO_RUNNER=run-enclave.sh;  COMBO_RUN_USER=root ;;
    mock)    COMBO_RUNNER=run-appchain.sh; COMBO_RUN_USER="$DEPLOY_USER" ;;
  esac
  case "$network" in
    sepolia) COMBO_VOYAGER=https://sepolia.voyager.online ;;
    *)       COMBO_VOYAGER=https://voyager.online ;;
  esac
}

# export_combo_matrix — exports flattened per-combo vars for envsubst templates:
#   RPC_PORT_SEPOLIA_MOCK, …, METRICS_PORT_*, UNIT_* (combo uppercased, '-' → '_').
export_combo_matrix() {
  local c key
  for c in $ALL_COMBOS; do
    resolve_combo "${c%-*}" "${c##*-}"
    key="$(echo "$c" | tr 'a-z-' 'A-Z_')"
    export "RPC_PORT_$key=$COMBO_RPC_PORT"
    export "METRICS_PORT_$key=$COMBO_METRICS_PORT"
    export "UNIT_$key=$COMBO_UNIT"
  done
}

# prometheus_fragments — builds + exports the dynamic-shape template fragments:
#   KATANA_SCRAPE_TARGETS / BLACKBOX_SCRAPE_TARGETS  (pre-indented YAML static_configs
#     entries, one per MONITORED_COMBOS member, with deployment/network/mode/unit labels)
#   APPCHAIN_RPC_TARGETS  (comma list `deployment=http://127.0.0.1:port` for the
#     starknet-exporter head-block poller; caller env wins if already set)
prometheus_fragments() {
  local c katana="" blackbox="" rpc=""
  for c in $MONITORED_COMBOS; do
    resolve_combo "${c%-*}" "${c##*-}"
    katana+="      - targets: ['127.0.0.1:$COMBO_METRICS_PORT']
        labels: {instance: $COMBO_DEPLOYMENT, deployment: $COMBO_DEPLOYMENT, network: $COMBO_NETWORK, mode: $COMBO_MODE, unit: $COMBO_UNIT}
"
    blackbox+="      - targets: ['http://127.0.0.1:$COMBO_RPC_PORT/']
        labels: {deployment: $COMBO_DEPLOYMENT, network: $COMBO_NETWORK, mode: $COMBO_MODE}
"
    rpc+="${rpc:+,}$COMBO_DEPLOYMENT=http://127.0.0.1:$COMBO_RPC_PORT"
  done
  # strip the trailing newline so ${VAR} substitution sits flush in the template
  export KATANA_SCRAPE_TARGETS="${katana%$'\n'}"
  export BLACKBOX_SCRAPE_TARGETS="${blackbox%$'\n'}"
  export APPCHAIN_RPC_TARGETS="${APPCHAIN_RPC_TARGETS:-$rpc}"
}

# Whitelist of variables envsubst may substitute — anything else ($host, $request_uri,
# promtail's $1, …) passes through untouched.
TEMPLATE_VARS='${CHAIN_NAME} ${APPCHAIN_DOMAIN} ${GRAFANA_DOMAIN} ${GRAFANA_PORT} ${DEPLOY_USER} ${UNIT} ${HOST_LABEL} ${KATANA_SCRAPE_TARGETS} ${BLACKBOX_SCRAPE_TARGETS} ${RPC_PORT_SEPOLIA_MOCK} ${RPC_PORT_SEPOLIA_ENCLAVE} ${RPC_PORT_MAINNET_ENCLAVE} ${RPC_PORT_MAINNET_MOCK}'

# render_template <src.tpl> <dst> — envsubst restricted to TEMPLATE_VARS; refuses to
# render if the template references a whitelisted var that is unset/empty.
render_template() {
  local src="$1" dst="$2" v name
  for v in $TEMPLATE_VARS; do
    name="${v#\$\{}"; name="${name%\}}"
    if grep -q "\${$name}" "$src" && [[ -z "${!name:-}" ]]; then
      echo "error: $src references \${$name}, which is unset — did you export the combo matrix / fragments?" >&2
      return 2
    fi
  done
  envsubst "$TEMPLATE_VARS" < "$src" > "$dst"
}

# emit_github_env <network> <mode> — resolve a combo and append the values the
# workflows consume to $GITHUB_ENV.
emit_github_env() {
  resolve_combo "$1" "$2"
  {
    echo "NETWORK=$COMBO_NETWORK"
    echo "MODE=$COMBO_MODE"
    echo "UNIT=$COMBO_UNIT"
    echo "RPC_PORT=$COMBO_RPC_PORT"
    echo "TEE_REGISTRY_ADDRESS=$COMBO_REGISTRY"
    echo "CHAIN_ID=$COMBO_CHAIN_ID"
    echo "CHAIN_CONFIG_DIR=$COMBO_CHAIN_CONFIG_DIR"
    echo "SETTLEMENT_RPC_URL=$COMBO_SETTLEMENT_RPC"
    echo "VOYAGER=$COMBO_VOYAGER"
    # conf-side defaults later workflow steps fall back to
    echo "CONF_DEPLOY_HOST=$DEPLOY_HOST"
    echo "CONF_DEPLOY_USER=$DEPLOY_USER"
    echo "KATANA_VERSION_DEFAULT=$KATANA_VERSION"
    echo "KATANA_TEE_VERSION_DEFAULT=$KATANA_TEE_VERSION"
  } >> "$GITHUB_ENV"
}

print_combo_map() {
  local c
  printf '%-16s %-28s %5s %8s %-10s %s\n' COMBO UNIT RPC METRICS CHAIN_ID REGISTRY
  for c in $ALL_COMBOS; do
    resolve_combo "${c%-*}" "${c##*-}"
    printf '%-16s %-28s %5s %8s %-10s %s\n' \
      "$COMBO_DEPLOYMENT" "$COMBO_UNIT" "$COMBO_RPC_PORT" "$COMBO_METRICS_PORT" "$COMBO_CHAIN_ID" "$COMBO_REGISTRY"
  done
}
