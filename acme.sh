#!/bin/bash
# ==============================================================================
#  证书一键申请 http模式 (Debian/Ubuntu 专用版)
#  基于acme.sh实现，支持自动续期、防火墙自动配置
# ==============================================================================

# --- 脚本基础配置 ---
set -eEuo pipefail
# 错误捕获：输出错误行号和提示
trap 'echo -e "\033[31m❌ 脚本在 [\033[1m${BASH_SOURCE}:${LINENO}\033[0m\033[31m] 行发生错误\033[0m" >&2; exit 1' ERR

# --- 颜色定义（增强可读性）---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BOLD='\033[1m'
RESET='\033[0m'

# --- 全局变量（固定root路径，避免冲突）---
DOMAIN=""
EMAIL=""
CA_SERVER="letsencrypt"
OS_TYPE=""
PKG_MANAGER=""
# 固定为root的acme.sh安装目录，避免$HOME变量问题
ACME_INSTALL_PATH="/root/.acme.sh"
CERT_KEY_DIR=""
ACME_CMD=""

# --- 函数定义（模块化+容错+日志可见）---

# 1. 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}❌ 错误：请使用 root 权限运行此脚本。${RESET}" >&2
        exit 1
    fi
    echo -e "${GREEN}✅ Root 权限检查通过。${RESET}"
}

