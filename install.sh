cat > /root/install_hysteria.sh <<'SCRIPT'
#!/bin/bash

set -e

# ============================================================
# Hysteria 2 — автоматическая установка
# Ubuntu 24.04+
#
# Поддержка:
#   1 IP  -> Hysteria слушает этот IP
#
#   2 IP  -> определяется:
#            incoming IP = IP, отличный от source IP
#            default route
#
# Пример:
#   Incoming: 159.200.236.58
#   Outgoing: 94.131.125.21
#
# Скрипт НЕ изменяет ip route / ip rule.
# ============================================================

CONFIG="/etc/hysteria/config.yaml"
CERT_DIR="/etc/hysteria/cert"
CERT_FILE="$CERT_DIR/server.crt"
KEY_FILE="$CERT_DIR/server.key"
SERVICE="/etc/systemd/system/hysteria-server.service"
BINARY="/usr/local/bin/hysteria"

PORT=443

echo
echo "============================================================"
echo "             HYSTERIA 2 INSTALLER"
echo "============================================================"
echo

# ------------------------------------------------------------
# ROOT
# ------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: запусти скрипт от root."
    exit 1
fi

# ------------------------------------------------------------
# OS
# ------------------------------------------------------------

if [ ! -f /etc/os-release ]; then
    echo "ERROR: не удалось определить ОС."
    exit 1
fi

source /etc/os-release

echo "OS: $PRETTY_NAME"
echo "Kernel: $(uname -r)"
echo "Architecture: $(uname -m)"
echo

# ------------------------------------------------------------
# ARCHITECTURE
# ------------------------------------------------------------

case "$(uname -m)" in
    x86_64|amd64)
        HY_ARCH="amd64"
        ;;
    aarch64|arm64)
        HY_ARCH="arm64"
        ;;
    armv7l|armv7)
        HY_ARCH="arm"
        ;;
    *)
        echo "ERROR: неподдерживаемая архитектура."
        exit 1
        ;;
esac

# ------------------------------------------------------------
# IP ADDRESSES
# ------------------------------------------------------------

mapfile -t IPV4_LIST < <(
    ip -4 -o addr show scope global \
    | awk '{print $4}' \
    | cut -d/ -f1
)

if [ "${#IPV4_LIST[@]}" -eq 0 ]; then
    echo "ERROR: IPv4 не найдены."
    exit 1
fi

echo "Обнаруженные IPv4:"
for IP in "${IPV4_LIST[@]}"; do
    echo "  $IP"
done
echo

# ------------------------------------------------------------
# OUTGOING IP
# ------------------------------------------------------------

ROUTE_INFO="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"

OUT_IP="$(
    echo "$ROUTE_INFO" |
    awk '
    {
        for (i=1; i<=NF; i++) {
            if ($i == "src") {
                print $(i+1)
                exit
            }
        }
    }'
)"

if [ -z "$OUT_IP" ]; then
    echo "ERROR: не удалось определить outgoing IP."
    echo
    echo "$ROUTE_INFO"
    exit 1
fi

echo "IP исходящего трафика:"
echo "  $OUT_IP"
echo

# ------------------------------------------------------------
# INCOMING IP
# ------------------------------------------------------------

LISTEN_IP=""

if [ "${#IPV4_LIST[@]}" -eq 1 ]; then

    LISTEN_IP="${IPV4_LIST[0]}"

    echo "Обнаружен один IPv4."
    echo "Используем его как IP Hysteria."

elif [ "${#IPV4_LIST[@]}" -eq 2 ]; then

    for IP in "${IPV4_LIST[@]}"; do
        if [ "$IP" != "$OUT_IP" ]; then
            LISTEN_IP="$IP"
            break
        fi
    done

    if [ -z "$LISTEN_IP" ]; then
        echo
        echo "Не удалось автоматически определить incoming IP."
        echo
        read -rp "Введите IP для входящих подключений: " LISTEN_IP
    fi

else

    echo
    echo "Обнаружено более двух IPv4:"
    printf '  %s\n' "${IPV4_LIST[@]}"
    echo
    echo "Автоматический выбор небезопасен."
    echo

    read -rp "Введите IP для входящих подключений: " LISTEN_IP

fi

