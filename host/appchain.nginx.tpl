# nginx vhost template — the host-level appchain router: https://${APPCHAIN_DOMAIN}
# Rendered by scripts/deploy.sh (envsubst; ${RPC_PORT_*}/${APPCHAIN_DOMAIN} substituted,
# nginx runtime vars like $host/$request_uri pass through). Path-routes to the appchain
# deployments on this host (all loopback-bound):
#   /sepolia/rpc      → sepolia-enclave (SEV-SNP enclave, settles Sepolia)
#   /mainnet/rpc      → mainnet-enclave (SEV-SNP enclave, settles Mainnet)
#   /sepolia-mock/rpc → sepolia-mock    (bare katana --tee mock)
#   /mainnet-mock/rpc → mainnet-mock    (bare katana --tee mock)
# A route to an undeployed combo just 502s — harmless, nothing alerts on it.
#
# Self-contained TLS; certbot only issues/renews the cert (bootstrap in deploy.sh).
# The domain's DNS record must point at the host; nginx does the routing.

server {
    listen 80;
    server_name ${APPCHAIN_DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${APPCHAIN_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${APPCHAIN_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${APPCHAIN_DOMAIN}/privkey.pem;

    # Mozilla "intermediate" equivalent (mirrors certbot's options-ssl-nginx.conf).
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:le_nginx_SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # Allow large contract-class declares (Sierra); katana is the real limiter
    # (--rpc.max-request-body-size, set by the runners).
    client_max_body_size 20m;

    # Shared proxy settings — inherited by the /<net>/rpc locations below (nginx inherits
    # proxy_* from server level when a location defines none of its own).
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";

    location = /health {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "ok\n";
    }

    # Per-deployment RPC — strip the /<net>/rpc prefix so katana sees a root path.
    location /sepolia/rpc {
        rewrite ^/sepolia/rpc/?(.*)$ /$1 break;
        proxy_pass http://127.0.0.1:${RPC_PORT_SEPOLIA_ENCLAVE};
    }
    location /mainnet/rpc {
        rewrite ^/mainnet/rpc/?(.*)$ /$1 break;
        proxy_pass http://127.0.0.1:${RPC_PORT_MAINNET_ENCLAVE};
    }
    location /sepolia-mock/rpc {
        rewrite ^/sepolia-mock/rpc/?(.*)$ /$1 break;
        proxy_pass http://127.0.0.1:${RPC_PORT_SEPOLIA_MOCK};
    }
    location /mainnet-mock/rpc {
        rewrite ^/mainnet-mock/rpc/?(.*)$ /$1 break;
        proxy_pass http://127.0.0.1:${RPC_PORT_MAINNET_MOCK};
    }
}
