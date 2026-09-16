#!/bin/bash
# ==============================================================================
# 脚本名称: Debian 全能初始化脚本 (最终纯净稳定版)
# 适用系统: Debian 11 / 12 / 13 (Trixie) / Ubuntu (兼容普通用户 sudo 执行)
# 设计原则: 尊重用户网络偏好、不擅改系统源、核心组件高可用
# ==============================================================================

set -u

# --- 终端颜色常量 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=================================================${NC}"
echo -e "${GREEN}  🚀 欢迎使用 Debian 全能初始化脚本 (纯净稳定版) 🚀  ${NC}"
echo -e "${BLUE}=================================================${NC}"

# 1. 权限预检：必须以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 错误: 请使用 sudo 权限运行此脚本！${NC}"
    echo -e "💡 推荐命令: sudo bash -c \"\$(curl -fsSL <URL>)\""
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# 2. 定位真实的普通操作账户及家目录
ACTUAL_USER=${SUDO_USER:-$(logname 2>/dev/null || whoami)}
USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    USER_HOME="/root"
fi

# ==============================================================================
# 🌐 网络与代理状态检查 (完全遵循用户意愿，不擅自开启与劫持)
# ==============================================================================
# 自动清理历史脚本可能残留的 APT 临时代理，防止导致 503 报错
rm -f /etc/apt/apt.conf.d/99temp-proxy 2>/dev/null || true

ACTIVE_PROXY="${http_proxy:-${HTTP_PROXY:-}}"
if [ -n "$ACTIVE_PROXY" ]; then
    echo -e "${GREEN}✨ 检测到当前终端已由用户主动挂载代理: $ACTIVE_PROXY${NC}"
else
    echo -e "${GREEN}🌐 当前终端未挂载代理，全程使用系统原生直接连接。${NC}"
fi

# ==============================================================================
# 0. 基础环境保底
# ==============================================================================
apt-get update -q && apt-get install -y -q sudo

# ==============================================================================
# 1. 账户安全与 SSH 配置
# ==============================================================================
echo -e "\n${YELLOW}🔐 [1/12] 账户与安全设置${NC}"

if [ "$ACTUAL_USER" = "root" ]; then
    echo -e "${YELLOW}⚠️ 检测到您当前正以 root 账户直接执行！${NC}"
    read -p "❓ 是否新建一个日常普通账户 (加入 sudo 组)？[Y/n]: " create_new_user </dev/tty
    if [[ ! "$create_new_user" =~ ^[Nn]$ ]]; then
        read -p "👤 请输入新用户名: " new_username </dev/tty
        if [ -n "$new_username" ] && ! id "$new_username" &>/dev/null; then
            adduser --gecos "" "$new_username"
            usermod -aG sudo "$new_username"
            ACTUAL_USER="$new_username"
            USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
            echo -e "${GREEN}✅ 用户 $new_username 创建完毕，已授予 sudo 权限。${NC}"
        fi
    fi
else
    echo -e "${GREEN}✅ 当前操作者为日常账户 ($ACTUAL_USER)，所有个性化配置将写入其主目录。${NC}"
fi

echo -e "👤 目标生效用户: ${GREEN}$ACTUAL_USER${NC} | 家目录: ${GREEN}$USER_HOME${NC}"
cd "$USER_HOME" || cd /tmp

# 确保目标用户的核心配置文件存在
sudo -u "$ACTUAL_USER" -H touch "$USER_HOME/.zshrc" "$USER_HOME/.bashrc"

# 1.5 配置 SSH 密钥登录
if [ -s "$USER_HOME/.ssh/authorized_keys" ]; then
    echo -e "${GREEN}✅ 账户 $ACTUAL_USER 已存在配置好的 SSH 公钥，跳过。${NC}"
else
    read -p "❓ 是否为账户 [$ACTUAL_USER] 配置 SSH 公钥？[Y/n]: " setup_ssh_key </dev/tty
    if [[ ! "$setup_ssh_key" =~ ^[Nn]$ ]]; then
        read -r -p "📝 请粘贴您的 SSH 公钥: " ssh_pub_key </dev/tty
        if [ -n "$ssh_pub_key" ]; then
            mkdir -p "$USER_HOME/.ssh"
            echo "$ssh_pub_key" >> "$USER_HOME/.ssh/authorized_keys"
            chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$USER_HOME/.ssh"
            chmod 700 "$USER_HOME/.ssh"
            chmod 600 "$USER_HOME/.ssh/authorized_keys"
            echo -e "${GREEN}✅ SSH 公钥已成功录入！${NC}"
        fi
    fi
fi