# ------------------------------------------------------------
# NETWORK SUMMARY
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                 NETWORK CONFIGURATION"
echo "============================================================"
echo
echo "Incoming / Hysteria IP:"
echo "  $LISTEN_IP"
echo
echo "Outgoing IP:"
echo "  $OUT_IP"
echo
echo "Port:"
echo "  $PORT"
echo
echo "============================================================"
echo

if [ "${#IPV4_LIST[@]}" -eq 2 ]; then
    echo "Обнаружена схема с двумя IP."
    echo
    echo "Важно:"
    echo "Скрипт НЕ меняет маршрутизацию провайдера."
    echo "ip route и ip rule остаются без изменений."
    echo
fi

# ------------------------------------------------------------
# INSTALL PACKAGES
# ------------------------------------------------------------

echo ">>> Устанавливаем необходимые пакеты..."

apt-get update -y

apt-get install -y \
    curl \
    ca-certificates \
    openssl \
    iproute2 \
    tcpdump \
    python3

# ------------------------------------------------------------
# DOWNLOAD HYSTERIA
# ------------------------------------------------------------

echo
echo ">>> Получаем последнюю версию Hysteria..."

LATEST_TAG="$(
    curl -fsSL \
    https://api.github.com/repos/apernet/hysteria/releases/latest |
    grep '"tag_name"' |
    head -1 |
    sed -E 's/.*"([^"]+)".*/\1/'
)"

if [ -z "$LATEST_TAG" ]; then
    echo "ERROR: не удалось определить версию Hysteria."
    exit 1
fi

echo "Hysteria version: $LATEST_TAG"

DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/${LATEST_TAG}/hysteria-linux-${HY_ARCH}"

echo
echo ">>> Download:"
echo "$DOWNLOAD_URL"

TMP_BINARY="/tmp/hysteria"

curl -fL "$DOWNLOAD_URL" -o "$TMP_BINARY"

chmod +x "$TMP_BINARY"

echo
echo ">>> Проверка бинарника:"
"$TMP_BINARY" version || true

# ------------------------------------------------------------
# USER
# ------------------------------------------------------------

if ! id hysteria >/dev/null 2>&1; then
    echo
    echo ">>> Создаём пользователя hysteria..."

    useradd \
        --system \
        --no-create-home \
        --shell /usr/sbin/nologin \
        hysteria
fi

# ------------------------------------------------------------
# STOP OLD SERVICE
# ------------------------------------------------------------

echo
echo ">>> Останавливаем старую службу..."

systemctl stop hysteria-server.service 2>/dev/null || true
systemctl stop hysteria.service 2>/dev/null || true

# ------------------------------------------------------------
# INSTALL BINARY
# ------------------------------------------------------------

echo
echo ">>> Устанавливаем Hysteria..."

install -m 0755 "$TMP_BINARY" "$BINARY"

rm -f "$TMP_BINARY"

# ------------------------------------------------------------
# DIRECTORIES
# ------------------------------------------------------------

mkdir -p /etc/hysteria
mkdir -p "$CERT_DIR"

chown root:root /etc/hysteria
chmod 755 /etc/hysteria

chown hysteria:hysteria "$CERT_DIR"
chmod 750 "$CERT_DIR"

# ------------------------------------------------------------
# PASSWORDS
# ------------------------------------------------------------

AUTH_PASSWORD="$(openssl rand -base64 32 | tr -d '\n')"
OBFS_PASSWORD="$(openssl rand -base64 32 | tr -d '\n')"

# ------------------------------------------------------------
# SELF-SIGNED CERTIFICATE
# ------------------------------------------------------------

echo
echo ">>> Генерируем TLS сертификат..."

openssl req \
    -x509 \
    -newkey rsa:2048 \
    -sha256 \
    -days 3650 \
    -nodes \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/CN=$LISTEN_IP"

chown hysteria:hysteria "$CERT_FILE" "$KEY_FILE"

chmod 644 "$CERT_FILE"
chmod 600 "$KEY_FILE"

# ------------------------------------------------------------
# FINGERPRINT
# ------------------------------------------------------------

FINGERPRINT="$(
    openssl x509 \
        -noout \
        -fingerprint \
        -sha256 \
        -in "$CERT_FILE" |
    cut -d= -f2 |
    tr -d ':'
)"

