#!/bin/bash
#
# ==============================================================================
#  证书一键申请 http模式 (Debian/Ubuntu 代理专用版)
#  支持已存在证书覆盖重建
# ==============================================================================

# --- 脚本设置与错误处理 ---
set -eEuo pipefail
trap 'echo -e "\033[31m❌ 脚本在 [\033[1m${BASH_SOURCE}:${LINENO}\033[0m\033[31m] 行发生错误\033[0m" >&2; exit 1' ERR

# --- ANSI 颜色代码 ---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BOLD='\033[1m'
RESET='\033[0m'

# --- 全局变量 ---
DOMAIN=""
EMAIL=""
CA_SERVER="letsencrypt"
OS_TYPE=""
PKG_MANAGER=""
ACME_INSTALL_PATH="/root/.acme.sh"
CERT_KEY_DIR=""
ACME_CMD=""

# --- 函数定义 ---

# 检查 root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}❌ 错误：请使用 root 权限运行此脚本。${RESET}" >&2
        exit 1
    fi
    echo -e "${GREEN}✅ Root 权限检查通过。${RESET}"
}

# 获取用户输入
get_user_input() {
    read -r -p "请输入域名: " DOMAIN
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        echo -e "${RED}❌ 错误：域名格式不正确！${RESET}" >&2; exit 1
    fi

    read -r -p "请输入电子邮件地址: " EMAIL
    if ! [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}❌ 错误：电子邮件格式不正确！${RESET}" >&2; exit 1
    fi

    echo -e "${GREEN}✅ 用户信息收集完成 (默认使用 Let's Encrypt)。${RESET}"
}

# 检测操作系统
detect_os() {
    if grep -qi "ubuntu" /etc/os-release; then
        OS_TYPE="ubuntu"; PKG_MANAGER="apt"
    elif grep -qi "debian" /etc/os-release; then
        OS_TYPE="debian"; PKG_MANAGER="apt"
    elif grep -qi "centos" /etc/os-release; then
        OS_TYPE="centos"; PKG_MANAGER="yum"
    elif grep -qi "rhel" /etc/os-release; then
        OS_TYPE="rhel"; PKG_MANAGER="yum"
    else
        echo -e "${RED}❌ 错误：不支持的操作系统！${RESET}" >&2; exit 1
    fi
    echo -e "${GREEN}✅ 检测到操作系统: $OS_TYPE ($PKG_MANAGER)。${RESET}"
}

# 安装依赖
install_dependencies() {
    local dependencies=()
    if [[ "$OS_TYPE" == "ubuntu" || "$OS_TYPE" == "debian" ]]; then
        dependencies=("curl" "socat" "cron" "ufw")
    elif [[ "$OS_TYPE" == "centos" || "$OS_TYPE" == "rhel" ]]; then
        dependencies=("curl" "socat" "cronie" "firewalld")
    fi

    echo -e "${YELLOW}📦 开始安装依赖包...${RESET}"
    for pkg in "${dependencies[@]}"; do
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            if ! dpkg -s "$pkg" &>/dev/null; then
                apt update -y >/dev/null 2>&1
                apt install -y "$pkg" >/dev/null 2>&1 || { echo -e "${RED}❌ 安装 $pkg 失败${RESET}" >&2; exit 1; }
            fi
        else
            if ! rpm -q "$pkg" &>/dev/null; then
                yum install -y "$pkg" >/dev/null 2>&1 || { echo -e "${RED}❌ 安装 $pkg 失败${RESET}" >&2; exit 1; }
            fi
        fi
    done
    echo -e "${GREEN}✅ 依赖安装完成。${RESET}"
}

# 配置防火墙
configure_firewall() {
    read -r -p "请输入 SSH 端口（默认22）: " ssh_port
    ssh_port=${ssh_port:-22}

    if [[ "$OS_TYPE" == "ubuntu" || "$OS_TYPE" == "debian" ]]; then
        [[ $(ufw status | grep inactive) ]] && echo "y" | ufw enable >/dev/null 2>&1
        ufw allow "$ssh_port"/tcp comment 'SSH' >/dev/null 2>&1
        ufw allow 80/tcp comment 'HTTP' >/dev/null 2>&1
        ufw allow 443/tcp comment 'HTTPS' >/dev/null 2>&1
        echo -e "${GREEN}✅ UFW 已配置端口 $ssh_port, 80, 443${RESET}"
    else
        systemctl start firewalld >/dev/null 2>&1 || true
        firewall-cmd --zone=public --add-port="$ssh_port"/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port=80/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port=443/tcp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        echo -e "${GREEN}✅ Firewalld 已配置端口 $ssh_port, 80, 443${RESET}"
    fi
}

