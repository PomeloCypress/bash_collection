#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# 定义存储所有 Worker 脚本和日志的根目录
BASE_DIR="/root/auto_backups"
WORKER_DIR="$BASE_DIR/scripts"
LOG_DIR="$BASE_DIR/logs"

# 确保基础目录存在
mkdir -p "$WORKER_DIR" "$LOG_DIR"

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ 请使用 root 权限运行此脚本 (例如: sudo bash setup_backup.sh)${NC}"
  exit 1
fi

# ==========================================
# 0. 依赖环境智能检测与安装 (仅在启动时检测一次)
# ==========================================
check_dependencies() {
    local missing=0
    if ! command -v tar &> /dev/null; then
        echo -e "${YELLOW}⚠️ 缺少打包工具 'tar'，正在尝试安装...${NC}"
        if command -v apt-get &> /dev/null; then apt-get update -q && apt-get install -y tar; else echo -e "${RED}❌ 请手动安装 tar${NC}"; missing=1; fi
    fi

    if ! command -v crontab &> /dev/null; then
        echo -e "${YELLOW}⚠️ 缺少定时任务工具 'cron'，正在尝试安装...${NC}"
        if command -v apt-get &> /dev/null; then apt-get install -y cron; systemctl enable cron --now; else echo -e "${RED}❌ 请手动安装 cron${NC}"; missing=1; fi
    fi

    if [ $missing -eq 1 ]; then
        exit 1
    fi
}

