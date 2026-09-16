#!/bin/bash
# ==============================================================================
# 脚本名称: Debian 全能初始化脚本 (生产稳定版)
# 适用系统: Debian 11 / Debian 12 / Debian 13 (Trixie) / Ubuntu
# 特点: 零残留、自动代理穿透、Debian 13 架构兼容、输入重定向安全防护
# ==============================================================================

set -u

# --- 终端颜色常量 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=================================================${NC}"
echo -e "${GREEN}  🚀 欢迎使用 Debian 全能初始化脚本 (稳定版) 🚀  ${NC}"
echo -e "${BLUE}=================================================${NC}"

# 1. 权限预检：必须拥有 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 错误: 请使用 sudo 权限运行此脚本！${NC}"
    echo -e "💡 推荐命令: sudo bash -c \"\$(curl -fsSL <URL>)\""
    exit 1
fi

# 避免 apt 弹出交互式配置弹窗
export DEBIAN_FRONTEND=noninteractive

# 2. 精准定位真实日常账户与家目录
ACTUAL_USER=${SUDO_USER:-$(logname 2>/dev/null || whoami)}
USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    USER_HOME="/root"
fi

# ==============================================================================
# 🚀 代理智能捕获与全局临时穿透引擎
# ==============================================================================
DETECTED_PROXY=""

# A. 优先捕获父环境中的代理变量 (如果使用了 sudo -E)
if [ -n "${http_proxy:-}" ]; then
    DETECTED_PROXY="$http_proxy"
elif [ -n "${HTTP_PROXY:-}" ]; then
    DETECTED_PROXY="$HTTP_PROXY"
fi

# B. 如果当前为空，深度解析调用者账户已有的 bashrc/zshrc (捕获之前配置过的 proxy alias)
if [ -z "$DETECTED_PROXY" ] && [ "$ACTUAL_USER" != "root" ]; then
    for rc_file in "$USER_HOME/.bashrc" "$USER_HOME/.zshrc"; do
        if [ -f "$rc_file" ]; then
            PARSED_PROXY=$(grep -oE "http_proxy=['\"][^'\"]+['\"]" "$rc_file" 2>/dev/null | head -n 1 | cut -d"'" -f2 | cut -d'"' -f2)
            if [ -n "$PARSED_PROXY" ]; then
                DETECTED_PROXY="$PARSED_PROXY"
                break
            fi
            PARSED_PROXY=$(grep -oE "[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+" "$rc_file" 2>/dev/null | head -n 1)
            if [ -n "$PARSED_PROXY" ]; then
                DETECTED_PROXY="http://$PARSED_PROXY"
                break
            fi
        fi
    done
fi

# C. 注入临时全局代理通道
if [ -n "$DETECTED_PROXY" ]; then
    DETECTED_PROXY=$(echo "$DETECTED_PROXY" | tr -d '\r\n ' | sed 's/[^a-zA-Z0-9.:/_-]//g')
    
    export http_proxy="$DETECTED_PROXY"
    export https_proxy="$DETECTED_PROXY"
    export all_proxy="$DETECTED_PROXY"
    export HTTP_PROXY="$DETECTED_PROXY"
    export HTTPS_PROXY="$DETECTED_PROXY"
    export ALL_PROXY="$DETECTED_PROXY"

    echo -e "${GREEN}✨ [检测成功] 已自动穿透并挂载内网代理: $DETECTED_PROXY${NC}"

    # 临时注入 APT
    echo "Acquire::http::Proxy \"$DETECTED_PROXY\";" > /etc/apt/apt.conf.d/99temp-proxy
    echo "Acquire::https::Proxy \"$DETECTED_PROXY\";" >> /etc/apt/apt.conf.d/99temp-proxy
    
    # 临时注入 cURL
    echo "proxy = \"$DETECTED_PROXY\"" > /root/.curlrc
    echo "proxy = \"$DETECTED_PROXY\"" > "$USER_HOME/.curlrc"
    chown "$ACTUAL_USER":"$ACTUAL_USER" "$USER_HOME/.curlrc" 2>/dev/null || true

    # 临时注入 Git
    git config --global http.proxy "$DETECTED_PROXY" 2>/dev/null || true
    git config --global https.proxy "$DETECTED_PROXY" 2>/dev/null || true
