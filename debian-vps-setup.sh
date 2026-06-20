#!/usr/bin/env bash
#
# debian-vps-setup.sh — Debian VPS 安全加固脚本
# 适用于 Debian 11 / 12 / 13
# 用法: bash debian-vps-setup.sh [--dry-run]
#
# 功能:
#   1. 自定义 SSH 端口 + 禁用密码登录 + 仅密钥登录 (root)
#   2. fail2ban 防暴力破解
#   3. 自动安全更新 (unattended-upgrades)
#   4. Swap 自动创建 (小内存 VPS)
#   5. 时区设置 + sysctl TCP 调优
#
# ⚠️  重要提醒:
#   - 执行前请确保你有 VPS 控制台备用访问方式 (VNC/Console)
#   - 脚本会修改 SSH 配置，错误配置可能导致无法远程登录
#   - 建议先用 --dry-run 模式预览将执行的操作
#

set -euo pipefail

# ============================================================
# 内建公钥 (脚本自带，批量部署时无需手动粘贴)
# 如需更换密钥，替换下面这行即可
# ============================================================
BUILTIN_PUB_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINFXNEWr6ltrJnaOzhSS8MrSTXnar4NU811ctepYBHq mickey@reasonix"

# ============================================================
# 颜色与工具函数
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

log_info()  { echo -e "${GREEN}[✔]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[⚠]${NC} $*"; }
log_error() { echo -e "${RED}[✘]${NC} $*"; }
log_step()  { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}"; }

run_cmd() {
    if $DRY_RUN; then
        echo -e "  ${YELLOW}[DRY-RUN]${NC} $*"
    else
        bash -c "$*"
    fi
}

# ============================================================
# 前置检查
# ============================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行此脚本 (sudo bash $0)"
        exit 1
    fi
}

check_distro() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法检测系统版本"
        exit 1
    fi
    . /etc/os-release
    if [[ "$ID" != "debian" ]]; then
        log_warn "检测到系统为 $ID (非 Debian)，脚本针对 Debian 优化，继续可能出现问题"
        read -rp "是否继续？[y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
    fi
    log_info "检测到系统: $PRETTY_NAME"
}

# ============================================================
# 步骤 1: 交互式信息收集
# ============================================================
collect_info() {
    log_step "步骤 1/7: 信息收集"

    # SSH 端口
    read -rp "请输入新的 SSH 端口号 [默认: 2222]: " SSH_PORT
    SSH_PORT="${SSH_PORT:-2222}"
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
        log_error "端口号无效: $SSH_PORT (应为 1-65535)"
        exit 1
    fi
    if (( SSH_PORT == 22 )); then
        log_error "新端口不能是 22，请选择其他端口"
        exit 1
    fi
    log_info "SSH 端口: $SSH_PORT"

    # 公钥 - 自动检测多种密钥类型
    local auto_key_file=""
    for keyfile in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
        if [[ -f "$keyfile" ]]; then
            auto_key_file="$keyfile"
            break
        fi
    done

    if [[ -n "$auto_key_file" ]]; then
        PUB_KEY=$(cat "$auto_key_file")
        log_info "已自动读取公钥 (${auto_key_file}): ${PUB_KEY:0:40}..."
        read -rp "是否使用此公钥？[Y/n]: " use_auto_key
        if [[ "${use_auto_key}" =~ ^[Nn]$ ]]; then
            PUB_KEY=""
        fi
    fi

    if [[ -z "${PUB_KEY:-}" ]]; then
        log_info "使用脚本内建公钥: ${BUILTIN_PUB_KEY:0:50}..."
        read -rp "是否使用内建公钥？[Y/n]: " use_builtin
        if [[ "${use_builtin}" =~ ^[Nn]$ ]]; then
            log_warn "请粘贴你的 SSH 公钥 (以 ssh-rsa / ssh-ed25519 开头):"
            read -rp "> " PUB_KEY
            if [[ -z "$PUB_KEY" ]]; then
                log_error "公钥不能为空！"
                exit 1
            fi
        else
            PUB_KEY="$BUILTIN_PUB_KEY"
        fi
    fi

    # 确认
    echo ""
    echo -e "${BOLD}配置确认:${NC}"
    echo -e "  SSH 端口:     ${CYAN}${SSH_PORT}${NC}"
    echo -e "  登录用户:     ${CYAN}root${NC}"
    echo -e "  公钥:         ${CYAN}${PUB_KEY:0:50}...${NC}"
    echo -e "  fail2ban:     ${CYAN}启用${NC}"
    echo -e "  自动安全更新: ${CYAN}启用${NC}"
    echo -e "  Swap:         ${CYAN}自动 (≤2GB 内存时创建)${NC}"
    echo -e "  时区:         ${CYAN}Asia/Shanghai${NC}"
    echo ""
    read -rp "确认以上配置并开始执行？[Y/n]: " go
    if [[ "${go}" =~ ^[Nn]$ ]]; then
        log_warn "用户取消操作"
        exit 0
    fi
}

