#!/bin/bash
# ==============================================================================
# 脚本名称: Debian 全能生产级初始化脚本 (生产稳定版)
# 适用系统: Debian 11 / Debian 12+ (兼容 Ubuntu / 兼容 WSL)
# 执行身份: 普通用户通过 sudo 执行 (例如: sudo bash init.sh)
# ==============================================================================

# 严格模式：遇到未定义变量报错（遇到部分兼容错误手动处理）
set -u

# --- 终端颜色常量 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=================================================${NC}"
echo -e "${GREEN}  🚀 欢迎使用 Debian 全能交互式初始化脚本 (稳定版) 🚀  ${NC}"
echo -e "${BLUE}=================================================${NC}"

# 1. 权限预检：必须拥有 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 错误: 请使用 sudo 权限运行此脚本！${NC}"
    echo -e "💡 推荐命令: sudo bash -c \"\$(curl -fsSL <URL>)\""
    exit 1
fi

# 非交互前端（避免 apt 弹出紫色的配置交互弹窗）
export DEBIAN_FRONTEND=noninteractive

# 2. 精准定位“凡人日常账户”与“对应家目录”
# 优先获取触发 sudo 的真实普通用户名，保底获取当前执行者
ACTUAL_USER=${SUDO_USER:-$(logname 2>/dev/null || whoami)}
USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    USER_HOME="/root"
fi

# ==============================================================================
# 🚀 代理智能捕获与全局临时穿透引擎
# 功能：如果宿主环境配有代理，自动无感穿透到 apt、curl、git 中，并在退出时秒级自毁
# ==============================================================================
DETECTED_PROXY=""

# A. 优先捕获父进程环境变量
if [ -n "${http_proxy:-}" ]; then
    DETECTED_PROXY="$http_proxy"
elif [ -n "${HTTP_PROXY:-}" ]; then
    DETECTED_PROXY="$HTTP_PROXY"
fi

# B. 如果父环境无代理且为普通用户，自动解析其 shell 配置文件 (.bashrc / .zshrc)
if [ -z "$DETECTED_PROXY" ] && [ "$ACTUAL_USER" != "root" ]; then
    for rc_file in "$USER_HOME/.bashrc" "$USER_HOME/.zshrc"; do
        if [ -f "$rc_file" ]; then
            PARSED_PROXY=$(grep -oE "http_proxy=['\"][^'\"]+['\"]" "$rc_file" 2>/dev/null | head -n 1 | cut -d"'" -f2 | cut -d'"' -f2)
            if [ -n "$PARSED_PROXY" ]; then
                DETECTED_PROXY="$PARSED_PROXY"
                break
            fi
            # 备用：匹配 IP:PORT 格式
            PARSED_PROXY=$(grep -oE "[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+" "$rc_file" 2>/dev/null | head -n 1)
            if [ -n "$PARSED_PROXY" ]; then
                DETECTED_PROXY="http://$PARSED_PROXY"
                break
            fi
        fi
    done
fi

# C. 注入临时代理到系统各个通道
if [ -n "$DETECTED_PROXY" ]; then
    # 彻底洗净不可见字符与回车
    DETECTED_PROXY=$(echo "$DETECTED_PROXY" | tr -d '\r\n ' | sed 's/[^a-zA-Z0-9.:/_-]//g')
    
    export http_proxy="$DETECTED_PROXY"
    export https_proxy="$DETECTED_PROXY"
    export all_proxy="$DETECTED_PROXY"
    export HTTP_PROXY="$DETECTED_PROXY"
    export HTTPS_PROXY="$DETECTED_PROXY"
    export ALL_PROXY="$DETECTED_PROXY"

    echo -e "${GREEN}✨ [检测成功] 已自动穿透并继承凡人账户代理: $DETECTED_PROXY${NC}"

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

