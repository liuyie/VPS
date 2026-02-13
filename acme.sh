#!/bin/bash
#
# ==============================================================================
#  证书一键申请 http模式 (增强覆盖检测版)
# ==============================================================================

set -eEuo pipefail
trap 'echo -e "\033[31m❌ 脚本在 [\033[1m${BASH_SOURCE}:${LINENO}\033[0m\033[31m] 行发生错误\033[0m" >&2; exit 1' ERR

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BOLD='\033[1m'
RESET='\033[0m'

DOMAIN=""
EMAIL=""
CA_SERVER="letsencrypt"
OS_TYPE=""
PKG_MANAGER=""
ACME_INSTALL_PATH="/root/.acme.sh"
CERT_KEY_DIR=""
ACME_CMD=""

# -------------------- Root检查 --------------------
check_root() {
    [ "$EUID" -ne 0 ] && { echo -e "${RED}❌ 请使用 root 运行${RESET}"; exit 1; }
    echo -e "${GREEN}✅ Root 权限检查通过${RESET}"
}

# -------------------- 用户输入 --------------------
get_user_input() {
    read -r -p "请输入域名: " DOMAIN
    read -r -p "请输入电子邮件地址: " EMAIL
    echo -e "${GREEN}✅ 信息收集完成${RESET}"
}

# -------------------- 系统检测 --------------------
detect_os() {
    if grep -qi "ubuntu" /etc/os-release; then
        OS_TYPE="ubuntu"; PKG_MANAGER="apt"
    elif grep -qi "debian" /etc/os-release; then
        OS_TYPE="debian"; PKG_MANAGER="apt"
    elif grep -qi "centos" /etc/os-release; then
        OS_TYPE="centos"; PKG_MANAGER="yum"
    else
        echo -e "${RED}❌ 不支持的系统${RESET}"; exit 1
    fi
}

# -------------------- 依赖安装 --------------------
install_dependencies() {
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        apt update -y
        apt install -y curl socat cron ufw
    else
        yum install -y curl socat cronie firewalld
    fi
}

# -------------------- 下载acme --------------------
download_acme() {
    [ ! -d "$ACME_INSTALL_PATH" ] && curl https://get.acme.sh | sh -s -- home "$ACME_INSTALL_PATH"
}

find_acme_cmd() {
    ACME_CMD="$ACME_INSTALL_PATH/acme.sh"
    [ ! -x "$ACME_CMD" ] && { echo "❌ acme.sh 未找到"; exit 1; }
}

update_acme() {
    "$ACME_CMD" --upgrade >/dev/null 2>&1 || true
}

# -------------------- 申请证书 --------------------
issue_cert() {

    CERT_KEY_DIR="/etc/ssl/$DOMAIN"

    # ====== 检测是否已存在证书 ======
    if [ -f "$CERT_KEY_DIR/$DOMAIN.crt" ] || [ -f "$CERT_KEY_DIR/$DOMAIN.key" ]; then
        echo -e "${YELLOW}⚠️ 检测到已存在证书文件${RESET}"
        read -rp "是否覆盖重建证书？(y/N): " OVERWRITE
        OVERWRITE=${OVERWRITE:-N}

        if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}❌ 已取消覆盖，脚本结束${RESET}"
            exit 0
        fi

        echo -e "${YELLOW}♻️ 正在撤销并清理旧证书...${RESET}"
        "$ACME_CMD" --revoke -d "$DOMAIN" --server "$CA_SERVER" >/dev/null 2>&1 || true
        "$ACME_CMD" --remove -d "$DOMAIN" --server "$CA_SERVER" >/dev/null 2>&1 || true
        rm -rf "$CERT_KEY_DIR"
    fi

    echo -e "${YELLOW}🔍 开始申请证书...${RESET}"

    if ! "$ACME_CMD" --issue --standalone -d "$DOMAIN" --server "$CA_SERVER" --force \
        --pre-hook "systemctl stop nginx 2>/dev/null || systemctl stop apache2 2>/dev/null || true" \
        --post-hook "systemctl start nginx 2>/dev/null || systemctl start apache2 2>/dev/null || true"; then

        echo -e "${RED}❌ 证书申请失败，正在清理...${RESET}"
        "$ACME_CMD" --revoke -d "$DOMAIN" --server "$CA_SERVER" >/dev/null 2>&1 || true
        "$ACME_CMD" --remove -d "$DOMAIN" --server "$CA_SERVER" >/dev/null 2>&1 || true
        exit 1
    fi

    echo -e "${GREEN}✅ 证书申请成功${RESET}"
}

# -------------------- 安装证书 --------------------
install_cert() {

    mkdir -p "$CERT_KEY_DIR"

    echo -e "${YELLOW}📦 安装证书到 $CERT_KEY_DIR${RESET}"

    "$ACME_CMD" --installcert -d "$DOMAIN" \
        --key-file       "${CERT_KEY_DIR}/${DOMAIN}.key" \
        --fullchain-file "${CERT_KEY_DIR}/${DOMAIN}.crt" \
        --reloadcmd "systemctl reload nginx 2>/dev/null || systemctl reload apache2 2>/dev/null || true"

    chmod 600 "${CERT_KEY_DIR}/${DOMAIN}.key"
    chown root:root "${CERT_KEY_DIR}/${DOMAIN}.key"

    echo -e "${GREEN}✅ 证书安装完成${RESET}"

    "$ACME_CMD" --install-cronjob >/dev/null 2>&1 || \
        echo -e "${YELLOW}⚠️ 自动续期安装失败，请手动检查${RESET}"
}

# -------------------- 主流程 --------------------
check_root
get_user_input
detect_os
install_dependencies
download_acme
find_acme_cmd
update_acme
issue_cert
install_cert

echo "======================================"
echo -e "${GREEN}🎉 全部完成${RESET}"
echo -e "证书路径: ${BOLD}${CERT_KEY_DIR}/${DOMAIN}.crt${RESET}"
echo -e "私钥路径: ${BOLD}${CERT_KEY_DIR}/${DOMAIN}.key${RESET}"
echo "======================================"

exit 0
