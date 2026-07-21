# Setup checklist

Everything to go from "Use this template" to a settling appchain. Do these in order.

## 1. Configure `appchain.conf`

- [ ] `CHAIN_NAME` — lowercase slug; prefixes systemd units and state dirs
- [ ] `CHAIN_ID_TESTNET` / `CHAIN_ID_MAINNET` — felt short-strings (≤ 31 ASCII chars);
      baked into the chain at init and **not changeable afterwards**
- [ ] `APPCHAIN_DOMAIN` / `GRAFANA_DOMAIN` — your public hostnames
- [ ] `DEPLOY_USER` (and optionally `DEPLOY_HOST`, if you're OK committing it)
- [ ] Leave ports/registries/version pins at their defaults unless you know why not
- [ ] `MONITORED_COMBOS` — only the combos you'll actually deploy

Sanity-check locally: `bash scripts/validate.sh` (also runs in CI on every push).

## 2. DNS

- [ ] `APPCHAIN_DOMAIN` → the host's public IP
- [ ] `GRAFANA_DOMAIN` → the host's public IP

Both must resolve before the first deploy (certbot needs port 80 reachable).

## 3. Bootstrap the host

Follow [`HOST_SETUP.md`](HOST_SETUP.md): packages, deploy user + passwordless sudo,
ufw (80/443 only), and — for mock mode — the paymaster/vrf sidecar binaries.
Enclave mode needs an **AMD SEV-SNP host** (see [`TEE.md`](TEE.md)).

## 4. Accounts + keys

- [ ] **Settlement account ("saya")** — a deployed Starknet account on the settlement
      network, funded with STRK (each `update_state` needs ~18 STRK of resource-bounds
      headroom; the monitoring alert fires below 100). It deploys piltover at init and is
      the sole `update_state` caller at runtime. Mainnet and Sepolia can use different
      accounts (`*_MAINNET` secrets).
- [ ] **SP1 prover key** (enclave mode) — a [Succinct prover network](https://docs.succinct.xyz)
      key, funded with $PROVE. Without it the enclave falls back to mock proving.
- [ ] **Deploy SSH keypair** — `ssh-keygen -t ed25519 -f deploy_key -N ''`; put the public
      half in the host's `~<user>/.ssh/authorized_keys`.

## 5. GitHub secrets / vars

Settings → Secrets and variables → Actions:

| Kind | Name | Value |
|---|---|---|
| secret | `SETTLEMENT_ADDRESS` / `SETTLEMENT_PRIVATE_KEY` | settlement account (Sepolia; also mainnet unless `*_MAINNET` set) |
| secret | `SETTLEMENT_ADDRESS_MAINNET` / `SETTLEMENT_PRIVATE_KEY_MAINNET` | optional mainnet-specific settlement account |
| secret | `PROVER_KEY` | SP1 prover-network key (enclave; absent ⇒ mock proving) |
| secret | `DEPLOY_SSH_KEY` | the private deploy key (contents of `deploy_key`) |
| secret | `DEPLOY_KNOWN_HOSTS` | `ssh-keyscan <host>` output |
| var | `DEPLOY_HOST` | the host's IP/hostname (falls back to appchain.conf `DEPLOY_HOST`) |
| var | `DEPLOY_USER` | SSH user (falls back to appchain.conf `DEPLOY_USER`, then `ubuntu`) |

## 6. Init each combo (one-time, real gas)

- [ ] Actions → **Init Rollup** — pick `network`/`mode`, type the confirm string
      (`INIT-<NETWORK>-<MODE>`). It deploys piltover (gas from the saya account) and opens
      a PR adding `chain-config-<network>-<mode>/`.
- [ ] Verify the piltover address + chain id in the PR, then **merge it**.

Start with `sepolia`/`mock` (no SEV-SNP hardware needed) or `sepolia`/`enclave`.

## 7. Deploy

- [ ] Actions → **Deploy** — same `network`/`mode`. Version inputs blank = the
      appchain.conf pins. The run's manifest (unit, port, piltover, prover mode) is
      committed to `manifests/` and shown in the run summary.

## 8. Monitoring (optional but recommended)

- [ ] `SLACK_WEBHOOK_URL=… GRAFANA_ADMIN_PASSWORD=… SUCCINCT_PROVER_ACCOUNTS=… \`
      `STARKNET_SETTLEMENT_ACCOUNTS=… scripts/deploy-monitoring.sh <user>@<host>`
- [ ] Grafana at `https://<GRAFANA_DOMAIN>` — dashboards + alerts are provisioned;
      **set a real admin password** (it defaults to `admin`).

## 9. Verify

```sh
# through the router (mock/enclave path per combo):
curl -s https://<APPCHAIN_DOMAIN>/sepolia/rpc -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"starknet_chainId","params":[]}'
# health:
curl -s https://<APPCHAIN_DOMAIN>/health
# lifecycle:
scripts/appchainctl -n sepolia -m enclave status
```

Settlement is working when the unit logs show `katana_settlement::service` batches landing
and (enclave) the piltover's `update_state` transactions succeed on the settlement network.
