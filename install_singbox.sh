#!/bin/bash
set -euo pipefail  # 开启严格模式：遇到错误立即退出、未定义变量报错、管道失败整体报错

# ===================== 基础配置 =====================

# 定义颜色（兼容无终端场景）
if [ -t 1 ]; then  # 判断是否为交互式终端
    CYAN='\033[0;36m'
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    CYAN=''
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

# 定义关键变量（便于维护）
GPG_KEY_URL="https://sing-box.app/gpg.key"
GPG_KEY_PATH="/etc/apt/keyrings/sagernet.asc"
SOURCES_FILE="/etc/apt/sources.list.d/sagernet.sources"
SING_BOX_USER="sing-box"

# ===================== 工具函数 =====================

# 日志输出函数
log_info() {
    echo -e "${CYAN}[INFO] $1${NC}"
}
log_success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}
log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}
log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1  # 错误退出
}

# 检查是否有 sudo 权限
check_sudo() {
    if ! sudo -v >/dev/null 2>&1; then
        log_error "当前用户无 sudo 权限，请使用 root 或有 sudo 权限的用户执行脚本"
    fi
}

# 检查网络连通性
check_network() {
    log_info "检查网络连通性..."
    if ! curl -fsSL --max-time 10 "$GPG_KEY_URL" >/dev/null 2>&1; then
        log_error "无法访问 sing-box 官方服务器，请检查网络或代理配置"
    fi
}

# 检查 apt 环境
check_apt() {
    if ! command -v apt >/dev/null 2>&1; then
        log_error "当前系统不支持 apt 包管理器，仅支持 Debian/Ubuntu 系统"
    fi
}

# ===================== 核心逻辑 =====================

# 前置检查
main() {
    log_info "===== 开始执行 sing-box 安装脚本 ====="
    check_sudo
    check_apt
    check_network

    # 检查 sing-box 是否已安装
    if command -v sing-box >/dev/null 2>&1; then
        sing_box_version=$(sing-box version | grep -oP 'sing-box version \K\S+' || echo "未知版本")
        log_success "sing-box 已安装，当前版本：$sing_box_version，跳过安装步骤"
        exit 0
    fi

    # 1. 添加 GPG 密钥（避免重复添加）
    log_info "添加 sing-box 官方 GPG 密钥..."
    sudo mkdir -p /etc/apt/keyrings
    if [ ! -f "$GPG_KEY_PATH" ]; then
        sudo curl -fsSL "$GPG_KEY_URL" -o "$GPG_KEY_PATH" || log_error "GPG 密钥下载失败"
        sudo chmod a+r "$GPG_KEY_PATH"
    else
        log_warn "GPG 密钥已存在，跳过下载"
    fi

    # 2. 添加 apt 源（避免重复添加）
    log_info "配置 sing-box apt 源..."
    if [ ! -f "$SOURCES_FILE" ]; then
        echo "Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: $GPG_KEY_PATH" | sudo tee "$SOURCES_FILE" >/dev/null || log_error "apt 源配置文件写入失败"
    else
        log_warn "apt 源配置文件已存在，跳过创建"
    fi

    # 3. 更新包列表（保留关键输出，便于排查）
    log_info "更新 apt 包列表..."
    sudo apt-get update -qq || log_error "apt 包列表更新失败，请检查源配置"

    # 4. 选择安装版本（增加默认值，超时自动选稳定版）
    log_info "请选择安装版本（默认 10 秒后自动选择稳定版）"
    read -rp "1: 稳定版 | 2: 测试版 (输入 1/2，回车确认): " -t 10 version_choice
    version_choice=${version_choice:-1}  # 默认选1

    case $version_choice in
        1)
            pkg_name="sing-box"
            log_info "开始安装 sing-box 稳定版..."
            ;;
        2)
            pkg_name="sing-box-beta"
            log_info "开始安装 sing-box 测试版..."
            ;;
        *)
            log_warn "无效选择_
