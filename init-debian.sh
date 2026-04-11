#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=================================================${NC}"
echo -e "${GREEN}  🚀 欢迎使用 Debian 全能交互式初始化脚本 🚀  ${NC}"
echo -e "${BLUE}=================================================${NC}"

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo -e "${YELLOW}❌ 请使用 root 权限运行此脚本 (例如: sudo bash init.sh)${NC}"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# 0. 极简环境保底：确保 Debian 中存在 sudo，防止后续提权失败
apt update -q && apt install -y -q sudo

# 1. 账户安全与日常用户设置 (拦截 Root 环境污染)
ACTUAL_USER=${SUDO_USER:-$(whoami)}
echo -e "\n${YELLOW}🔐 [1/12] 账户与安全设置${NC}"

if [ "$ACTUAL_USER" = "root" ]; then
    echo -e "${YELLOW}⚠️ 检测到您当前正使用 root 账户直接运行此脚本。${NC}"
    read -p "❓ 是否新建一个普通账户 (带 sudo 权限) 作为日常使用，并禁用 Root 远程登录？(VPS 强烈推荐) [Y/n]: " create_new_user
    if [[ ! "$create_new_user" =~ ^[Nn]$ ]]; then
        read -p "👤 请输入新用户的用户名 (例如: rn1): " new_username
        if [ -n "$new_username" ] && ! id "$new_username" &>/dev/null; then
            echo -e "${YELLOW}🔑 正在创建用户 $new_username，请按提示为其设置密码：${NC}"
            # --gecos "" 用于跳过全名、房间号等繁琐询问
            adduser --gecos "" "$new_username"
            usermod -aG sudo "$new_username"
            
            ACTUAL_USER="$new_username"
            echo -e "${GREEN}✅ 用户 $new_username 创建完毕，已加入 sudo 组。${NC}"
        else
            echo -e "${YELLOW}⚠️ 用户名无效或已存在，将继续使用 root 身份安装。${NC}"
        fi
    fi
else
    echo -e "${GREEN}✅ 当前已经是普通账户 ($ACTUAL_USER)，跳过新建用户步骤。${NC}"
fi

# 重新计算目标用户主目录
USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
echo -e "\n👤 最终环境配置目标用户: ${GREEN}$ACTUAL_USER${NC}, 主目录: ${GREEN}$USER_HOME${NC}"

# ！！！核心修复：强行切换工作目录！！！
cd "$USER_HOME" || cd /tmp

# 兜底创建 .zshrc 和 .bashrc
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
        systemctl restart ssh || systemctl restart sshd
        echo -e "${GREEN}🛡️ Root 账户的远程 SSH 登录已被永久封锁。${NC}"
    fi
fi

# 2. 基础工具 (必装)
echo -e "\n${YELLOW}📦 [2/12] 正在更新系统并安装基础工具...${NC}"
apt upgrade -y -q
apt install -y -q curl wget git nano htop zsh unzip tmux jq ca-certificates

# 3. BBR 加速
echo -e "\n${YELLOW}🌐 [3/12] 网络优化${NC}"
if grep -q "bbr" /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null; then
    echo -e "${GREEN}✅ BBR 已经处于开启状态，跳过配置。${NC}"
else
    read -p "❓ 是否开启 BBR TCP 拥塞控制加速? [Y/n]: " enable_bbr
    if [[ ! "$enable_bbr" =~ ^[Nn]$ ]]; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
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
        timedatectl set-timezone Asia/Shanghai
        echo -e "${GREEN}✅ 系统时区已设置为: $(date)${NC}"
    fi
fi

# 5. 防火墙与安全 (已优化：支持复用检测、状态输出、自定义端口)
echo -e "\n${YELLOW}🛡️ [5/12] 防火墙配置 (UFW & Fail2ban)${NC}"
if grep -qEi "(Microsoft|WSL)" /proc/version &> /dev/null; then
    echo -e "${GREEN}💻 检测到 WSL 环境，自动跳过 UFW/Fail2ban 安装。${NC}"
