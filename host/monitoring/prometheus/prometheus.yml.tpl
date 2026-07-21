# Prometheus scrape config template for the appchain host. Rendered by
# scripts/deploy-monitoring.sh: the KATANA_SCRAPE_TARGETS / BLACKBOX_SCRAPE_TARGETS
# placeholders below expand to one static_configs entry per MONITORED_COMBOS member
# (see scripts/lib/config.sh), labeled deployment/network/mode/unit. All targets are loopback:
#   node_exporter  127.0.0.1:9100        — host CPU/mem/disk/net
#   katana         127.0.0.1:<metrics>   — one port per monitored combo
#   blackbox       probes each combo's RPC health endpoint (GET / → {"health":true})
# Alerting is Grafana-managed (unified alerting), so no rule_files/Alertmanager here.
global:
  scrape_interval: 30s
  evaluation_interval: 30s
  external_labels:
    host: ${HOST_LABEL}

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:9090']

  - job_name: node
    static_configs:
      - targets: ['127.0.0.1:9100']
        labels: { instance: ${HOST_LABEL} }

  # Succinct prover-network account balance ($PROVE) — for the out-of-funds alert.
  - job_name: succinct-prover
    static_configs:
      - targets: ['127.0.0.1:9116']

  # Settlement (saya) account STRK balances — update_state needs ~18 STRK of
  # resource-bounds headroom to pass validation; the low-balance alert fires
  # well before that.
  - job_name: starknet-settlement
    static_configs:
      - targets: ['127.0.0.1:9117']

  - job_name: katana
    metrics_path: /metrics
    # katana's metrics endpoint sends a blank Content-Type; Prometheus 3.x needs a fallback.
    fallback_scrape_protocol: PrometheusText0.0.4
    # instance is set to the friendly deployment name (overriding the default host:port) so the
    # katana dashboard's $instance selector reads sepolia-mock / sepolia-enclave / ….
    static_configs:
${KATANA_SCRAPE_TARGETS}

  # Blackbox RPC liveness — probe GET / on each node; probe_success=1 when it returns
  # 200 + {"health":true}. Relabel so __address__ points at blackbox and the probed URL
  # rides in __param_target (the standard blackbox pattern).
  - job_name: blackbox-rpc
    metrics_path: /probe
    params:
      module: [starknet_health]
    static_configs:
${BLACKBOX_SCRAPE_TARGETS}
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: rpc_url
      - target_label: __address__
        replacement: 127.0.0.1:9115
