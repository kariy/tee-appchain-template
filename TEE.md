# Real-TEE appchain (AMD SEV-SNP + real SP1 proofs)

In **enclave mode** the appchain's katana sequencer runs **inside AMD SEV-SNP confidential
VMs** with `--tee sev-snp`, settling to Starknet against the **real** on-chain
`AMDTeeRegistry` — the production TEE proving pipeline, as opposed to the `--tee mock`
bare-metal node of mock mode. Multiple combos run as separate enclaves/units on one host
(see `scripts/lib/config.sh` for the unit/port derivation).

| | mock mode | enclave mode |
|---|---|---|
| Node | bare `katana` under systemd | `katana` **inside an SEV-SNP VM** |
| Attester | `--tee mock` (software) | `--tee sev-snp` (real AMD hardware) |
| TEE registry | mock (`TEE_REGISTRY_MOCK` in appchain.conf) | **real `AMDTeeRegistry`** (`TEE_REGISTRY_SEPOLIA`/`_MAINNET`) |
| Settlement proof | trivial mock | real **SP1 Groth16** (Succinct network), verified on-chain |
| Launcher | `scripts/run-appchain.sh` | `scripts/run-enclave.sh` → `host/amdsev/start-vm.sh` |

## Architecture

The enclave katana is a **generic, measured** node. The game/appchain config is injected at
**launch, unmeasured but bound into the attestation `report_data`**:

- **Measured** (hashed into the SEV-SNP launch measurement): OVMF + kernel + initrd +
  kernel cmdline (`console=ttyS0`). This is the published, reproducible image.
- **Runtime, not measured:**
  - `--katana-args` → QEMU `fw_cfg opt/org.katana/args` (e.g. `--tee sev-snp`, `--http.*`,
    `--block-time`, `--messaging.enabled`, `--paymaster`/`--cartridge.*`).
  - `--chain-dir` → packed into a read-only virtio-blk disk; the guest mounts it at
    `/run/katana-chain` and passes it to katana as `--chain` (start-vm.sh owns
    `--chain`/`--db-*`/`--data-dir`). This carries `genesis.json` + `config.toml`
    (with `[settlement.runtime]` = the saya key + the **real** `tee-registry`).
- The TEE quote's `report_data` commits to the block's `state_root`/`block_hash`/
  `events_commitment` + `katanaTeeConfigHash`, so a verifier checks both "genuine
  published image on a real AMD chip" and "which state it produced."

## The prebuilt TEE-VM image

Shipped, reproducible, from the katana TEE-VM releases (the `tee-vm-*` line versions the VM
image independently of katana; the `+katana-…` suffix records the embedded binary). The tag
your deployment runs is pinned as `KATANA_TEE_VERSION` in appchain.conf. Example:

```
https://github.com/dojoengine/katana/releases/tag/tee-vm-v0.3.0+katana-v1.8.0-rc.8
  katana-tee-vm-<tag>.tar.gz       # OVMF.fd + vmlinuz + initrd.img + katana + build-info
  launch-measurement-<tag>.txt     # the blessed (sealed) measurement
  build-info-<tag>.txt
```

