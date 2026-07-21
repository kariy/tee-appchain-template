# Host setup (one-time, manual)

One-time bootstrap of the deploy host; after it, everything is driven by
`scripts/deploy.sh` (or the Deploy workflow). Mock mode runs a bare `katana` binary under
systemd, fronted by nginx — no VM/QEMU needed. **Enclave mode additionally requires an AMD
SEV-SNP-capable host** (Milan/Genoa) with SEV-SNP enabled in the hypervisor — see
[`TEE.md`](TEE.md) "Host requirements".

Values like the deploy user and domains come from your [`appchain.conf`](appchain.conf)
(`DEPLOY_USER`, `APPCHAIN_DOMAIN`, `GRAFANA_DOMAIN`); the examples below use the defaults.

## 1. Packages

```sh
sudo apt-get update
sudo apt-get install -y nginx certbot python3-certbot-nginx curl rsync
```

## 2. Deploy user

`scripts/deploy.sh` and `scripts/appchainctl` SSH in as a normal user (`DEPLOY_USER`,
default `ubuntu`) with **passwordless sudo** (they run `systemctl`, write `/etc/...`,
reload nginx, certbot):

```sh
echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/appchain-deploy
sudo chmod 440 /etc/sudoers.d/appchain-deploy
```

Add the CI/deploy SSH public key to `~<user>/.ssh/authorized_keys`.

## 3. Firewall

Expose only HTTP/HTTPS at the edge; katana stays loopback-bound (the `BASE_PORT`+n ports).

```sh
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
# Do NOT open the katana RPC ports — they are reached only via the nginx router.
```

## 4. DNS

`$APPCHAIN_DOMAIN` and `$GRAFANA_DOMAIN` (appchain.conf) → this host's public IP.
Both must resolve before `deploy.sh` / `deploy-monitoring.sh` run certbot.

## 5. GitHub secrets / vars

See the full table in [`SETUP.md`](SETUP.md). Short version — secrets: `SAYA_ADDRESS`,
`SAYA_PRIVATE_KEY` (+ optional `*_MAINNET`), `PROVER_KEY`, `DEPLOY_SSH_KEY`,
`DEPLOY_KNOWN_HOSTS`; vars: `DEPLOY_HOST`, `DEPLOY_USER`.

## 6. Sidecar binaries (paymaster + VRF) — **mock mode only**

Katana runs two sidecars as child processes and expects their binaries on `PATH`.
**Enclave hosts do NOT need this step**: from `tee-vm-v0.2.0` the TEE-VM image bundles
both binaries inside the measured initrd at `/bin`, where the guest katana finds them.
For mock (bare-katana) deployments they are **not** installed by `deploy.sh` — grab the
version-matched builds from the katana release (same tag as `KATANA_VERSION` in
appchain.conf) into `/usr/local/bin`:

```sh
VER=v1.8.0-rc.8   # keep in sync with appchain.conf KATANA_VERSION
for s in paymaster-service vrf-server; do
  curl -sSL "https://github.com/dojoengine/katana/releases/download/$VER/${s}_${VER}_linux_amd64.tar.gz" | tar xz -C /tmp
  sudo install -m755 "$(find /tmp -type f -name "$s" | head -1)" "/usr/local/bin/$s"
done
```

- `paymaster-service` — required by `--paymaster` (Controller sponsorship; also the VRF relayer/forwarder).
- `vrf-server` — required by `--vrf` (ECVRF proof sidecar on `127.0.0.1:3000`). Katana spawns it
  and passes the derived VRF account credentials; no manual config.

## 7. Bring it up

1. **Actions → Init Rollup** (one-time per combo) → review + merge the chain-config PR.
2. **Actions → Deploy** (or `scripts/deploy.sh <user>@<host>`) → installs katana (mock),
   the unit, the nginx vhost + cert, and starts the node.

The node's chain state and `chain-config/` (incl. the injected `[settlement.runtime]` key)
live under `/var/lib/<unit>/` and survive deploys.

## 8. Monitoring (Grafana + Loki + Prometheus)

Self-contained on the host via docker-compose (`host/monitoring/`), driven by
`scripts/deploy-monitoring.sh`. Everything binds **loopback** — **no new ufw ports**;
Grafana is the only public surface, via the nginx TLS vhost `$GRAFANA_DOMAIN`.

Prereqs:
- **Docker** — auto-installed by `deploy-monitoring.sh` (get.docker.com) if missing.
- The monitored nodes **deployed with metrics enabled** (`scripts/deploy.sh`) so katana
  `/metrics` is up on the loopback metrics ports (`METRICS_BASE_PORT`+n). Which combos are
  scraped comes from `MONITORED_COMBOS` in appchain.conf.
- The `$GRAFANA_DOMAIN` record → the host must be live before the cert can issue.

Bring it up:

```sh
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/... \
GRAFANA_ADMIN_PASSWORD=<pick-one> \
  scripts/deploy-monitoring.sh <user>@<host>
```

Ports (all loopback, ufw-blocked off-box): grafana **3001** (3000 is the mock's
`vrf-server`), prometheus 9090, loki 3100, node_exporter 9100, blackbox 9115, promtail
9080. Stack secrets live in `/var/lib/<chain-name>-monitoring/monitoring/.env` (chmod 600,
never committed). Alerts route to Slack; dashboards + datasources are provisioned. Data
survives via docker named volumes (15d metrics / 7d logs).
