#!/bin/bash
set -e

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"

echo "=============================="
echo " sing-box Ultimate Auto Install"
echo "=============================="

# 1️⃣ 安装依赖
apt update -y
apt install -y curl openssl jq uuid-runtime

# 2️⃣ 安装 sing-box 稳定版
bash <(curl -fsSL https://sing-box.app/install.sh)

mkdir -p ${CONFIG_DIR}

# 3️⃣ 随机生成参数

UUID=$(uuidgen)

# 随机 short_id
SHORT_ID=$(openssl rand -hex 4)

# 生成 Reality 密钥
KEY_PAIR=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEY_PAIR" | grep PrivateKey | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | grep PublicKey | awk '{print $2}')

# 随机 Hysteria 混淆密码
HY2_OBFS_PASS=$(openssl rand -hex 8)

# 随机混淆算法
OBFS_LIST=("salamander" "none")
HY2_OBFS=${OBFS_LIST[$RANDOM % ${#OBFS_LIST[@]}]}

# 4️⃣ 自动选择伪装域名
FAKE_DOMAINS=(
"www.cloudflare.com"
"www.microsoft.com"
"www.apple.com"
"www.amazon.com"
)

echo ""
echo "可用伪装域名："
for i in "${!FAKE_DOMAINS[@]}"; do
  echo "$i) ${FAKE_DOMAINS[$i]}"
done

read -p "选择伪装域名编号 (默认0): " INDEX
INDEX=${INDEX:-0}
SERVER_NAME=${FAKE_DOMAINS[$INDEX]}

echo "使用伪装域名: $SERVER_NAME"

# 5️⃣ 自动获取证书（使用 acme.sh 示例）
if [ ! -d "/root/.acme.sh" ]; then
  curl https://get.acme.sh | sh
fi

read -p "请输入你的真实域名 (用于证书申请): " REAL_DOMAIN

~/.acme.sh/acme.sh --issue -d ${REAL_DOMAIN} --standalone
~/.acme.sh/acme.sh --install-cert -d ${REAL_DOMAIN} \
--key-file       ${CONFIG_DIR}/key.pem  \
--fullchain-file ${CONFIG_DIR}/cert.pem

# 6️⃣ 生成全新格式 config.json

cat > ${CONFIG_FILE} <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SERVER_NAME}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2",
      "listen": "::",
      "listen_port": 8443,
      "users": [
        {
          "password": "${UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CONFIG_DIR}/cert.pem",
        "key_path": "${CONFIG_DIR}/key.pem"
      },
      "obfs": {
        "type": "${HY2_OBFS}",
        "password": "${HY2_OBFS_PASS}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

# 7️⃣ systemd 服务

cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c ${CONFIG_FILE}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

IP=$(curl -s ifconfig.me)

echo ""
echo "=============================="
echo "        安装完成"
echo "=============================="
echo ""
echo "VLESS Reality 客户端参数："
echo "服务器: ${IP}"
echo "端口: 443"
echo "UUID: ${UUID}"
echo "公钥: ${PUBLIC_KEY}"
echo "short_id: ${SHORT_ID}"
echo "伪装域名: ${SERVER_NAME}"
echo ""
echo "Hysteria2 参数："
echo "服务器: ${IP}"
echo "端口: 8443"
echo "密码: ${UUID}"
echo "混淆算法: ${HY2_OBFS}"
echo "混淆密码: ${HY2_OBFS_PASS}"
echo ""
echo "sing-box 已启动 ✔"