# D. 退出钩子：脚本无论正常结束还是中断 (Ctrl+C)，物理擦除临时注入，不留残留
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
# 0. 底层环境保底
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
            echo -e "${YELLOW}🔑 正在创建用户 $new_username，请按提示设置其密码：${NC}"
            adduser --gecos "" "$new_username"
            usermod -aG sudo "$new_username"
            
            ACTUAL_USER="$new_username"
            USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
            echo -e "${GREEN}✅ 用户 $new_username 创建完毕并已授权 sudo。${NC}"
        fi
    fi
else
    echo -e "${GREEN}✅ 当前操作者为普通账户 ($ACTUAL_USER)，环境配置将针对其家目录执行。${NC}"
fi

echo -e "👤 目标生效用户: ${GREEN}$ACTUAL_USER${NC} | 目标家目录: ${GREEN}$USER_HOME${NC}"
cd "$USER_HOME" || cd /tmp

# 确保目标用户的配置文件实体存在
sudo -u "$ACTUAL_USER" -H touch "$USER_HOME/.zshrc" "$USER_HOME/.bashrc"

# 1.5 交互式配置 SSH 公钥
SSH_KEY_CONFIGURED=false
if [ -s "$USER_HOME/.ssh/authorized_keys" ]; then
    echo -e "${GREEN}✅ 账户 $ACTUAL_USER 已存在配置好的 SSH 公钥，跳过配置。${NC}"
    SSH_KEY_CONFIGURED=true
else
    read -p "❓ 是否为目标账户 [$ACTUAL_USER] 粘贴并配置 SSH 公钥？[Y/n]: " setup_ssh_key </dev/tty
    if [[ ! "$setup_ssh_key" =~ ^[Nn]$ ]]; then
        read -r -p "📝 请粘贴您的公钥 (例如 ssh-ed25519 或 ssh-rsa 开头): " ssh_pub_key </dev/tty
        if [ -n "$ssh_pub_key" ]; then
            mkdir -p "$USER_HOME/.ssh"
            echo "$ssh_pub_key" >> "$USER_HOME/.ssh/authorized_keys"
            chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$USER_HOME/.ssh"
            chmod 700 "$USER_HOME/.ssh"
            chmod 600 "$USER_HOME/.ssh/authorized_keys"
            echo -e "${GREEN}✅ SSH 公钥已成功录入！${NC}"
            SSH_KEY_CONFIGURED=true
        fi
    fi
fi

# 1.6 禁用 Root 远程登录 (安全防锁机制 + Debian 12 兼容)
if [ "$ACTUAL_USER" != "root" ]; then
    read -p "❓ 是否禁用 Root 远程 SSH 登录？(强化安全防爆破) [y/N]: " disable_root </dev/tty
    if [[ "$disable_root" =~ ^[Yy]$ ]]; then
        # 兼容 Debian 12+ 的 sshd_config.d 子配置目录
        if [ -d "/etc/ssh/sshd_config.d" ]; then
            echo "PermitRootLogin no" > /etc/ssh/sshd_config.d/99-disable-root.conf
        else
            sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
        fi

        # 安全语法预检，避免 ssh 配置写炸导致失联
        if sshd -t 2>/dev/null; then
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
            echo -e "${GREEN}🛡️ Root 远程登录已安全封禁。${NC}"
        else
            echo -e "${RED}⚠️ SSH 配置检测失败！为防失联，已自动撤销更改。${NC}"
            rm -f /etc/ssh/sshd_config.d/99-disable-root.conf 2>/dev/null
        fi
    else
        echo -e "${YELLOW}⏭️ 已保留 Root 远程登录权限。${NC}"
    fi
fi

# ==============================================================================
# 2. 基础系统工具
# ==============================================================================
echo -e "\n${YELLOW}📦 [2/12] 正在更新系统索引并安装基础运维工具...${NC}"
apt-get upgrade -y -q
apt-get install -y -q curl wget git nano htop zsh unzip tmux jq ca-certificates software-properties-common

# ==============================================================================
# 3. 网络拥塞控制 (BBR)
# ==============================================================================
echo -e "\n${YELLOW}🌐 [3/12] 网络优化 (TCP BBR 加速)${NC}"
if grep -qEi "(Microsoft|WSL)" /proc/version 2>/dev/null; then
    echo -e "${GREEN}💻 WSL 环境，网络栈由 Windows 宿主机内核掌管，自动跳过。${NC}"
