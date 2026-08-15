#!/bin/bash
#
# ==============================================================================
#  HY2 证书申请 + 自动续期 (Debian/Ubuntu sing-box DNS-01 Cloudflare版)
#  DNS-01验证｜密钥明文输入方便校验｜修复ufw交互阻塞｜无需人工交互
# ==============================================================================
set -eEuo pipefail
trap 'echo -e "\033[31m❌ 脚本在 [\033[1m${BASH_SOURCE}:${LINENO}\033[0m\033[31m] 行发生错误\033[0m" >&2; exit 1' ERR

# --- ANSI 颜色 ---
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BOLD='\033[1m'; RESET='\033[0m'

# --- 全局变量 ---
DOMAIN=""
EMAIL=""
CF_EMAIL=""
CF_GLOBAL_KEY=""
CA_SERVER="letsencrypt.org"
OS_TYPE=""
PKG_MANAGER=""
ACME_INSTALL_PATH="/root/.acme.sh"
CERT_KEY_DIR=""
ACME_CMD=""
LOG_FILE="/root/acme_renew.log"

# =====================
# --- 核心函数 ---
# =====================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}❌ 请使用 root 权限运行此脚本。${RESET}" >&2; exit 1
    fi
    echo -e "${GREEN}✅ Root 权限检查通过。${RESET}"
}

get_user_input() {
    read -r -p "请输入域名(例如 vip.23456.xyz): " DOMAIN
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        echo -e "${RED}❌ 域名格式不正确！${RESET}" >&2; exit 1
    fi

    read -r -p "请输入证书通知邮箱: " EMAIL
    if ! [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}❌ 邮箱格式不正确！${RESET}" >&2; exit 1
    fi

    read -r -p "请输入 Cloudflare 登录邮箱: " CF_EMAIL
    read -r -p "请输入 Cloudflare 全局API密钥: " CF_GLOBAL_KEY

    echo -e "${GREEN}✅ 用户信息收集完成。${RESET}"
}

detect_os() {
    if grep -qi "ubuntu" /etc/os-release; then OS_TYPE="ubuntu"; PKG_MANAGER="apt"
    elif grep -qi "debian" /etc/os-release; then OS_TYPE="debian"; PKG_MANAGER="apt"
    elif grep -qi "centos" /etc/os-release; then OS_TYPE="centos"; PKG_MANAGER="yum"
    elif grep -qi "rhel" /etc/os-release; then OS_TYPE="rhel"; PKG_MANAGER="yum"
    else echo -e "${RED}❌ 不支持的操作系统${RESET}" >&2; exit 1; fi
    echo -e "${GREEN}✅ 检测到系统: $OS_TYPE ($PKG_MANAGER)${RESET}"
}

install_dependencies() {
    local deps=("curl" "cron" "ufw" "openssl")
    echo -e "${YELLOW}➡️ 安装依赖...${RESET}"
    for pkg in "${deps[@]}"; do
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            dpkg -s "$pkg" &>/dev/null || { apt update -y >/dev/null 2>&1; apt install -y "$pkg" >/dev/null 2>&1; }
        else
            rpm -q "$pkg" &>/dev/null || yum install -y "$pkg" >/dev/null 2>&1
        fi
    done
    echo -e "${GREEN}✅ 依赖安装完成。${RESET}"
}

configure_firewall() {
    read -r -p "请输入 SSH 端口 (默认 22): " ssh_port
    ssh_port=${ssh_port:-22}
    if [[ "$OS_TYPE" == "ubuntu" || "$OS_TYPE" == "debian" ]]; then
        # 先判断ufw状态，仅未启用时执行启用，配合自动应答，彻底防止交互阻塞
        if ! ufw status | grep -q "active"; then
            echo y | ufw enable >/dev/null 2>&1 || true
        fi
        ufw allow "$ssh_port"/tcp comment 'SSH' >/dev/null 2>&1
        ufw allow 443/tcp comment 'HTTPS' >/dev/null 2>&1
        ufw allow 443/udp comment 'HY2 UDP' >/dev/null 2>&1
    else
        systemctl start firewalld >/dev/null 2>&1 || true
        firewall-cmd --zone=public --add-port="$ssh_port"/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port=443/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port=443/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
    echo -e "${GREEN}✅ 防火墙端口配置完成（仅放行SSH+443 TCP/UDP，无需80）。${RESET}"
}

download_acme() {
    if [ ! -d "$ACME_INSTALL_PATH" ]; then
        curl -fsSL https://get.acme.sh | sh -s -- home "$ACME_INSTALL_PATH"
        echo -e "${GREEN}✅ acme.sh 下载完成。${RESET}"
    else
        echo -e "${YELLOW}ℹ️ acme.sh 已安装，跳过下载。${RESET}"
    fi
}