# ============================================================
# 步骤 2: 系统更新 + 基础工具
# ============================================================
update_system() {
    log_step "步骤 2/7: 系统更新 & 安装基础工具"

    log_info "更新软件源..."
    run_cmd "apt update -y"

    log_info "升级系统软件包..."
    run_cmd "DEBIAN_FRONTEND=noninteractive apt upgrade -y"

    log_info "安装基础工具..."
    run_cmd "DEBIAN_FRONTEND=noninteractive apt install -y curl wget vim git htop unzip"
}

# ============================================================
# 步骤 3: SSH 安全加固 (核心)
# ============================================================
harden_ssh() {
    log_step "步骤 3/7: SSH 安全加固"

    local SSHD_CONF="/etc/ssh/sshd_config"
    local SSHD_CONF_DIR="/etc/ssh/sshd_config.d"
    local BACKUP="${SSHD_CONF}.bak.$(date +%Y%m%d%H%M%S)"

    # 确保 .ssh 目录存在且权限正确
    log_info "配置 root SSH 公钥..."
    run_cmd "mkdir -p /root/.ssh"
    run_cmd "chmod 700 /root/.ssh"

    # 写入公钥 (追加，避免覆盖已有密钥)
    if ! grep -qxF "$PUB_KEY" /root/.ssh/authorized_keys 2>/dev/null; then
        if $DRY_RUN; then
            echo -e "  ${YELLOW}[DRY-RUN]${NC} 写入公钥到 /root/.ssh/authorized_keys"
        else
            printf '%s\n' "$PUB_KEY" >> /root/.ssh/authorized_keys
        fi
        log_info "公钥已写入 /root/.ssh/authorized_keys"
    else
        log_info "公钥已存在于 authorized_keys 中，跳过"
    fi
    run_cmd "chmod 600 /root/.ssh/authorized_keys"

    # 备份原配置
    log_info "备份原 SSH 配置 -> $BACKUP"
    run_cmd "cp '$SSHD_CONF' '$BACKUP'"

    # 备份并清理 sshd_config.d 目录 (Debian 12/13 可能残留冲突配置)
    if [[ -d "$SSHD_CONF_DIR" ]]; then
        local CONF_DIR_BACKUP="/root/sshd_config.d.bak.$(date +%Y%m%d%H%M%S)"
        log_info "备份 sshd_config.d -> $CONF_DIR_BACKUP"
        run_cmd "cp -r '$SSHD_CONF_DIR' '$CONF_DIR_BACKUP'"
        # 清理 .d 目录，防止残留的 PasswordAuthentication yes 等覆盖我们的配置
        log_info "清理 sshd_config.d 目录 (移除可能冲突的配置)..."
        run_cmd "rm -f '${SSHD_CONF_DIR}'/*.conf"
    fi

    # 生成新的 sshd_config
    log_info "写入加固后的 SSH 配置..."
    if ! $DRY_RUN; then
        cat > "$SSHD_CONF" <<SSHEOF
# ==============================================================
# sshd_config — 加固配置 (由 debian-vps-setup.sh 生成)
# 原始配置备份: ${BACKUP}
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# ==============================================================

# --- 加载 .d 目录 (目录已清空，无冲突配置) ---
Include /etc/ssh/sshd_config.d/*.conf

# --- 基本设置 ---
Port ${SSH_PORT}
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

# --- 主机密钥 ---
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# --- 认证 ---
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no

# --- PAM (Debian 需要保持 yes 但密码已关闭) ---
UsePAM yes

# --- 安全限制 ---
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

# --- 功能开关 ---
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PrintMotd no

# --- 子系统 ---
Subsystem sftp /usr/lib/openssh/sftp-server

# --- 日志 ---
LogLevel VERBOSE
SSHEOF
    fi

    # 校验配置
    log_info "校验 SSH 配置语法..."
    if ! sshd -t 2>/dev/null; then
        log_error "SSH 配置语法错误！正在回滚..."
        run_cmd "cp '$BACKUP' '$SSHD_CONF'"
        exit 1
    fi
    log_info "SSH 配置语法正确"

    # 重启 SSH
    log_info "重启 SSH 服务..."
    run_cmd "systemctl restart ssh"
    log_info "SSH 加固完成 (端口: ${SSH_PORT})"

    # 生成紧急恢复脚本
    log_info "生成紧急恢复脚本 /root/ssh-restore.sh ..."
    if ! $DRY_RUN; then
        cat > /root/ssh-restore.sh <<RESTOREEOF
#!/usr/bin/env bash
# SSH 紧急恢复脚本 — 如果 SSH 连不上，在 VPS 控制台执行此脚本
# 用法: bash /root/ssh-restore.sh
set -euo pipefail
echo "=== SSH 紧急恢复 ==="
echo "正在还原配置..."

# 还原 sshd_config
BACKUP_FILE="${BACKUP}"
if [[ -f "\$BACKUP_FILE" ]]; then
    cp "\$BACKUP_FILE" /etc/ssh/sshd_config
    echo "已还原 sshd_config: \$BACKUP_FILE"
else
    echo "备份文件不存在: \$BACKUP_FILE"
    echo "手动恢复: 编辑 /etc/ssh/sshd_config 设置 Port 22 和 PasswordAuthentication yes"
    exit 1
fi

# 还原 sshd_config.d
CONF_DIR_BACKUP="/root/sshd_config.d.bak.*"
if ls \$CONF_DIR_BACKUP 1>/dev/null 2>&1; then
    LATEST_DIR=\$(ls -td \$CONF_DIR_BACKUP | head -1)
    rm -rf /etc/ssh/sshd_config.d
    cp -r "\$LATEST_DIR" /etc/ssh/sshd_config.d
    echo "已还原 sshd_config.d: \$LATEST_DIR"
fi

# 临时启用密码登录 (确保能连上)
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

systemctl restart ssh
echo ""
echo "✅ 恢复完成！"
echo "SSH 已恢复为端口 22 + 密码登录"
echo "登录后请重新执行加固脚本"
RESTOREEOF
        chmod +x /root/ssh-restore.sh
    fi
    log_info "如需恢复，在 VPS 控制台执行: bash /root/ssh-restore.sh"
}

# ============================================================
# 步骤 4: fail2ban
# ============================================================
setup_fail2ban() {
    log_step "步骤 4/7: 安装配置 fail2ban"

    log_info "安装 fail2ban..."
    run_cmd "DEBIAN_FRONTEND=noninteractive apt install -y fail2ban"

    log_info "写入 fail2ban 配置..."
    if ! $DRY_RUN; then
        # 自动检测日志后端: 有 auth.log 用 auto，纯 journald 用 systemd
        local f2b_backend="auto"
        if [[ ! -f /var/log/auth.log ]]; then
            f2b_backend="systemd"
            log_info "未检测到 /var/log/auth.log，fail2ban 使用 journald 后端"
        fi

        cat > /etc/fail2ban/jail.local <<F2BEOF
# fail2ban jail.local — 由 debian-vps-setup.sh 生成
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
backend  = ${f2b_backend}
maxretry = 3
bantime  = 1h
F2BEOF
    fi

    log_info "启动 fail2ban..."
    run_cmd "systemctl enable fail2ban"
    run_cmd "systemctl restart fail2ban"
    log_info "fail2ban 已启用 (SSH 端口: ${SSH_PORT})"
}

# ============================================================
# 步骤 5: 自动安全更新
# ============================================================
setup_auto_updates() {
    log_step "步骤 5/7: 配置自动安全更新"

    log_info "安装 unattended-upgrades..."
    run_cmd "DEBIAN_FRONTEND=noninteractive apt install -y unattended-upgrades apt-listchanges"

    log_info "启用自动安全更新..."
    run_cmd "dpkg-reconfigure -plow unattended-upgrades"

    # 确保配置正确
    if ! $DRY_RUN; then
        cat > /etc/apt/apt.conf.d/20auto-upgrades <<'UUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
UUEOF
    fi
    log_info "自动安全更新已配置"
}

# ============================================================
# 步骤 6: Swap (小内存 VPS)
# ============================================================
setup_swap() {
    log_step "步骤 6/7: Swap 配置"

    # 检查是否已有 swap
    local current_swap
    current_swap=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
    if (( current_swap > 0 )); then
        log_info "已存在 Swap (${current_swap}kB)，跳过创建"
        return
    fi

    # 检测内存大小
    local mem_mb
    mem_mb=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
    log_info "检测到内存: ${mem_mb}MB"

    if (( mem_mb > 2048 )); then
        log_info "内存大于 2GB，跳过 Swap 创建"
        return
    fi

    local swap_size=$mem_mb
    local swapfile="/swapfile"

    log_info "创建 ${swap_size}MB Swap 文件..."
    run_cmd "fallocate -l ${swap_size}M ${swapfile}"
    run_cmd "chmod 600 ${swapfile}"
    run_cmd "mkswap ${swapfile}"
    run_cmd "swapon ${swapfile}"

    # 持久化
    if ! grep -qF "$swapfile" /etc/fstab; then
        run_cmd "echo '${swapfile} none swap sw 0 0' >> /etc/fstab"
    fi

    # 优化 swappiness
    if ! $DRY_RUN; then
        cat > /etc/sysctl.d/99-swap.conf <<'SWAPEOF'
vm.swappiness = 10
SWAPEOF
        sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null 2>&1
    fi

    log_info "Swap ${swap_size}MB 已创建并启用 (swappiness=10)"
}

# ============================================================
# 步骤 7: 时区 + sysctl 优化
# ============================================================
setup_timezone_and_sysctl() {
    log_step "步骤 7/7: 时区 & 系统参数优化"

    # 时区
    log_info "设置时区为 Asia/Shanghai..."
    run_cmd "timedatectl set-timezone Asia/Shanghai"

    # sysctl TCP 调优
    log_info "写入 sysctl 优化参数..."

    # 显式加载 BBR 内核模块 (确保 sysctl 参数能生效)
    if ! $DRY_RUN; then
        if ! modprobe tcp_bbr 2>/dev/null; then
            log_warn "tcp_bbr 模块加载失败，尝试其他方式..."
            # 部分内核将 BBR 编译为内建而非模块
            if ! sysctl net.ipv4.tcp_congestion_control=bbr 2>/dev/null; then
                log_warn "BBR 不可用，跳过 BBR 配置 (不影响其他 TCP 优化)"
            fi
        fi
    fi
    if ! $DRY_RUN; then
        cat > /etc/sysctl.d/99-tcp-tuning.conf <<'SYSCTLEOF'
# TCP 调优 — 由 debian-vps-setup.sh 生成

# TCP 拥塞控制 (使用 BBR)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP 缓冲区
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# TCP 连接优化
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# 安全相关
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
SYSCTLEOF
        sysctl --system >/dev/null 2>&1
    fi

    # 验证 BBR 是否生效
    if ! $DRY_RUN; then
        local current_cc
        current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
        if [[ "$current_cc" == "bbr" ]]; then
            log_info "BBR 拥塞控制已生效 ✅"
        else
            log_warn "BBR 未生效 (当前: $current_cc)，可能需要重启系统"
        fi
    fi

    log_info "时区 & sysctl 优化完成"
}

# ============================================================
# 完成后自动验证
# ============================================================
verify_setup() {
    log_step "验证配置"

    local all_ok=true

    # 1. 验证 BBR
    if ! $DRY_RUN; then
        local current_cc
        current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
        if [[ "$current_cc" == "bbr" ]]; then
            log_info "BBR 拥塞控制: ${GREEN}✅ 已生效${NC}"
        else
            log_warn "BBR 拥塞控制: ${RED}❌ 未生效${NC} (当前: $current_cc，可能需要重启)"
            all_ok=false
        fi
    fi

    # 2. 验证 SSH 端口监听
    if ! $DRY_RUN; then
        if ss -tlnp 2>/dev/null | grep -q ":${SSH_PORT} "; then
            log_info "SSH 端口 ${SSH_PORT}:   ${GREEN}✅ 正在监听${NC}"
        else
            log_warn "SSH 端口 ${SSH_PORT}:   ${RED}❌ 未监听${NC} (请检查 sshd 状态)"
            all_ok=false
        fi
    fi

    # 3. 验证密码登录已禁用
    if ! $DRY_RUN; then
        local sshd_output
        sshd_output=$(sshd -T 2>/dev/null | grep "^passwordauthentication" || true)
        if [[ "$sshd_output" == *"no"* ]]; then
            log_info "密码登录:         ${GREEN}✅ 已禁用${NC}"
        else
            log_warn "密码登录:         ${RED}❌ 仍启用${NC}"
            all_ok=false
        fi
    fi

    # 4. 验证 fail2ban
    if ! $DRY_RUN; then
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            log_info "fail2ban:         ${GREEN}✅ 运行中${NC}"
        else
            log_warn "fail2ban:         ${RED}❌ 未运行${NC}"
            all_ok=false
        fi
    fi

    # 5. 验证公钥已写入
    if ! $DRY_RUN; then
        if [[ -f /root/.ssh/authorized_keys ]] && [[ -s /root/.ssh/authorized_keys ]]; then
            log_info "authorized_keys:  ${GREEN}✅ 已配置${NC}"
        else
            log_warn "authorized_keys:  ${RED}❌ 为空或不存在${NC}"
            all_ok=false
        fi
    fi

    # 总结
    if ! $DRY_RUN; then
        echo ""
        if $all_ok; then
            log_info "${GREEN}${BOLD}所有验证通过！配置正确。${NC}"
        else
            log_warn "${YELLOW}${BOLD}部分验证未通过，请检查上方 ⚠️ 标记的项目。${NC}"
        fi
    fi
}

# ============================================================
# 完成总结
# ============================================================
print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              🎉 VPS 安全加固已完成!                      ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "${BOLD}配置摘要:${NC}"
    echo -e "  SSH 端口:     ${CYAN}${SSH_PORT}${NC}"
    echo -e "  登录方式:     ${CYAN}密钥登录 (仅 root)${NC}"
    echo -e "  密码登录:     ${RED}已禁用${NC}"
    echo -e "  fail2ban:     ${GREEN}已启用${NC}"
    echo -e "  自动更新:     ${GREEN}已启用${NC}"
    echo -e "  时区:         ${CYAN}Asia/Shanghai${NC}"
    echo ""
    echo -e "${BOLD}连接测试:${NC}"
    echo -e "  ${CYAN}ssh -p ${SSH_PORT} root@<你的服务器IP>${NC}"
    echo ""
    echo -e "${YELLOW}${BOLD}⚠️  重要提醒:${NC}"
    echo -e "  1. ${YELLOW}请先在另一个终端测试新端口连接是否正常，再关闭当前连接${NC}"
    echo -e "  2. ${YELLOW}如果连接失败，请使用 VPS 控制台 (VNC) 进行修复${NC}"
    echo -e "  3. SSH 配置备份位于 /etc/ssh/sshd_config.bak.*"
    echo ""
    if $DRY_RUN; then
        echo -e "${YELLOW}${BOLD}📌 当前为 DRY-RUN 模式，以上操作均未实际执行${NC}"
        echo -e "${YELLOW}   去掉 --dry-run 参数即可正式执行${NC}"
    fi
}

# ============================================================
# 主流程
# ============================================================
main() {
    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         Debian VPS 安全加固脚本                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if $DRY_RUN; then
        echo -e "${YELLOW}${BOLD}📌 DRY-RUN 模式: 仅预览操作，不会实际执行${NC}"
        echo ""
    fi

    check_root
    check_distro
    collect_info
    update_system
    harden_ssh
    setup_fail2ban
    setup_auto_updates
    setup_swap
    setup_timezone_and_sysctl
    verify_setup
    print_summary
}

main "$@"