# ------------------------------------------------------------
# URL ENCODE
# ------------------------------------------------------------

urlencode() {
    python3 - "$1" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=''))
PY
}

AUTH_ENC="$(urlencode "$AUTH_PASSWORD")"
OBFS_ENC="$(urlencode "$OBFS_PASSWORD")"

# ------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------

echo
echo ">>> Создаём конфигурацию Hysteria..."

cat > "$CONFIG" <<EOF
listen: ${LISTEN_IP}:${PORT}

tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}

auth:
  type: password
  password: "${AUTH_PASSWORD}"

obfs:
  type: salamander
  salamander:
    password: "${OBFS_PASSWORD}"

masquerade:
  type: proxy
  proxy:
    url: https://www.cloudflare.com/
    rewriteHost: true
EOF

chown root:hysteria "$CONFIG"
chmod 640 "$CONFIG"

# ------------------------------------------------------------
# SYSTEMD
# ------------------------------------------------------------

echo
echo ">>> Создаём systemd service..."

cat > "$SERVICE" <<EOF
[Unit]
Description=Hysteria Server Service (config.yaml)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hysteria
Group=hysteria

ExecStart=${BINARY} server --config ${CONFIG}

Restart=on-failure
RestartSec=3

LimitNOFILE=1048576

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

# ------------------------------------------------------------
# START
# ------------------------------------------------------------

echo
echo ">>> Запускаем Hysteria..."

systemctl daemon-reload
systemctl enable hysteria-server.service
systemctl restart hysteria-server.service

sleep 2

# ------------------------------------------------------------
# STATUS
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                    SERVICE STATUS"
echo "============================================================"

if ! systemctl is-active --quiet hysteria-server.service; then

    echo
    echo "ERROR: Hysteria не запустилась."
    echo
    systemctl status hysteria-server.service --no-pager
    echo
    echo "LOG:"
    journalctl -u hysteria-server.service -n 50 --no-pager

    exit 1
fi

systemctl status hysteria-server.service --no-pager

# ------------------------------------------------------------
# PORT
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                    UDP 443"
echo "============================================================"

ss -lunp | grep ':443' || true

# ------------------------------------------------------------
# HY2 LINK
# ------------------------------------------------------------

HY2_URI="hy2://${AUTH_ENC}@${LISTEN_IP}:${PORT}/?insecure=1&obfs=salamander&obfs-password=${OBFS_ENC}#Hysteria"

# ------------------------------------------------------------
# SAVE INFO
# ------------------------------------------------------------

INFO_FILE="/root/hysteria-info.txt"

cat > "$INFO_FILE" <<EOF
============================================================
HYSTERIA 2
============================================================

Version:
${LATEST_TAG}

Incoming IP:
${LISTEN_IP}

Outgoing IP:
${OUT_IP}

Port:
${PORT}

Auth password:
${AUTH_PASSWORD}

Salamander password:
${OBFS_PASSWORD}

TLS SHA256:
${FINGERPRINT}

HY2 URI:

${HY2_URI}

Config:
${CONFIG}

Service:
hysteria-server.service

============================================================
EOF

chmod 600 "$INFO_FILE"

# ------------------------------------------------------------
# FINAL
# ------------------------------------------------------------

echo
echo
echo "============================================================"
echo "              HYSTERIA УСТАНОВЛЕНА"
echo "============================================================"
echo
echo "Incoming IP:"
echo "  $LISTEN_IP"
echo
echo "Outgoing IP:"
echo "  $OUT_IP"
echo
echo "TLS SHA256:"
echo "  $FINGERPRINT"
echo
echo "============================================================"
echo "                    HY2 LINK"
echo "============================================================"
echo
echo "$HY2_URI"
echo
echo "============================================================"
echo
echo "Информация сохранена:"
echo "  $INFO_FILE"
echo
echo "Проверка:"
echo "  systemctl status hysteria-server --no-pager"
echo "  ss -lunp | grep 443"
echo "  journalctl -u hysteria-server -n 50 --no-pager"
echo
echo "UDP мониторинг:"
echo "  tcpdump -ni ens3 'udp port 443'"
echo
echo "============================================================"
SCRIPT

chmod +x /root/install_hysteria.sh
/root/install_hysteria.sh
