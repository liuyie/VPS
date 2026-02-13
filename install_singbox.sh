#!/bin/bash
set -euo pipefail

CONFIG_PATH="/etc/sing-box/config.json"

echo "==== 安装 sing-box ===="

# 安装依赖
apt update -qq
apt install -y curl jq uuid-runtime

# 添加官方源（如果不存在）
if [ ! -f /etc/apt/sources.list.d/sagernet.sources ]; then
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
  chmod a+r /etc/apt/keyrings/sagernet.asc

  cat > /etc/apt/sources.list.d/sagernet.sources <<EOF
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
fi

apt update -qq
apt install -y sing-box

echo "==== 生成参数 ===="

UUID=$(uuidgen)
HY2_PASS=$(uuidgen)
SS_PASS=$(openssl rand -base64 16)

# 生成 reality keypair
REALITY_JSON=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$REALITY_JSON" | jq -r .private_key)
PUBLIC_KEY=$(echo "$REALITY_JSON" | jq -r .public_key)

SHORT_ID=$(openssl rand -hex 4)

echo "UUID: $UUID"
echo "Reality Public Key: $PUBLIC_KEY"
echo "Short ID: $SHORT_ID"

echo "==== 写入配置 ===="

mkdir -p /etc/sing-box

cat > $CONFIG_PATH <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      { "type": "udp", "server": "1.1.1.1" },
      { "type": "udp", "server": "8.8.8.8" }
    ]
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": 8080,
      "method": "2022-blake3-aes-128-gcm",
      "password": "$SS_PASS"
    },
    {
      "type": "vless",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.apple.com",
        "reality": {
          "enabled": true,
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"],
          "handshake": {
            "server": "www.apple.com",
            "server_port": 443
          }
        }
      }
    },
    {
      "type": "hysteria2",
      "listen": "::",
      "listen_port": 8443,
      "users": [
        { "password": "$HY2_PASS" }
      ],
      "obfs": {
        "type": "salamander",
        "password": "$HY2_PASS"
      },
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/server.crt",
        "key_path": "/etc/sing-box/server.key"
      }
    }
  ],
  "outbounds": [
    { "type": "direct" }
  ]
}
EOF

echo "==== 检查配置 ===="
sing-box check -c $CONFIG_PATH

echo "==== 启动服务 ===="
systemctl enable sing-box
systemctl restart sing-box

echo "==== 安装完成 ===="
echo "VLESS UUID: $UUID"
echo "Reality Public Key: $PUBLIC_KEY"
echo "Short ID: $SHORT_ID"
echo "SS Password: $SS_PASS"
echo "Hysteria2 Password: $HY2_PASS"
