---
name: setup-appchain
description: >
  Guided first-time setup + deployment of a TEE appchain from this template: configure
  appchain.conf, bootstrap the host, set GitHub secrets, init the rollup (deploys piltover —
  real gas), deploy, verify. Use when the user asks to "set up my appchain", "deploy my first
  TEE instance", "get started with this template", or has just created a repo from the
  template and wants it running end to end.
---

# Set up and deploy your first TEE appchain

You are driving the consumer flow of this template end to end. The authoritative references
are `SETUP.md` (checklist + secrets table), `HOST_SETUP.md` (host bootstrap), and `TEE.md`
(enclave internals) — consult them for detail; this skill is the execution order, the
commands, and the checkpoints.

Ground rules:

- **Real money is involved.** The Init step deploys a piltover contract with real gas, and
  mainnet settlement spends real STRK. Confirm with the user before any Init run and before
  anything targeting `mainnet`.
- **Never generate or guess settlement account keys.** The user supplies them. If they paste
  a private key into chat, use it, but suggest rotating it later since it transited chat.
- **Recommend the progression** `sepolia`/`mock` → `sepolia`/`enclave` → `mainnet`/`enclave`.
  Mock mode needs no SEV-SNP hardware and no prover key — it's the cheapest way to prove the
  pipeline works. Only `sepolia-mock` can use the mock TEE registry (it is Sepolia-only).
- Work through the phases in order; each has a checkpoint. Don't advance past a failing
  checkpoint.

## Phase 0 — prerequisites

Check, and help the user fix what's missing:

```sh
gh auth status                      # gh CLI authenticated, repo scope
git remote -v                       # this repo (created from the template)
bash scripts/validate.sh            # template machinery healthy before any edits
```

Ask the user up front (one round of questions):
1. Chain name (lowercase slug) and chain id short-strings (testnet + mainnet, ≤ 31 chars —
   **immutable after Init**).
2. The two public domains (appchain RPC router + Grafana), and whether DNS for them is
   already pointed at the host.
3. The host: IP/hostname, SSH user, whether it's AMD SEV-SNP-capable (Milan/Genoa). If not
   SEV-SNP: mock mode only until they have such a host.
4. Which combo to bring up first (recommend sepolia/mock or sepolia/enclave).

## Phase 1 — appchain.conf

Edit `appchain.conf` with the user's answers: `CHAIN_NAME`, `CHAIN_ID_TESTNET`,
`CHAIN_ID_MAINNET`, `APPCHAIN_DOMAIN`, `GRAFANA_DOMAIN`, `DEPLOY_USER` (and `DEPLOY_HOST` if
they're comfortable committing it), `MONITORED_COMBOS` (only combos they'll actually deploy —
extra entries page down-alerts forever). Leave ports, registries, and version pins at their
defaults unless the user has a reason.

**Checkpoint:**

```sh
bash scripts/validate.sh            # must pass
RENDER_ONLY=1 scripts/deploy.sh     # prints the derived combo map — show it to the user
```

Commit + push the conf; the `Validate` workflow must go green.

## Phase 2 — DNS + host bootstrap

1. Verify DNS (both domains must resolve to the host **before** any deploy — certbot needs
   port 80): `dig +short <APPCHAIN_DOMAIN>` and `<GRAFANA_DOMAIN>`.
2. Bootstrap the host per `HOST_SETUP.md` over SSH: packages (nginx, certbot, curl, rsync),
   the deploy user with passwordless sudo, ufw allowing only 80/443, and — for mock mode —
   the version-matched `paymaster-service` + `vrf-server` sidecars into `/usr/local/bin`
   (enclave images bundle them; mock does not).
3. For enclave mode, verify SEV-SNP: `ssh <user>@<host> 'ls /dev/sev* /dev/kvm && dmesg | grep -i "SEV-SNP" | head -3'`.

**Checkpoint:** `ssh -o BatchMode=yes <user>@<host> 'sudo true && echo ok'` prints `ok`.

## Phase 3 — accounts + secrets

1. **Deploy SSH keypair** — generate it yourself and authorize it:
   ```sh
   ssh-keygen -t ed25519 -N '' -C '<repo> deploy-ci' -f /tmp/deploy_ci_key
   ssh <user>@<host> "echo '$(cat /tmp/deploy_ci_key.pub)' >> ~/.ssh/authorized_keys"
   ssh -i /tmp/deploy_ci_key -o IdentitiesOnly=yes <user>@<host> 'echo key-ok'   # verify!
   gh secret set DEPLOY_SSH_KEY < /tmp/deploy_ci_key
   ssh-keyscan <host> 2>/dev/null | gh secret set DEPLOY_KNOWN_HOSTS
   rm /tmp/deploy_ci_key /tmp/deploy_ci_key.pub          # only AFTER both secrets are set
   ```
