#!/bin/bash
# ============================================================
# 云端备份拉取脚本 - 从 Cloudflare R2 / Backblaze B2 下载并恢复
# 用法: bash backup-pull.sh
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
BACKUP_DIR="/tmp/devops-backup-restore"

# 数据目录
GITEA_POSTGRES_DATA="/home/zyg/postgres_data"
GITEA_DATA="/home/zyg/gitea_data"
DRONE_DATA="/home/zyg/drone_data"
PLANE_DATA="$SCRIPT_DIR/plane_data"

# rclone 远程名称
RCLONE_REMOTE="r2"
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
        echo "然后按照以下步骤配置 Cloudflare R2:"
        echo "1. 选择 's3' 类型"
        echo "2. provider 选择 'Cloudflare'"
        echo "3. 输入 Access Key ID 和 Secret Access Key"
        echo "4. endpoint 输入: https://<ACCOUNT_ID>.r2.cloudflarestorage.com"
        exit 1
    fi
    
    log_ok "依赖检查完成"
}

# ============================================================
# 停止服务
# ============================================================
stop_services() {
    log_info "停止现有服务..."
    
    cd "$SCRIPT_DIR"
    podman-compose -f podman-compose.yml down 2>/dev/null || true
    podman-compose -f plane-robust.yml down 2>/dev/null || true
    
    sleep 3
    log_ok "服务已停止"
}

# ============================================================
# 从云端下载
# ============================================================
download_from_cloud() {
    log_info "从云端下载备份 ($RCLONE_REMOTE:$RCLONE_BUCKET/latest/)..."
    
    mkdir -p "$BACKUP_DIR"
    
    rclone sync "$RCLONE_REMOTE:$RCLONE_BUCKET/latest/" "$BACKUP_DIR/" \
        --progress \
        --transfers 4 \
        --checkers 8
    
    if [ ! -f "$BACKUP_DIR/metadata.txt" ]; then
        log_error "备份数据不完整或不存在"
        exit 1
    fi
    
    echo ""
    log_info "备份元数据:"
    cat "$BACKUP_DIR/metadata.txt"
    echo ""
    
    log_ok "下载完成"
}

# ============================================================
# 恢复数据
# ============================================================
restore_data() {
    log_info "恢复数据..."
    
    # 恢复配置文件
    log_info "恢复配置文件..."
    cp "$BACKUP_DIR/.env.plane" "$SCRIPT_DIR/" 2>/dev/null || true
    
    # 恢复 PostgreSQL 数据
    if [ -f "$BACKUP_DIR/postgres_data.tar.gz" ]; then
        log_info "恢复 Gitea PostgreSQL 数据..."
        rm -rf "$GITEA_POSTGRES_DATA"
        mkdir -p "$(dirname $GITEA_POSTGRES_DATA)"
        tar -xzf "$BACKUP_DIR/postgres_data.tar.gz" -C "$(dirname $GITEA_POSTGRES_DATA)"
    fi
    
    # 恢复 Gitea 数据
    if [ -f "$BACKUP_DIR/gitea_data.tar.gz" ]; then
        log_info "恢复 Gitea 数据..."
        rm -rf "$GITEA_DATA"
        mkdir -p "$(dirname $GITEA_DATA)"
        tar -xzf "$BACKUP_DIR/gitea_data.tar.gz" -C "$(dirname $GITEA_DATA)"
    fi
    
    # 恢复 Drone 数据
    if [ -f "$BACKUP_DIR/drone_data.tar.gz" ]; then
        log_info "恢复 Drone 数据..."
        rm -rf "$DRONE_DATA"
        mkdir -p "$(dirname $DRONE_DATA)"
        tar -xzf "$BACKUP_DIR/drone_data.tar.gz" -C "$(dirname $DRONE_DATA)"
    fi
    
    # 恢复 Plane 数据
    if [ -f "$BACKUP_DIR/plane_data.tar.gz" ]; then
        log_info "恢复 Plane 数据..."
        rm -rf "$PLANE_DATA"
        mkdir -p "$(dirname $PLANE_DATA)"
        tar -xzf "$BACKUP_DIR/plane_data.tar.gz" -C "$(dirname $PLANE_DATA)"
    fi
    
    log_ok "数据恢复完成"
}

# ============================================================
# 启动服务
# ============================================================
start_services() {
    log_info "启动服务..."
    
    cd "$SCRIPT_DIR"
    bash depoly.sh || log_warn "Gitea/Drone 启动失败"
    bash depoly-plane-robust.sh || log_warn "Plane 启动失败"
    
    log_ok "服务已启动"
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
    echo -e "${GREEN}DevOps 数据备份拉取${NC}"
    echo "========================================================"
    echo ""
    
    check_dependencies
    stop_services
    download_from_cloud
    restore_data
    cleanup
    start_services
    
    echo ""
    echo "========================================================"
    echo -e "${GREEN}✅ 备份拉取并恢复完成！${NC}"
    echo ""
    echo "访问地址:"
    echo "  Gitea: http://gitea.localhost:8080"
    echo "  Drone: http://drone.localhost:8080"
    echo "  Plane: http://localhost:8090"
    echo "========================================================"
}

main "$@"