`scripts/run-enclave.sh` fetches and extracts it to `$BASE/vm-image/<tag>` on first run —
**it is never built here**. The image is **self-sufficient for embedded settlement out of
the box**: the initrd bakes in the SP1 katana (registry-matching vkey), a tmpfs `/dev/shm`
(SP1 executor), IPv4 preference (qemu SLIRP has no IPv6 route), and the CA bundle at every
trust-store path the guest's TLS stacks probe — so `run-enclave.sh` boots the **published
`initrd.img` directly** (no host-side patching, and the running measurement matches the
release's). From `tee-vm-v0.2.0` the initrd also bundles the **`paymaster-service` +
`vrf-server` sidecars at `/bin`**, so the enclave runs Controller-capable
(`--paymaster --cartridge.* --vrf`) like the mock deployment — no host-side sidecar
install. From `tee-vm-v0.3.0` the embedded katana is the cairo-native build
(`--enable-native-compilation`).

### Launch measurements

Each release publishes its measurements (artifact SHA256s verifiable with katana's
`misc/AMDSEV/verify-build.sh` against the release; computed at `--vcpus=1 --cpu=epyc-v4`).
Sealed and unsealed boots produce **different** measurements (the sealed cmdline adds a
LUKS UUID token). The registry verifies the SP1 vk + AMD cert chain + freshness — it does
**not** pin a specific launch measurement — so the unsealed boot also verifies on-chain;
the measurement is the value external verifiers pin to recognize an exact image. Sealed
binds the DB to the chip+measurement but isn't forward-compatible across katana versions
(see katana `docs/amdsev.md`). **`run-enclave.sh` runs unsealed.**

The registry **must pin the SP1 program the running TEE-VM image proves** — a mismatch
reverts `update_state` with `Wrong program`. The canonical registries in appchain.conf are
kept in lockstep with the released images; if you pin a different registry or image,
verify their vkeys match.

## Host requirements

- **AMD SEV-SNP host** — a CPU family the real registry trusts (Milan/Genoa root certs),
  running SEV-SNP as a **hypervisor** (`kvm_amd: SEV-SNP enabled`); the *guest* gets
  `/dev/sev-guest` for attestation. The enclave units run as root (need `/dev/kvm` +
  `/dev/sev*`). See HOST_SETUP.md for the rest of the host bootstrap.

## Deploy

1. **`scripts/init.sh`** (one-time, **real gas** on the target network) — `katana init
   rollup --tee --tee-registry-address <registry>` deploys the piltover wired to that
   network's registry and writes its chain-config. The Init workflow's `network`/`mode`
   inputs pick the registry + output dir from appchain.conf. (`init` has a declare→deploy
   race handled by init.sh's retry — see INIT_ATTEMPTS.)
2. **`NETWORK=<net> scripts/deploy.sh <user@host>`** — deploys the enclave for the
   selected network **alongside the other combos** on one host, each with its own unit /
   state dir / env / port. It rsyncs the repo, injects `[settlement.runtime]` into the
   host `chain-config`, installs + starts the unit (as root, rendered from
   `host/enclave.service.tpl`), and installs **no** host katana binary (the enclave boots
   the self-contained TEE-VM image). For real proving the runtime block needs, besides the
   saya key + `tee-registry`, a **`prover-key`** = the SP1 prover-network private key,
   passed as the `PROVER_KEY` env (absent ⇒ `TeeProver::Mock`):

   ```toml
   [settlement.runtime]
   account-address = "0x…"          # saya (settlement account)
   account-private-key = "0x…"
   tee-registry = "0x…"             # the network's real AMDTeeRegistry
   prover-key = "0x…"               # SP1 network key — present ⇒ TeeProver::Sp1 (real); absent ⇒ Mock
   batch-size = 120
   idle-flush-secs = 600
   ```
3. **`scripts/run-enclave.sh`** (run by the unit) — fetches the TEE-VM image, ensures the
   ext4 data disk, and boots the enclave with the chain dir + `--tee sev-snp`.

## Verify the running enclave

```bash
# real SEV-SNP attestation for block 0 (params: [prev_block_id|null, block_id])
curl -s http://<host>:<rpc-port>/ -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tee_generateQuote","params":[null,0]}'
# the 1184-byte SEV-SNP report's measurement is at byte offset 0x90 (hex chars 289–384);
# katanaTeeConfigHash in the response must match the registry's pinned config hash.
```

## Provenance

`host/amdsev/` (the enclave launcher) is vendored from `dojoengine/katana` `misc/AMDSEV/`
(`HOST_RPC_PORT` made env-overridable). The authoritative docs are katana `docs/amdsev.md`.
