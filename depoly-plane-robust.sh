#!/bin/bash
# Plane 项目管理工具 - 稳健版部署脚本
# 特性：完整容错、健康检查、自动重试

# 不使用 set -e，手动处理错误以提供更好的容错
set -uo pipefail

# ============================================================
# 配置
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_FILE="$SCRIPT_DIR/plane-robust.yml"
BASE_DIR="$SCRIPT_DIR/plane_data"
APP_PORT=8090
DOMAIN="localhost"
TAG="latest"
MAX_RETRIES=3
RETRY_DELAY=5

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================
# 容错函数
# ============================================================
retry_command() {
    local cmd="$1"
    local description="$2"
    local retries=0
    
    while [ $retries -lt $MAX_RETRIES ]; do
        log_info "尝试: $description (第 $((retries+1))/$MAX_RETRIES 次)"
        if eval "$cmd"; then
            log_ok "$description 成功"
            return 0
        fi
        retries=$((retries + 1))
        if [ $retries -lt $MAX_RETRIES ]; then
            log_warn "失败，${RETRY_DELAY}秒后重试..."
            sleep $RETRY_DELAY
        fi
    done
    
    log_error "$description 在 $MAX_RETRIES 次尝试后失败"
    return 1
}

wait_for_container() {
    local container="$1"
    local max_wait="${2:-60}"
    local waited=0
    
    log_info "等待容器 $container 启动..."
    while [ $waited -lt $max_wait ]; do
        if podman ps --format "{{.Names}}" | grep -q "^${container}$"; then
            log_ok "容器 $container 正在运行"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    
    log_error "容器 $container 启动超时"
    return 1
}