elif sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo -e "${GREEN}✅ BBR 拥塞控制已经在运行中，跳过。${NC}"
else
    read -p "❓ 是否开启 BBR TCP 加速算法？[Y/n]: " enable_bbr </dev/tty
    if [[ ! "$enable_bbr" =~ ^[Nn]$ ]]; then
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p 2>/dev/null || true
        echo -e "${GREEN}✅ BBR 加速已成功激活！${NC}"
    fi
fi

# ==============================================================================
# 4. 时区同步
# ==============================================================================
echo -e "\n${YELLOW}⏰ [4/12] 时区配置${NC}"
CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")
if [ "$CURRENT_TZ" = "Asia/Shanghai" ]; then
    echo -e "${GREEN}✅ 系统时区已是 Asia/Shanghai，跳过。${NC}"
else
    read -p "❓ 是否将时区设置为 Asia/Shanghai (北京时间)？[Y/n]: " set_tz </dev/tty
    if [[ ! "$set_tz" =~ ^[Nn]$ ]]; then
        timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
        echo -e "${GREEN}✅ 系统时区更新完成: $(date)${NC}"
    fi
fi

# ==============================================================================
# 5. 防火墙与防爆破 (UFW & Fail2ban)
# ==============================================================================
echo -e "\n${YELLOW}🛡️ [5/12] 防火墙配置 (UFW & Fail2ban)${NC}"
if grep -qEi "(Microsoft|WSL)" /proc/version 2>/dev/null; then
    echo -e "${GREEN}💻 WSL 环境，自动跳过防火墙安装。${NC}"
