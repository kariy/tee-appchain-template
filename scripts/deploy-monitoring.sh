#!/usr/bin/env bash
# deploy-monitoring.sh — deploy the self-contained monitoring stack (host/monitoring/) to the
# appchain host: render the combo-dependent configs, rsync the compose stack, ensure Docker,
# bring it up, and install the Grafana TLS vhost + cert. Host-level (independent of the
# per-(network,mode) node deploys). Idempotent.
#
# Prereq: the monitored nodes must be (re)deployed with metrics enabled (scripts/deploy.sh)
# so katana's /metrics is up on the loopback metrics ports. DNS $GRAFANA_DOMAIN → the host
# must be live before the cert can issue.
#
# Which combos are scraped/probed comes from MONITORED_COMBOS in appchain.conf — re-run this
# script after changing it.
#
# Usage: [SLACK_WEBHOOK_URL=… GRAFANA_ADMIN_PASSWORD=…] scripts/deploy-monitoring.sh <user@host>
# Env:
#   SLACK_WEBHOOK_URL        Slack incoming-webhook for Grafana alerts (empty ⇒ alerts fire in UI only)
#   GRAFANA_ADMIN_PASSWORD   Grafana admin password (default 'admin' — set one!)
#   SUCCINCT_PROVER_ACCOUNTS prover-network accounts to alert on, comma list of
#                            `network=address[=deployment]` — $PROVE balance low alert. The
#                            optional deployment segment becomes a `deployment` label shown
#                            in the Slack notification.
#   STARKNET_SETTLEMENT_ACCOUNTS
#                            settlement (saya) accounts to watch, same format — STRK balance
#                            panel + low-balance alert (update_state needs ~18 STRK
#                            resource-bounds headroom to pass validation)
#   RENDER_ONLY              render configs + print the plan, no ssh (dry run)
#
# Unset secret env vars keep the value already in the host's monitoring/.env (a redeploy
# without the full env doesn't wipe existing config).
#   GRAFANA_DOMAIN / GRAFANA_PORT   appchain.conf defaults
#   CERTBOT_EMAIL                   optional ACME account email
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"
validate_config

SSH_TARGET="${1:-}"
[[ -n "$SSH_TARGET" || -n "${RENDER_ONLY:-}" ]] || { echo "usage: deploy-monitoring.sh <user@host>" >&2; exit 2; }
BASE="/var/lib/${CHAIN_NAME}-monitoring"
REPO_DIR="$APPCHAIN_ROOT"
say() { echo "→ $*"; }

# Render the combo-dependent configs (prometheus scrape targets, promtail unit mapping,
# Grafana vhost) into a staging copy — the host only ever sees final files.
export CHAIN_NAME GRAFANA_DOMAIN GRAFANA_PORT HOST_LABEL
prometheus_fragments
STAGE="$(mktemp -d)"
cp -R "$REPO_DIR/host/monitoring/." "$STAGE/monitoring/"
render_template "$STAGE/monitoring/prometheus/prometheus.yml.tpl" "$STAGE/monitoring/prometheus/prometheus.yml"
render_template "$STAGE/monitoring/promtail/config.yml.tpl" "$STAGE/monitoring/promtail/config.yml"
rm -f "$STAGE/monitoring/prometheus/prometheus.yml.tpl" "$STAGE/monitoring/promtail/config.yml.tpl"
render_template "$REPO_DIR/host/grafana.nginx.tpl" "$STAGE/grafana.nginx"

if [ -n "${RENDER_ONLY:-}" ]; then
  say "RENDER_ONLY — monitored combos: $MONITORED_COMBOS"
  say "rendered stack in $STAGE (prometheus.yml, promtail config, grafana.nginx), no ssh."
  exit 0
fi

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET")
[[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]] || echo "→ warning: GRAFANA_ADMIN_PASSWORD unset — Grafana admin defaults to 'admin'" >&2
[[ -n "${SLACK_WEBHOOK_URL:-}" ]] || echo "→ warning: SLACK_WEBHOOK_URL unset — alerts will fire in Grafana only (no Slack)" >&2

# 1. rsync the rendered stack + the Grafana vhost.
say "rsync monitoring stack → ${BASE}/monitoring"
"${SSH[@]}" "sudo mkdir -p $BASE && sudo chown -R \$(id -un): $BASE"
# --exclude=.env: the host-side env file is operator state (written by the step
# below), not repo content — without the exclude, --delete wipes it before the
# preservation logic can read it.
rsync -az --delete --exclude=.env -e ssh "$STAGE/monitoring/" "$SSH_TARGET:$BASE/monitoring/"
rsync -az -e ssh "$STAGE/grafana.nginx" "$SSH_TARGET:$BASE/grafana.nginx"

