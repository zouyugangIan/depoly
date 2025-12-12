#!/bin/bash
# ============================================================
# Cloudflare R2 / Backblaze B2 配置向导
# 用法: bash setup-cloud.sh
# ============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${CYAN}========================================================"
echo "云存储配置向导"
echo "========================================================${NC}"
echo ""

# 检查并安装 rclone
if ! command -v rclone &> /dev/null; then
    echo -e "${YELLOW}[INFO]${NC} rclone 未安装，正在安装..."
    curl https://rclone.org/install.sh | sudo bash
    echo ""
fi

echo -e "${GREEN}rclone 版本:${NC} $(rclone version | head -1)"
echo ""

# 选择云存储
echo -e "${BLUE}请选择云存储服务:${NC}"
echo "  1) Cloudflare R2 (推荐，10GB 免费，无出口流量费)"
echo "  2) Backblaze B2 (10GB 免费)"
echo "  3) 阿里云 OSS"
echo "  4) 手动配置"
echo ""
read -p "请输入选项 [1-4]: " choice

case $choice in
    1)
        echo ""
        echo -e "${CYAN}======== Cloudflare R2 配置步骤 ========${NC}"
        echo ""
        echo "1. 登录 Cloudflare Dashboard: https://dash.cloudflare.com"
        echo "2. 左侧菜单选择 'R2 对象存储'"
        echo "3. 点击 '管理 R2 API 令牌' -> '创建 API 令牌'"
        echo "4. 权限选择 '对象读和写'，TTL 选择 '永久'"
        echo "5. 记录以下信息:"
        echo "   - Access Key ID"
        echo "   - Secret Access Key"
        echo "   - Account ID (在 R2 页面右侧)"
        echo ""
        read -p "准备好了吗？按 Enter 继续配置 rclone..."
        
        echo ""
        echo -e "${YELLOW}请输入以下信息:${NC}"
        read -p "Access Key ID: " access_key
        read -s -p "Secret Access Key: " secret_key
        echo ""
        read -p "Account ID: " account_id
        
        # 创建 rclone 配置
        rclone config create r2 s3 \
            provider Cloudflare \
            access_key_id "$access_key" \
            secret_access_key "$secret_key" \
            endpoint "https://${account_id}.r2.cloudflarestorage.com" \
            acl private
        
        echo ""
        echo -e "${GREEN}✅ Cloudflare R2 配置完成！${NC}"
        ;;
    2)
        echo ""
        echo -e "${CYAN}======== Backblaze B2 配置步骤 ========${NC}"
        echo ""
        echo "1. 登录 Backblaze: https://www.backblaze.com/b2/cloud-storage.html"
        echo "2. 创建账号并登录控制台"
        echo "3. 点击 'App Keys' -> 'Add a New Application Key'"
        echo "4. 记录 keyID 和 applicationKey"
        echo ""
        read -p "准备好了吗？按 Enter 继续配置 rclone..."
        
        echo ""
        echo -e "${YELLOW}请输入以下信息:${NC}"
        read -p "Key ID: " key_id
        read -s -p "Application Key: " app_key
        echo ""
        
        rclone config create r2 b2 \
            account "$key_id" \
            key "$app_key"
        
        echo ""
        echo -e "${GREEN}✅ Backblaze B2 配置完成！${NC}"
        ;;
    3)
        echo ""
        echo -e "${CYAN}======== 阿里云 OSS 配置 ========${NC}"
        echo ""
        read -p "Access Key ID: " access_key
        read -s -p "Secret Access Key: " secret_key
        echo ""
        read -p "Endpoint (如 oss-cn-hangzhou.aliyuncs.com): " endpoint
        
        rclone config create r2 s3 \
            provider Alibaba \
            access_key_id "$access_key" \
            secret_access_key "$secret_key" \
            endpoint "$endpoint" \
            acl private
        
        echo ""
        echo -e "${GREEN}✅ 阿里云 OSS 配置完成！${NC}"
        ;;
    4)
        echo ""
        echo "运行 'rclone config' 进行手动配置"
        rclone config
        ;;
    *)
        echo -e "${RED}无效选项${NC}"
        exit 1
        ;;
esac

# 测试连接
echo ""
echo -e "${BLUE}测试连接...${NC}"
if rclone lsd r2: 2>/dev/null; then
    echo -e "${GREEN}✅ 连接成功！${NC}"
else
    echo -e "${YELLOW}首次使用，尝试创建 bucket...${NC}"
    rclone mkdir r2:devops-backup && echo -e "${GREEN}✅ Bucket 创建成功！${NC}"
fi

echo ""
echo -e "${CYAN}========================================================"
echo "配置完成！"
echo "========================================================${NC}"
echo ""
echo "现在可以使用以下命令:"
echo "  • 推送备份: bash backup-push.sh"
echo "  • 拉取备份: bash backup-pull.sh"
echo ""
