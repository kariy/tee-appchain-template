#!/usr/bin/env bash
# validate.sh — validate the appchain.conf-driven configuration without touching a host.
# Run locally or via .github/workflows/validate.yml. Checks:
#   1. bash syntax (+ shellcheck when available) for every script
#   2. appchain.conf sanity + the derived combo map
#   3. every .tpl renders completely (no whitelisted ${…} survives) and leaks nothing
#   4. rendered prometheus/promtail/nginx/compose configs are valid (docker; skipped if absent)
#   5. dashboards parse as JSON; exporters compile
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/config.sh"
ROOT="$APPCHAIN_ROOT"
fail=0
say() { echo "→ $*"; }
bad() { echo "✗ $*" >&2; fail=1; }

# 1. shell syntax
say "bash -n…"
scripts=("$ROOT"/scripts/*.sh "$ROOT/scripts/lib/config.sh" "$ROOT/scripts/appchainctl")
vendored=("$ROOT"/host/amdsev/*.sh "$ROOT"/host/amdsev/scripts/*.sh)
for s in "${scripts[@]}" "${vendored[@]}"; do
  bash -n "$s" || bad "syntax: $s"
done
if command -v shellcheck >/dev/null 2>&1; then
  say "shellcheck…"
  # Own scripts only (host/amdsev is vendored from katana upstream), warning severity.
  # SC1091: sourced appchain.conf isn't followable. SC2034: the lib sets COMBO_* for callers.
  shellcheck -S warning -e SC1091,SC2034 -x "${scripts[@]}" || bad "shellcheck findings (see above)"
else
  say "shellcheck not installed — skipped"
fi

# 2. config + combo map
say "validate_config + combo map…"
validate_config || bad "appchain.conf invalid"
print_combo_map

# 3. render every template
say "rendering templates…"
OUT="$(mktemp -d)"
export CHAIN_NAME APPCHAIN_DOMAIN GRAFANA_DOMAIN GRAFANA_PORT DEPLOY_USER HOST_LABEL
export_combo_matrix
prometheus_fragments
resolve_combo sepolia enclave; UNIT="$COMBO_UNIT"; export UNIT
render_template "$ROOT/host/enclave.service.tpl"  "$OUT/enclave.service"  || bad "render enclave.service.tpl"
resolve_combo sepolia mock; UNIT="$COMBO_UNIT"; export UNIT
render_template "$ROOT/host/appchain.service.tpl" "$OUT/appchain.service" || bad "render appchain.service.tpl"
render_template "$ROOT/host/appchain.nginx.tpl"   "$OUT/appchain.nginx"   || bad "render appchain.nginx.tpl"
render_template "$ROOT/host/grafana.nginx.tpl"    "$OUT/grafana.nginx"    || bad "render grafana.nginx.tpl"
mkdir -p "$OUT/monitoring"
render_template "$ROOT/host/monitoring/prometheus/prometheus.yml.tpl" "$OUT/monitoring/prometheus.yml" || bad "render prometheus.yml.tpl"
render_template "$ROOT/host/monitoring/promtail/config.yml.tpl"       "$OUT/monitoring/promtail.yml"   || bad "render promtail config.yml.tpl"

# render completeness: no whitelisted ${VAR} may survive in any rendered file
for v in $TEMPLATE_VARS; do
  name="${v#\$\{}"; name="${name%\}}"
  if grep -rq "\${$name}" "$OUT"; then bad "unrendered \${$name} in output"; fi
done
# leak check: no instance-specific strings in rendered output
if grep -rEi '185\.26|cartridge' "$OUT"; then bad "instance-specific string leaked into rendered output"; fi

# 4. docker-based config checks (graceful skip)
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  say "promtool check config…"
  docker run --rm --entrypoint promtool -v "$OUT/monitoring/prometheus.yml:/p.yml:ro" \
    prom/prometheus:v3.1.0 check config /p.yml || bad "prometheus config invalid"
  say "promtail check-syntax…"
  docker run --rm -v "$OUT/monitoring/promtail.yml:/c.yml:ro" \
    grafana/promtail:3.3.2 -config.file=/c.yml -check-syntax || bad "promtail config invalid"
  say "nginx -t…"
  # Point the cert directives at a throwaway self-signed cert (no letsencrypt in CI) and
  # wrap the vhosts in a minimal shim conf. The shim must live OUTSIDE the included
  # vhosts dir or the include glob eats it.
  mkdir -p "$OUT/nginx/vhosts"
  for f in appchain.nginx grafana.nginx; do
    sed -E 's#ssl_certificate_key[[:space:]]+.*#ssl_certificate_key /tmp/snakeoil.key;#; s#ssl_certificate[[:space:]]+/etc/letsencrypt.*#ssl_certificate /tmp/snakeoil.crt;#' \
      "$OUT/$f" > "$OUT/nginx/vhosts/$f.conf"
  done
  printf 'events {}\nhttp { include /etc/nginx/vhosts/*.conf; }\n' > "$OUT/nginx/shim.conf"
  docker run --rm -v "$OUT/nginx/shim.conf:/etc/nginx/nginx.conf:ro" \
    -v "$OUT/nginx/vhosts:/etc/nginx/vhosts:ro" nginx:stable sh -c \
    'openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/snakeoil.key -out /tmp/snakeoil.crt -days 1 -subj /CN=validate >/dev/null 2>&1 && nginx -t' \
    || bad "nginx vhosts invalid"
  say "docker compose config…"
  compose_env="$OUT/compose.env"
  printf 'GRAFANA_DOMAIN=%s\nGRAFANA_PORT=%s\nGRAFANA_ADMIN_PASSWORD=x\nSLACK_WEBHOOK_URL=\nSUCCINCT_PROVER_ACCOUNTS=\nSTARKNET_SETTLEMENT_ACCOUNTS=\nAPPCHAIN_RPC_TARGETS=\n' \
    "$GRAFANA_DOMAIN" "$GRAFANA_PORT" > "$compose_env"
  docker compose -f "$ROOT/host/monitoring/docker-compose.yml" --env-file "$compose_env" config -q \
    || bad "docker-compose.yml invalid"
else
  say "docker unavailable — skipped promtool/promtail/nginx/compose checks"
fi

# 5. dashboards + exporters
say "dashboards + exporters…"
for d in "$ROOT"/host/monitoring/grafana/dashboards/*.json; do
  if command -v jq >/dev/null 2>&1; then jq empty "$d" || bad "invalid JSON: $d"
  else python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$d" || bad "invalid JSON: $d"; fi
done
python3 -m py_compile "$ROOT"/host/monitoring/*/exporter.py || bad "exporter compile failed"

if [ "$fail" = 0 ]; then say "all checks passed (rendered output in $OUT)"; else echo "VALIDATION FAILED" >&2; fi
exit "$fail"
