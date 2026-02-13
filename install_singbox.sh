#!/bin/bash
set -euo pipefail

# ===================== 基础配置 =====================
CYAN='\033[0;36m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

GPG_KEY_URL="https://sing-box.app/gpg.key"
GPG_KEY_PATH="/etc/apt/keyrings/sagernet.asc"
SOURCES_FILE="/etc/apt/sources.list.d/sagernet.sources"
SING_BOX_USER="sing-box"
CONFIG_FILE="/etc/sing-box/config.json"

log() { echo -e "${CYAN}[INFO] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

# ===================== 检查 sudo =====================
check_sudo() {
    if ! sudo -v >/dev/null 2>&1; then
        log_error "当前用户无 sudo 权限，请使用 root 或有 sudo 权限的用户执行脚本"
    fi
}

# ===================== 修复主机名解析 =====================
fix_hostname() {
    HOSTNAME=$(hostname)
    if ! grep -q "$HOSTNAME" /etc/hosts; then
        log_warn "修复主机名解析 /etc/hosts"
        echo "127.0.0.1 $HOSTNAME" | sudo tee -a /etc/hosts >/dev/null
    fi
}

# ===================== 网络与 apt =====================
check_network() {
    log "检查网络..."
    if ! curl -fsSL --max-time 10 "$GPG_KEY_URL" >/dev/null 2>&1; then
        log_error "无法访问 sing-box 官方服务器，请检查网络"
    fi
}

check_apt() {
    if ! command -v apt >/dev/null 2>&1; then
        log_error "当前系统不支持 apt 包管理器，仅支持 Debian/Ubuntu 系统"
    fi
}

# ===================== 安装 sing-box =====================
install_sing_box() {
    sudo mkdir -p /etc/apt/keyrings
    if [ ! -f "$GPG_KEY_PATH" ]; then
        log "下载 GPG Key..."
        sudo curl -fsSL "$GPG_KEY_URL" -o "$GPG_KEY_PATH" || log_error "GPG Key 下载失败"
        sudo chmod a+r "$GPG_KEY_PATH"
    fi

    if [ ! -f "$SOURCES_FILE" ]; then
        log "配置 apt 源..."
        echo "Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: $GPG_KEY_PATH" | sudo tee "$SOURCES_FILE" >/dev/null
    fi

    sudo apt-get update -qq
    sudo apt-get install -y sing-box
}

# ===================== 创建系统用户 & 目录 =====================
setup_user_dir() {
    if ! id "$SING_BOX_USER" >/dev/null 2>&1; then
        sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$SING_BOX_USER"
    fi

    for dir in /var/lib/sing-box /etc/sing-box; do
        sudo mkdir -p "$dir"
        sudo chown -R "$SING_BOX_USER:$SING_BOX_USER" "$dir"
        sudo chmod 700 "$dir"
    done
}

# ===================== 生成配置 =====================
generate_config() {
    log "生成最新版 config.json ..."

    # 随机生成密码/UUID
    UUID=$(sing-box generate uuid)
    SS_PASS=$(head /dev/urandom | tr -dc a-zA-Z0-9 | head -c 16)
    HYSTERIA_PASS=$(head /dev/urandom | tr -dc a-zA-Z0-9 | head -c 16)

    cat <<EOF | sudo tee "$CONFIG_FILE" >/dev/null
{
  "dns": {
    "servers":[
      {"tag":"cloudflare","type":"udp","server":"1.1.1.1"},
      {"tag":"google","type":"udp","server":"8.8.8.8"}
    ]
  },
  "inbounds":[
    {
      "tag":"VLESS",
      "type":"vless",
      "listen":"::",
      "listen_port":443,
      "users":[{"uuid":"$UUID","flow":"xtls-rprx-vision"}],
      "tls":{"enabled":true}
    },
    {
      "tag":"SS",
      "type":"shadowsocks",
      "listen":"::",
      "listen_port":80,
      "method":"2022-blake3-aes-128-gcm",
      "password":"$SS_PASS",
      "multiplex":{"enabled":true}
    },
    {
      "tag":"HYSTERIA2",
      "type":"hysteria2",
      "listen":"::",
      "listen_port":61,
      "obfs":{"type":"salamander","password":"$HYSTERIA_PASS"},
      "users":[{"password":"$HYSTERIA_PASS"}],
      "tls":{"enabled":true,"alpn":["h3"],"certificate_path":".crt","key_path":".key"}
    }
  ],
  "outbounds":[{"tag":"direct","type":"direct"}],
  "route":{"final":"direct"},
  "log":{"disabled":false,"level":"info","timestamp":true}
}
EOF

    sudo chown "$SING_BOX_USER:$SING_BOX_USER" "$CONFIG_FILE"
    sudo chmod 600 "$CONFIG_FILE"
}

# ===================== systemd =====================
setup_systemd() {
    if [ ! -f /etc/systemd/system/sing-box.service ]; then
        log "创建 systemd 服务..."
        cat <<'EOT' | sudo tee /etc/systemd/system/sing-box.service >/dev/null
[Unit]
Description=sing-box service
After=network.target

[Service]
Type=simple
User=sing-box
Group=sing-box
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOT
        sudo systemctl daemon-reload
        sudo systemctl enable sing-box
    fi
    sudo systemctl restart sing-box
}

# ===================== 主函数 =====================
main() {
    check_sudo
    fix_hostname
    check_network
    check_apt
    install_sing_box
    setup_user_dir
    generate_config
    setup_systemd
    log_success "sing-box 安装完成并已启动，配置位于 $CONFIG_FILE"
}

main
