#!/bin/bash
#
# ==============================================================================
#  HY2 证书申请 + 自动续期 + 每日自检 (Debian/Ubuntu 代理专用版)
# ==============================================================================
set -eEuo pipefail
trap 'echo -e "\033[31m❌ 脚本在 [\033[1m${BASH_SOURCE}:${LINENO}\033[0m\033[31m] 行发生错误\033[0m" >&2; exit 1' ERR

# --- ANSI 颜色 ---
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BOLD='\033[1m'; RESET='\033[0m'

# --- 全局变量 ---
DOMAIN=""
EMAIL=""
CA_SERVER="letsencrypt"
OS_TYPE=""
PKG_MANAGER=""
ACME_INSTALL_PATH="/root/.acme.sh"
CERT_KEY_DIR=""
ACME_CMD=""
WEBROOT_PATH="/var/www/html"
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
    read -r -p "请输入域名: " DOMAIN
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        echo -e "${RED}❌ 域名格式不正确！${RESET}" >&2; exit 1
    fi
    read -r -p "请输入邮箱: " EMAIL
    if ! [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}❌ 邮箱格式不正确！${RESET}" >&2; exit 1
    fi
    read -r -p "请输入 Webroot 目录 (默认 /var/www/html): " WR
    WEBROOT_PATH=${WR:-/var/www/html}
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
    local deps=("curl" "socat" "cron" "ufw")
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
        ufw enable >/dev/null 2>&1 || true
        ufw allow "$ssh_port"/tcp comment 'SSH' >/dev/null 2>&1
        ufw allow 80/tcp comment 'HTTP' >/dev/null 2>&1
        ufw allow 443/tcp comment 'HTTPS' >/dev/null 2>&1
    else
        systemctl start firewalld >/dev/null 2>&1 || true
        firewall-cmd --zone=public --add-port="$ssh_port"/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port=80/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port=443/tcp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
    echo -e "${GREEN}✅ 防火墙端口配置完成。${RESET}"
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
    "$ACME_CMD" --update-account --days 60 >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ acme.sh 更新完成。${RESET}"
}

issue_cert() {
    CERT_KEY_DIR="/etc/ssl/$DOMAIN"
    mkdir -p "$CERT_KEY_DIR" >/dev/null 2>&1 || true
    echo -e "${YELLOW}➡️ 申请证书: $DOMAIN${RESET}"
    "$ACME_CMD" --issue -d "$DOMAIN" --webroot "$WEBROOT_PATH" --server "$CA_SERVER" --force
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

# --------------------------
# HY2证书自检功能
# --------------------------
check_cert_expiry() {
    CERT_FILE="${CERT_KEY_DIR}/${DOMAIN}.crt"
    if [ ! -f "$CERT_FILE" ]; then
        echo -e "${RED}❌ 警告：证书不存在 $CERT_FILE${RESET}" | tee -a "$LOG_FILE"
        return
    fi
    DAYS_LEFT=$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2 | xargs -I{} date -d "{}" +%s)
    NOW=$(date +%s)
    REMAIN_DAYS=$(( (DAYS_LEFT - NOW) / 86400 ))
    echo -e "$(date '+%F %T') ℹ️ 证书剩余有效期: $REMAIN_DAYS 天" | tee -a "$LOG_FILE"
    if [ "$REMAIN_DAYS" -lt 30 ]; then
        echo -e "$(date '+%F %T') ⚠️ 证书快到期，触发自动续期..." | tee -a "$LOG_FILE"
        "$ACME_CMD" --renew -d "$DOMAIN" --webroot "$WEBROOT_PATH" --force >> "$LOG_FILE" 2>&1
        "$ACME_CMD" --installcert -d "$DOMAIN" \
            --key-file       "${CERT_KEY_DIR}/${DOMAIN}.key" \
            --fullchain-file "${CERT_KEY_DIR}/${DOMAIN}.crt" \
            --reloadcmd "systemctl restart sing-box" >> "$LOG_FILE" 2>&1
        echo -e "$(date '+%F %T') ✅ 自动续期完成并重启 Sing-box" | tee -a "$LOG_FILE"
    fi
}

# =====================
# 设置 Cron 任务
# =====================
setup_cron() {
    echo -e "${YELLOW}➡️ 配置自动续期 + 自检任务${RESET}"
    # 清理重复 cron
    crontab -l -u root 2>/dev/null | grep -v "$ACME_CMD" | crontab -u root - 2>/dev/null || true
    # cron: 每天 00:00 执行续期 + 自检
    (crontab -l -u root 2>/dev/null; \
    echo "0 0 * * * $ACME_CMD --cron --home $ACME_INSTALL_PATH >> $LOG_FILE 2>&1; /bin/bash -c 'source $ACME_INSTALL_PATH/acme.sh.env; check_cert_expiry' >> $LOG_FILE 2>&1") | crontab -u root -
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
echo -e "${GREEN}自动续期 + 自检任务已配置，日志: $LOG_FILE${RESET}"
echo "==============================================="
exit 0
