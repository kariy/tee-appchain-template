# Promtail config template — rendered by scripts/deploy-monitoring.sh (envsubst substitutes
# ${CHAIN_NAME}/${HOST_LABEL}; promtail's own $1 capture reference passes through).
# Ships the host systemd journal to Loki, keeping only the appchain units
# (${CHAIN_NAME}-<network>-<mode>.service) and mapping each unit to its `deployment`
# label (<network>-<mode>) with one capture rule. katana logs `--log.stdout.format json`,
# so a json pipeline stage lifts `level`/`target` into labels/fields (non-JSON firmware
# lines from the enclave serial pass through untouched).
server:
  http_listen_address: 127.0.0.1
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /promtail/positions.yaml

clients:
  - url: http://127.0.0.1:3100/loki/api/v1/push

scrape_configs:
  - job_name: journal
    journal:
      path: /var/log/journal
      max_age: 12h
      labels:
        job: systemd-journal
        host: ${HOST_LABEL}
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: unit
      # Keep only the appchain units.
      - source_labels: ['unit']
        regex: '${CHAIN_NAME}-(sepolia|mainnet)-(mock|enclave)\.service'
        action: keep
      # unit → deployment: the unit name is ${CHAIN_NAME}-<network>-<mode>, the deployment
      # label is <network>-<mode> — one anchored capture covers every combo.
      - source_labels: ['unit']
        regex: '${CHAIN_NAME}-((sepolia|mainnet)-(mock|enclave))\.service'
        target_label: deployment
        replacement: '$1'
    pipeline_stages:
      - json:
          expressions:
            level: level
            target: target
      - labels:
          level:
