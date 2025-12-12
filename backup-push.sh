#!/bin/bash
# ============================================================
# 云端备份推送脚本 - 使用 rclone 同步到 Cloudflare R2 / Backblaze B2
# 用法: bash backup-push.sh
# ============================================================

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================
# 配置 - 请根据实际情况修改
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="/tmp/devops-backup"
BACKUP_NAME="devops-backup-$(date +%Y%m%d-%H%M%S).tar.gz"

# 数据目录
GITEA_POSTGRES_DATA="/home/zyg/postgres_data"
GITEA_DATA="/home/zyg/gitea_data"
DRONE_DATA="/home/zyg/drone_data"
PLANE_DATA="$SCRIPT_DIR/plane_data"

# rclone 远程名称 (配置后修改)
RCLONE_REMOTE="r2"  # 或 "b2" 取决于你用哪个
RCLONE_BUCKET="devops-backup"

# ============================================================
# 检查依赖
# ============================================================
check_dependencies() {
    log_info "检查依赖..."
    
    if ! command -v rclone &> /dev/null; then
        log_error "rclone 未安装，正在安装..."
        curl https://rclone.org/install.sh | sudo bash
    fi
    
    if ! rclone listremotes | grep -q "^${RCLONE_REMOTE}:"; then
        log_error "rclone 远程 '$RCLONE_REMOTE' 未配置"
        echo ""
        echo "请先运行: rclone config"
        echo "配置指南请参考: https://rclone.org/s3/#cloudflare-r2"
        exit 1
    fi
    
    log_ok "依赖检查完成"
}

# ============================================================
# 停止服务（确保数据一致性）
# ============================================================
stop_services() {
    log_info "停止服务以确保数据一致性..."
    
    cd "$SCRIPT_DIR"
    podman-compose -f podman-compose.yml down 2>/dev/null || true
    podman-compose -f plane-robust.yml down 2>/dev/null || true
    
    # 等待容器完全停止
    sleep 3
    log_ok "服务已停止"
}

# ============================================================
# 创建备份
# ============================================================
create_backup() {
    log_info "创建备份..."
    
    mkdir -p "$BACKUP_DIR"
    
    # 备份配置文件
    log_info "备份配置文件..."
    cp "$SCRIPT_DIR/.env.plane" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$SCRIPT_DIR/podman-compose.yml" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$SCRIPT_DIR/plane-robust.yml" "$BACKUP_DIR/" 2>/dev/null || true
    
    # 备份数据目录
    log_info "备份 Gitea PostgreSQL 数据..."
    if [ -d "$GITEA_POSTGRES_DATA" ]; then
        tar -czf "$BACKUP_DIR/postgres_data.tar.gz" -C "$(dirname $GITEA_POSTGRES_DATA)" "$(basename $GITEA_POSTGRES_DATA)"
    fi
    
    log_info "备份 Gitea 数据..."
    if [ -d "$GITEA_DATA" ]; then
        tar -czf "$BACKUP_DIR/gitea_data.tar.gz" -C "$(dirname $GITEA_DATA)" "$(basename $GITEA_DATA)"
    fi
    
    log_info "备份 Drone 数据..."
    if [ -d "$DRONE_DATA" ]; then
        tar -czf "$BACKUP_DIR/drone_data.tar.gz" -C "$(dirname $DRONE_DATA)" "$(basename $DRONE_DATA)"
    fi
    
    log_info "备份 Plane 数据..."
    if [ -d "$PLANE_DATA" ]; then
        tar -czf "$BACKUP_DIR/plane_data.tar.gz" -C "$(dirname $PLANE_DATA)" "$(basename $PLANE_DATA)"
    fi
    
    # 创建元数据文件
    cat > "$BACKUP_DIR/metadata.txt" <<EOF
Backup created: $(date)
Hostname: $(hostname)
User: $(whoami)
EOF
    
    log_ok "备份创建完成: $BACKUP_DIR"
}

# ============================================================
# 上传到云端
# ============================================================
upload_to_cloud() {
    log_info "上传到云端 ($RCLONE_REMOTE:$RCLONE_BUCKET)..."
    
    # 创建 bucket（如果不存在）
    rclone mkdir "$RCLONE_REMOTE:$RCLONE_BUCKET" 2>/dev/null || true
    
    # 同步上传（只传输变化的文件）
    rclone sync "$BACKUP_DIR/" "$RCLONE_REMOTE:$RCLONE_BUCKET/latest/" \
        --progress \
        --transfers 4 \
        --checkers 8
    
    # 保留一个带时间戳的历史版本
    rclone copy "$BACKUP_DIR/" "$RCLONE_REMOTE:$RCLONE_BUCKET/history/$(date +%Y%m%d-%H%M%S)/" \
        --progress
    
    log_ok "上传完成！"
}

# ============================================================
# 重启服务
# ============================================================
restart_services() {
    log_info "重启服务..."
    
    cd "$SCRIPT_DIR"
    bash depoly.sh 2>/dev/null || log_warn "Gitea/Drone 启动失败"
    bash depoly-plane-robust.sh 2>/dev/null || log_warn "Plane 启动失败"
    
    log_ok "服务已重启"
}

# ============================================================
# 清理临时文件
# ============================================================
cleanup() {
    log_info "清理临时文件..."
    rm -rf "$BACKUP_DIR"
    log_ok "清理完成"
}

# ============================================================
# 主流程
# ============================================================
main() {
    echo "========================================================"
    echo -e "${GREEN}DevOps 数据备份推送${NC}"
    echo "========================================================"
    echo ""
    
    check_dependencies
    stop_services
    create_backup
    upload_to_cloud
    cleanup
    restart_services
    
    echo ""
    echo "========================================================"
    echo -e "${GREEN}✅ 备份推送完成！${NC}"
    echo "云端位置: $RCLONE_REMOTE:$RCLONE_BUCKET/latest/"
    echo "========================================================"
}

main "$@"