else
    read -p "❓ 是否检测并配置 UFW 防火墙与 Fail2ban (将自动开放 SSH 和 443 端口)? [Y/n]: " config_sec
    if [[ ! "$config_sec" =~ ^[Nn]$ ]]; then
        
        # 1. 检查并安装工具
        if ! command -v ufw &> /dev/null || ! command -v fail2ban-server &> /dev/null; then
            echo -e "${YELLOW}📦 正在安装 UFW 和 Fail2ban...${NC}"
            apt install -y -q ufw fail2ban
        fi

        # 2. Fail2ban：防爆破守护，直接启用并设置开机自启
        systemctl enable fail2ban --now >/dev/null 2>&1
        echo -e "${GREEN}✅ Fail2ban (防 SSH 爆破) 已在后台运行并设置开机自启。${NC}"

        # 3. UFW：基础规则配置
        systemctl enable ufw >/dev/null 2>&1  # 确保 systemd 服务开机自启
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1

        # 4. 放行核心端口 (幂等操作，已存在的规则会安全跳过)
        ufw allow ssh >/dev/null 2>&1
        ufw allow 443/tcp >/dev/null 2>&1
        echo -e "${GREEN}✅ 已确保放行 SSH 端口 和 HTTPS (443) 端口。${NC}"

        # 4.5 交互式放行其他自定义端口
        while true; do
            read -p "❓ 是否需要开放其他端口？请以逗号分隔输入 (如: 80,81,8080)，输入 n/N 跳过: " extra_ports
            
            # 判断是否跳过 (包含 n, N 或直接回车为空)
            if [[ "$extra_ports" =~ ^[Nn]$ ]] || [ -z "$extra_ports" ]; then
                echo -e "${YELLOW}⏭️ 跳过开放其他额外端口。${NC}"
                break
            fi
            
            # 正则校验：只允许数字和英文逗号组合，且开头结尾必须是数字
            if [[ "$extra_ports" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
                IFS=',' read -ra PORT_ARRAY <<< "$extra_ports"
                for port in "${PORT_ARRAY[@]}"; do
                    ufw allow "$port/tcp" >/dev/null 2>&1
                    echo -e "${GREEN}✅ 已放行额外端口: $port/tcp${NC}"
                done
                break # 成功放行后跳出循环
            else
                echo -e "${YELLOW}❌ 输入格式有误！请严格按格式输入数字并用英文逗号分割 (例如: 80,81,8080)${NC}"
            fi
        done

        # 5. 强制激活并输出状态
        ufw --force enable >/dev/null 2>&1
        echo -e "${GREEN}✅ UFW 防火墙已激活并设置开机自启。${NC}"
        
        echo -e "\n${BLUE}📋 当前防火墙状态如下：${NC}"
        ufw status verbose
    else
        echo -e "${YELLOW}⏭️ 已跳过防火墙配置。${NC}"
    fi
fi

# 6. Swap 虚拟内存 (升级为 2GB)
echo -e "\n${YELLOW}💾 [6/12] 内存管理${NC}"
SWAP_SIZE=$(free -m | grep -i swap | awk '{print $2}')
if [ -n "$SWAP_SIZE" ] && [ "$SWAP_SIZE" -gt 0 ]; then
    echo -e "${GREEN}✅ 系统已存在 Swap 虚拟内存 (${SWAP_SIZE}MB)，无需重复创建。${NC}"
else
    read -p "❓ 是否创建 2GB Swap 虚拟内存 (防 OOM 死机神器)? [Y/n]: " create_swap
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

# 7. Docker 引擎
echo -e "\n${YELLOW}🐳 [7/12] 容器环境${NC}"
if command -v docker &> /dev/null; then
    echo -e "${GREEN}✅ Docker 官方环境已安装，跳过。${NC}"
else
    read -p "❓ 是否安装 Docker 官方环境 (生产环境必备)? [Y/n]: " install_docker
    if [[ ! "$install_docker" =~ ^[Nn]$ ]]; then
        curl -fsSL https://get.docker.com | sh
        usermod -aG docker "$ACTUAL_USER"
        echo -e "${GREEN}✅ Docker 安装完成，已将 $ACTUAL_USER 加入 docker 用户组。${NC}"
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
            cd "$HOME"
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
            nvm install --lts
            nvm use --lts
            npm install -g pnpm
        '
        echo -e "${GREEN}✅ NVM, Node.js LTS 及 pnpm 安装完毕。${NC}"
    fi
fi

# 10. Python 环境
echo -e "\n${YELLOW}🐍 [10/12] 后端开发环境 (Miniconda)${NC}"
if [ -d "$USER_HOME/miniconda3" ]; then
    echo -e "${GREEN}✅ Miniconda 已安装，跳过。${NC}"
else
    read -p "❓ 是否安装 Miniconda? [Y/n]: " install_conda
    if [[ ! "$install_conda" =~ ^[Nn]$ ]]; then
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
            if [ -f "$USER_HOME/.mytheme.omp.json" ]; then
                sudo -u "$ACTUAL_USER" -H bash -c "
                    cd \"$USER_HOME\"
                    jq '(.. | select(.type? == \"python\") | .properties.fetch_virtual_env?) = true | (.. | select(.type? == \"python\") | .template?) = \" \ue235 {{ if .Error }}{{ .Error }}{{ else }}{{ if .Venv }}[{{ .Venv }}] {{ end }}{{ .Full }}{{ end }} \"' \"$USER_HOME/.mytheme.omp.json\" > /tmp/tmp_theme.json && mv /tmp/tmp_theme.json \"$USER_HOME/.mytheme.omp.json\"
                "
            fi
            echo -e "${GREEN}✅ Miniconda 安装完毕。${NC}"
        fi
    fi
fi

# 11. 终端代理设置
echo -e "\n${YELLOW}🔌 [11/12] 终端代理设置${NC}"
if grep -q 'alias proxy=' "$USER_HOME/.bashrc" 2>/dev/null || grep -q 'alias proxy=' "$USER_HOME/.zshrc" 2>/dev/null; then
    echo -e "${GREEN}✅ 终端代理快捷键已配置，跳过。${NC}"
else
    read -p "❓ 是否配置终端代理快捷键 (输入 proxy 开启，unproxy 关闭)? [Y/n]: " setup_proxy
    if [[ ! "$setup_proxy" =~ ^[Nn]$ ]]; then
        read -p "🔗 请输入代理地址 (默认: http://192.168.31.227:20172): " proxy_url
        proxy_url=${proxy_url:-"http://192.168.31.227:20172"}
        
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
        echo -e "${GREEN}✅ 代理快捷键已配置！${NC}"
    fi
fi

# 12. 系统清理
echo -e "\n${YELLOW}🧹 [12/12] 正在清理无用安装包与缓存...${NC}"
apt autoremove -y
apt clean
echo -e "${GREEN}✅ 系统垃圾清理完成！为你释放了宝贵的磁盘空间。${NC}"

echo -e "\n${BLUE}=================================================${NC}"
echo -e "${GREEN}🎉 恭喜！Debian 初始化流程全部完美结束！🎉${NC}"
if [ "$ACTUAL_USER" != "root" ]; then
    echo -e "${YELLOW}👉 请断开当前的 Root SSH 连接，以后请使用配置好公钥的【 $ACTUAL_USER 】账户重新登录！${NC}"
else
    echo -e "${YELLOW}👉 请断开当前的 SSH 连接并重新登录，即可享受全新的开发体验！${NC}"
fi
echo -e "${BLUE}=================================================${NC}"
