#!/usr/bin/env python3
"""Prometheus exporter for Succinct Prover Network account balances.

Polls the ProverNetwork `GetBalance` gRPC (no auth, address only) via grpcurl + the vendored
proto, for one or more accounts, and serves the balances on :$PORT/metrics (loopback).
GetBalance returns credits in base units (1e18 = 1 PROVE), exposed raw + scaled, labeled by
`network` and `account`. Prometheus scrapes it; a Grafana alert fires per series when low.

Config (env):
  SUCCINCT_PROVER_ACCOUNTS  comma list of `network=address[=deployment]`
                            (e.g. "sepolia=0x…=mychain-sepolia-enclave"). The optional
                            deployment segment becomes a `deployment` label so alerts can
                            say which unit the account funds.
  SUCCINCT_PROVER_ADDRESS   single address fallback (labeled network="prover") if the list is unset.
"""
import base64, json, os, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

RPC = os.environ.get("SUCCINCT_RPC", "rpc.mainnet.succinct.xyz:443")
INTERVAL = int(os.environ.get("INTERVAL", "60"))
PORT = int(os.environ.get("PORT", "9116"))
DECIMALS = int(os.environ.get("PROVE_DECIMALS", "18"))


def parse_accounts():
    raw = os.environ.get("SUCCINCT_PROVER_ACCOUNTS", "").strip()
    accts = []
    if raw:
        for part in raw.split(","):
            fields = [f.strip() for f in part.strip().split("=")]
            if len(fields) >= 2 and fields[1]:
                net, addr = fields[0], fields[1].lower()
                deployment = fields[2] if len(fields) > 2 else ""
                accts.append((net, addr, deployment))
    elif os.environ.get("SUCCINCT_PROVER_ADDRESS", "").strip():
        accts.append(("prover", os.environ["SUCCINCT_PROVER_ADDRESS"].strip().lower(), ""))
    return accts


ACCOUNTS = parse_accounts()
_state = {"balances": {}}  # (network, address, deployment) -> base_units | None


def query_balance(addr):
    b64 = base64.b64encode(bytes.fromhex(addr[2:] if addr.startswith("0x") else addr)).decode()
    r = subprocess.run(
        ["grpcurl", "-max-time", "20", "-proto", "/proto/network.proto", "-import-path", "/proto",
         "-d", json.dumps({"address": b64}), RPC, "network.ProverNetwork/GetBalance"],
        capture_output=True, text=True, timeout=30,
    )
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip() or "grpcurl failed")
    return int(json.loads(r.stdout)["amount"])


def poll():
    while True:
        by_addr = {}  # dedupe: query each unique address once
        for _net, addr, _dep in ACCOUNTS:
            if addr not in by_addr:
                try:
                    by_addr[addr] = query_balance(addr)
                except Exception as e:  # noqa: BLE001
                    by_addr[addr] = None
                    print(f"GetBalance {addr} failed: {e}", flush=True)
        _state["balances"] = {(net, addr, dep): by_addr[addr] for net, addr, dep in ACCOUNTS}
        time.sleep(INTERVAL)


def render():
    out = [
        "# HELP succinct_prover_scrape_success 1 if the last GetBalance for the account succeeded",
        "# TYPE succinct_prover_scrape_success gauge",
        "# HELP succinct_prover_balance_base_units GetBalance amount (base units)",
        "# TYPE succinct_prover_balance_base_units gauge",
        "# HELP succinct_prover_balance_prove Prover-network credit balance in PROVE",
        "# TYPE succinct_prover_balance_prove gauge",
    ]
    for (net, addr, deployment), bu in _state["balances"].items():
        lbl = f'network="{net}",account="{addr}"'
        if deployment:
            lbl += f',deployment="{deployment}"'
        out.append(f"succinct_prover_scrape_success{{{lbl}}} {0 if bu is None else 1}")
        if bu is not None:
            out.append(f"succinct_prover_balance_base_units{{{lbl}}} {bu}")
            out.append(f"succinct_prover_balance_prove{{{lbl}}} {bu / (10 ** DECIMALS):.9f}")
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
    print(f"succinct-exporter on 127.0.0.1:{PORT} for {ACCOUNTS} (poll {INTERVAL}s)", flush=True)
    threading.Thread(target=poll, daemon=True).start()
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