# 安装 acme.sh
download_acme() {
    if [ ! -d "$ACME_INSTALL_PATH" ]; then
        curl -fsSL https://get.acme.sh | sh -s -- home "$ACME_INSTALL_PATH" || { echo -e "${RED}❌ 下载 acme.sh 失败${RESET}" >&2; exit 1; }
    fi
}

# 查找 acme.sh
find_acme_cmd() {
    if [ -x "$ACME_INSTALL_PATH/acme.sh" ]; then
        ACME_CMD="$ACME_INSTALL_PATH/acme.sh"
    else
        export PATH="$ACME_INSTALL_PATH:$PATH"
        ACME_CMD=$(command -v acme.sh)
    fi
    [ -z "$ACME_CMD" ] && { echo -e "${RED}❌ 找不到 acme.sh${RESET}" >&2; exit 1; }
}

# 更新 acme.sh
update_acme() {
    "$ACME_CMD" --upgrade >/dev/null 2>&1 || true
    "$ACME_CMD" --update-account --days 60 >/dev/null 2>&1 || true
}

# -------------------- 申请证书 --------------------
issue_cert() {
    CERT_KEY_DIR="/etc/ssl/$DOMAIN"
    mkdir -p "$CERT_KEY_DIR" >/dev/null 2>&1

    # 检查是否已有证书
    if [ -f "$CERT_KEY_DIR/${DOMAIN}.crt" ] || [ -f "$CERT_KEY_DIR/${DOMAIN}.key" ]; then
        read -rp "⚠️  证书已存在，是否覆盖重建？(y/N): " OVERWRITE
        OVERWRITE=${OVERWRITE:-N}
        if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}❌ 用户选择不覆盖，跳过证书申请。${RESET}"
            return
        else
            echo -e "${YELLOW}♻️  强制覆盖旧证书...${RESET}"
            "$ACME_CMD" --revoke -d "$DOMAIN" --server "$CA_SERVER" >/dev/null 2>&1 || true
            "$ACME_CMD" --remove -d "$DOMAIN" --server "$CA_SERVER" >/dev/null 2>&1 || true
            rm -rf "$CERT_KEY_DIR"/*
        fi
    fi

    "$ACME_CMD" --issue --standalone -d "$DOMAIN" --server "$CA_SERVER" --force \
        --pre-hook "systemctl stop nginx 2>/dev/null || systemctl stop apache2 2>/dev/null || true" \
        --post-hook "systemctl start nginx 2>/dev/null || systemctl start apache2 2>/dev/null || true" || \
        { echo -e "${RED}❌ 证书申请失败${RESET}"; exit 1; }
    echo -e "${GREEN}✅ 证书申请成功${RESET}"
}

# -------------------- 安装证书 --------------------
install_cert() {
    mkdir -p "$CERT_KEY_DIR"
    "$ACME_CMD" --installcert -d "$DOMAIN" \
        --key-file       "${CERT_KEY_DIR}/${DOMAIN}.key" \
        --fullchain-file "${CERT_KEY_DIR}/${DOMAIN}.crt" \
        --reloadcmd "systemctl reload nginx 2>/dev/null || systemctl reload apache2 2>/dev/null || true"
    chmod 600 "${CERT_KEY_DIR}/${DOMAIN}.key"
    chown root:root "${CERT_KEY_DIR}/${DOMAIN}.key"
    echo -e "${GREEN}✅ 证书安装完成${RESET}"

    # 配置自动续期
    "$ACME_CMD" --install-cronjob >/dev/null 2>&1 || \
        echo -e "${YELLOW}⚠️ acme.sh 自动续期未成功，请手动检查${RESET}"
}

# --- 主体逻辑 ---
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

echo -e "${GREEN}✅ 脚本执行完毕，证书已安装到 ${CERT_KEY_DIR}${RESET}"
echo -e "${YELLOW}提示: 可以使用 'crontab -l' 查看自动续期任务。${RESET}"
