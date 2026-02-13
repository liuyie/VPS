#!/bin/bash
#
# ==============================================================================
# 一键开启 BBR + TCP 优化 + 修改 SSH 登录密码 (Debian/Ubuntu)
# ==============================================================================

set -eEuo pipefail
trap 'echo -e "\033[31m❌ 脚本在 [${BASH_SOURCE}:${LINENO}] 行发生错误\033[0m" >&2; exit 1' ERR

# ANSI 颜色
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

# 检查 root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}❌ 请使用 root 权限运行脚本！${RESET}"
        exit 1
    fi
}

# 开启 BBR 并优化 TCP
enable_bbr() {
    echo -e "${YELLOW}⚡ 开启 BBR 并优化 TCP 参数...${RESET}"
    SYSCTL_CONF="/etc/sysctl.d/99-bbr.conf"
    
    # 备份已有 sysctl 配置
    [ -f "$SYSCTL_CONF" ] && cp "$SYSCTL_CONF" "${SYSCTL_CONF}.bak_$(date +%F_%T)"
    
    cat > "$SYSCTL_CONF" <<EOF
# BBR + TCP 优化参数
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
EOF

    # 应用 sysctl 配置
    sysctl --system >/dev/null
    echo -e "${GREEN}✅ BBR + TCP 优化已应用。${RESET}"

    # 检查是否开启 BBR
    TCP_CCA=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [ "$TCP_CCA" == "bbr" ]; then
        echo -e "${GREEN}✅ 当前 TCP 拥塞控制算法: $TCP_CCA${RESET}"
    else
        echo -e "${RED}⚠️ BBR 未生效，请重启后再检查。${RESET}"
    fi
}

# 修改 SSH 密码
change_ssh_password() {
    echo -e "${YELLOW}🔑 修改 SSH 登录密码${RESET}"
    read -s -r -p "请输入新密码: " NEW_PASS
    echo
    read -s -r -p "请再次输入确认密码: " NEW_PASS_CONFIRM
    echo
    if [ "$NEW_PASS" != "$NEW_PASS_CONFIRM" ]; then
        echo -e "${RED}❌ 两次输入密码不一致！${RESET}"
        exit 1
    fi

    echo "root:$NEW_PASS" | chpasswd
    echo -e "${GREEN}✅ SSH 登录密码已修改。${RESET}"
}

# 显示当前 BBR 状态
show_bbr_status() {
    echo -e "${YELLOW}ℹ️ 当前 TCP 拥塞控制算法: $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')${RESET}"
    echo -e "${YELLOW}ℹ️ 当前队列调度器: $(sysctl net.core.default_qdisc | awk '{print $3}')${RESET}"
}

# 主逻辑
check_root
enable_bbr
show_bbr_status
change_ssh_password

echo -e "${GREEN}✅ 脚本执行完毕！建议重启系统以确保 BBR 生效。${RESET}"
