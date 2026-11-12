FROM debian:bookworm-slim

ARG VPN_PORT=24443

ENV VPN_PORT=${VPN_PORT} \
    DATA=/var/lib/openvpn \
    OVPN_REMOTE=vpn.example.net

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openvpn \
        easy-rsa \
        ca-certificates \
        iproute2 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p \
        /etc/openvpn/server \
        /var/lib/openvpn/pki \
        /var/lib/openvpn/ccd \
        /var/lib/openvpn/clients \
        /run/openvpn

RUN cat > /usr/local/sbin/ovpn-entrypoint <<'SH'
#!/bin/sh
set -eu

DATA="${DATA:-/var/lib/openvpn}"
PKI="$DATA/pki"
EASYRSA="/usr/share/easy-rsa/easyrsa"
VPN_PORT="${VPN_PORT:-24443}"
OVPN_REMOTE="${OVPN_REMOTE:-vpn.example.net}"

init_pki() {
    mkdir -p "$PKI" "$DATA/ccd" "$DATA/clients"

    if [ ! -f "$PKI/pki/ca.crt" ]; then
        echo "Initializing PKI..."

        cd "$PKI"

        EASYRSA_BATCH=1 \
        EASYRSA_PKI="$PKI/pki" \
            "$EASYRSA" init-pki

        EASYRSA_BATCH=1 \
        EASYRSA_REQ_CN="OpenVPN CA" \
        EASYRSA_PKI="$PKI/pki" \
            "$EASYRSA" build-ca nopass

        EASYRSA_BATCH=1 \
        EASYRSA_PKI="$PKI/pki" \
            "$EASYRSA" build-server-full server nopass

        EASYRSA_BATCH=1 \
        EASYRSA_PKI="$PKI/pki" \
            "$EASYRSA" gen-crl

        openvpn --genkey tls-crypt "$PKI/pki/ta.key"

        chmod 755 "$DATA" "$PKI" "$PKI/pki"
        chmod 644 "$PKI/pki/crl.pem"

        echo "PKI initialized."
    fi

    # OpenVPN после запуска работает от nobody:nogroup.
    # Сертификаты сервер читает до снижения привилегий,
    # а CCD-файлы должны быть доступны процессу после запуска.
    chmod 755 "$DATA" "$DATA/ccd" "$DATA/clients"
    find "$DATA/ccd" -type f -exec chmod 644 {} \;
}

write_server_config() {
    mkdir -p /run/openvpn
    touch /run/openvpn/status.log
    chown nobody:nogroup /run/openvpn/status.log || true

    cat > /etc/openvpn/server/server.conf <<EOF
port ${VPN_PORT}
proto udp4
dev tun

topology subnet
server 10.77.0.0 255.255.255.0

mssfix 1420

ca ${PKI}/pki/ca.crt
cert ${PKI}/pki/issued/server.crt
key ${PKI}/pki/private/server.key
crl-verify ${PKI}/pki/crl.pem
tls-crypt ${PKI}/pki/ta.key

dh none
ecdh-curve prime256v1
tls-version-min 1.2

remote-cert-tls client
verify-client-cert require

client-to-client
client-config-dir ${DATA}/ccd

# Явно сообщаем клиентам маршрут VPN-сети.
push "route 10.77.0.0 255.255.255.0"

keepalive 10 60
persist-key
persist-tun

#user nobody
#group nogroup

data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA256
allow-compression no

status /run/openvpn/status.log
status-version 3
verb 3
EOF
}

issue_client() {
    CN="$1"

    case "$CN" in
        ""|*[!A-Za-z0-9._-]*)
            echo "Invalid client name: $CN" >&2
            exit 1
            ;;
    esac

    if [ -f "$PKI/pki/issued/${CN}.crt" ]; then
        echo "Client already exists: $CN" >&2
        exit 1
    fi

    cd "$PKI"

    EASYRSA_BATCH=1 \
    EASYRSA_PKI="$PKI/pki" \
        "$EASYRSA" build-client-full "$CN" nopass

    OUT="$DATA/clients/$CN"
    mkdir -p "$OUT"

    cp "$PKI/pki/ca.crt" "$OUT/ca.crt"
    cp "$PKI/pki/issued/${CN}.crt" "$OUT/${CN}.crt"
    cp "$PKI/pki/private/${CN}.key" "$OUT/${CN}.key"
    cp "$PKI/pki/ta.key" "$OUT/ta.key"

    OVPN="$OUT/${CN}.ovpn"

    cat > "$OVPN" <<EOF
client
dev tun
proto udp4
remote ${OVPN_REMOTE} ${VPN_PORT}

resolv-retry infinite
nobind
persist-key
persist-tun

remote-cert-tls server
auth-nocache
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA256
allow-compression no

verb 3

<ca>
EOF

    cat "$OUT/ca.crt" >> "$OVPN"

    cat >> "$OVPN" <<EOF
</ca>
<cert>
EOF

    cat "$OUT/${CN}.crt" >> "$OVPN"

    cat >> "$OVPN" <<EOF
</cert>
<key>
EOF

    cat "$OUT/${CN}.key" >> "$OVPN"

    cat >> "$OVPN" <<EOF
</key>
<tls-crypt>
EOF

    cat "$OUT/ta.key" >> "$OVPN"

    cat >> "$OVPN" <<EOF
</tls-crypt>
EOF

    chmod 600 "$OUT"/*
    echo "Client profile created: $OVPN"
}

revoke_client() {
    CN="$1"

    cd "$PKI"

    EASYRSA_BATCH=1 \
    EASYRSA_PKI="$PKI/pki" \
        "$EASYRSA" revoke "$CN"

    EASYRSA_BATCH=1 \
    EASYRSA_PKI="$PKI/pki" \
        "$EASYRSA" gen-crl

    chmod 644 "$PKI/pki/crl.pem"

    echo "Client revoked: $CN"
    echo "Restart or reload OpenVPN server to apply the new CRL."
}

case "${1:-run}" in
    init)
        init_pki
        ;;

    client)
        if [ "$#" -ne 2 ]; then
            echo "Usage: client <name>" >&2
            exit 1
        fi
        init_pki
        issue_client "$2"
        ;;

    revoke)
        if [ "$#" -ne 2 ]; then
            echo "Usage: revoke <name>" >&2
            exit 1
        fi
        init_pki
        revoke_client "$2"
        ;;

    run)
        init_pki
        write_server_config
        exec openvpn --config /etc/openvpn/server/server.conf
        ;;

    *)
        echo "Usage: $0 {run|init|client <name>|revoke <name>}" >&2
        exit 1
        ;;
esac
SH

RUN chmod 755 /usr/local/sbin/ovpn-entrypoint

ENTRYPOINT ["/usr/local/sbin/ovpn-entrypoint"]
CMD ["run"]
