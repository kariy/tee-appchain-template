# nginx vhost template — Grafana for the appchain monitoring stack: https://${GRAFANA_DOMAIN}
# → 127.0.0.1:${GRAFANA_PORT} (the docker Grafana, loopback-bound; :3000 is the mock's
# vrf-server). Rendered + installed by scripts/deploy-monitoring.sh; certbot issues the cert.
# The domain's DNS record must point at the host.

# WebSocket upgrade map for Grafana Live (keeps keep-alive for normal HTTP).
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name ${GRAFANA_DOMAIN};

    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name ${GRAFANA_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${GRAFANA_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${GRAFANA_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:le_nginx_SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    location / {
        proxy_pass http://127.0.0.1:${GRAFANA_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
