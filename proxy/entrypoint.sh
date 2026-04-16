#!/bin/sh
set -eu

WEBSITE_ADDRESS="${WEBSITE_ADDRESS:-localhost}"
SSL_CERT_DAYS="${SSL_CERT_DAYS:-365}"
CERT_DIR="/etc/nginx/certs"
CERT_KEY="${CERT_DIR}/selfsigned.key"
CERT_CRT="${CERT_DIR}/selfsigned.crt"
NGINX_CONF="/etc/nginx/conf.d/default.conf"
OPENSSL_CONFIG="$(mktemp)"

if printf '%s' "$WEBSITE_ADDRESS" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    SERVER_NAMES="${WEBSITE_ADDRESS} localhost"
    cat > "$OPENSSL_CONFIG" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = ${WEBSITE_ADDRESS}

[v3_req]
subjectAltName = @alt_names

[alt_names]
IP.1 = ${WEBSITE_ADDRESS}
DNS.2 = localhost
IP.3 = 127.0.0.1
EOF
else
    SERVER_NAMES="${WEBSITE_ADDRESS} www.${WEBSITE_ADDRESS} localhost"
    cat > "$OPENSSL_CONFIG" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = ${WEBSITE_ADDRESS}

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${WEBSITE_ADDRESS}
DNS.2 = www.${WEBSITE_ADDRESS}
DNS.3 = localhost
IP.4 = 127.0.0.1
EOF
fi

mkdir -p "$CERT_DIR"

if [ ! -s "$CERT_KEY" ] || [ ! -s "$CERT_CRT" ]; then
    echo "Generating self-signed certificate for ${WEBSITE_ADDRESS}..."
    openssl req \
        -x509 \
        -nodes \
        -newkey rsa:2048 \
        -days "$SSL_CERT_DAYS" \
        -keyout "$CERT_KEY" \
        -out "$CERT_CRT" \
        -config "$OPENSSL_CONFIG"
    chmod 600 "$CERT_KEY"
    chmod 644 "$CERT_CRT"
fi

rm -f "$OPENSSL_CONFIG"

cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAMES};

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${SERVER_NAMES};

    ssl_certificate ${CERT_CRT};
    ssl_certificate_key ${CERT_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;

    client_max_body_size 256m;

    location / {
        proxy_pass http://lms-web:80;
        proxy_http_version 1.1;
        proxy_redirect off;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
    }
}
EOF

nginx -t
exec "$@"
