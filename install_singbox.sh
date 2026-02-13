#!/bin/bash
set -euo pipefail

# ===================== 基础颜色 =====================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

log(){ echo -e "${CYAN}[INFO] $1${NC}"; }
ok(){ echo -e "${GREEN}[OK] $1${NC}"; }
warn(){ echo -e "${YELLOW}[WARN] $1${NC}"; }
err(){ echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

[[ $EUID -ne 0 ]] && err "请使用 root 用户运行"

CONFIG="/etc/sing-box/config.json"
USERS_FILE="/etc/sing-box/users.json"
KEYRING="/etc/apt/keyrings/sagernet.asc"
SOURCE_FILE="/etc/apt/sources.list.d/sagernet.sources"
ACME_HOME="/root/.acme.sh"

# ===================== 选择版本 =====================
echo "选择 sing-box 版本："
echo "1) 稳定版"
echo "2) 测试版"
read -rp "输入 1 或 2 (默认1): " VERSION
VERSION=${VERSION:-1}
COMPONENT="stable"
[[ "$VERSION" == "2" ]] && COMPONENT="dev"
log "使用 $COMPONENT 版本"

# ===================== 安装 sing-box =====================
mkdir -p /etc/apt/keyrings
curl -fsSL https://sing-box.app/gpg.key -o $KEYRING
chmod a+r $KEYRING

cat > $SOURCE_FILE <<EOF
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: $COMPONENT
Signed-By: $KEYRING
EOF

apt update -qq
apt install -y sing-box curl openssl iproute2 jq qrencode
ok "sing-box 安装完成"

# ===================== TCP / BBR 优化 =====================
echo "net.core.default_qdisc=fq" >> /etc/sysctl.d/99-bbr.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-bbr.conf
sysctl --system
ok "BBR + TCP 优化已开启"

# ===================== IP 检测 =====================
IPV4=$(curl -4 -s ifconfig.me || true)
IPV6=$(curl -6 -s ifconfig.me || true)

if [[ -n "$IPV6" ]]; then
    STRATEGY="ipv4_and_ipv6"
    LISTEN="::"
    SERVER_IP="$IPV6"
else
    STRATEGY="ipv4_only"
    LISTEN="0.0.0.0"
    SERVER_IP="$IPV4"
fi
ok "服务器 IP: $SERVER_IP"

# ===================== 端口检测 =====================
for p in 443 8443; do
    if ss -lnt | grep -q ":$p"; then
        err "端口 $p 已被占用"
    fi
done

# ===================== 防火墙开放 =====================
if command -v ufw >/dev/null 2>&1; then
    ufw allow 443
    ufw allow 8443
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=443/tcp
    firewall-cmd --permanent --add-port=8443/tcp
    firewall-cmd --reload
else
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT || true
    iptables -I INPUT -p tcp --dport 8443 -j ACCEPT || true
fi

# ===================== VLESS Reality 参数 =====================
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 4)
PRIVATE_KEY=$(sing-box generate private-key)
PUBLIC_KEY=$(echo "$PRIVATE_KEY" | sing-box generate public-key)

# ===================== Hysteria2 参数 =====================
HY_PASS=$(cat /proc/sys/kernel/random/uuid)
HY_OBFS=$(shuf -n1 -e salamander none)

# ===================== 伪装域名测速 =====================
DOMAINS=("www.apple.com" "www.cloudflare.com" "www.microsoft.com" "www.amazon.com")
declare -A PINGS

log "测速伪装域名..."
for d in "${DOMAINS[@]}"; do
    t=$(ping -c1 -W1 $d 2>/dev/null | grep time= | awk -F'time=' '{print $2}' | awk '{print $1}')
    PINGS[$d]=${t:-9999}
done

SORTED=$(for d in "${!PINGS[@]}"; do echo "${PINGS[$d]} $d"; done | sort -n)
echo "$SORTED"
read -rp "选择域名(默认第一项): " FAKE_DOMAIN
FAKE_DOMAIN=${FAKE_DOMAIN:-$(echo "$SORTED" | head -n1 | awk '{print $2}')}