# 1.6 禁用 Root 远程密码登录 (安全防爆破，兼顾 Debian 12/13)
if [ "$ACTUAL_USER" != "root" ]; then
    read -p "❓ 是否禁用 Root 远程 SSH 登录？(家庭内网服务器推荐保持 n) [y/N]: " disable_root </dev/tty
    if [[ "$disable_root" =~ ^[Yy]$ ]]; then
        if [ -d "/etc/ssh/sshd_config.d" ]; then
            echo "PermitRootLogin no" > /etc/ssh/sshd_config.d/99-disable-root.conf
        else
            sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
        fi

        # 语法检测，防止误锁
        if sshd -t 2>/dev/null; then
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
            echo -e "${GREEN}🛡️ Root 远程登录已安全封禁。${NC}"
        else
            echo -e "${RED}⚠️ SSH 配置检测失败！已自动回滚，未禁用 Root。${NC}"
            rm -f /etc/ssh/sshd_config.d/99-disable-root.conf 2>/dev/null
        fi
    else
        echo -e "${YELLOW}⏭️ 已保留 Root 远程登录权限。${NC}"
    fi
fi

# ==============================================================================
# 2. 核心必备运维工具 (剔除无关包，纯净必装)
# ==============================================================================
echo -e "\n${YELLOW}📦 [2/12] 正在更新系统并安装核心运维工具...${NC}"
apt-get upgrade -y -q
apt-get install -y -q curl wget git nano htop zsh unzip tmux jq ca-certificates

# ==============================================================================
# 3. 网络优化 (TCP BBR 加速)
# ==============================================================================
echo -e "\n${YELLOW}🌐 [3/12] TCP BBR 拥塞控制优化${NC}"
if grep -qEi "(Microsoft|WSL)" /proc/version 2>/dev/null; then
    echo -e "${GREEN}💻 WSL 环境，自动跳过 BBR 设置。${NC}"
elif sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
    echo -e "${GREEN}✅ BBR 加速已经在运行中，跳过。${NC}"
else
    read -p "❓ 是否开启 BBR 加速？(家庭无线连接抗抖动利器) [Y/n]: " enable_bbr </dev/tty
    if [[ ! "$enable_bbr" =~ ^[Nn]$ ]]; then
        mkdir -p /etc/sysctl.d
        cat << 'EOF' > /etc/sysctl.d/99-bbr.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
        # 兼容性重载配置 (彻底解决 Debian 13 can't read /etc/sysctl.conf 报错)
        sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-bbr.conf 2>/dev/null || true
        echo -e "${GREEN}✅ BBR 加速模块配置完毕并已生效！${NC}"
    fi
fi

# ==============================================================================
# 4. 时区校验
# ==============================================================================
echo -e "\n${YELLOW}⏰ [4/12] 系统时区校验${NC}"
CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")
if [ "$CURRENT_TZ" = "Asia/Shanghai" ]; then
    echo -e "${GREEN}✅ 当前时区已是 Asia/Shanghai，跳过。${NC}"
else
    read -p "❓ 是否将时区设置为 Asia/Shanghai (北京时间)？[Y/n]: " set_tz </dev/tty
    if [[ ! "$set_tz" =~ ^[Nn]$ ]]; then
        timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
        echo -e "${GREEN}✅ 系统时区已调整为: $(date)${NC}"
    fi
fi

# ==============================================================================
# 5. 防火墙与安全配置
# ==============================================================================
echo -e "\n${YELLOW}🛡️ [5/12] 防火墙配置 (UFW & Fail2ban)${NC}"
if grep -qEi "(Microsoft|WSL)" /proc/version 2>/dev/null; then
    echo -e "${GREEN}💻 WSL 环境，自动跳过防火墙配置。${NC}"