wait_for_healthy() {
    local container="$1"
    local max_wait="${2:-120}"
    local waited=0
    
    log_info "等待容器 $container 健康检查通过..."
    while [ $waited -lt $max_wait ]; do
        local health=$(podman inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
        if [ "$health" = "healthy" ]; then
            log_ok "容器 $container 健康"
            return 0
        elif [ "$health" = "none" ]; then
            # 没有健康检查，检查是否在运行
            if podman ps --format "{{.Names}}" | grep -q "^${container}$"; then
                log_ok "容器 $container 运行中（无健康检查）"
                return 0
            fi
        fi
        sleep 3
        waited=$((waited + 3))
        echo -n "."
    done
    echo ""
    
    log_warn "容器 $container 健康检查超时，继续执行..."
    return 0
}

check_podman() {
    if ! command -v podman &> /dev/null; then
        log_error "podman 未安装"
        exit 1
    fi
    
    if ! command -v podman-compose &> /dev/null; then
        log_error "podman-compose 未安装，正在安装..."
        sudo apt install -y podman-compose || {
            log_error "安装 podman-compose 失败"
            exit 1
        }
    fi
    
    # 确保 podman socket 启用
    systemctl --user enable --now podman.socket 2>/dev/null || true
    log_ok "Podman 环境检查通过"
}

# ============================================================
# 清理函数
# ============================================================
cleanup_containers() {
    log_info "清理旧容器..."
    
    # 先尝试用 compose 停止
    podman-compose -f "$PROJECT_FILE" down 2>/dev/null || true
    
    # 强制删除可能残留的容器
    local containers="plane-proxy plane-web plane-admin plane-beat plane-worker plane-api plane-migrator plane-createbuckets plane-minio plane-redis plane-db"
    for c in $containers; do
        podman stop "$c" 2>/dev/null || true
        podman rm -f "$c" 2>/dev/null || true
    done
    
    # 清理悬空的网络
    podman network prune -f 2>/dev/null || true
    
    log_ok "清理完成"
}

# ============================================================
# 准备配置
# ============================================================
prepare_dirs() {
    log_info "准备数据目录: $BASE_DIR"
    mkdir -p "$BASE_DIR"/{pg_data,redis_data,minio_data,logs,nginx_conf}
    log_ok "目录准备完成"
}

prepare_env() {
    log_info "生成环境变量配置..."
    
    # 保留现有的 SECRET_KEY
    if [ -f "$SCRIPT_DIR/.env.plane" ] && grep -q "^SECRET_KEY=" "$SCRIPT_DIR/.env.plane"; then
        SECRET_KEY=$(grep "^SECRET_KEY=" "$SCRIPT_DIR/.env.plane" | cut -d'=' -f2)
        log_info "使用现有 SECRET_KEY"
    else
        SECRET_KEY=$(openssl rand -hex 32)
        log_info "生成新 SECRET_KEY"
    fi
    
    MINIO_ACCESS="plane-admin"
    MINIO_SECRET="plane-secret-key-123"
    
    cat > "$SCRIPT_DIR/.env.plane" <<EOF
NGINX_PORT=80
WEB_URL=http://${DOMAIN}:${APP_PORT}
API_BASE_URL=http://${DOMAIN}:${APP_PORT}/api
NEXT_PUBLIC_API_BASE_URL=http://${DOMAIN}:${APP_PORT}/api
DEBUG=0
ENVIRONMENT=production

# 数据库配置
PG_DB=plane
PG_USER=plane
PG_PASSWORD=plane_password
DB_HOST=plane-db
PGHOST=plane-db
PGPORT=5432
DATABASE_URL=postgres://plane:plane_password@plane-db:5432/plane

# Redis 配置
REDIS_HOST=plane-redis
REDIS_PORT=6379
REDIS_URL=redis://plane-redis:6379/
CELERY_BROKER_URL=redis://plane-redis:6379/0
BROKER_URL=redis://plane-redis:6379/0

# 安全密钥
SECRET_KEY=${SECRET_KEY}
JWT_SECRET=${SECRET_KEY}

# MinIO 配置
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=${MINIO_ACCESS}
AWS_SECRET_ACCESS_KEY=${MINIO_SECRET}
AWS_S3_ENDPOINT_URL=http://plane-minio:9000
AWS_S3_BUCKET_NAME=plane-uploads
USE_MINIO=1
MINIO_ROOT_USER=${MINIO_ACCESS}
MINIO_ROOT_PASSWORD=${MINIO_SECRET}

# 应用配置
ENABLE_SIGNUP=1
GUNICORN_WORKERS=4
CORS_ALLOWED_ORIGINS=http://${DOMAIN}:${APP_PORT}
CSRF_TRUSTED_ORIGINS=http://${DOMAIN}:${APP_PORT}
EOF
    
    log_ok "环境变量配置完成"
}

prepare_nginx() {
    log_info "生成 Nginx 配置..."
    cat > "$BASE_DIR/nginx_conf/plane.conf" <<'EOF'
server {
    listen 80;
    server_name _;
    client_max_body_size 100M;
    
    # 前端
    location / {
        proxy_pass http://plane-web:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    # API
    location /api/ {
        proxy_pass http://plane-api:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_connect_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    # 认证
    location /auth/ {
        proxy_pass http://plane-api:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # 管理后台
    location /god-mode/ {
        proxy_pass http://plane-admin:3000/god-mode/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # MinIO 文件存储
    location /plane-uploads/ {
        proxy_pass http://plane-minio:9000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
    log_ok "Nginx 配置完成"
}

prepare_compose() {
    log_info "生成 podman-compose 配置..."
    cat > "$PROJECT_FILE" <<EOF
version: '3.8'

services:
  plane-db:
    image: docker.io/library/postgres:15-alpine
    container_name: plane-db
    restart: always
    environment:
      POSTGRES_USER: plane
      POSTGRES_PASSWORD: plane_password
      POSTGRES_DB: plane
      PGDATA: /var/lib/postgresql/data
    volumes:
      - $BASE_DIR/pg_data:/var/lib/postgresql/data:Z
    networks:
      - plane_net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U plane -d plane"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s

  plane-redis:
    image: docker.io/library/redis:7-alpine
    container_name: plane-redis
    restart: always
    volumes:
      - $BASE_DIR/redis_data:/data:Z
    networks:
      - plane_net
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  plane-minio:
    image: docker.io/minio/minio
    container_name: plane-minio
    restart: always
    command: server /data --console-address ":9090"
    environment:
      MINIO_ROOT_USER: plane-admin
      MINIO_ROOT_PASSWORD: plane-secret-key-123
    volumes:
      - $BASE_DIR/minio_data:/data:Z
    networks:
      - plane_net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 10s
      retries: 3

  plane-createbuckets:
    image: docker.io/minio/mc
    container_name: plane-createbuckets
    depends_on:
      plane-minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
      sleep 5;
      /usr/bin/mc alias set myminio http://plane-minio:9000 plane-admin plane-secret-key-123;
      /usr/bin/mc mb myminio/plane-uploads --ignore-existing;
      /usr/bin/mc anonymous set download myminio/plane-uploads;
      exit 0;
      "
    networks:
      - plane_net

  plane-migrator:
    image: docker.io/makeplane/plane-backend:${TAG}
    container_name: plane-migrator
    restart: "no"
    env_file: $SCRIPT_DIR/.env.plane
    command: ["/bin/sh", "-c", "echo 'Waiting 15s for DB...' && sleep 15 && ./bin/docker-entrypoint-migrator.sh"]
    depends_on:
      plane-db:
        condition: service_healthy
      plane-redis:
        condition: service_healthy
    networks:
      - plane_net

  plane-api:
    image: docker.io/makeplane/plane-backend:${TAG}
    container_name: plane-api
    restart: always
    command: ./bin/docker-entrypoint-api.sh
    env_file: $SCRIPT_DIR/.env.plane
    depends_on:
      plane-db:
        condition: service_healthy
      plane-redis:
        condition: service_healthy
    networks:
      - plane_net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  plane-worker:
    image: docker.io/makeplane/plane-backend:${TAG}
    container_name: plane-worker
    restart: always
    command: ./bin/docker-entrypoint-worker.sh
    env_file: $SCRIPT_DIR/.env.plane
    depends_on:
      - plane-api
    networks:
      - plane_net

  plane-beat:
    image: docker.io/makeplane/plane-backend:${TAG}
    container_name: plane-beat
    restart: always
    command: ./bin/docker-entrypoint-beat.sh
    env_file: $SCRIPT_DIR/.env.plane
    depends_on:
      - plane-api
    networks:
      - plane_net

  plane-web:
    image: docker.io/makeplane/plane-frontend:${TAG}
    container_name: plane-web
    restart: always
    env_file: $SCRIPT_DIR/.env.plane
    command: node web/server.js
    depends_on:
      - plane-api
    networks:
      - plane_net

  plane-admin:
    image: docker.io/makeplane/plane-admin:${TAG}
    container_name: plane-admin
    restart: always
    env_file: $SCRIPT_DIR/.env.plane
    command: node admin/server.js
    depends_on:
      - plane-api
    networks:
      - plane_net

  plane-proxy:
    image: docker.io/library/nginx:alpine
    container_name: plane-proxy
    restart: always
    ports:
      - "${APP_PORT}:80"
    volumes:
      - $BASE_DIR/nginx_conf/plane.conf:/etc/nginx/conf.d/default.conf:ro,Z
    depends_on:
      - plane-web
      - plane-api
      - plane-admin
    networks:
      - plane_net

networks:
  plane_net:
    driver: bridge
EOF
    log_ok "Compose 配置完成"
}

# ============================================================
# 镜像拉取（带重试）
# ============================================================
pull_images() {
    log_info "预拉取镜像（带重试）..."
    
    local images=(
        "docker.io/library/postgres:15-alpine"
        "docker.io/library/redis:7-alpine"
        "docker.io/minio/minio"
        "docker.io/minio/mc"
        "docker.io/makeplane/plane-backend:${TAG}"
        "docker.io/makeplane/plane-frontend:${TAG}"
        "docker.io/makeplane/plane-admin:${TAG}"
        "docker.io/library/nginx:alpine"
    )
    
    for img in "${images[@]}"; do
        if podman image exists "$img" 2>/dev/null; then
            log_ok "镜像已存在: $img"
        else
            retry_command "podman pull $img" "拉取镜像 $img" || {
                log_warn "跳过镜像 $img，将在启动时拉取"
            }
        fi
    done
}

# ============================================================
# 启动服务
# ============================================================
start_services() {
    log_info "启动服务..."
    
    # 使用 podman-compose 启动
    if ! podman-compose -f "$PROJECT_FILE" up -d; then
        log_warn "首次启动失败，重试中..."
        sleep 5
        podman-compose -f "$PROJECT_FILE" up -d || {
            log_error "服务启动失败"
            return 1
        }
    fi
    
    log_ok "服务启动命令已执行"
}

# ============================================================
# 等待所有服务就绪
# ============================================================
wait_for_services() {
    log_info "等待所有服务就绪..."
    
    # 关键服务列表
    local services="plane-db plane-redis plane-minio plane-api plane-web plane-proxy"
    
    for svc in $services; do
        wait_for_container "$svc" 60 || log_warn "容器 $svc 可能未启动"
    done
    
    # 等待数据库健康
    wait_for_healthy "plane-db" 120
    
    # 等待 API 就绪
    log_info "等待 API 服务响应..."
    local waited=0
    while [ $waited -lt 90 ]; do
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${APP_PORT}/api/" 2>/dev/null | grep -q "^[23]"; then
            log_ok "API 服务已就绪"
            break
        fi
        sleep 3
        waited=$((waited + 3))
        echo -n "."
    done
    echo ""
    
    log_ok "服务启动完成"
}

# ============================================================
# 显示状态
# ============================================================
show_status() {
    echo ""
    echo "========================================================"
    echo -e "${GREEN}Plane 部署状态${NC}"
    echo "========================================================"
    
    echo ""
    echo "容器状态:"
    podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(NAMES|plane)" || echo "无 plane 容器运行"
    
    echo ""
    echo "========================================================"
    echo -e "${GREEN}✅ 部署完成！${NC}"
    echo ""
    echo "访问地址: http://${DOMAIN}:${APP_PORT}"
    echo "管理后台: http://${DOMAIN}:${APP_PORT}/god-mode/"
    echo ""
    echo "首次使用请等待约 30 秒让数据库迁移完成"
    echo "========================================================"
}

# ============================================================
# 主流程
# ============================================================
main() {
    echo "========================================================"
    echo "Plane 项目管理工具 - 稳健版部署脚本"
    echo "========================================================"
    echo ""
    
    check_podman
    cleanup_containers
    prepare_dirs
    prepare_env
    prepare_nginx
    prepare_compose
    pull_images
    start_services
    wait_for_services
    show_status
}

# 执行主流程
main "$@"