# ===================== Hysteria2 证书 =====================
read -rp "输入 Hysteria2 真实域名: " HY_DOMAIN
read -rp "证书邮箱(默认 admin@$HY_DOMAIN): " EMAIL
EMAIL=${EMAIL:-admin@$HY_DOMAIN}

if [ ! -d "$ACME_HOME" ]; then
    curl https://get.acme.sh | sh
fi
export PATH="$ACME_HOME:$PATH"
acme.sh --set-default-ca --server letsencrypt
acme.sh --issue -d "$HY_DOMAIN" --standalone -m "$EMAIL"

CERT_DIR="/etc/ssl/$HY_DOMAIN"
mkdir -p $CERT_DIR
acme.sh --install-cert -d $HY_DOMAIN \
--key-file $CERT_DIR/$HY_DOMAIN.key \
--fullchain-file $CERT_DIR/$HY_DOMAIN.crt \
--reloadcmd "systemctl restart sing-box"

# ===================== 生成 config.json =====================
mkdir -p /etc/sing-box
cat > $CONFIG <<EOF
{
  "dns": {
    "servers": [{"tag":"cf","address":"1.1.1.1"}],
    "final":"cf",
    "strategy":"$STRATEGY"
  },
  "inbounds":[
    {
      "type":"vless",
      "tag":"vless-reality",
      "listen":"$LISTEN",
      "listen_port":443,
      "users":[{"uuid":"$UUID","flow":"xtls-rprx-vision"}],
      "tls":{
        "enabled":true,
        "server_name":"$FAKE_DOMAIN",
        "reality":{
          "enabled":true,
          "private_key":"$PRIVATE_KEY",
          "short_id":["$SHORT_ID"]
        }
      }
    },
    {
      "type":"hysteria2",
      "tag":"hy2",
      "listen":"$LISTEN",
      "listen_port":8443,
      "users":[{"password":"$HY_PASS"}],
      "obfs":{"type":"$HY_OBFS","password":"$HY_PASS"},
      "tls":{
        "enabled":true,
        "certificate_path":"$CERT_DIR/$HY_DOMAIN.crt",
        "key_path":"$CERT_DIR/$HY_DOMAIN.key"
      }
    }
  ],
  "outbounds":[{"type":"direct","tag":"direct"}],
  "route":{
    "rules":[
      {"action":"sniff","sniffer":["http","tls","quic","dns"]},
      {"protocol":"dns","action":"hijack-dns"}
    ],
    "final":"direct",
    "auto_detect_interface":true
  },
  "experimental":{"cache_file":{"enabled":true,"path":"/etc/sing-box/cache.db"}},
  "log":{"level":"info"}
}
EOF
ok "config.json 已生成"

# ===================== 启动服务 =====================
systemctl enable sing-box
systemctl restart sing-box
ok "sing-box 已启动"

# ===================== 生成订阅链接 =====================
CLASH_SUB="http://$SERVER_IP:443/subscription/clash.yaml"
SURGE_SUB="http://$SERVER_IP:443/subscription/surge.conf"
SHADOWROCKET_SUB="http://$SERVER_IP:443/subscription/sr.rocket"

echo ""
echo "=========== 完成 ==========="
echo "服务器 IP: $SERVER_IP"
echo ""
echo "VLESS:"
echo "UUID: $UUID"
echo "PublicKey: $PUBLIC_KEY"
echo "ShortID: $SHORT_ID"
echo "伪装域名: $FAKE_DOMAIN"
echo ""
echo "Hysteria2:"
echo "密码: $HY_PASS"
echo "混淆: $HY_OBFS"
echo "证书域名: $HY_DOMAIN"
echo ""
echo "订阅链接:"
echo "Clash: $CLASH_SUB"
echo "Surge: $SURGE_SUB"
echo "Shadowrocket: $SHADOWROCKET_SUB"
echo ""
echo "二维码生成示例:"
echo "qrencode -o vless.png 'vless://$UUID@$SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$FAKE_DOMAIN&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp'"
echo ""
echo "qrencode -o hysteria2.png 'hysteria2://$HY_PASS@$SERVER_IP:8443/?sni=$HY_DOMAIN&obfs=$HY_OBFS'"
echo "================================="