# 2. 获取并校验用户输入
get_user_input() {
    # 域名输入校验
    read -r -p "请输入域名 (如: example.com): " DOMAIN
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        echo -e "${RED}❌ 错误：域名格式不正确！仅支持字母、数字、-、.${RESET}" >&2
        exit 1
    fi

    # 邮箱输入校验
    read -r -p "请输入电子邮件地址 (用于证书到期提醒): " EMAIL
    if ! [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo -e "${RED}❌ 错误：电子邮件格式不正确！${RESET}" >&2
        exit 1
    fi

    echo -e "${GREEN}✅ 用户信息收集完成 (CA服务器: Let's Encrypt)。${RESET}"
}

# 3. 检测操作系统
detect_os() {
    if grep -qi "ubuntu" /etc/os-release; then
        OS_TYPE="ubuntu"
        PKG_MANAGER="apt"
    elif grep -qi "debian" /etc/os-release; then
        OS_TYPE="debian"
        PKG_MANAGER="apt"
    else
        echo -e "${RED}❌ 错误：仅支持 Debian/Ubuntu 系统！${RESET}" >&2
        exit 1
    fi
    echo -e "${GREEN}✅ 检测到操作系统: $OS_TYPE ($PKG_MANAGER)。${RESET}"
}

# 4. 安装依赖（仅保留Debian/Ubuntu，简化逻辑）
install_dependencies() {
    local dependencies=("curl" "socat" "cron" "ufw" "dos2unix")
    
    echo -e "${YELLOW}📦 开始安装依赖包...${RESET}"
    # 先更新源（避免依赖安装失败）
    $PKG_MANAGER update -y >/dev/null 2>&1
    
    for pkg in "${dependencies[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            echo -e "${YELLOW}安装依赖: $pkg...${RESET}"
            $PKG_MANAGER install -y "$pkg" >/dev/null 2>&1 || {
                echo -e "${RED}❌ 错误：安装 $pkg 失败，请检查网络！${RESET}" >&2
                exit 1
            }
        fi
    done
    echo -e "${GREEN}✅ 依赖安装完成。${RESET}"
}

# 5. 配置防火墙（修复规则检查逻辑）
configure_firewall() {
    local ssh_port=""
    # 提示输入SSH端口，默认22
    read -r -p "请输入需要开放的 SSH 端口 (默认 22): " ssh_port
    ssh_port=${ssh_port:-22}

    # 仅处理UFW（Debian/Ubuntu）
    echo -e "${YELLOW}🔐 配置防火墙规则...${RESET}"
    # 启用UFW（若未启用）
    if ufw status | grep -q "inactive"; then
        echo "y" | ufw enable >/dev/null 2>&1 || {
            echo -e "${RED}❌ 错误：UFW 启用失败！${RESET}" >&2
            exit 1
        }
    fi

    # 修复规则检查：精准匹配端口
    check_ufw_rule() {
        ufw status numbered | grep -E "ALLOW +IN +.*$1/tcp" &>/dev/null
    }

    # 开放SSH端口
    if ! check_ufw_rule "$ssh_port"; then
        ufw allow "$ssh_port"/tcp comment 'Allow SSH' >/dev/null || {
            echo -e "${YELLOW}⚠️  警告: 无法添加 UFW $ssh_port/tcp 规则，请手动检查！${RESET}" >&2
        }
    fi

    # 开放80/443端口（证书验证必需）
    if ! check_ufw_rule "80"; then
        ufw allow 80/tcp comment 'Allow HTTP (ACME验证)' >/dev/null || {
            echo -e "${YELLOW}⚠️  警告: 无法添加 UFW 80/tcp 规则，请手动检查！${RESET}" >&2
        }
    fi
    if ! check_ufw_rule "443"; then
        ufw allow 443/tcp comment 'Allow HTTPS' >/dev/null || {
            echo -e "${YELLOW}⚠️  警告: 无法添加 UFW 443/tcp 规则，请手动检查！${RESET}" >&2
        }
    fi

    echo -e "${GREEN}✅ UFW 已配置开放 $ssh_port (SSH)、80 (HTTP)、443 (HTTPS) 端口。${RESET}"
}

# 6. 安装/检查acme.sh（固定路径+容错）
install_acme() {
    # 检查是否已安装
    if [ ! -d "$ACME_INSTALL_PATH" ]; then
        echo -e "${YELLOW}📥 开始安装 acme.sh...${RESET}"
        # 手动安装到固定路径，保留日志
        curl -fsSL https://get.acme.sh | sh -s -- home "$ACME_INSTALL_PATH" || {
            echo -e "${RED}❌ 错误：acme.sh 安装失败，请检查网络！${RESET}" >&2
            exit 1
        }
    else
        echo -e "${YELLOW}ℹ️  acme.sh 已安装，跳过安装步骤。${RESET}"
    fi

    # 创建软链接到系统PATH，全局可用（核心修复路径问题）
    if [ ! -L "/usr/local/bin/acme.sh" ]; then
        ln -s "$ACME_INSTALL_PATH/acme.sh" /usr/local/bin/acme.sh
    fi

    # 验证acme.sh是否可执行
    ACME_CMD=$(command -v acme.sh)
    if [ -z "$ACME_CMD" ] || [ ! -x "$ACME_CMD" ]; then
        echo -e "${RED}❌ 错误：找不到可执行的 acme.sh！路径: $ACME_INSTALL_PATH${RESET}" >&2
        exit 1
    fi
    echo -e "${GREEN}✅ acme.sh 路径验证通过: $ACME_CMD${RESET}"
}

# 7. 更新acme.sh
update_acme() {
    echo -e "${YELLOW}🔄 检查并更新 acme.sh...${RESET}"
    $ACME_CMD --upgrade >/dev/null 2>&1 || {
        echo -e "${YELLOW}⚠️  警告：acme.sh 更新失败，将使用当前版本！${RESET}" >&2
    }
    # 更新账户信息
    $ACME_CMD --update-account --days 60 >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ acme.sh 更新完成。${RESET}"
}

