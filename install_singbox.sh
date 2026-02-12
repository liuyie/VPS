#!/bin/bash
set -euo pipefail  # 严格模式：错误立即退出、未定义变量报错、管道失败整体报错

# ===================== 基础配置 =====================
# 定义颜色（兼容无终端场景）
if [ -t 1 ]; then
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

# 关键变量（便于维护）
GPG_KEY_URL="https://sing-box.app/gpg.key"
GPG_KEY_PATH="/etc/apt/keyrings/sagernet.asc"
SOURCES_FILE="/etc/apt/sources.list.d/sagernet.sources"
SING_BOX_USER="sing-box"

# ===================== 工具函数 =====================
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
    exit 1
}

# 检查sudo权限
check_sudo() {
    if ! sudo -v >/dev/null 2>&1; then
        log_error "当前用户无sudo权限，请使用root或有sudo权限的用户执行"
    fi
}

# 检查apt环境
check_apt() {
    if ! command -v apt >/dev/null 2>&1; then
        log_error "仅支持Debian/Ubuntu系统（apt包管理器）"
    fi
}

# 检查网络连通性
check_network() {
    log_info "检查网络连通性..."
    if ! curl -fsSL --max-time 10 "$GPG_KEY_URL" >/dev/null 2>&1; then
        log_error "无法访问sing-box官方服务器，请检查网络/代理"
    fi
}

# ===================== 核心逻辑 =====================
main() {
    log_info "===== 开始安装sing-box ====="
    
    # 前置检查
    check_sudo
    check_apt
    check_network

    # 检查是否已安装
    if command -v sing-box >/dev/null 2>&1; then
        local version
        version=$(sing-box version | grep -oP 'sing-box version \K\S+' || echo "未知版本")
        log_success "sing-box已安装，版本：$version，跳过安装"
        exit 0
    fi

    # 1. 安装GPG密钥
    log_info "添加GPG密钥..."
    sudo mkdir -p /etc/apt/keyrings
    if [ ! -f "$GPG_KEY_PATH" ]; then
        if ! sudo curl -fsSL "$GPG_KEY_URL" -o "$GPG_KEY_PATH"; then
            log_error "GPG密钥下载失败"
        fi
        sudo chmod a+r "$GPG_KEY_PATH"
    else
        log_warn "GPG密钥已存在，跳过"
    fi

    # 2. 配置apt源
    log_info "配置apt源..."
    if [ ! -f "$SOURCES_FILE" ]; then
        cat << 'EOF' | sudo tee "$SOURCES_FILE" >/dev/null
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
        if [ $? -ne 0 ]; then
            log_error "apt源文件写入失败"
        fi
    else
        log_warn "apt源文件已存在，跳过"
    fi

    # 3. 更新包列表
    log_info "更新apt包列表..."
    if ! sudo apt-get update -qq; then
        log_error "apt包列表更新失败"
    fi

    # 4. 选择安装版本
    log_info "请选择安装版本（10秒后默认选稳定版）"
    read -rp "1:稳定版 | 2:测试版 (输入1/2回车): " -t 10 version_choice
    version_choice=${version_choice:-1}

    local pkg_name
    case "$version_choice" in
        1)
            pkg_name="sing-box"
            log_info "安装稳定版..."
            ;;
        2)
            pkg_name="sing-box-beta"
            log_info "安装测试版..."
            ;;
        *)
            log_warn "无效选择，默认安装稳定版"
            pkg_name="sing-box"
            ;;
    esac

    # 5. 安装包
    if ! sudo apt-get install -y "$pkg_name"; then
        log_error "$pkg_name安装失败，查看日志：/var/log/apt/term.log"
    fi

    # 6. 验证安装
    if ! command -v sing-box >/dev/null 2>&1; then
        log_error "安装后未检测到sing-box可执行文件"
    fi
    local final_version
    final_version=$(sing-box version | grep -oP 'sing-box version \K\S+' || echo "未知版本")
    log_success "sing-box安装成功，版本：$final_version"

    # 7. 配置用户和权限
    log_info "配置权限..."
    if ! id "$SING_BOX_USER" >/dev/null 2>&1; then
        sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$SING_BOX_USER"
        log_info "创建$SING_BOX_USER系统用户"
    else
        log_warn "$SING_BOX_USER用户已存在，跳过"
    fi

    # 创建目录并设置权限
    local dirs=("/var/lib/sing-box" "/etc/sing-box")
    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            sudo mkdir -p "$dir"
            log_info "创建目录：$dir"
        fi
        sudo chown -R "$SING_BOX_USER:$SING_BOX_USER" "$dir"
        sudo chmod 700 "$dir"
    done

    log_success "===== sing-box安装配置完成 ====="
}

# 执行主函数
main