else
    echo -e "${YELLOW}ℹ️ 未检测到活动的代理配置，将使用原生直连网络。${NC}"
fi

# D. 退出清理钩子：脚本结束或中断时，秒级物理擦除临时网络配置
cleanup_temp_proxy() {
    echo -e "\n${YELLOW}🧹 正在物理恢复系统原生网络环境，清理临时凭据...${NC}"
    rm -f /etc/apt/apt.conf.d/99temp-proxy
    rm -f /root/.curlrc
    rm -f "$USER_HOME/.curlrc"
    git config --global --unset http.proxy 2>/dev/null || true
    git config --global --unset https.proxy 2>/dev/null || true
}
trap cleanup_temp_proxy EXIT INT TERM

# ==============================================================================
# 0. 基础包更新保障
# ==============================================================================
apt-get update -q && apt-get install -y -q sudo

# ==============================================================================
# 1. 账户安全与 SSH 配置
# ==============================================================================
echo -e "\n${YELLOW}🔐 [1/12] 账户与安全设置${NC}"

if [ "$ACTUAL_USER" = "root" ]; then
    echo -e "${YELLOW}⚠️ 检测到您当前直接以 root 账户执行！${NC}"
    read -p "❓ 是否新建一个日常普通账户 (自动加入 sudo 组)？[Y/n]: " create_new_user </dev/tty
    if [[ ! "$create_new_user" =~ ^[Nn]$ ]]; then
        read -p "👤 请输入新用户的用户名: " new_username </dev/tty
        if [ -n "$new_username" ] && ! id "$new_username" &>/dev/null; then
            echo -e "${YELLOW}🔑 正在创建用户 $new_username，请按提示为其设置密码：${NC}"
            adduser --gecos "" "$new_username"
            usermod -aG sudo "$new_username"
            
            ACTUAL_USER="$new_username"
            USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
            echo -e "${GREEN}✅ 用户 $new_username 创建完毕并已授权 sudo。${NC}"
        fi
    fi
else
    echo -e "${GREEN}✅ 当前操作者为普通账户 ($ACTUAL_USER)，配置将针对其家目录执行。${NC}"
fi

echo -e "👤 目标生效用户: ${GREEN}$ACTUAL_USER${NC} | 目标家目录: ${GREEN}$USER_HOME${NC}"
cd "$USER_HOME" || cd /tmp

# 确保配置文件存在
sudo -u "$ACTUAL_USER" -H touch "$USER_HOME/.zshrc" "$USER_HOME/.bashrc"

# 1.5 交互式配置 SSH 公钥
if [ -s "$USER_HOME/.ssh/authorized_keys" ]; then
    echo -e "${GREEN}✅ 账户 $ACTUAL_USER 已配置 SSH 公钥，跳过配置。${NC}"
else
    read -p "❓ 是否为账户 [$ACTUAL_USER] 配置 SSH 公钥登录？[Y/n]: " setup_ssh_key </dev/tty
    if [[ ! "$setup_ssh_key" =~ ^[Nn]$ ]]; then
        read -r -p "📝 请在此处粘贴您的 SSH 公钥: " ssh_pub_key </dev/tty
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

# 1.6 禁用 Root 远程登录 (兼容 Debian 12/13 与 sshd_config.d)
if [ "$ACTUAL_USER" != "root" ]; then
    read -p "❓ 是否禁用 Root 远程 SSH 登录？(家庭服务器可选) [y/N]: " disable_root </dev/tty
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
            echo -e "${RED}⚠️ SSH 配置检测失败！已自动回滚，未做更改。${NC}"
            rm -f /etc/ssh/sshd_config.d/99-disable-root.conf 2>/dev/null
        fi
    else
        echo -e "${YELLOW}⏭️ 已保留 Root 远程登录权限。${NC}"
    fi
fi

# ==============================================================================
# 2. 核心必备运维工具 (已彻底剔除无效依赖)
# ==============================================================================
echo -e "\n${YELLOW}📦 [2/12] 正在更新系统并安装核心必备工具...${NC}"
apt-get upgrade -y -q
# 仅保留纯净、核心的工具，绝不因多余包名阻断流程
apt-get install -y -q curl wget git nano htop zsh unzip tmux jq ca-certificates

