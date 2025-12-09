#!/bin/bash
set -euo pipefail

# === 配置 ===
PROJECT_FILE="plane-new.yml"
BASE_DIR="./plane_data_new"
APP_PORT=8090
DOMAIN="localhost"
# 必须使用 latest，其他 tag 都在 DockerHub 上消失了
TAG="latest"

echo ">>> 1. 清理残局..."
podman-compose -f "$PROJECT_FILE" down || true
podman rm -f plane-proxy plane-web plane-beat plane-worker plane-api plane-migrator plane-createbuckets plane-minio plane-redis plane-db || true

echo ">>> 2. 准备目录: $BASE_DIR ..."
mkdir -p "$BASE_DIR"/{pg_data,redis_data,minio_data,logs,nginx_conf}

# 保留现有的 SECRET_KEY (关键修复：避免每次重新生成导致用户登出)
if [ -f .env ] && grep -q "^SECRET_KEY=" .env; then
    SECRET_KEY=$(grep "^SECRET_KEY=" .env | cut -d'=' -f2)
    echo ">>> 使用现有 SECRET_KEY"
else
    SECRET_KEY=$(openssl rand -hex 32)
    echo ">>> 生成新 SECRET_KEY"
fi

MINIO_ACCESS="plane-admin"
MINIO_SECRET="plane-secret-key-123"

echo ">>> 3. 生成环境变量 (.env)..."
cat > .env <<EOF
NGINX_PORT=80
WEB_URL=http://${DOMAIN}:${APP_PORT}
API_BASE_URL=http://${DOMAIN}:${APP_PORT}/api
NEXT_PUBLIC_API_BASE_URL=http://${DOMAIN}:${APP_PORT}/api
DEBUG=0
ENVIRONMENT=production

# --- 数据库配置修复 ---
PG_DB=plane
PG_USER=plane
PG_PASSWORD=plane_password

# Plane 应用配置读取的变量
DB_HOST=plane-db
# 强制底层驱动使用 TCP 连接的变量 (关键修复)
PGHOST=plane-db
PGPORT=5432
DATABASE_URL=postgres://plane:plane_password@plane-db:5432/plane
# --------------------

REDIS_HOST=plane-redis
REDIS_PORT=6379
REDIS_URL=redis://plane-redis:6379/
# Celery 配置 - 使用 Redis 作为消息代理
CELERY_BROKER_URL=redis://plane-redis:6379/0
BROKER_URL=redis://plane-redis:6379/0
SECRET_KEY=${SECRET_KEY}
JWT_SECRET=${SECRET_KEY}
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=${MINIO_ACCESS}
AWS_SECRET_ACCESS_KEY=${MINIO_SECRET}
AWS_S3_ENDPOINT_URL=http://plane-minio:9000
AWS_S3_BUCKET_NAME=plane-uploads
USE_MINIO=1
MINIO_ROOT_USER=${MINIO_ACCESS}
MINIO_ROOT_PASSWORD=${MINIO_SECRET}
ENABLE_SIGNUP=1
GUNICORN_WORKERS=4

# CORS 和 CSRF 配置 - 修复表单提交失败问题
CORS_ALLOWED_ORIGINS=http://${DOMAIN}:${APP_PORT}
CSRF_TRUSTED_ORIGINS=http://${DOMAIN}:${APP_PORT}
EOF

echo ">>> 4. 写入 Nginx 配置..."
cat > "$BASE_DIR/nginx_conf/plane.conf" <<EOF
server {
    listen 80;
    server_name _;
    client_max_body_size 100M;
    location / {
        proxy_pass http://plane-web:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location /api/ {
        proxy_pass http://plane-api:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    # 添加认证路由 - 修复登录/注册问题
    location /auth/ {
        proxy_pass http://plane-api:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    # God Mode (管理后台) 路由
    location /god-mode/ {
        proxy_pass http://plane-admin:3000/god-mode/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location /plane-uploads/ {
        proxy_pass http://plane-minio:9000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

echo ">>> 5. 生成 $PROJECT_FILE ..."
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
      retries: 5

  plane-redis:
    image: docker.io/library/redis:7-alpine
    container_name: plane-redis
    restart: always
    volumes:
      - $BASE_DIR/redis_data:/data:Z
    networks:
      - plane_net

  plane-minio:
    image: docker.io/minio/minio
    container_name: plane-minio
    restart: always
    command: server /data --console-address ":9090"
    environment:
      MINIO_ROOT_USER: ${MINIO_ACCESS}
      MINIO_ROOT_PASSWORD: ${MINIO_SECRET}
    volumes:
      - $BASE_DIR/minio_data:/data:Z
    networks:
      - plane_net

  createbuckets:
    image: docker.io/minio/mc
    container_name: plane-createbuckets
    depends_on:
      - plane-minio
    entrypoint: >
      /bin/sh -c "
      /usr/bin/mc alias set myminio http://plane-minio:9000 ${MINIO_ACCESS} ${MINIO_SECRET};
      /usr/bin/mc mb myminio/plane-uploads || true;
      /usr/bin/mc anonymous set download myminio/plane-uploads;
      exit 0;
      "
    networks:
      - plane_net

  # 数据库迁移 (关键修复点)
  plane-migrator:
    image: docker.io/makeplane/plane-backend:${TAG}
    container_name: plane-migrator
    # 必须加引号，解决 "False" 报错
    restart: "no"
    env_file: .env
    # 终极修复：使用 sleep 等待，确保数据库可用
    command: ["/bin/sh", "-c", "echo 'Waiting 10s for DB...' && sleep 10 && ./bin/docker-entrypoint-migrator.sh"]
    depends_on:
      - plane-db
      - plane-redis
    networks:
      - plane_net

  plane-api:
    image: docker.io/makeplane/plane-backend:${TAG}
    container_name: plane-api
    restart: always
    # 最新版正确命令
    command: ./bin/docker-entrypoint-api.sh
    env_file: .env
    depends_on:
      - plane-db
      - plane-redis
    networks:
      - plane_net

  plane-worker:
    image: docker.io/makeplane/plane-backend:${TAG}
    container_name: plane-worker
    restart: always
    command: ./bin/docker-entrypoint-worker.sh
    env_file: .env
    depends_on:
      - plane-api
      - plane-db
      - plane-redis
    networks:
      - plane_net

  plane-beat:
    image: docker.io/makeplane/plane-backend:${TAG}
    container_name: plane-beat
    restart: always
    command: ./bin/docker-entrypoint-beat.sh
    env_file: .env
    depends_on:
      - plane-api
      - plane-db
      - plane-redis
    networks:
      - plane_net

  plane-web:
    image: docker.io/makeplane/plane-frontend:${TAG}
    container_name: plane-web
    restart: always
    env_file: .env
    # 修复：默认CMD是 node，需要指定运行 web/server.js
    command: node web/server.js
    depends_on:
      - plane-api
    networks:
      - plane_net

  # 管理后台 (God Mode)
  plane-admin:
    image: docker.io/makeplane/plane-admin:${TAG}
    container_name: plane-admin
    restart: always
    env_file: .env
    command: node admin/server.js
    depends_on:
      - plane-api
    networks:
      - plane_net

  nginx:
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

echo ">>> 6. 确保 Podman socket..."
systemctl --user enable --now podman.socket || true

echo ">>> 7. 启动服务..."
podman-compose -f "$PROJECT_FILE" up -d

echo "========================================================"
echo "✅ 部署命令已下达"
echo "请等待 30 秒，让 Migrator 跑完初始化。"
echo "访问: http://${DOMAIN}:${APP_PORT}"
echo "========================================================"