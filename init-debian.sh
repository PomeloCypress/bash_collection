#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=================================================${NC}"
echo -e "${GREEN}  🚀 欢迎使用 Debian 全能交互式初始化脚本 (终极完全体) 🚀  ${NC}"
echo -e "${BLUE}=================================================${NC}"

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo -e "${YELLOW}❌ 请使用 root 权限运行此脚本 (例如: sudo bash init.sh)${NC}"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# 获取调用此脚本的真实凡人账户与家目录
ACTUAL_USER=${SUDO_USER:-$(whoami)}
USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

# =========================================================
# 🚀 黑科技一：父环境代理自动捕获与全局临时穿透引擎 (不带 -E 也能飞)
# =========================================================
DETECTED_PROXY=""

# 1. 优先捕获当前环境变量（如果使用了 -E）
if [ -n "$http_proxy" ]; then
    DETECTED_PROXY="$http_proxy"
elif [ -n "$HTTP_PROXY" ]; then
    DETECTED_PROXY="$HTTP_PROXY"
fi

# 2. 如果环境变量为空（没带 -E），深度解析调用者账户的 rc 配置文件
if [ -z "$DETECTED_PROXY" ] && [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    for rc_file in "$USER_HOME/.bashrc" "$USER_HOME/.zshrc"; do
        if [ -f "$rc_file" ]; then
            # 精准匹配 alias proxy="export http_proxy='...'" 里的 IP 端口
            PARSED_PROXY=$(grep -oE "http_proxy=['\"][^'\"]+['\"]" "$rc_file" | head -n 1 | cut -d"'" -f2 | cut -d'"' -f2)
            if [ -n "$PARSED_PROXY" ]; then
                DETECTED_PROXY="$PARSED_PROXY"
                break
            fi
            # 保底备用：直接匹配 IP:PORT 格式
            PARSED_PROXY=$(grep -oE "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]+" "$rc_file" | head -n 1)
            if [ -n "$PARSED_PROXY" ]; then
                DETECTED_PROXY="http://$PARSED_PROXY"
                break
            fi
        fi
    done
fi

# 3. 如果成功定位到代理，执行系统级临时无感穿透
if [ -n "$DETECTED_PROXY" ]; then
    # 彻底洗净提取出的代理字符串（粉碎任何不可见零宽控制字符、回车符、前后空格）
    DETECTED_PROXY=$(echo "$DETECTED_PROXY" | tr -d '\r' | sed 's/[^a-zA-Z0-9.:/_-]//g')
    
    export http_proxy="$DETECTED_PROXY"
    export https_proxy="$DETECTED_PROXY"
    export all_proxy="$DETECTED_PROXY"
    export HTTP_PROXY="$DETECTED_PROXY"
    export HTTPS_PROXY="$DETECTED_PROXY"
    export ALL_PROXY="$DETECTED_PROXY"

    echo -e "${GREEN}✨ [检测成功] 已自动穿透并继承凡人账户代理: $DETECTED_PROXY${NC}"

    # A. 临时将代理注入 APT 包管理器（解决 get-docker.sh 内部调用 apt-get 的网络断流问题）
    echo "Acquire::http::Proxy \"$DETECTED_PROXY\";" > /etc/apt/apt.conf.d/99temp-proxy
    echo "Acquire::https::Proxy \"$DETECTED_PROXY\";" >> /etc/apt/apt.conf.d/99temp-proxy
    
    # B. 临时注入 curl 全局配置（解决官方脚本子 shell 里 curl 断流问题）
    echo "proxy = \"$DETECTED_PROXY\"" > /root/.curlrc
    echo "proxy = \"$DETECTED_PROXY\"" > "$USER_HOME/.curlrc"
    chown "$ACTUAL_USER":"$ACTUAL_USER" "$USER_HOME/.curlrc" 2>/dev/null || true

    # C. 临时注入 Git 全局配置
    git config --global http.proxy "$DETECTED_PROXY" 2>/dev/null || true
    git config --global https.proxy "$DETECTED_PROXY" 2>/dev/null || true
else
    echo -e "${YELLOW}ℹ️ 未检测到活动的代理配置，将使用原生直接连接。${NC}"
fi

# D. 物理钩子：在脚本结束或意外中断时，秒级物理擦除所有临时代理，绝不留一丝系统垃圾
cleanup_temp_proxy() {
    echo -e "\n${YELLOW}🧹 正在物理恢复系统级原生网络环境...${NC}"
    rm -f /etc/apt/apt.conf.d/99temp-proxy
    rm -f /root/.curlrc
    rm -f "$USER_HOME/.curlrc"
    git config --global --unset http.proxy 2>/dev/null || true
    git config --global --unset https.proxy 2>/dev/null || true
}
trap cleanup_temp_proxy EXIT INT TERM

# =========================================================

# 0. 极简环境保底
apt update -q && apt install -y -q sudo

# 1. 账户安全与日常用户设置
echo -e "\n${YELLOW}🔐 [1/12] 账户与安全设置${NC}"

if [ "$ACTUAL_USER" = "root" ]; then
    echo -e "${YELLOW}⚠️ 检测到您当前正使用 root 账户直接运行此脚本。${NC}"
    read -p "❓ 是否新建一个普通账户 (带 sudo 权限) 作为日常使用，并禁用 Root 远程登录？(VPS 强烈推荐) [Y/n]: " create_new_user
    if [[ ! "$create_new_user" =~ ^[Nn]$ ]]; then
        read -p "👤 请输入新用户的用户名 (例如: rn1): " new_username
        if [ -n "$new_username" ] && ! id "$new_username" &>/dev/null; then
            echo -e "${YELLOW}🔑 正在创建用户 $new_username，请按提示为其设置密码：${NC}"
            adduser --gecos "" "$new_username"
            usermod -aG sudo "$new_username"
            
            ACTUAL_USER="$new_username"
            USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
            echo -e "${GREEN}✅ 用户 $new_username 创建完毕，已加入 sudo 组。${NC}"
        else
            echo -e "${YELLOW}⚠️ 用户名无效或已存在，将继续使用 root 身份安装。${NC}"
        fi
    fi
else
    echo -e "${GREEN}✅ 当前已经是普通账户 ($ACTUAL_USER)，跳过新建用户步骤。${NC}"
fi

echo -e "\n👤 最终环境配置目标用户: ${GREEN}$ACTUAL_USER${NC}, 主目录: ${GREEN}$USER_HOME${NC}"

# 强行切换工作目录至 Linux 娘家
cd "$USER_HOME" || cd /tmp

# 兜底创建配置文件
sudo -u "$ACTUAL_USER" -H touch "$USER_HOME/.zshrc" "$USER_HOME/.bashrc"

# 1.5 交互式配置 SSH 公钥
if [ -s "$USER_HOME/.ssh/authorized_keys" ]; then
    echo -e "${GREEN}✅ 账户 $ACTUAL_USER 已配置 SSH 公钥，跳过配置。${NC}"
else
    read -p "❓ 是否为目标账户 [$ACTUAL_USER] 粘贴并配置 SSH 公钥登录 (强烈推荐)? [Y/n]: " setup_ssh_key
    if [[ ! "$setup_ssh_key" =~ ^[Nn]$ ]]; then
        read -r -p "📝 请在此处粘贴您的 SSH 公钥 (例如 ssh-rsa 开头): " ssh_pub_key
        if [ -n "$ssh_pub_key" ]; then
            mkdir -p "$USER_HOME/.ssh"
            echo "$ssh_pub_key" >> "$USER_HOME/.ssh/authorized_keys"
            chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$USER_HOME/.ssh"
            chmod 700 "$USER_HOME/.ssh"
            chmod 600 "$USER_HOME/.ssh/authorized_keys"
            echo -e "${GREEN}✅ SSH 公钥已成功添加至 $ACTUAL_USER 账户！${NC}"
        fi
    fi
fi

# 1.6 禁用 Root 登录
if [ "$ACTUAL_USER" != "root" ]; then
    if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config 2>/dev/null; then
        echo -e "${GREEN}✅ Root 远程登录已被禁用，跳过。${NC}"
    else
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
        systemctl restart ssh || systemctl restart sshd 2>/dev/null || true
        echo -e "${GREEN}🛡️ Root 账户的远程 SSH 登录已被永久封锁。${NC}"
    fi
fi

# 2. 基础工具 (必装)
echo -e "\n${YELLOW}📦 [2/12] 正在更新系统并安装基础工具...${NC}"
apt upgrade -y -q
apt install -y -q curl wget git nano htop zsh unzip tmux jq ca-certificates

# 3. BBR 加速
echo -e "\n${YELLOW}🌐 [3/12] 网络优化${NC}"
if grep -qEi "(Microsoft|WSL)" /proc/version &> /dev/null; then
    echo -e "${GREEN}💻 检测到 WSL 环境，网络栈与物理网卡由 Windows 宿主机内核统一掌管。自动跳过 BBR 开启。${NC}"
elif grep -q "bbr" /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null; then
    echo -e "${GREEN}✅ BBR 已经处于开启状态，跳过配置。${NC}"
else
    read -p "❓ 是否开启 BBR TCP 拥塞控制加速 (极力推荐，无线网络不丢包神器)? [Y/n]: " enable_bbr
    if [[ ! "$enable_bbr" =~ ^[Nn]$ ]]; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p 2>/dev/null || true
        echo -e "${GREEN}✅ BBR 加速已成功开启！${NC}"
    fi
fi

# 4. 时区设置
echo -e "\n${YELLOW}⏰ [4/12] 时区设置${NC}"
if [ "$(timedatectl show --property=Timezone --value 2>/dev/null)" = "Asia/Shanghai" ]; then
    echo -e "${GREEN}✅ 系统时区已经是 Asia/Shanghai，跳过设置。${NC}"
else
    read -p "❓ 是否将系统时区修改为 Asia/Shanghai (北京时间)? [Y/n]: " set_tz
    if [[ ! "$set_tz" =~ ^[Nn]$ ]]; then
        timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
        echo -e "${GREEN}✅ 系统时区已设置为: $(date)${NC}"
    fi
fi

# 5. 防火墙与安全
echo -e "\n${YELLOW}🛡️ [5/12] 防火墙配置 (UFW & Fail2ban)${NC}"
if grep -qEi "(Microsoft|WSL)" /proc/version &> /dev/null; then
    echo -e "${GREEN}💻 检测到 WSL 环境，自动跳过 UFW/Fail2ban 安装。${NC}"
else
    read -p "❓ 是否检测并配置 UFW 防火墙与 Fail2ban (局域网内网推荐选 n 跳过)? [Y/n]: " config_sec
    if [[ ! "$config_sec" =~ ^[Nn]$ ]]; then
        if ! command -v ufw &> /dev/null || ! command -v fail2ban-server &> /dev/null; then
            echo -e "${YELLOW}📦 正在安装 UFW 和 Fail2ban...${NC}"
            apt install -y -q ufw fail2ban
        fi

        systemctl enable fail2ban --now >/dev/null 2>&1
        echo -e "${GREEN}✅ Fail2ban (防 SSH 爆破) 已在后台运行并设置开机自启。${NC}"

        systemctl enable ufw >/dev/null 2>&1
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1

        ufw allow ssh >/dev/null 2>&1
        ufw allow 443/tcp >/dev/null 2>&1
        echo -e "${GREEN}✅ 已确保放行 SSH 端口 和 HTTPS (443) 端口。${NC}"

        while true; do
            read -p "❓ 是否需要开放其他端口？请以逗号分隔输入 (如: 80,81,8080)，输入 n 跳过: " extra_ports
            if [[ "$extra_ports" =~ ^[Nn]$ ]] || [ -z "$extra_ports" ]; then
                echo -e "${YELLOW}⏭️ 跳过开放其他额外端口。${NC}"
                break
            fi
            if [[ "$extra_ports" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                IFS=',' read -ra PORT_ARRAY <<< "$extra_ports"
                for port in "${PORT_ARRAY[@]}"; do
                    ufw allow "$port/tcp" >/dev/null 2>&1
                    echo -e "${GREEN}✅ 已放行额外端口: $port/tcp${NC}"
                done
                break
            else
                echo -e "${YELLOW}❌ 输入格式有误！请重新输入 (例如: 80,81,8080)${NC}"
            fi
        done

        ufw --force enable >/dev/null 2>&1
        echo -e "${GREEN}✅ UFW 防火墙已激活并设置开机自启。${NC}"
        ufw status verbose
    else
        echo -e "${YELLOW}⏭️ 已跳过防火墙配置。${NC}"
    fi
fi

# 6. Swap 虚拟内存
echo -e "\n${YELLOW}💾 [6/12] 内存管理${NC}"
SWAP_SIZE=$(free -m | grep -i swap | awk '{print $2}')
if [ -n "$SWAP_SIZE" ] && [ "$SWAP_SIZE" -gt 0 ]; then
    echo -e "${GREEN}✅ 系统已存在 Swap 虚拟内存 (${SWAP_SIZE}MB)，无需重复创建。${NC}"
else
    read -p "❓ 是否创建 2GB Swap 虚拟内存 (防 OOM 死机)? [Y/n]: " create_swap
    if [[ ! "$create_swap" =~ ^[Nn]$ ]]; then
        if [ ! -f /swapfile ]; then
            fallocate -l 2G /swapfile
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
            echo -e "${GREEN}✅ 2GB Swap 已成功启用。${NC}"
        fi
    fi
fi

# 7. Docker 引擎 (由于临时全局代理穿透，这里将百分之百完美、丝滑落盘)
echo -e "\n${YELLOW}🐳 [7/12] 容器环境${NC}"
if command -v docker &> /dev/null; then
    echo -e "${GREEN}✅ Docker 官方环境已安装，跳过。${NC}"
else
    read -p "❓ 是否安装 Docker 官方环境 (生产环境必备)? [Y/n]: " install_docker
    if [[ ! "$install_docker" =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}📡 正在从官方通道安全下载并启动 Docker 引擎部署...${NC}"
        
        # 抓取官方安装脚本
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        
        if [ -f /tmp/get-docker.sh ]; then
            # 执行时，临时 APT 和 curl 代理配置已经挂载，其子 Shell 升级与 GPG 拉取将畅通无阻
            sh /tmp/get-docker.sh
            rm -f /tmp/get-docker.sh
        else
            echo -e "${YELLOW}⚠️ 官方直连由于外界干扰失败，强制启动备用阿里云高速镜像通道...${NC}"
            curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
        fi
        
        # 确保 docker 用户组存在
        groupadd docker 2>/dev/null || true
        usermod -aG docker "$ACTUAL_USER"
        
        # 如果是 systemd，启动服务
        systemctl enable docker --now 2>/dev/null || true
        
        echo -e "${GREEN}✅ Docker 官方引擎配置完成，已成功授权 $ACTUAL_USER 组。${NC}"
    fi
fi

# 8. Zsh & Oh-My-Zsh & Oh-My-Posh 配置
echo -e "\n${YELLOW}✨ [8/12] 终端美化 (Zsh + Plugins + Oh-My-Posh)${NC}"
if [ -d "$USER_HOME/.oh-my-zsh" ] && grep -q "oh-my-posh" "$USER_HOME/.zshrc" 2>/dev/null; then
    echo -e "${GREEN}✅ Zsh 终端环境与美化配置已存在，跳过。${NC}"
else
    read -p "❓ 是否配置专属 Zsh 终端环境? [Y/n]: " config_zsh
    if [[ ! "$config_zsh" =~ ^[Nn]$ ]]; then
        chsh -s $(which zsh) "$ACTUAL_USER"
        
        sudo -u "$ACTUAL_USER" -H bash -c "
            cd \"$USER_HOME\"
            if [ ! -d \"$USER_HOME/.oh-my-zsh\" ]; then
                RUNZSH=no sh -c \"\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\" \"\" --unattended
            fi
        "
        
        ZSH_CUSTOM="$USER_HOME/.oh-my-zsh/custom"
        sudo -u "$ACTUAL_USER" -H bash -c "
            cd \"$USER_HOME\"
            git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM}/plugins/zsh-autosuggestions 2>/dev/null || true
            git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting 2>/dev/null || true
            if [ -f \"$USER_HOME/.zshrc\" ]; then
                sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/g' \"$USER_HOME/.zshrc\"
            fi
        "
        
        curl -s https://ohmyposh.dev/install.sh | bash -s -- -d /usr/local/bin
        
        sudo -u "$ACTUAL_USER" -H bash -c "
            cd \"$USER_HOME\"
            curl -fsSL https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/jandedobbeleer.omp.json -o \"$USER_HOME/.mytheme.omp.json\"
            if [ -f \"$USER_HOME/.zshrc\" ]; then
                sed -i 's/^ZSH_THEME=.*/ZSH_THEME=\"\"/g' \"$USER_HOME/.zshrc\"
                if ! grep -q \"oh-my-posh init zsh\" \"$USER_HOME/.zshrc\"; then
                    echo 'eval \"\$(oh-my-posh init zsh --config ~/.mytheme.omp.json)\"' >> \"$USER_HOME/.zshrc\"
                fi
            fi
        "
        echo -e "${GREEN}✅ 终端美化与插件配置完成！${NC}"
    fi
fi

# 9. 前端开发环境 (Node.js/pnpm)
echo -e "\n${YELLOW}🟩 [9/12] 前端开发环境 (Node.js/pnpm)${NC}"
if [ -d "$USER_HOME/.nvm" ]; then
    echo -e "${GREEN}✅ NVM 及 Node.js 已安装，跳过。${NC}"
else
    read -p "❓ 是否安装 NVM 及 Node.js LTS? [Y/n]: " install_node
    if [[ ! "$install_node" =~ ^[Nn]$ ]]; then
        sudo -u "$ACTUAL_USER" -H bash -c '
            export NVM_DIR="$HOME/.nvm"
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
            nvm install --lts
            nvm use --lts
            npm install -g pnpm
        '
        echo -e "${GREEN}✅ NVM, Node.js LTS 及 pnpm 安装完毕。${NC}"
    fi
fi

# 10. Python 环境
echo -e "\n${YELLOW}🐍 [10/12] 后端开发环境 (uv / Miniconda)${NC}"
if [ -f "$USER_HOME/.local/bin/uv" ] || [ -d "$USER_HOME/miniconda3" ]; then
    echo -e "${GREEN}✅ 物理层 Python 环境管理工具已经存在，跳过。${NC}"
else
    echo -e "💡 极客提示：2026年强烈推荐使用 Rust 编写的 ${GREEN}uv${NC}，空载 0 消耗，拉包速度比 Conda 快几十倍！"
    read -p "❓ 请选择安装的环境管理器 [1] uv (极力推荐) / [2] Miniconda / [3] 跳过 (默认 1): " python_env_choice
    python_env_choice=${python_env_choice:-1}

    if [ "$python_env_choice" = "1" ]; then
        echo -e "${YELLOW}📦 正在为日常用户 $ACTUAL_USER 快速注入 Rust 核心 uv...${NC}"
        
        sudo -u "$ACTUAL_USER" -H bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
        
        # 将 uv 路径实时注入当前执行脚本的根环境中
        export PATH="$USER_HOME/.local/bin:$PATH"
        
        # 让 uv 自动把路径全自动追加进目标账户的 Shell 配置文件中
        sudo -u "$ACTUAL_USER" -H "$USER_HOME/.local/bin/uv" python update-shell >/dev/null 2>&1
        
        echo -e "${YELLOW}📦 正在通过 uv 极速获取官方 Python 3.12 运行时...${NC}"
        sudo -u "$ACTUAL_USER" -H PATH="$PATH" bash -c "uv python install 3.12"
        
        # 一键为目标日常账户创建全局环境快捷软链接，确保原地秒开
        ln -sf "$USER_HOME/.local/bin/uv" /usr/local/bin/uv
        
        echo -e "${GREEN}✅ uv 部署成功，且全局环境变量已锁死，沙箱 Python 3.12 内核就位！${NC}"
        NEED_SHELL_RELOAD=true
        
    elif [ "$python_env_choice" = "2" ]; then
        ARCH=$(uname -m)
        if [ "$ARCH" = "x86_64" ]; then
            CONDA_URL="https://repo.continuum.io/miniconda/Miniconda3-latest-Linux-x86_64.sh"
        elif [ "$ARCH" = "aarch64" ]; then
            CONDA_URL="https://repo.continuum.io/miniconda/Miniconda3-latest-Linux-aarch64.sh"
        else
            echo -e "${YELLOW}⚠️ 暂不支持当前架构 $ARCH 的 Conda 自动安装。${NC}"
            CONDA_URL=""
        fi

        if [ -n "$CONDA_URL" ]; then
            sudo -u "$ACTUAL_USER" -H bash -c "
                cd \"$USER_HOME\"
                wget $CONDA_URL -O /tmp/miniconda.sh
                bash /tmp/miniconda.sh -b -p \"$USER_HOME/miniconda3\"
                \"$USER_HOME/miniconda3/bin/conda\" init bash
                \"$USER_HOME/miniconda3/bin/conda\" init zsh
                rm -f /tmp/miniconda.sh
            "
            echo -e "${GREEN}✅ Miniconda 安装完毕。${NC}"
        fi
    else
        echo -e "${YELLOW}⏭️ 已跳过 Python 环境配置。${NC}"
    fi
fi

# 11. 终端代理设置 (✨ 注入物理粉碎机，彻底杜绝隐藏脏字符、回车符)
echo -e "\n${YELLOW}🔌 [11/12] 终端代理设置${NC}"
if grep -q 'alias proxy=' "$USER_HOME/.bashrc" 2>/dev/null || grep -q 'alias proxy=' "$USER_HOME/.zshrc" 2>/dev/null; then
    echo -e "${GREEN}✅ 终端代理快捷键已配置，跳过。${NC}"
else
    read -p "❓ 是否配置终端代理快捷键 (输入 proxy 开启，unproxy 关闭)? [Y/n]: " setup_proxy
    if [[ ! "$setup_proxy" =~ ^[Nn]$ ]]; then
        read -p "🔗 请输入代理地址 (默认: http://127.0.0.1:10808): " proxy_url
        proxy_url=${proxy_url:-"http://127.0.0.1:10808"}
        
        # 🛡️ 核心修复：物理粉碎机 —— 过滤清除输入中可能存在的任何 \r 换行符、零宽不可见字符或前后多余空格
        proxy_url=$(echo "$proxy_url" | tr -d '\r' | sed 's/[^a-zA-Z0-9.:/_-]//g')
        
        PROXY_CONFIG="
# Magic Network Switch
alias proxy=\"export http_proxy='$proxy_url' && export https_proxy='$proxy_url' && export all_proxy='$proxy_url' && echo '🟢 Proxy Enabled! ($proxy_url)'\"
alias unproxy=\"unset http_proxy && unset https_proxy && unset all_proxy && echo '🟡 Proxy Disabled!'\""

        if [ -f "$USER_HOME/.bashrc" ] && ! grep -q 'alias proxy=' "$USER_HOME/.bashrc"; then
            echo "$PROXY_CONFIG" | sudo -u "$ACTUAL_USER" -H tee -a "$USER_HOME/.bashrc" > /dev/null
        fi
        if [ -f "$USER_HOME/.zshrc" ] && ! grep -q 'alias proxy=' "$USER_HOME/.zshrc"; then
            echo "$PROXY_CONFIG" | sudo -u "$ACTUAL_USER" -H tee -a "$USER_HOME/.zshrc" > /dev/null
        fi
        echo -e "${GREEN}✅ 代理快捷键已成功配置为: $proxy_url ！${NC}"
    fi
fi

# 12. 系统清理 (工业级极致瘦身与 eMMC 寿命保护)
echo -e "\n${YELLOW}🧹 [12/12] 正在深度清理系统垃圾、旧日志与缓存...${NC}"
apt-get autoremove -y --purge >/dev/null 2>&1
apt-get autoclean -y >/dev/null 2>&1
apt-get clean -y >/dev/null 2>&1
journalctl --vacuum-size=50M >/dev/null 2>&1
find /var/log -type f -regex '.*\.gz$' -delete >/dev/null 2>&1
find /var/log -type f -regex '.*\.[0-9]$' -delete >/dev/null 2>&1
rm -rf /tmp/* /var/tmp/* >/dev/null 2>&1
rm -rf "$USER_HOME/.cache" /root/.cache >/dev/null 2>&1
echo -e "${GREEN}✅ 系统极致清理完成！已为您最大化释放磁盘空间，全力呵护闪存颗粒寿命。${NC}"

echo -e "\n${BLUE}=================================================${NC}"
echo -e "${GREEN}🎉 恭喜！Debian 初始化流程全部完美结束！🎉${NC}"
if [ "$ACTUAL_USER" != "root" ]; then
    echo -e "${YELLOW}👉 请断开当前的 Root SSH 连接，以后请使用配置好公钥的【 $ACTUAL_USER 】账户重新登录！${NC}"
else
    echo -e "${YELLOW}👉 请断开当前的 SSH 连接并重新登录，即可享受全新的开发体验！${NC}"
fi
echo -e "${BLUE}=================================================${NC}"

# 🛠️ 终极点睛之笔：如果安装了 uv，在脚本彻底退出前，自动原位热替换刷新当前用户的 Shell 环境
if [ "$NEED_SHELL_RELOAD" = true ]; then
    CURRENT_SHELL=$(basename "$SHELL")
    if [ "$CURRENT_SHELL" = "zsh" ] || [ "$CURRENT_SHELL" = "bash" ]; then
        echo -e "${BLUE}🔄 检测到全新的环境变量注入，正在为您原地秒级热重载 ${GREEN}$CURRENT_SHELL${BLUE} 环境...${NC}"
        unset NEED_SHELL_RELOAD
        exec sudo -u "$ACTUAL_USER" -H "$SHELL"
    fi
fi
```
eof
