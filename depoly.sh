#!/bin/bash
set -euo pipefail

# ============================================================
# 数据目录配置 - 使用绝对路径防止数据丢失
# ============================================================
POSTGRES_DATA="/home/zyg/postgres_data"
GITEA_DATA="/home/zyg/gitea_data"
DRONE_DATA="/home/zyg/drone_data"
BACKUP_DIR="/home/zyg/backup"

# 脚本所在目录（用于nginx配置等）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_FILE="$SCRIPT_DIR/podman-compose.yml"
NGINX_CONF_DIR="$SCRIPT_DIR/nginx_conf"

# ============================================================
# 安全检查函数
# ============================================================
check_data_safety() {
    local dir="$1"
    local name="$2"
    
    if [[ -d "$dir" ]]; then
        local file_count=$(find "$dir" -type f 2>/dev/null | wc -l)
        if [[ $file_count -gt 0 ]]; then
            echo "✓ $name 数据目录存在且包含 $file_count 个文件: $dir"
            return 0
        else
            echo "⚠ $name 数据目录存在但为空: $dir"
            return 1
        fi
    else
        echo "⚠ $name 数据目录不存在: $dir"
        return 1
    fi
}

echo "============================================================"
echo "Gitea + Drone 部署脚本"
echo "============================================================"

# 检查现有数据
echo ""
echo ">>> 检查数据目录状态..."
POSTGRES_OK=false
GITEA_OK=false

if check_data_safety "$POSTGRES_DATA" "PostgreSQL"; then
    POSTGRES_OK=true
fi

if check_data_safety "$GITEA_DATA" "Gitea"; then
    GITEA_OK=true
fi

# 如果是首次部署（数据目录为空），给出提示
if [[ "$POSTGRES_OK" == "false" ]] && [[ "$GITEA_OK" == "false" ]]; then
    echo ""
    echo ">>> 检测到首次部署，将创建新的数据目录..."
fi

echo ""
echo ">>> 停止并删除旧容器（保留数据卷）..."
podman-compose -f "$PROJECT_FILE" down 2>/dev/null || true

echo ">>> 创建/确认持久化目录..."
mkdir -p "$POSTGRES_DATA" "$GITEA_DATA" "$DRONE_DATA" "$NGINX_CONF_DIR" "$BACKUP_DIR"

echo ">>> 写入 Nginx 配置..."
cat > "$NGINX_CONF_DIR/nginx.conf" <<'EOF'
events {
    worker_connections 1024;
}

http {
    client_max_body_size 512M;

    server {
        listen 8080;
        server_name gitea.localhost;

        location / {
            proxy_pass http://gitea:3000;
            proxy_set_header Host $host:$server_port;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_buffering off;
        }
    }

    server {
        listen 8080;
        server_name drone.localhost;

        location / {
            proxy_pass http://drone:80;
            proxy_set_header Host $host:$server_port;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_buffering off;
        }
    }
}
EOF

echo ">>> 写入 podman-compose.yml..."
cat > "$PROJECT_FILE" <<EOF
version: "3.8"