# ==========================================
# 功能函数：列出当前所有任务
# ==========================================
list_tasks() {
    echo -e "\n${BLUE}=================================================${NC}"
    echo -e "${GREEN}             📋 当前已配置的备份任务             ${NC}"
    echo -e "${BLUE}=================================================${NC}"
    
    local count=0
    # 将文件读入数组
    shopt -s nullglob
    local files=("$WORKER_DIR"/*.sh)
    shopt -u nullglob

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}暂无任何备份任务。您可选择添加新任务。${NC}"
        echo -e "${BLUE}=================================================${NC}"
        return 0
    fi

    for script in "${files[@]}"; do
        count=$((count+1))
        local task_name=$(basename "$script" .sh)
        # 从脚本和 crontab 中提取元数据以供显示
        local source_dir=$(grep '^SOURCE_DIR=' "$script" | head -n 1 | cut -d'"' -f2)
        local cron_expr=$(crontab -l 2>/dev/null | grep "$script" | awk -F '/bin/bash' '{print $1}' | xargs)
        
        echo -e "  [${YELLOW}${count}${NC}] 🏷️  名称: ${GREEN}${task_name}${NC}"
        echo -e "      📁 源路径: $source_dir"
        echo -e "      ⏰ 定时规则: ${cron_expr:-"未在crontab中找到"}"
        echo -e "      -----------------------------------------"
    done
    echo -e "${BLUE}=================================================${NC}"
    return ${#files[@]}
}

# ==========================================
# 功能函数：删除已有任务
# ==========================================
delete_task() {
    list_tasks
    local task_count=$?
    
    if [ $task_count -eq 0 ]; then
        return
    fi

    echo ""
    read -p "🗑️  请输入要删除的任务序号 (1-$task_count, 直接回车取消操作): " del_idx

    if [[ ! "$del_idx" =~ ^[0-9]+$ ]] || [ "$del_idx" -lt 1 ] || [ "$del_idx" -gt "$task_count" ]; then
        echo -e "${YELLOW}⏭️ 已取消删除操作。${NC}"
        return
    fi

    shopt -s nullglob
    local files=("$WORKER_DIR"/*.sh)
    shopt -u nullglob

    local target_script="${files[$((del_idx-1))]}"
    local task_name=$(basename "$target_script" .sh)
    local target_log="$LOG_DIR/${task_name}.log"

    echo -e "\n${YELLOW}⚠️ 您正在删除备份任务: ${GREEN}${task_name}${NC}"
    read -p "❗ 确定要删除该任务及其定时配置吗？[y/N]: " confirm_del
    if [[ "$confirm_del" =~ ^[Yy]$ ]]; then
        # 1. 从 crontab 中抹除
        (crontab -l 2>/dev/null | grep -v "$target_script") | crontab -
        # 2. 删除物理文件
        rm -f "$target_script" "$target_log"
        echo -e "${GREEN}✅ 任务 '${task_name}' 已彻底清理！${NC}"
    else
        echo -e "${YELLOW}⏭️ 已取消删除操作。${NC}"
    fi
}

# ==========================================
# 功能函数：添加新任务 (交互收集)
# ==========================================
add_task() {
    echo -e "\n${BLUE}=================================================${NC}"
    echo -e "${GREEN}              ✨ 创建新的备份任务 ✨             ${NC}"
    echo -e "${BLUE}=================================================${NC}"

    read -p "🏷️  1. 请输入【任务名称】(仅限英文字母、数字和下划线，例如 docker_data): " TASK_NAME
    if [[ ! "$TASK_NAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo -e "${RED}❌ 任务名称无效！只能包含英文字母、数字和下划线，且不能为空。${NC}"
        return
    fi

    WORKER_SCRIPT="$WORKER_DIR/${TASK_NAME}.sh"
    LOG_FILE="$LOG_DIR/${TASK_NAME}.log"

    if [ -f "$WORKER_SCRIPT" ]; then
        echo -e "${RED}❌ 任务名称 '${TASK_NAME}' 已存在！请使用其他名称或先删除旧任务。${NC}"
        return
    fi

    read -p "📁 2. 请输入需要备份的【源目录或文件】绝对路径 (默认: /volume1/Docker): " SOURCE_DIR
    SOURCE_DIR=${SOURCE_DIR:-"/volume1/Docker"}

    read -p "💾 3. 请输入存放备份的【目标文件夹】绝对路径 (默认: /volume2/Backup/Docker_Backups): " BACKUP_DEST
    BACKUP_DEST=${BACKUP_DEST:-"/volume2/Backup/Docker_Backups"}

    read -p "⏳ 4. 备份文件保留天数 (默认: 7): " RETAIN_DAYS
    RETAIN_DAYS=${RETAIN_DAYS:-7}

    read -p "🐳 5. 是否需要在备份时自动【停止并重新启动】所有 Docker 容器? (备份数据库必选) [Y/n]: " MANAGE_DOCKER
    if [[ "$MANAGE_DOCKER" =~ ^[Nn]$ ]]; then
        MANAGE_DOCKER="no"
    else
        MANAGE_DOCKER="yes"
    fi

    while true; do
        read -p "⏰ 6. 请设置备份频率 (格式 1h-24h 代表每天指定小时，或 1d-28d 代表每月指定日期，默认: 6h): " FREQ_INPUT
        FREQ_INPUT=${FREQ_INPUT:-"6h"}

        # 处理每天的备份 (例如 6h, 24h)
        if [[ "$FREQ_INPUT" =~ ^([0-9]{1,2})[hH]$ ]]; then
            HOUR="${BASH_REMATCH[1]}"
            HOUR=$((10#$HOUR)) # 去除前导零，防止被当成八进制
            if [ "$HOUR" -ge 1 ] && [ "$HOUR" -le 24 ]; then
                if [ "$HOUR" -eq 24 ]; then HOUR=0; fi
                CRON_EXPR="0 $HOUR * * *"
                echo -e "${GREEN}✅ 已自动转换为: 每天 $HOUR:00 执行 ($CRON_EXPR)${NC}"
                break
            fi
        fi

        # 处理每月的备份 (例如 15d)
        if [[ "$FREQ_INPUT" =~ ^([0-9]{1,2})[dD]$ ]]; then
            DAY="${BASH_REMATCH[1]}"
            DAY=$((10#$DAY))
            if [ "$DAY" -ge 1 ] && [ "$DAY" -le 28 ]; then
                CRON_EXPR="0 6 $DAY * *"
                echo -e "${GREEN}✅ 已自动转换为: 每月 $DAY 号 6:00 执行 ($CRON_EXPR)${NC}"
                break
            fi
        fi

        echo -e "${RED}❌ 输入格式无效！请输入例如 6h (每天早上6点) 或 15d (每月15号)。${NC}"
    done

    echo -e "\n${YELLOW}⚙️ 正在生成后台工作脚本并注册定时任务...${NC}"

    # 动态写入 Worker 脚本
    cat << EOF > "$WORKER_SCRIPT"
#!/bin/bash
# ==========================================
# 自动生成的备份任务: $TASK_NAME
# ==========================================
SOURCE_DIR="$SOURCE_DIR"
BACKUP_DEST="$BACKUP_DEST"
RETAIN_DAYS="$RETAIN_DAYS"
MANAGE_DOCKER="$MANAGE_DOCKER"

DATE_SUFFIX=\$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_FILE="\$BACKUP_DEST/${TASK_NAME}_backup_\$DATE_SUFFIX.tar.gz"

echo "========================================================"
echo "[\$(date +"%Y-%m-%d %H:%M:%S")] 🚀 任务 [$TASK_NAME] 开始执行"
echo "========================================================"

# 第一步：停止 Docker (如果启用)
if [ "\$MANAGE_DOCKER" = "yes" ]; then
    echo "[\$(date +"%Y-%m-%d %H:%M:%S")] [1/4] 正在停止所有 Docker 容器..."
    RUNNING_CONTAINERS=\$(docker ps -q)
    if [ ! -z "\$RUNNING_CONTAINERS" ]; then
        docker stop \$RUNNING_CONTAINERS
    fi
else
    echo "[\$(date +"%Y-%m-%d %H:%M:%S")] [1/4] Docker 管理已禁用，跳过停止容器..."
fi

# 第二步：压缩数据
echo "[\$(date +"%Y-%m-%d %H:%M:%S")] [2/4] 正在压缩并备份数据..."
mkdir -p "\$BACKUP_DEST"
tar -czf "\$BACKUP_FILE" "\$SOURCE_DIR"

# 第三步：恢复 Docker (如果启用)
if [ "\$MANAGE_DOCKER" = "yes" ]; then
    echo "[\$(date +"%Y-%m-%d %H:%M:%S")] [3/4] 备份完成！正在重新拉起所有容器..."
    ALL_CONTAINERS=\$(docker ps -aq)
    if [ ! -z "\$ALL_CONTAINERS" ]; then
        docker start \$ALL_CONTAINERS
    fi
else
    echo "[\$(date +"%Y-%m-%d %H:%M:%S")] [3/4] Docker 管理已禁用，跳过拉起容器..."
fi

# 第四步：清理旧备份
echo "[\$(date +"%Y-%m-%d %H:%M:%S")] [4/4] 正在清理 \$RETAIN_DAYS 天前的旧备份..."
find "\$BACKUP_DEST" -name "${TASK_NAME}_backup_*.tar.gz" -type f -mtime +\$RETAIN_DAYS -exec rm -f {} \;

echo "[\$(date +"%Y-%m-%d %H:%M:%S")] ✅ 任务 [$TASK_NAME] 执行完毕"
echo "========================================================"
echo ""
EOF

    # 赋予执行权限
    chmod +x "$WORKER_SCRIPT"

    # 写入 Crontab
    (crontab -l 2>/dev/null; echo "$CRON_EXPR /bin/bash $WORKER_SCRIPT >> $LOG_FILE 2>&1") | crontab -

    echo -e "${GREEN}🎉 任务 [$TASK_NAME] 创建成功并已加入定时调度！${NC}"
    echo -e "👉 脚本路径: $WORKER_SCRIPT"
    echo -e "👉 日志路径: $LOG_FILE"
}

# ==========================================
# 主程序入口
# ==========================================
check_dependencies

while true; do
    list_tasks
    
    echo -e "请选择操作菜单："
    echo -e "  ${GREEN}1.${NC} ➕ 添加新的备份任务"
    echo -e "  ${YELLOW}2.${NC} 🗑️  删除已有备份任务"
    echo -e "  ${RED}3.${NC} 🚪 退出程序"
    echo ""
    read -p "👉 请输入对应数字并回车 [1-3]: " choice

    case $choice in
        1)
            add_task
            read -p "按回车键返回主菜单..."
            ;;
        2)
            delete_task
            read -p "按回车键返回主菜单..."
            ;;
        3)
            echo -e "\n${GREEN}👋 感谢使用，再见！${NC}"
            exit 0
            ;;
        *)
            echo -e "\n${RED}❌ 无效的输入，请输入 1、2 或 3。${NC}"
            sleep 1
            ;;
    esac
done
