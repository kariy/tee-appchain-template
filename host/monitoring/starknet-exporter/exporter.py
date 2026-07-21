#!/usr/bin/env python3
"""Prometheus exporter for Starknet-side scrapes: settlement-account STRK
balances and appchain head blocks.

Polls STRK `balanceOf(account)` via plain JSON-RPC `starknet_call` for one or more
settlement (saya) accounts and serves the balances on 127.0.0.1:$PORT/metrics.
Balances are exposed raw (fri, 1e18 = 1 STRK) + scaled, labeled by `network` and
`account`. Prometheus scrapes it; a Grafana alert fires per series when a balance
drops below the ~18 STRK resource-bounds headroom an `update_state` needs to pass
validation (running dry stalls settlement).

Sibling of succinct-exporter (PROVE balance) — deliberately the same shape.

Config (env):
  STARKNET_SETTLEMENT_ACCOUNTS  comma list of `network=address[=deployment]`
                                (e.g. "sepolia=0x…=mychain-sepolia-enclave"). The network
                                label doubles as the RPC path segment in
                                STARKNET_RPC_TEMPLATE. The optional deployment segment
                                becomes a `deployment` label so alerts can say which
                                unit the account funds.
  STARKNET_RPC_TEMPLATE         override the RPC URL template; `{network}` is replaced.
  APPCHAIN_RPC_TARGETS          comma list of `deployment=url` appchain RPC endpoints to
                                poll for the head block (starknet_blockNumber), exported
                                as appchain_latest_block{deployment}. katana (sequencer
                                mode) exposes no head-block metric of its own, hence RPC.
                                Written to ./.env by deploy-monitoring.sh from
                                MONITORED_COMBOS; empty ⇒ no head-block polling.
"""
import json, os, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

RPC_TEMPLATE = os.environ.get(
    "STARKNET_RPC_TEMPLATE", "https://api.cartridge.gg/x/starknet/{network}/rpc/v0_9"
)
INTERVAL = int(os.environ.get("INTERVAL", "60"))
PORT = int(os.environ.get("PORT", "9117"))
DECIMALS = int(os.environ.get("STRK_DECIMALS", "18"))
# The STRK ERC20 lives at the same address on mainnet and sepolia.
STRK_TOKEN = os.environ.get(
    "STRK_TOKEN_ADDRESS", "0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d"
)
# sn_keccak("balanceOf")
BALANCE_OF_SELECTOR = "0x2e4263afad30923c891518314c3c95dbe830a16874e8abc5777a9a20b54c76e"


def parse_accounts():
    raw = os.environ.get("STARKNET_SETTLEMENT_ACCOUNTS", "").strip()
    accts = []
    if raw:
        for part in raw.split(","):
            fields = [f.strip() for f in part.strip().split("=")]
            if len(fields) >= 2 and fields[1]:
                net, addr = fields[0], fields[1].lower()
                deployment = fields[2] if len(fields) > 2 else ""
                accts.append((net, addr, deployment))
    return accts


def parse_rpc_targets():
    # deploy-monitoring.sh derives this from MONITORED_COMBOS; empty ⇒ no head polling.
    raw = os.environ.get("APPCHAIN_RPC_TARGETS", "").strip()
    targets = []
    for part in raw.split(","):
        dep, _, url = part.strip().partition("=")
        if dep and url:
            targets.append((dep.strip(), url.strip()))
    return targets


ACCOUNTS = parse_accounts()
RPC_TARGETS = parse_rpc_targets()
_state = {"balances": {}, "heads": {}}  # (network, address, deployment) -> fri | None; deployment -> block | None


def query_balance(network, addr):
    payload = json.dumps({
        "jsonrpc": "2.0",
        "method": "starknet_call",
        "params": {
            "request": {
                "contract_address": STRK_TOKEN,
                "entry_point_selector": BALANCE_OF_SELECTOR,
                "calldata": [addr],
            },
            "block_id": "latest",
        },
        "id": 1,
    }).encode()
    req = urllib.request.Request(
        RPC_TEMPLATE.format(network=network), data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = json.loads(resp.read())
    if "result" not in body:
        raise RuntimeError(body.get("error", "no result"))
    # u256 as [low, high] felts
    low, high = (int(x, 16) for x in body["result"][:2])
    return low + (high << 128)


def query_head(url):
    payload = json.dumps({"jsonrpc": "2.0", "method": "starknet_blockNumber", "id": 1}).encode()
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = json.loads(resp.read())
    if "result" not in body:
        raise RuntimeError(body.get("error", "no result"))
    return int(body["result"])


def poll():
    while True:
        balances = {}
        for net, addr, deployment in ACCOUNTS:
            try:
                balances[(net, addr, deployment)] = query_balance(net, addr)
            except Exception as e:  # noqa: BLE001
                balances[(net, addr, deployment)] = None
                print(f"balanceOf {net}/{addr} failed: {e}", flush=True)
        heads = {}
        for dep, url in RPC_TARGETS:
            try:
                heads[dep] = query_head(url)
            except Exception as e:  # noqa: BLE001
                heads[dep] = None
                print(f"blockNumber {dep} ({url}) failed: {e}", flush=True)
        _state["balances"] = balances
        _state["heads"] = heads
        time.sleep(INTERVAL)


def render():
    out = [
        "# HELP starknet_settlement_scrape_success 1 if the last balanceOf for the account succeeded",
        "# TYPE starknet_settlement_scrape_success gauge",
        "# HELP starknet_settlement_balance_fri STRK balance (fri, base units)",
        "# TYPE starknet_settlement_balance_fri gauge",
        "# HELP starknet_settlement_balance_strk Settlement (saya) account balance in STRK",
        "# TYPE starknet_settlement_balance_strk gauge",
    ]
    for (net, addr, deployment), fri in _state["balances"].items():
        lbl = f'network="{net}",account="{addr}"'
        if deployment:
            lbl += f',deployment="{deployment}"'
        out.append(f"starknet_settlement_scrape_success{{{lbl}}} {0 if fri is None else 1}")
        if fri is not None:
            out.append(f"starknet_settlement_balance_fri{{{lbl}}} {fri}")
            out.append(f"starknet_settlement_balance_strk{{{lbl}}} {fri / (10 ** DECIMALS):.9f}")
    out += [
        "# HELP appchain_rpc_scrape_success 1 if the last starknet_blockNumber for the deployment succeeded",
        "# TYPE appchain_rpc_scrape_success gauge",
        "# HELP appchain_latest_block Appchain head block number (via starknet_blockNumber)",
        "# TYPE appchain_latest_block gauge",
    ]
    for dep, block in _state["heads"].items():
        lbl = f'deployment="{dep}"'
        out.append(f"appchain_rpc_scrape_success{{{lbl}}} {0 if block is None else 1}")
        if block is not None:
            out.append(f"appchain_latest_block{{{lbl}}} {block}")
    return "\n".join(out) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = render().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print(f"starknet-exporter on 127.0.0.1:{PORT} for {ACCOUNTS} (poll {INTERVAL}s)", flush=True)
    threading.Thread(target=poll, daemon=True).start()
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