# 2. stack env → $BASE/monitoring/.env (docker-compose reads it; chmod 600; never committed).
#    Secrets keep-if-unset; derived values (grafana domain/port, RPC targets) are always
#    rewritten from the current appchain.conf.
say "monitoring .env (Slack + Grafana admin + derived targets)…"
"${SSH[@]}" BASE="$BASE" SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}" \
  GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}" \
  SUCCINCT_PROVER_ACCOUNTS="${SUCCINCT_PROVER_ACCOUNTS:-}" \
  STARKNET_SETTLEMENT_ACCOUNTS="${STARKNET_SETTLEMENT_ACCOUNTS:-}" \
  GRAFANA_DOMAIN="$GRAFANA_DOMAIN" GRAFANA_PORT="$GRAFANA_PORT" \
  APPCHAIN_RPC_TARGETS="$APPCHAIN_RPC_TARGETS" 'bash -s' <<'EOF'
set -e
umask 077
# Unset caller env keeps the value already on the host, so a partial redeploy
# doesn't wipe previously-configured secrets/accounts. Must be set-e-safe: a
# missing file/key yields empty output, never a non-zero status (which would
# abort the whole remote script from inside the $(...) assignment).
existing() { sed -n "s/^$1=//p" "$BASE/monitoring/.env" 2>/dev/null | head -1 || true; }
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-$(existing SLACK_WEBHOOK_URL)}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-$(existing GRAFANA_ADMIN_PASSWORD)}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
SUCCINCT_PROVER_ACCOUNTS="${SUCCINCT_PROVER_ACCOUNTS:-$(existing SUCCINCT_PROVER_ACCOUNTS)}"
STARKNET_SETTLEMENT_ACCOUNTS="${STARKNET_SETTLEMENT_ACCOUNTS:-$(existing STARKNET_SETTLEMENT_ACCOUNTS)}"
{
  printf 'SLACK_WEBHOOK_URL=%s\n' "$SLACK_WEBHOOK_URL"
  printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "$GRAFANA_ADMIN_PASSWORD"
  printf 'SUCCINCT_PROVER_ACCOUNTS=%s\n' "$SUCCINCT_PROVER_ACCOUNTS"
  printf 'STARKNET_SETTLEMENT_ACCOUNTS=%s\n' "$STARKNET_SETTLEMENT_ACCOUNTS"
  printf 'GRAFANA_DOMAIN=%s\n' "$GRAFANA_DOMAIN"
  printf 'GRAFANA_PORT=%s\n' "$GRAFANA_PORT"
  printf 'APPCHAIN_RPC_TARGETS=%s\n' "$APPCHAIN_RPC_TARGETS"
} > "$BASE/monitoring/.env"
chmod 600 "$BASE/monitoring/.env"
# Provision the Slack contact point/policy only when a webhook is set — an empty Slack
# integration fails Grafana's provisioning validation (fatal). Without it, alert rules still
# evaluate and show in the Grafana UI; add the webhook + redeploy to route them to Slack.
alertdir="$BASE/monitoring/grafana/provisioning/alerting"
if [ -z "$SLACK_WEBHOOK_URL" ]; then
  rm -f "$alertdir/contactpoints.yml" "$alertdir/policies.yml"
  echo "  (no Slack webhook — alert rules provisioned UI-only)"
fi
EOF

# 3. ensure Docker + bring the stack up.
say "ensure docker + compose up…"
"${SSH[@]}" BASE="$BASE" 'bash -s' <<'EOF'
set -e
if ! command -v docker >/dev/null 2>&1; then
  echo "  installing docker…"; curl -fsSL https://get.docker.com | sudo sh
fi
# Ubuntu's docker.io ships no compose v2 plugin — install it into cli-plugins if missing.
if ! sudo docker compose version >/dev/null 2>&1; then
  echo "  installing docker compose v2 plugin…"
  sudo mkdir -p /usr/libexec/docker/cli-plugins
  sudo curl -fsSL "https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)" \
    -o /usr/libexec/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/libexec/docker/cli-plugins/docker-compose
  sudo docker compose version | head -1
fi
cd "$BASE/monitoring"
sudo docker compose pull -q 2>/dev/null || true
# --build for the succinct-exporter image; --force-recreate so edited bind-mounted configs
# (prometheus.yml, grafana provisioning) are re-read.
sudo docker compose up -d --force-recreate --build
sudo docker compose ps
EOF

# 4. Grafana nginx vhost + TLS (same bootstrap as the appchain router: throwaway acme vhost →
#    certbot certonly → install the real self-contained TLS vhost).
say "nginx vhost + TLS ($GRAFANA_DOMAIN)…"
"${SSH[@]}" BASE="$BASE" GRAFANA_DOMAIN="$GRAFANA_DOMAIN" CERTBOT_EMAIL="${CERTBOT_EMAIL:-}" 'bash -s' <<'EOF'
set -e
domain="$GRAFANA_DOMAIN"; name=grafana-appchain
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
sudo cp "$BASE/grafana.nginx" "$site"
sudo nginx -t && sudo systemctl reload nginx
EOF
say "monitoring deployed — Grafana → https://$GRAFANA_DOMAIN"