find_acme_cmd() {
    if [ -x "$ACME_INSTALL_PATH/acme.sh" ]; then ACME_CMD="$ACME_INSTALL_PATH/acme.sh"
    else ACME_CMD=$(command -v acme.sh); fi
    if [ -z "$ACME_CMD" ] || [ ! -x "$ACME_CMD" ]; then
        echo -e "${RED}❌ 找不到 acme.sh${RESET}" >&2; exit 1
    fi
    echo -e "${GREEN}✅ 找到 acme.sh: $ACME_CMD${RESET}"
}

update_acme() {
    "$ACME_CMD" --upgrade >/dev/null 2>&1 || true
    "$ACME_CMD" --register-account -m "$EMAIL" >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ acme.sh 更新&账号注册完成。${RESET}"
}

issue_cert() {
    CERT_KEY_DIR="/etc/ssl/$DOMAIN"
    mkdir -p "$CERT_KEY_DIR" >/dev/null 2>&1 || true
    echo -e "${YELLOW}➡️ DNS-01 申请ECC证书: $DOMAIN${RESET}"
    echo -e "${YELLOW}ℹ️ 正在添加DNS TXT记录，等待DNS传播，请耐心等待...${RESET}"

    export CF_Email="$CF_EMAIL"
    export CF_Key="$CF_GLOBAL_KEY"

    "$ACME_CMD" --issue \
        -d "$DOMAIN" \
        --dns dns_cf \
        --server "$CA_SERVER" \
        --keylength ec-256
    echo -e "${GREEN}✅ 证书申请完成！${RESET}"
}

install_cert() {
    echo -e "${YELLOW}➡️ 安装证书到 $CERT_KEY_DIR${RESET}"
    "$ACME_CMD" --installcert -d "$DOMAIN" \
        --key-file       "${CERT_KEY_DIR}/${DOMAIN}.key" \
        --fullchain-file "${CERT_KEY_DIR}/${DOMAIN}.crt" \
        --reloadcmd "systemctl restart sing-box" >/dev/null 2>&1
    chmod 600 "${CERT_KEY_DIR}/${DOMAIN}.key"
    chown root:root "${CERT_KEY_DIR}/${DOMAIN}.key"
    echo -e "${GREEN}✅ 证书安装完成。${RESET}"
}

# =====================
# 设置 Cron 自动续期
# =====================
setup_cron() {
    echo -e "${YELLOW}➡️ 配置每日自动续期任务${RESET}"
    crontab -l -u root 2>/dev/null | grep -v "$ACME_CMD" | crontab -u root - 2>/dev/null || true

    local cron_job="0 0 * * * export CF_Email=\"${CF_EMAIL}\";export CF_Key=\"${CF_GLOBAL_KEY}\";$ACME_CMD --cron --home $ACME_INSTALL_PATH >> $LOG_FILE 2>&1"
    (crontab -l -u root 2>/dev/null; echo "$cron_job") | crontab -u root -
    echo -e "${GREEN}✅ Cron 配置完成，日志: $LOG_FILE${RESET}"
}

# =====================
# --- 主体流程 ---
# =====================
check_root
get_user_input
detect_os
install_dependencies
configure_firewall
download_acme
find_acme_cmd
update_acme
issue_cert
install_cert
setup_cron

echo "==============================================="
echo -e "${GREEN}✅ 脚本执行完毕${RESET}"
echo -e "${GREEN}证书文件: ${CERT_KEY_DIR}/${DOMAIN}.crt${RESET}"
echo -e "${GREEN}私钥文件: ${CERT_KEY_DIR}/${DOMAIN}.key${RESET}"
echo -e "${GREEN}自动续期任务已配置（无需80端口，续期成功自动重启sing-box）${RESET}"
echo ""
echo -e "${BOLD}👉 查询证书到期时间命令：${RESET}"
echo -e "${YELLOW}openssl x509 -in ${CERT_KEY_DIR}/${DOMAIN}.crt -noout -dates${RESET}"
echo ""
echo -e "${BOLD}👉 强制重新签发证书命令（证书异常时使用）：${RESET}"
echo -e "${YELLOW}export CF_Email=\"${CF_EMAIL}\";export CF_Key=\"${CF_GLOBAL_KEY}\";acme.sh --issue -d ${DOMAIN} --dns dns_cf --keylength ec-256 --force${RESET}"
echo "==============================================="
exit 0