else
    read -p "❓ 是否配置 UFW 防火墙与 Fail2ban 防爆破服务 (局域网设备建议跳过)？[Y/n]: " config_sec </dev/tty
    if [[ ! "$config_sec" =~ ^[Nn]$ ]]; then
        apt-get install -y -q ufw fail2ban
        
        systemctl enable fail2ban --now >/dev/null 2>&1
        echo -e "${GREEN}✅ Fail2ban (防暴力破解) 启动完成并常驻后台。${NC}"

        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        ufw allow ssh >/dev/null 2>&1
        ufw allow 443/tcp >/dev/null 2>&1
        ufw allow 80/tcp >/dev/null 2>&1
        echo -e "${GREEN}✅ 默认放行核心端口: SSH, 80(HTTP), 443(HTTPS)。${NC}"

        while true; do
            read -p "❓ 是否需要开放其他端口？(逗号隔开，如 8080,9000，按 n 或回车跳过): " extra_ports </dev/tty
            if [[ "$extra_ports" =~ ^[Nn]$ ]] || [ -z "$extra_ports" ]; then
                break
            fi
            if [[ "$extra_ports" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                IFS=',' read -ra PORT_ARRAY <<< "$extra_ports"
                for port in "${PORT_ARRAY[@]}"; do
                    ufw allow "$port/tcp" >/dev/null 2>&1
                    echo -e "${GREEN}✅ 额外放行端口: $port/tcp${NC}"
                done
                break
            else
                echo -e "${YELLOW}❌ 输入格式有误，请重新输入（如 8080,9000）${NC}"
            fi
        done

        ufw --force enable >/dev/null 2>&1
        echo -e "${GREEN}✅ UFW 防火墙已生效并开启自启。${NC}"
    fi
fi

# ==============================================================================
# 6. Swap 虚拟内存 (防 OOM 崩溃)
# ==============================================================================
echo -e "\n${YELLOW}💾 [6/12] 虚拟内存管理 (Swap)${NC}"
SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
if [ -n "$SWAP_TOTAL" ] && [ "$SWAP_TOTAL" -gt 0 ]; then
    echo -e "${GREEN}✅ 系统已存在 Swap (${SWAP_TOTAL}MB)，无需创建。${NC}"
else
    read -p "❓ 是否创建 2GB Swap 虚拟内存 (低内存服务器强烈建议)？[Y/n]: " create_swap </dev/tty
    if [[ ! "$create_swap" =~ ^[Nn]$ ]]; then
        if [ ! -f /swapfile ]; then
            echo -e "${YELLOW}📦 正在分配 2GB Swap 空间...${NC}"
            # 兼容性分配：优先 fallocate，遇非连续存储或 Btrfs 自动退避至 dd
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
# 7. 容器环境 (Docker Engine)
# ==============================================================================
echo -e "\n${YELLOW}🐳 [7/12] 容器引擎 (Docker)${NC}"
if command -v docker &> /dev/null; then
    echo -e "${GREEN}✅ Docker 官方引擎已安装，跳过。${NC}"
else
    read -p "❓ 是否安装 Docker 官方容器引擎？[Y/n]: " install_docker </dev/tty
    if [[ ! "$install_docker" =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}📡 正在通过 Docker 官方自动化脚本部署...${NC}"
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        
        if [ -f /tmp/get-docker.sh ]; then
            sh /tmp/get-docker.sh
            rm -f /tmp/get-docker.sh
        else
            echo -e "${YELLOW}⚠️ 直连下载失败，尝试镜像通道部署...${NC}"
            curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
        fi
        
        # 授权目标普通用户加入 docker 组
        groupadd docker 2>/dev/null || true
        usermod -aG docker "$ACTUAL_USER"
        systemctl enable docker --now 2>/dev/null || true
        
        echo -e "${GREEN}✅ Docker 安装完成！已自动将用户 $ACTUAL_USER 纳入授权组。${NC}"
        echo -e "${YELLOW}💡 提示: 组权限生效需重新登录或在终端执行: newgrp docker${NC}"
    fi
fi

# ==============================================================================
# 8. 终端环境美化 (Zsh + Oh-My-Zsh + 实用插件 + Oh-My-Posh)
# ==============================================================================
echo -e "\n${YELLOW}✨ [8/12] 终端美化 (Zsh + Oh-My-Zsh)${NC}"
if [ -d "$USER_HOME/.oh-my-zsh" ] && grep -q "oh-my-posh" "$USER_HOME/.zshrc" 2>/dev/null; then
    echo -e "${GREEN}✅ Zsh 终端美化已存在，跳过。${NC}"
else
    read -p "❓ 是否为 [$ACTUAL_USER] 部署现代化 Zsh 终端体验？[Y/n]: " config_zsh </dev/tty
    if [[ ! "$config_zsh" =~ ^[Nn]$ ]]; then
        # 修改默认 Shell 为 zsh
        chsh -s "$(which zsh)" "$ACTUAL_USER" 2>/dev/null || true

        # 部署 Oh-My-Zsh
        sudo -u "$ACTUAL_USER" -H bash -c "
            if [ ! -d \"$USER_HOME/.oh-my-zsh\" ]; then
                RUNZSH=no sh -c \"\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\" \"\" --unattended
            fi
        "
        
        # 安装官方高频生产插件
        ZSH_CUSTOM="$USER_HOME/.oh-my-zsh/custom"
        sudo -u "$ACTUAL_USER" -H bash -c "
            git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM}/plugins/zsh-autosuggestions 2>/dev/null || true
            git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting 2>/dev/null || true
            if [ -f \"$USER_HOME/.zshrc\" ]; then
                sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/g' \"$USER_HOME/.zshrc\"
            fi
        "
        
        # 部署 Oh-My-Posh 渲染引擎
        curl -s https://ohmyposh.dev/install.sh | bash -s -- -d /usr/local/bin
        
        sudo -u "$ACTUAL_USER" -H bash -c "
            curl -fsSL https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/jandedobbeleer.omp.json -o \"$USER_HOME/.mytheme.omp.json\" 2>/dev/null || true
            if [ -f \"$USER_HOME/.zshrc\" ]; then
                sed -i 's/^ZSH_THEME=.*/ZSH_THEME=\"\"/g' \"$USER_HOME/.zshrc\"
                if ! grep -q \"oh-my-posh init zsh\" \"$USER_HOME/.zshrc\"; then
                    echo 'eval \"\$(oh-my-posh init zsh --config ~/.mytheme.omp.json)\"' >> \"$USER_HOME/.zshrc\"
                fi
            fi
        "
        echo -e "${GREEN}✅ Zsh 终端美化与高频插件安装完毕。${NC}"
    fi
fi

# ==============================================================================
# 9. 前端环境 (Node.js & NVM)
# ==============================================================================
echo -e "\n${YELLOW}🟩 [9/12] 前端运行时环境 (Node.js/pnpm)${NC}"
if [ -d "$USER_HOME/.nvm" ]; then
    echo -e "${GREEN}✅ NVM 及 Node.js 已安装，跳过。${NC}"
else
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
        echo -e "${GREEN}✅ Node.js LTS 及 pnpm 部署成功。${NC}"
    else
        echo -e "${YELLOW}⏭️ 已跳过 Node.js 环境配置。${NC}"
    fi
fi

# ==============================================================================
# 10. Python 生产环境 (uv / Miniconda)
# ==============================================================================
echo -e "\n${YELLOW}🐍 [10/12] 后端开发环境 (uv / Miniconda)${NC}"
if [ -f "$USER_HOME/.local/bin/uv" ] || [ -f "/usr/local/bin/uv" ] || [ -d "$USER_HOME/miniconda3" ]; then
    echo -e "${GREEN}✅ Python 环境管理套件已存在，跳过。${NC}"
else
    echo -e "💡 架构提示：现代工程更推荐使用 Rust 构建的 ${GREEN}uv${NC} 工具链，毫秒级冷启动。"
    read -p "❓ 请选择安装组件 [1] uv (轻量高速) / [2] Miniconda / [3] 跳过 (默认 3): " py_choice </dev/tty
    py_choice=${py_choice:-3}

    if [ "$py_choice" = "1" ]; then
        echo -e "${YELLOW}📦 正在为 $ACTUAL_USER 快速部署 uv...${NC}"
        sudo -u "$ACTUAL_USER" -H bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
        
        # 建立全局系统软链接，避免不同 Shell 找不到 uv
        if [ -f "$USER_HOME/.local/bin/uv" ]; then
            ln -sf "$USER_HOME/.local/bin/uv" /usr/local/bin/uv
            ln -sf "$USER_HOME/.local/bin/uvx" /usr/local/bin/uvx
        fi
        
        echo -e "${YELLOW}📦 正在通过 uv 部署预构建的 Python 3.12 运行时...${NC}"
        sudo -u "$ACTUAL_USER" -H /usr/local/bin/uv python install 3.12
        echo -e "${GREEN}✅ uv 架构准备就绪，已关联 Python 3.12。${NC}"
        
    elif [ "$py_choice" = "2" ]; then
        ARCH=$(uname -m)
        CONDA_URL=""
        if [ "$ARCH" = "x86_64" ]; then
            CONDA_URL="https://repo.continuum.io/miniconda/Miniconda3-latest-Linux-x86_64.sh"
        elif [ "$ARCH" = "aarch64" ]; then
            CONDA_URL="https://repo.continuum.io/miniconda/Miniconda3-latest-Linux-aarch64.sh"
        fi

        if [ -n "$CONDA_URL" ]; then
            sudo -u "$ACTUAL_USER" -H bash -c "
                wget $CONDA_URL -O /tmp/miniconda.sh
                bash /tmp/miniconda.sh -b -p \"$USER_HOME/miniconda3\"
                \"$USER_HOME/miniconda3/bin/conda\" init bash
                \"$USER_HOME/miniconda3/bin/conda\" init zsh
                rm -f /tmp/miniconda.sh
            "
            echo -e "${GREEN}✅ Miniconda 安装完毕。${NC}"
        else
            echo -e "${YELLOW}⚠️ 当前架构 ($ARCH) 暂无匹配 Conda 安装包，已跳过。${NC}"
        fi
    else
        echo -e "${YELLOW}⏭️ 已跳过 Python 环境配置。${NC}"
    fi
fi

# ==============================================================================
# 11. 终端网络代理快捷开关注入 (proxy / unproxy)
# ==============================================================================
echo -e "\n${YELLOW}🔌 [11/12] 终端快捷网络开关配置${NC}"
if grep -q 'alias proxy=' "$USER_HOME/.bashrc" 2>/dev/null; then
    echo -e "${GREEN}✅ 终端快捷代理已配置，跳过。${NC}"
else
    read -p "❓ 是否注入代理开关命令 (终端输入 proxy 开启，unproxy 恢复)？[Y/n]: " setup_proxy </dev/tty
    if [[ ! "$setup_proxy" =~ ^[Nn]$ ]]; then
        read -p "🔗 请输入代理连接串 (默认 http://127.0.0.1:10808): " proxy_url </dev/tty
        proxy_url=${proxy_url:-"http://127.0.0.1:10808"}
        
        # 清洗输入字符
        proxy_url=$(echo "$proxy_url" | tr -d '\r\n ' | sed 's/[^a-zA-Z0-9.:/_-]//g')
        
        PROXY_SNIPPET="
# --- Quick Proxy Switch ---
alias proxy=\"export http_proxy='$proxy_url' https_proxy='$proxy_url' all_proxy='$proxy_url' && echo '🟢 代理已开启 ($proxy_url)'\"
alias unproxy=\"unset http_proxy https_proxy all_proxy && echo '🟡 代理已关闭'\""

        for file in "$USER_HOME/.bashrc" "$USER_HOME/.zshrc"; do
            if [ -f "$file" ] && ! grep -q 'alias proxy=' "$file"; then
                echo "$PROXY_SNIPPET" >> "$file"
            fi
        done
        echo -e "${GREEN}✅ 代理快捷指令已绑定到目标用户配置文件。${NC}"
    fi
fi

# ==============================================================================
# 12. 系统垃圾清理 (保护闪存寿命，安全清理旧日志与临时文件)
# ==============================================================================
echo -e "\n${YELLOW}🧹 [12/12] 深度系统瘦身与缓存清理...${NC}"
apt-get autoremove -y --purge >/dev/null 2>&1
apt-get autoclean -y >/dev/null 2>&1
apt-get clean -y >/dev/null 2>&1
journalctl --vacuum-size=50M >/dev/null 2>&1

# 安全清理旧日志，保留活动句柄
find /var/log -type f -regex '.*\.gz$' -delete >/dev/null 2>&1
find /var/log -type f -regex '.*\.[0-9]$' -delete >/dev/null 2>&1

# 安全清理临时目录（仅清理存在超过 1 天的文件，不破坏运行中服务创建的活跃套接字与 PID 锁）
find /tmp -mindepth 1 -maxdepth 2 -mtime +1 -delete 2>/dev/null || true
find /var/tmp -mindepth 1 -maxdepth 2 -mtime +1 -delete 2>/dev/null || true
systemd-tmpfiles --clean 2>/dev/null || true

# 清理构建缓存
rm -rf "$USER_HOME/.cache" /root/.cache >/dev/null 2>&1

echo -e "${GREEN}✅ 磁盘清理完成，冗余缓存已安全释放。${NC}"

# ==============================================================================
# 流程完结
# ==============================================================================
echo -e "\n${BLUE}=================================================${NC}"
echo -e "${GREEN}🎉 恭喜！Debian 初始化流程全部安全结束！🎉${NC}"
if [ "$ACTUAL_USER" != "root" ]; then
    echo -e "${YELLOW}👉 请断开当前 SSH 连接，直接使用【 $ACTUAL_USER 】用户重新登录！${NC}"
    echo -e "${YELLOW}👉 如果刚刚安装了 Docker，重新登录后即可免 sudo 直接执行 docker 命令。${NC}"
else
    echo -e "${YELLOW}👉 请退出当前终端并重新登录，即可享受全新的环境配置。${NC}"
fi
echo -e "${BLUE}=================================================${NC}"