else
    read -p "❓ 是否配置防火墙与 Fail2ban？(家庭局域网服务器强烈建议选 n 跳过) [y/N]: " config_sec </dev/tty
    if [[ "$config_sec" =~ ^[Yy]$ ]]; then
        apt-get install -y -q ufw fail2ban
        systemctl enable fail2ban --now >/dev/null 2>&1

        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        ufw allow ssh >/dev/null 2>&1
        ufw allow 443/tcp >/dev/null 2>&1
        ufw allow 80/tcp >/dev/null 2>&1

        while true; do
            read -p "❓ 是否放行其他端口？(逗号隔开如 8080,9000，回车或按 n 跳过): " extra_ports </dev/tty
            if [[ "$extra_ports" =~ ^[Nn]$ ]] || [ -z "$extra_ports" ]; then
                break
            fi
            if [[ "$extra_ports" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                IFS=',' read -ra PORT_ARRAY <<< "$extra_ports"
                for port in "${PORT_ARRAY[@]}"; do
                    ufw allow "$port/tcp" >/dev/null 2>&1
                    echo -e "${GREEN}✅ 已放行: $port/tcp${NC}"
                done
                break
            else
                echo -e "${YELLOW}❌ 输入格式错误，请重新输入（如 8080,9000）${NC}"
            fi
        done

        ufw --force enable >/dev/null 2>&1
        echo -e "${GREEN}✅ UFW 防火墙已激活。${NC}"
    else
        echo -e "${YELLOW}⏭️ 已跳过防火墙配置。${NC}"
    fi
fi

# ==============================================================================
# 6. Swap 虚拟内存管理
# ==============================================================================
echo -e "\n${YELLOW}💾 [6/12] 虚拟内存管理 (Swap)${NC}"
SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
if [ -n "$SWAP_TOTAL" ] && [ "$SWAP_TOTAL" -gt 0 ]; then
    echo -e "${GREEN}✅ 系统已存在 Swap (${SWAP_TOTAL}MB)，无需重复创建。${NC}"
else
    read -p "❓ 是否创建 2GB Swap 虚拟内存 (防内存耗尽死机)？[Y/n]: " create_swap </dev/tty
    if [[ ! "$create_swap" =~ ^[Nn]$ ]]; then
        if [ ! -f /swapfile ]; then
            echo -e "${YELLOW}📦 正在分配 2GB Swap 空间...${NC}"
            fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null
            swapon /swapfile 2>/dev/null || true
            if ! grep -q '/swapfile' /etc/fstab; then
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
            fi
            echo -e "${GREEN}✅ 2GB Swap 已成功挂载并写入开机引导！${NC}"
        fi
    fi
fi

# ==============================================================================
# 7. Docker 引擎安装 (纯净官方原生通道 + 网络抖动自动重试)
# ==============================================================================
echo -e "\n${YELLOW}🐳 [7/12] 容器引擎 (Docker)${NC}"
if command -v docker &> /dev/null; then
    echo -e "${GREEN}✅ Docker 官方引擎已安装，跳过。${NC}"
else
    read -p "❓ 是否安装 Docker 官方容器引擎？[Y/n]: " install_docker </dev/tty
    if [[ ! "$install_docker" =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}📡 正在从 Docker 官方拉取最新部署脚本...${NC}"
        
        # 使用 --retry 2 应对偶发性握手阻断，--connect-timeout 限制超时
        curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 10 https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null || true
        
        # 严格非空检查
        if [ -s /tmp/get-docker.sh ]; then
            sh /tmp/get-docker.sh
            rm -f /tmp/get-docker.sh
        else
            echo -e "${RED}❌ Docker 官方脚本下载失败！${NC}"
            echo -e "${YELLOW}💡 提示: 若外网偶发断流，请先退出执行 proxy 打开代理，再重新执行安装。${NC}"
        fi

        # 校验安装成果并授权
        if command -v docker &> /dev/null; then
            groupadd docker 2>/dev/null || true
            usermod -aG docker "$ACTUAL_USER"
            systemctl enable docker --now 2>/dev/null || true
            echo -e "${GREEN}✅ Docker 官方引擎安装完成！已将用户 $ACTUAL_USER 加入授权组。${NC}"
            echo -e "${YELLOW}💡 提示: 免 sudo 权限将在下次登录或执行 newgrp docker 后生效。${NC}"
        fi
    else
        echo -e "${YELLOW}⏭️ 已跳过 Docker 安装。${NC}"
    fi
fi

# ==============================================================================
# 8. 终端体验美化 (Zsh + Oh-My-Zsh)
# ==============================================================================
echo -e "\n${YELLOW}✨ [8/12] 终端体验美化 (Zsh + 插件)${NC}"
if [ -d "$USER_HOME/.oh-my-zsh" ]; then
    echo -e "${GREEN}✅ Oh-My-Zsh 环境已存在，跳过。${NC}"
else
    read -p "❓ 是否为 [$ACTUAL_USER] 安装 Oh-My-Zsh 终端环境？[Y/n]: " config_zsh </dev/tty
    if [[ ! "$config_zsh" =~ ^[Nn]$ ]]; then
        chsh -s "$(which zsh)" "$ACTUAL_USER" 2>/dev/null || true

        sudo -u "$ACTUAL_USER" -H bash -c "
            if [ ! -d \"$USER_HOME/.oh-my-zsh\" ]; then
                RUNZSH=no sh -c \"\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\" \"\" --unattended
            fi
        "

        ZSH_CUSTOM="$USER_HOME/.oh-my-zsh/custom"
        sudo -u "$ACTUAL_USER" -H bash -c "
            git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM}/plugins/zsh-autosuggestions 2>/dev/null || true
            git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting 2>/dev/null || true
            if [ -f \"$USER_HOME/.zshrc\" ]; then
                sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/g' \"$USER_HOME/.zshrc\"
            fi
        "
        echo -e "${GREEN}✅ Zsh 终端及自动补全、高亮插件安装完成。${NC}"
    fi
fi

# ==============================================================================
# 9. 前端开发环境 (默认跳过)
# ==============================================================================
echo -e "\n${YELLOW}🟩 [9/12] 前端开发环境 (Node.js/pnpm)${NC}"
read -p "❓ 是否安装 Node.js LTS 与 pnpm？[y/N]: " install_node </dev/tty
if [[ "$install_node" =~ ^[Yy]$ ]]; then
    sudo -u "$ACTUAL_USER" -H bash -c '
        export NVM_DIR="$HOME/.nvm"
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        nvm install --lts
        nvm use --lts
        npm install -g pnpm
    '
    echo -e "${GREEN}✅ Node.js 与 pnpm 安装完毕。${NC}"
else
    echo -e "${YELLOW}⏭️ 已跳过前端环境配置。${NC}"
fi

# ==============================================================================
# 10. Python 开发环境 (默认跳过)
# ==============================================================================
echo -e "\n${YELLOW}🐍 [10/12] 后端开发环境 (Python / uv)${NC}"
read -p "❓ 是否安装 Python uv 开发环境？[y/N]: " install_py </dev/tty
if [[ "$install_py" =~ ^[Yy]$ ]]; then
    sudo -u "$ACTUAL_USER" -H bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
    if [ -f "$USER_HOME/.local/bin/uv" ]; then
        ln -sf "$USER_HOME/.local/bin/uv" /usr/local/bin/uv
        ln -sf "$USER_HOME/.local/bin/uvx" /usr/local/bin/uvx
    fi
    sudo -u "$ACTUAL_USER" -H /usr/local/bin/uv python install 3.12
    echo -e "${GREEN}✅ uv 及 Python 3.12 准备就绪。${NC}"
else
    echo -e "${YELLOW}⏭️ 已跳过 Python 环境配置。${NC}"
fi

# ==============================================================================
# 11. 终端快捷网络开关 (proxy / unproxy)
# ==============================================================================
echo -e "\n${YELLOW}🔌 [11/12] 终端代理快捷命令配置${NC}"
read -p "❓ 是否配置终端 proxy/unproxy 快捷别名？[Y/n]: " setup_proxy </dev/tty
if [[ ! "$setup_proxy" =~ ^[Nn]$ ]]; then
    read -p "🔗 请输入代理连接地址 (例如 http://192.168.31.227:20172): " proxy_url </dev/tty
    if [ -n "$proxy_url" ]; then
        proxy_url=$(echo "$proxy_url" | tr -d '\r\n ' | sed 's/[^a-zA-Z0-9.:/_-]//g')
        
        PROXY_SNIPPET="
# --- Quick Proxy Switch ---
alias proxy=\"export http_proxy='$proxy_url' https_proxy='$proxy_url' all_proxy='$proxy_url' && echo '🟢 代理已开启 ($proxy_url)'\"
alias unproxy=\"unset http_proxy https_proxy all_proxy && echo '🟡 代理已关闭'\""

        for file in "$USER_HOME/.bashrc" "$USER_HOME/.zshrc"; do
            if [ -f "$file" ]; then
                sed -i '/Quick Proxy Switch/,+2d' "$file"
                echo "$PROXY_SNIPPET" >> "$file"
            fi
        done
        echo -e "${GREEN}✅ 别名配置完成！以后输入 proxy 即可开代理，输入 unproxy 即可关代理。${NC}"
    fi
fi

# ==============================================================================
# 12. 系统垃圾清理 (仅清理陈旧孤立缓存，保护存储介质)
# ==============================================================================
echo -e "\n${YELLOW}🧹 [12/12] 系统环境清理与瘦身...${NC}"
apt-get autoremove -y --purge >/dev/null 2>&1
apt-get autoclean -y >/dev/null 2>&1
apt-get clean -y >/dev/null 2>&1
journalctl --vacuum-size=50M >/dev/null 2>&1

# 仅清理超过 1 天的旧临时文件，绝不误删运行中的进程通信 socket
find /tmp -mindepth 1 -maxdepth 2 -mtime +1 -delete 2>/dev/null || true
find /var/tmp -mindepth 1 -maxdepth 2 -mtime +1 -delete 2>/dev/null || true
systemd-tmpfiles --clean 2>/dev/null || true

rm -rf "$USER_HOME/.cache" /root/.cache >/dev/null 2>&1
echo -e "${GREEN}✅ 系统清理完毕。${NC}"

# ==============================================================================
# 结束提示
# ==============================================================================
echo -e "\n${BLUE}=================================================${NC}"
echo -e "${GREEN}🎉 Debian 初始化流程全部顺利完成！🎉${NC}"
echo -e "${YELLOW}👉 请注销或断开当前终端，使用【 $ACTUAL_USER 】重新连接。${NC}"
echo -e "${YELLOW}👉 重新登录后，可直接输入 docker ps 测试免 sudo 权限。${NC}"
echo -e "${BLUE}=================================================${NC}"