2. **Settlement accounts** — the user provides, per network they'll use: a deployed Starknet
   account funded with STRK (each `update_state` needs ~18 STRK headroom; alert fires < 100).
   Set the per-network pairs (there is deliberately **no cross-network fallback** — a mainnet
   run with the `_MAINNET` pair unset fails loudly):
   ```sh
   gh secret set SETTLEMENT_ADDRESS_SEPOLIA
   gh secret set SETTLEMENT_PRIVATE_KEY_SEPOLIA
   gh secret set SETTLEMENT_ADDRESS_MAINNET        # when going to mainnet
   gh secret set SETTLEMENT_PRIVATE_KEY_MAINNET
   ```
3. **Prover key** (enclave real proving) — a funded Succinct prover-network key:
   `gh secret set PROVER_KEY`. Without it the enclave boots but proves with
   `TeeProver::Mock` (the deploy prints a warning, not an error).
4. Optionally `gh variable set DEPLOY_HOST` / `DEPLOY_USER` — otherwise the workflows fall
   back to `appchain.conf`.

**Checkpoint:** `gh secret list` shows every secret the chosen combo needs.

## Phase 4 — Init the rollup (one-time per combo, REAL GAS)

Get explicit user confirmation, then:

```sh
gh workflow run init.yml -f network=<net> -f mode=<mode> -f confirm=INIT-<NET>-<MODE>   # confirm string in CAPS
gh run watch $(gh run list --workflow=init.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status
```

- It deploys piltover from the settlement account and opens a **PR adding
  `chain-config-<net>-<mode>/`**. Have the user (or you, with their OK) review the piltover
  address + chain id in the PR, then merge it. Deploy will refuse to run without it.
- Known flake: `katana init rollup` has a declare→deploy race (`Class … is not declared`).
  `init.sh` retries automatically (`INIT_ATTEMPTS`, default 3); a failed attempt deploys
  nothing, so retrying is safe.

**Checkpoint:** chain-config PR merged; `manifests/init-<net>-<mode>.json` shows the
piltover address and the expected chain id.

## Phase 5 — Deploy

```sh
git pull    # the merged chain-config
gh workflow run deploy.yml -f network=<net> -f mode=<mode>
gh run watch $(gh run list --workflow=deploy.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status
```

Notes: blank version inputs use the `appchain.conf` pins. Mock deploys also install the
nginx router + TLS (first run needs DNS live for certbot; a failed cert leaves the vhost
http-only and the deploy still succeeds — rerun after fixing DNS). Enclave first boot
downloads the TEE-VM image, so the health check can take a couple of minutes.

**Checkpoint** (all three):

```sh
curl -s https://<APPCHAIN_DOMAIN>/health                                     # "ok" (after a mock deploy)
curl -s https://<APPCHAIN_DOMAIN>/<route>/rpc -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"starknet_chainId","params":[]}'      # the chain id felt
scripts/appchainctl -n <net> -m <mode> status                                # unit active + block height
```

Routes: `/sepolia` + `/mainnet` = enclaves, `/sepolia-mock` + `/mainnet-mock` = mocks.
Settlement is confirmed by `katana_settlement::service` lines in
`scripts/appchainctl -n <net> -m <mode> logs`; for a real-proving enclave, additionally
verify the attestation: `tee_generateQuote` per `TEE.md`. Idle chains only mint blocks on
traffic — a static head with a responsive RPC is healthy, not stalled.

## Phase 6 — monitoring (recommended)

```sh
SLACK_WEBHOOK_URL=… GRAFANA_ADMIN_PASSWORD=… \
SUCCINCT_PROVER_ACCOUNTS='<net>=<addr>' STARKNET_SETTLEMENT_ACCOUNTS='<net>=<addr>=<deployment>' \
  scripts/deploy-monitoring.sh <user>@<host>
```

Insist on a real `GRAFANA_ADMIN_PASSWORD` (defaults to `admin` and Grafana is public at
`https://<GRAFANA_DOMAIN>`). Unset env vars keep values already on the host, so partial
re-runs are safe. Re-run this script whenever `MONITORED_COMBOS` changes.

**Checkpoint:** Grafana login page loads over TLS; the Appchain Overview dashboard's
deployment variable lists the deployed combos.

## Wrap-up

Summarize for the user: what's deployed (combo, unit, port, piltover address, prover mode),
where the manifests are, the public RPC URLs, and — if they stopped at mock — that the path
to a real enclave is this same skill from Phase 3 (PROVER_KEY) with `mode=enclave`, and
mainnet is the same again with the `_MAINNET` secrets. Remind them a chain reset requires a
fresh Init (state diverges from its settled piltover otherwise — see the README caveat).