services:
  postgres:
    image: docker.io/library/postgres:15
    container_name: postgres
    restart: always
    environment:
      POSTGRES_USER: gitea_user
      POSTGRES_PASSWORD: gitea_pass
      POSTGRES_DB: gitea
    volumes:
      - $POSTGRES_DATA:/var/lib/postgresql/data:Z
      - $BACKUP_DIR:/backup:Z
    networks:
      - gitea_net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U gitea_user -d gitea"]
      interval: 10s
      timeout: 5s
      retries: 5

  gitea:
    image: docker.io/gitea/gitea:latest
    container_name: gitea
    restart: always
    environment:
      USER_UID: 1000
      USER_GID: 1000
      DB_TYPE: postgres
      DB_HOST: postgres:5432
      DB_NAME: gitea
      DB_USER: gitea_user
      DB_PASSWD: gitea_pass
      GITEA__server__ROOT_URL: http://gitea.localhost:8080/
      GITEA__server__DOMAIN: gitea.localhost
      GITEA__server__HTTP_PORT: 3000
      GITEA__server__SSH_DOMAIN: localhost
      GITEA__server__SSH_PORT: 2222
      GITEA__server__SSH_LISTEN_PORT: 22
    volumes:
      - $GITEA_DATA:/data:Z
    ports:
      - "2222:22"
    networks:
      gitea_net:
        aliases:
          - gitea.localhost
    depends_on:
      postgres:
        condition: service_healthy

  drone:
    image: docker.io/drone/drone:latest
    container_name: drone
    restart: always
    environment:
      # 改成外部地址，让浏览器能访问
      DRONE_GITEA_SERVER: http://gitea.localhost:8080
      DRONE_GITEA_CLIENT_ID: 1f1eb4d2-61af-451e-9db2-8c79de028b13
      DRONE_GITEA_CLIENT_SECRET: gto_6nkwtczf43crxwewtwa6556zfvtvsfnb6mcruujooihnauxujo5a
      DRONE_RPC_SECRET: super_secret_rpc_key_change_me_123
      DRONE_SERVER_HOST: drone.localhost:8080
      DRONE_SERVER_PROTO: http
      DRONE_USER_CREATE: username:admin,admin:true
      DRONE_LOGS_DEBUG: "true"
    # 添加这行，让容器内能解析 gitea.localhost
    extra_hosts:
      - "gitea.localhost:host-gateway"
    volumes:
      - $DRONE_DATA:/data:Z
    networks:
      gitea_net:
        aliases:
          - drone.localhost
    depends_on:
      - gitea


  drone-agent01:
    image: docker.io/drone/drone-runner-docker:latest
    container_name: drone-agent01
    restart: always
    environment:
      DRONE_RPC_PROTO: http
      DRONE_RPC_HOST: drone:80
      DRONE_RPC_SECRET: super_secret_rpc_key_change_me_123
      DRONE_RUNNER_CAPACITY: 2
      DRONE_RUNNER_NAME: drone-agent01
      DRONE_DEBUG: "true"
    volumes:
      - /run/user/1000/podman/podman.sock:/var/run/docker.sock:Z
    networks:
      - gitea_net
    depends_on:
      - drone

  nginx:
    image: docker.io/library/nginx:latest
    container_name: nginx
    restart: always
    volumes:
      - $NGINX_CONF_DIR/nginx.conf:/etc/nginx/nginx.conf:ro,Z
    ports:
      - "8080:8080"
    networks:
      - gitea_net
    depends_on:
      - gitea
      - drone

networks:
  gitea_net:
    driver: bridge
EOF

echo ">>> 预拉取镜像..."
podman pull docker.io/library/postgres:15
podman pull docker.io/gitea/gitea:latest
podman pull docker.io/drone/drone:latest
podman pull docker.io/drone/drone-runner-docker:latest
podman pull docker.io/library/nginx:latest

# 确保 Podman socket 启用
echo ">>> 确保 Podman socket 已启用..."
systemctl --user enable --now podman.socket || true

echo ">>> 启动所有服务..."
podman-compose -f "$PROJECT_FILE" up -d

cat <<'INSTRUCTIONS'

========================================================
部署完成！请按以下步骤操作：

1. 确保 /etc/hosts 包含：
   127.0.0.1  gitea.localhost drone.localhost

2. 访问 http://gitea.localhost:8080 完成初始化
   - 数据库已预配置，直接点安装即可
   - 创建管理员账号

3. 创建 OAuth2 应用：
   Gitea -> 头像 -> 设置 -> 应用 -> 创建 OAuth2 应用
   - 应用名称: Drone
   - 重定向 URI: http://drone.localhost:8080/login

4. 更新 podman-compose.yml 中的：
   - DRONE_GITEA_CLIENT_ID: 你获取的 Client ID
   - DRONE_GITEA_CLIENT_SECRET: 你获取的 Secret
   - DRONE_USER_CREATE: username:你的gitea用户名,admin:true

5. 重启 Drone：
   podman-compose restart drone drone-agent01

6. 访问 http://drone.localhost:8080 用 Gitea 账号登录

========================================================
INSTRUCTIONS