# 8. 申请证书（保留关键日志，便于排错）
issue_cert() {
    echo -e "${YELLOW}🔍 开始申请 $DOMAIN 证书（80端口需空闲）...${RESET}"
    # 停止占用80端口的服务（nginx/apache）
    local stop_web="systemctl stop nginx 2>/dev/null || systemctl stop apache2 2>/dev/null || true"
    local start_web="systemctl start nginx 2>/dev/null || systemctl start apache2 2>/dev/null || true"
    
    # 执行证书申请（不屏蔽日志，便于排错）
    if ! $ACME_CMD --issue --standalone -d "$DOMAIN" --server "$CA_SERVER" \
        --email "$EMAIL" --force \
        --pre-hook "$stop_web" --post-hook "$start_web"; then
        echo -e "${RED}❌ 错误：证书申请失败！${RESET}" >&2
        # 清理失败的证书
        $ACME_CMD --revoke -d "$DOMAIN" --server "$CA_SERVER" >/dev/null 2>&1 || true
        $ACME_CMD --remove -d "$DOMAIN" --server "$CA_SERVER" >/dev/null 2>&1 || true
        exit 1
    fi
    echo -e "${GREEN}✅ $DOMAIN 证书申请成功！${RESET}"
}

# 9. 安装证书（固定路径+权限加固）
install_cert() {
    CERT_KEY_DIR="/etc/ssl/$DOMAIN"
    # 创建证书目录（权限700，仅root可访问）
    mkdir -p "$CERT_KEY_DIR"
    chmod 700 "$CERT_KEY_DIR"

    echo -e "${YELLOW}📦 安装证书到 $CERT_KEY_DIR...${RESET}"
    if ! $ACME_CMD --installcert -d "$DOMAIN" \
        --key-file       "${CERT_KEY_DIR}/${DOMAIN}.key" \
        --fullchain-file "${CERT_KEY_DIR}/${DOMAIN}.crt" \
        --reloadcmd "systemctl reload nginx 2>/dev/null || systemctl reload apache2 2>/dev/null || true"; then
        echo -e "${RED}❌ 错误：证书安装失败！${RESET}" >&2
        exit 1
    fi

    # 加固私钥权限（600，仅root可读）
    chmod 600 "${CERT_KEY_DIR}/${DOMAIN}.key"
    chown root:root "${CERT_KEY_DIR}/${DOMAIN}.key"
    echo -e "${GREEN}✅ 证书安装完成，私钥权限已加固。${RESET}"
}

# 10. 配置自动续期（移除冗余sudo）
configure_auto_renew() {
    echo -e "${YELLOW}⏰ 配置证书自动续期...${RESET}"
    # acme.sh内置的cron任务，root运行无需sudo
    $ACME_CMD --install-cronjob >/dev/null 2>&1 || {
        echo -e "${YELLOW}⚠️  警告：自动续期任务配置失败！${RESET}" >&2
        echo -e "${YELLOW}请手动执行：${BOLD}$ACME_CMD --install-cronjob${RESET}" >&2
    }
    # 验证cron任务
    if crontab -l | grep -q "acme.sh"; then
        echo -e "${GREEN}✅ 自动续期任务已配置（每日检查，到期自动续期）。${RESET}"
    else
        echo -e "${YELLOW}⚠️  警告：未检测到acme.sh cron任务，请手动配置！${RESET}" >&2
    fi
}

# --- 主执行流程 ---
clear
echo -e "${BOLD}==============================================="
echo -e "      SSL证书一键申请脚本 (Debian/Ubuntu)      "
echo -e "===============================================${RESET}"

check_root
get_user_input
detect_os
install_dependencies
configure_firewall
install_acme
update_acme
issue_cert
install_cert
configure_auto_renew

# --- 执行完成提示 ---
echo -e "\n${BOLD}==============================================="
echo -e "${GREEN}✅ 所有操作执行完成！${RESET}"
echo -e "==============================================="
echo -e "${GREEN}证书文件路径：${BOLD}${CERT_KEY_DIR}/${DOMAIN}.crt${RESET}"
echo -e "${GREEN}私钥文件路径：${BOLD}${CERT_KEY_DIR}/${DOMAIN}.key${RESET}"
echo -e "${YELLOW}提示1：证书有效期90天，已配置自动续期${RESET}"
echo -e "${YELLOW}提示2：可执行 'crontab -l' 检查自动续期任务${RESET}"
echo -e "${YELLOW}提示3：80端口需保持开放，否则续期会失败${RESET}"
echo -e "===============================================${RESET}"

exit 0