# ==============================================================================
# 3. TCP BBR 加速 (完美适配 Debian 12/13 sysctl.d 模块化机制)
# ==============================================================================
echo -e "\n${YELLOW}🌐 [3/12] 网络拥塞控制 (TCP BBR 加速)${NC}"
if grep -qEi "(Microsoft|WSL)" /proc/version 2>/dev/null; then
    echo -e "${GREEN}💻 检测到 WSL 环境，自动跳过 BBR 配置。${NC}"
elif sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
    echo -e "${GREEN}✅ BBR 拥塞控制已经生效，跳过配置。${NC}"
else
    read -p "❓ 是否开启 BBR 加速？(家庭 Wi-Fi 及远程访问抗丢包神器) [Y/n]: " enable_bbr </dev/tty
    if [[ ! "$enable_bbr" =~ ^[Nn]$ ]]; then
        mkdir -p /etc/sysctl.d
        cat << 'EOF' > /etc/sysctl.d/99-bbr.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
        # 兼容性重载配置
        sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-bbr.conf 2>/dev/null || true
        echo -e "${GREEN}✅ BBR 加速配置完毕并已成功生效！${NC}"
    fi
fi

# ==============================================================================
# 4. 时区校验
# ==============================================================================
echo -e "\n${YELLOW}⏰ [4/12] 系统时区校验${NC}"
CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")
if [ "$CURRENT_TZ" = "Asia/Shanghai" ]; then
    echo -e "${GREEN}✅ 系统时区已经是 Asia/Shanghai，跳过。${NC}"
else
    read -p "❓ 是否将系统时区修改为 Asia/Shanghai (北京时间)？[Y/n]: " set_tz </dev/tty
    if [[ ! "$set_tz" =~ ^[Nn]$ ]]; then
        timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
        echo -e "${GREEN}✅ 系统时区已调整为: $(date)${NC}"
    fi
fi

# ==============================================================================
# 5. 防火墙与防爆破 (UFW & Fail2ban)
# ==============================================================================
echo -e "\n${YELLOW}🛡️ [5/12] 防火墙配置 (UFW & Fail2ban)${NC}"
if grep -qEi "(Microsoft|WSL)" /proc/version 2>/dev/null; then
    echo -e "${GREEN}💻 WSL 环境，自动跳过防火墙配置。${NC}"
