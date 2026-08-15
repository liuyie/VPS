#!/bin/bash
#
# ==============================================================================
# HY2 证书申请 + 自动续期
# Debian/Ubuntu + sing-box + acme.sh + Cloudflare DNS-01
#
# Cloudflare API Token版
# 无CF_ZONE_ID
# 自动清理旧域名缓存，解决 Domain key exists
# ==============================================================================

set -eEuo pipefail

trap 'echo -e "\033[31m❌ 错误位置: ${BASH_SOURCE}:${LINENO}\033[0m"' ERR


RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"


DOMAIN=""
EMAIL=""
CF_TOKEN=""

ACME_HOME="/root/.acme.sh"
ACME_CMD="${ACME_HOME}/acme.sh"

CERT_DIR=""


# ======================
# root检查
# ======================

check_root()
{

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用root运行${RESET}"
    exit 1
fi

echo -e "${GREEN}Root OK${RESET}"

}



# ======================
# 输入参数
# ======================

input_info()
{

read -rp "请输入域名: " DOMAIN


if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo "域名格式错误"
    exit 1
fi


read -rp "请输入通知邮箱: " EMAIL


read -rsp "请输入 Cloudflare API Token: " CF_TOKEN
echo


echo -e "${GREEN}参数输入完成${RESET}"

}



# ======================
# 安装依赖
# ======================

install_pkg()
{

apt update -y

apt install -y \
curl \
openssl \
cron \
ufw


echo -e "${GREEN}依赖安装完成${RESET}"

}



# ======================
# 防火墙
# ======================

firewall()
{

read -rp "SSH端口(默认22): " SSH_PORT

SSH_PORT=${SSH_PORT:-22}


ufw allow ${SSH_PORT}/tcp comment SSH

ufw allow 443/tcp comment HTTPS

ufw allow 443/udp comment HY2


if ! ufw status | grep -q active
then
    echo y | ufw enable
fi


ufw reload >/dev/null 2>&1 || true


echo -e "${GREEN}防火墙配置完成${RESET}"

}



# ======================
# 安装acme.sh
# ======================

install_acme()
{


if [ ! -f "$ACME_CMD" ]; then

curl https://get.acme.sh | sh -s email="$EMAIL"

fi


$ACME_CMD --upgrade


echo -e "${GREEN}acme.sh安装完成${RESET}"

}



# ======================
# Cloudflare Token配置
# ======================

config_cf()
{


touch "$ACME_HOME/account.conf"


cat >> "$ACME_HOME/account.conf" <<EOF

export CF_Token="${CF_TOKEN}"

EOF


chmod 600 "$ACME_HOME/account.conf"


echo -e "${GREEN}Cloudflare Token配置完成${RESET}"

}



# ======================
# 申请证书
# ======================

issue_cert()
{


CERT_DIR="/etc/ssl/${DOMAIN}"

mkdir -p "$CERT_DIR"


echo -e "${YELLOW}清理旧域名缓存${RESET}"


$ACME_CMD --remove -d "$DOMAIN" >/dev/null 2>&1 || true


rm -rf "${ACME_HOME}/${DOMAIN}_ecc"

rm -rf "${ACME_HOME}/${DOMAIN}"


echo -e "${YELLOW}"
echo "开始申请ECC证书:"
echo "$DOMAIN"
echo -e "${RESET}"


export CF_Token="$CF_TOKEN"


$ACME_CMD \
--issue \
-d "$DOMAIN" \
--dns dns_cf \
--server letsencrypt.org \
--keylength ec-256 \
--force


echo -e "${GREEN}证书申请成功${RESET}"

}



# ======================
# 安装证书
# ======================

install_cert()
{


$ACME_CMD \
--installcert \
-d "$DOMAIN" \
--key-file "${CERT_DIR}/${DOMAIN}.key" \
--fullchain-file "${CERT_DIR}/${DOMAIN}.crt" \
--reloadcmd "systemctl restart sing-box"



chmod 600 "${CERT_DIR}/${DOMAIN}.key"


chown root:root "${CERT_DIR}/${DOMAIN}.key"


echo -e "${GREEN}证书安装完成${RESET}"

}



# ======================
# 自动续期
# ======================

cron_setup()
{


systemctl enable cron

systemctl restart cron



(crontab -l 2>/dev/null | grep -v "acme.sh" || true

echo "0 3 * * * ${ACME_CMD} --cron --home ${ACME_HOME} >> /root/acme_renew.log 2>&1"

) | crontab -



echo -e "${GREEN}自动续期配置完成${RESET}"

}



# ======================
# 主流程
# ======================

check_root

input_info

install_pkg

firewall

install_acme

config_cf

issue_cert

install_cert

cron_setup



echo
echo "======================================"
echo -e "${GREEN}✅ 全部完成${RESET}"
echo
echo "证书:"
echo "${CERT_DIR}/${DOMAIN}.crt"
echo
echo "私钥:"
echo "${CERT_DIR}/${DOMAIN}.key"
echo
echo "检查有效期:"
echo "openssl x509 -in ${CERT_DIR}/${DOMAIN}.crt -noout -dates"
echo
echo "续期日志:"
echo "/root/acme_renew.log"
echo "======================================"
