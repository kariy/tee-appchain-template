[Unit]
Description=${CHAIN_NAME} appchain — ${UNIT} (katana rollup, embedded settlement)
After=network-online.target
Wants=network-online.target

[Service]
# /etc/${UNIT}/env is written by scripts/deploy.sh and carries KATANA (binary
# path), APPCHAIN_PORT, and BASE. The leading - tolerates it being absent on first install.
EnvironmentFile=-/etc/${UNIT}/env

# run-appchain.sh execs katana in the foreground; the chain-config it points at carries
# the [settlement.runtime] section (saya key) that deploy.sh injects from a secret.
Type=simple
ExecStart=/var/lib/${UNIT}/current/scripts/run-appchain.sh
Restart=always
RestartSec=5
LimitNOFILE=1048576

# The bare-metal deploy user (no VM/KVM needed — unlike the enclave unit).
User=${DEPLOY_USER}
Group=${DEPLOY_USER}
WorkingDirectory=/var/lib/${UNIT}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
