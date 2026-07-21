[Unit]
Description=${CHAIN_NAME} appchain — ${UNIT} (katana in an AMD SEV-SNP enclave, real TEE settlement)
After=network-online.target
Wants=network-online.target

[Service]
# Rendered per combo by scripts/deploy.sh (host/enclave.service.tpl). The env file
# carries KATANA_TEE_VERSION, APPCHAIN_PORT, BASE. Leading - tolerates absence.
EnvironmentFile=-/etc/${UNIT}/env

# run-enclave.sh boots the SEV-SNP confidential VM (qemu) and tails its serial log in the
# foreground, so systemd keeps the enclave alive. Runs as ROOT — unlike the bare-katana
# unit — because the confidential VM needs KVM (/dev/kvm) + the AMD SEV devices.
Type=simple
ExecStart=/var/lib/${UNIT}/current/scripts/run-enclave.sh
Restart=always
RestartSec=10
LimitNOFILE=1048576

User=root
Group=root
WorkingDirectory=/var/lib/${UNIT}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