else
    read -p "❓ 是否配置 UFW 防火墙与 Fail2ban？(家庭局域网服务器推荐跳过) [y/N]: " config_sec </dev/tty
    if [[ "$config_sec" =~ ^[Yy]$ ]]; then
        apt-get install -y -q ufw fail2ban
        systemctl enable fail2ban --now >/dev/null 2>&1

        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        ufw allow ssh >/dev/null 2>&1
        ufw allow 443/tcp >/dev/null 2>&1
        ufw allow 80/tcp >/dev/null 2>&1

        while true; do
            read -p "❓ 需要开放其他端口吗？(逗号分隔如 8080,9000，按 n 或回车跳过): " extra_ports </dev/tty
            if [[ "$extra_ports" =~ ^[Nn]$ ]] || [ -z "$extra_ports" ]; then
                break
            fi
            if [[ "$extra_ports" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                IFS=',' read -ra PORT_ARRAY <<< "$extra_ports"
                for port in "${PORT_ARRAY[@]}"; do
                    ufw allow "$port/tcp" >/dev/null 2>&1
                    echo -e "${GREEN}✅ 已放行端口: $port/tcp${NC}"
                done
                break
            else
                echo -e "${YELLOW}❌ 输入格式错误，请重新输入（如 8080,9000）${NC}"
            fi
        done

        ufw --force enable >/dev/null 2>&1
        echo -e "${GREEN}✅ UFW 防火墙已成功激活并开机自启。${NC}"
    else
        echo -e "${YELLOW}⏭️ 已跳过防火墙配置。${NC}"
    fi
fi

# ==============================================================================
# 6. Swap 虚拟内存 (智能容错机制)
# ==============================================================================
echo -e "\n${YELLOW}💾 [6/12] 虚拟内存管理 (Swap)${NC}"
SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
if [ -n "$SWAP_TOTAL" ] && [ "$SWAP_TOTAL" -gt 0 ]; then
    echo -e "${GREEN}✅ 系统已存在 Swap (${SWAP_TOTAL}MB)，无需配置。${NC}"
else
    read -p "❓ 是否创建 2GB Swap 虚拟内存？[Y/n]: " create_swap </dev/tty
    if [[ ! "$create_swap" =~ ^[Nn]$ ]]; then
        if [ ! -f /swapfile ]; then
            echo -e "${YELLOW}📦 正在分配 2GB Swap 虚拟内存...${NC}"
            fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null
            swapon /swapfile 2>/dev/null || true
            if ! grep -q '/swapfile' /etc/fstab; then
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
            fi
            echo -e "${GREEN}✅ 2GB Swap 已成功挂载并写入引导表！${NC}"
        fi
    fi
fi

# ==============================================================================
# 7. 容器环境 (Docker Engine - 修复假成功与超时重试)
# ==============================================================================
echo -e "\n${YELLOW}🐳 [7/12] 容器引擎 (Docker)${NC}"
if command -v docker &> /dev/null; then
    echo -e "${GREEN}✅ Docker 官方引擎已安装，跳过。${NC}"
else
    read -p "❓ 是否安装 Docker 官方容器引擎？[Y/n]: " install_docker </dev/tty
    if [[ ! "$install_docker" =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}📡 正在拉取 Docker 安装脚本...${NC}"
        
        # 尝试官方源下载
        curl -fsSL --connect-timeout 10 https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null || true
        
        # 严格检查：文件必须存在且体积大于 0（杜绝 0 字节假成功）
        if [ -s /tmp/get-docker.sh ]; then
            sh /tmp/get-docker.sh
            rm -f /tmp/get-docker.sh
        else
            echo -e "${YELLOW}⚠️ 官方直连由于网络原因超时，自动切换至阿里云国内镜像通道...${NC}"
            curl -fsSL --connect-timeout 10 https://get.docker.com | bash -s docker --mirror Aliyun
        fi
        
        # 核心防伪：二次验证命令实体是否存在
        if ! command -v docker &> /dev/null; then
            echo -e "${RED}❌ Docker 安装未能成功！${NC}"
            echo -e "${YELLOW}💡 原因排查: 国内网络直连 Docker 源超时。建议脚本跑完后，先执行 proxy 打开代理，再手动运行: curl -fsSL https://get.docker.com | bash${NC}"
        else
            groupadd docker 2>/dev/null || true
            usermod -aG docker "$ACTUAL_USER"
            systemctl enable docker --now 2>/dev/null || true
            echo -e "${GREEN}✅ Docker 官方引擎安装完成！已将用户 $ACTUAL_USER 纳入授权组。${NC}"
            echo -e "${YELLOW}💡 提示: 权限将在下次登录或执行 newgrp docker 后即刻生效。${NC}"
        fi
    fi
fi

# ==============================================================================
# 8. 终端环境美化 (Zsh + Oh-My-Zsh)
# ==============================================================================
echo -e "\n${YELLOW}✨ [8/12] 终端体验美化 (Zsh + 插件)${NC}"
if [ -d "$USER_HOME/.oh-my-zsh" ]; then
    echo -e "${GREEN}✅ Oh-My-Zsh 环境已存在，跳过。${NC}"
else
    read -p "❓ 是否为 [$ACTUAL_USER] 部署现代化 Zsh 终端体验？[Y/n]: " config_zsh </dev/tty
    if [[ ! "$config_zsh" =~ ^[Nn]$ ]]; then
        chsh -s "$(which zsh)" "$ACTUAL_USER" 2>/dev/null || true

        # 部署 Oh-My-Zsh
        sudo -u "$ACTUAL_USER" -H bash -c "
            if [ ! -d \"$USER_HOME/.oh-my-zsh\" ]; then
                RUNZSH=no sh -c \"\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\" \"\" --unattended
            fi
        "
        
        # 安装自动补全与高亮插件
        ZSH_CUSTOM="$USER_HOME/.oh-my-zsh/custom"
        sudo -u "$ACTUAL_USER" -H bash -c "
            git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM}/plugins/zsh-autosuggestions 2>/dev/null || true
            git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting 2>/dev/null || true
            if [ -f \"$USER_HOME/.zshrc\" ]; then
                sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/g' \"$USER_HOME/.zshrc\"
            fi
        "
        echo -e "${GREEN}✅ Zsh 终端及自动补全插件安装完毕。${NC}"
    fi
fi

# ==============================================================================
# 9. 前端开发环境 (默认跳过)
# ==============================================================================
echo -e "\n${YELLOW}🟩 [9/12] 前端运行时环境 (Node.js/pnpm)${NC}"
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
    echo -e "${GREEN}✅ Node.js 及 pnpm 部署成功。${NC}"
else
    echo -e "${YELLOW}⏭️ 已跳过前端环境配置。${NC}"
fi

# ==============================================================================
# 10. 后端开发环境 (默认跳过)
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
    echo -e "${GREEN}✅ Python uv 环境就绪。${NC}"
else
    echo -e "${YELLOW}⏭️ 已跳过 Python 环境配置。${NC}"
fi

# ==============================================================================
# 11. 快捷网络开关 (proxy / unproxy)
# ==============================================================================
echo -e "\n${YELLOW}🔌 [11/12] 终端快捷网络开关注入${NC}"
read -p "❓ 是否配置终端 proxy/unproxy 快捷开关？[Y/n]: " setup_proxy </dev/tty
if [[ ! "$setup_proxy" =~ ^[Nn]$ ]]; then
    # 优先展示当前探测到的代理地址作为默认推荐
    DEFAULT_PROXY=${DETECTED_PROXY:-"http://192.168.31.227:20172"}
    read -p "🔗 请输入代理地址 (默认: $DEFAULT_PROXY): " proxy_url </dev/tty
    proxy_url=${proxy_url:-"$DEFAULT_PROXY"}
    
    proxy_url=$(echo "$proxy_url" | tr -d '\r\n ' | sed 's/[^a-zA-Z0-9.:/_-]//g')
    
    PROXY_SNIPPET="
# --- Quick Proxy Switch ---
alias proxy=\"export http_proxy='$proxy_url' https_proxy='$proxy_url' all_proxy='$proxy_url' && echo '🟢 代理已开启 ($proxy_url)'\"
alias unproxy=\"unset http_proxy https_proxy all_proxy && echo '🟡 代理已关闭'\""

    for file in "$USER_HOME/.bashrc" "$USER_HOME/.zshrc"; do
        if [ -f "$file" ]; then
            # 先清理旧的 proxy alias，避免重复堆叠
            sed -i '/Quick Proxy Switch/,+2d' "$file"
            echo "$PROXY_SNIPPET" >> "$file"
        fi
    done
    echo -e "${GREEN}✅ 代理快捷指令 (proxy / unproxy) 已绑定完成！${NC}"
fi

# ==============================================================================
# 12. 系统垃圾清理 (保护 Flash 闪存，仅清理陈旧临时文件)
# ==============================================================================
echo -e "\n${YELLOW}🧹 [12/12] 深度系统瘦身与缓存清理...${NC}"
apt-get autoremove -y --purge >/dev/null 2>&1
apt-get autoclean -y >/dev/null 2>&1
apt-get clean -y >/dev/null 2>&1
journalctl --vacuum-size=50M >/dev/null 2>&1

# 安全清理旧日志
find /var/log -type f -regex '.*\.gz$' -delete >/dev/null 2>&1
find /var/log -type f -regex '.*\.[0-9]$' -delete >/dev/null 2>&1

# 安全清理超过 1 天的孤立临时文件 (绝不破坏活跃的 socket 与 PID 句柄)
find /tmp -mindepth 1 -maxdepth 2 -mtime +1 -delete 2>/dev/null || true
find /var/tmp -mindepth 1 -maxdepth 2 -mtime +1 -delete 2>/dev/null || true
systemd-tmpfiles --clean 2>/dev/null || true

# 清理缓存
rm -rf "$USER_HOME/.cache" /root/.cache >/dev/null 2>&1
echo -e "${GREEN}✅ 磁盘清理完成，系统已处于最轻盈状态。${NC}"

# ==============================================================================
# 结束引导
# ==============================================================================
echo -e "\n${BLUE}=================================================${NC}"
echo -e "${GREEN}🎉 Debian 初始化流程全部圆满结束！🎉${NC}"
echo -e "${YELLOW}👉 请断开当前连接并使用【 $ACTUAL_USER 】账户重新登录！${NC}"
echo -e "${YELLOW}👉 如果配置了 Docker，重新登录后即可直接运行 docker ps 免 sudo 验证。${NC}"
echo -e "${BLUE}=================================================${NC}"
