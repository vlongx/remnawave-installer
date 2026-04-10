#!/usr/bin/env bash
# Remnawave 一键安装脚本 (Ultimate Edition)

set -e

INSTALL_DIR="/opt/remnawave"
NGINX_DIR="/opt/remnawave/nginx"

echo "=========================================="
echo " Remnawave 一键安装脚本 (稳定完美版)"
echo "=========================================="
echo "注意事项："
echo "1. 请确保域名已解析到本机 IP。"
echo "2. 阿里云/腾讯云/AWS 等用户请务必在网页后台安全组放行 80 和 443 端口。"
echo "=========================================="
echo "本脚本将完成以下操作："
echo "1. 安装 Docker（如未安装）"
echo "2. 拉取 Remnawave 官方 docker-compose 与 .env"
echo "3. 自动生成 JWT / Postgres 等随机密钥"
echo "4. 设置订阅域名 SUB_PUBLIC_DOMAIN"
echo "5. 启动 Remnawave 面板 (已修复 0.0.0.0 监听与 iptables 冲突)"
echo "6. 切换 CA 到 Let's Encrypt 并申请证书"
echo "7. 生成 Nginx 配置 (已解决 HTTPS 代理拦截) 并启动"
echo "=========================================="
echo

#------------------------#
# 0. 检查 root 权限
#------------------------#
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 运行本脚本（例如：sudo bash install.sh）"
  exit 1
fi

#------------------------#
# 1. 交互获取域名与邮箱
#------------------------#
read -rp "请输入用于【面板访问】的域名（例如 panel.example.com）: " MAIN_DOMAIN
if [ -z "$MAIN_DOMAIN" ]; then
  echo "域名不能为空，退出。"
  exit 1
fi

read -rp "请输入用于【订阅地址】的域名（可留空，留空则与面板域名相同）: " SUB_DOMAIN
if [ -z "$SUB_DOMAIN" ]; then
  SUB_DOMAIN="$MAIN_DOMAIN"
fi

read -rp "请输入用于申请证书的邮箱（例如 admin@example.com）: " EMAIL
if [ -z "$EMAIL" ]; then
  echo "邮箱不能为空，退出。"
  exit 1
fi

echo
echo "面板域名: $MAIN_DOMAIN"
echo "订阅域名: $SUB_DOMAIN"
echo "证书邮箱: $EMAIL"
echo

#------------------------#
# 2. 安装基础依赖与【关闭防火墙】
#------------------------#
echo ">>> [1/8] 更新软件源并安装依赖..."
apt-get update -y
apt-get install -y curl socat cron openssl iptables ufw

echo ">>> [2/8] 正在执行：关闭防火墙并放行所有端口..."

# 关闭 UFW
if command -v ufw >/dev/null 2>&1; then
    echo "   - 正在禁用 UFW..."
    ufw disable
fi

# 清空 iptables 规则并允许所有流量
if command -v iptables >/dev/null 2>&1; then
    echo "   - 正在清空 iptables 规则并允许所有连接..."
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -F
    iptables -X
    
    # 尝试保存规则
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
    fi
fi

echo "✅ 防火墙已关闭，所有端口已放行。"

#------------------------#
# 3. 安装 Docker (并修复 iptables 链)
#------------------------#
if ! command -v docker >/dev/null 2>&1; then
  echo ">>> [3/8] 未检测到 Docker，正在安装..."
  curl -fsSL https://get.docker.com | sh
else
  echo ">>> [3/8] Docker 已安装，跳过安装环节。"
fi

# === 核心修复 3: 重启 Docker 以重建被清理的 iptables 链 ===
echo "   - 正在重启 Docker 服务以恢复网络路由链..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart docker
    sleep 3 # 等待 Docker 完全启动
fi

#------------------------#
# 4. 下载文件并修复格式错误
#------------------------#
echo ">>> [4/8] 创建目录并下载配置文件..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

if [ ! -f docker-compose.yml ]; then
  echo "   - 正在下载 docker-compose.yml..."
  curl -o docker-compose.yml https://raw.githubusercontent.com/vlongx/remnawave-installer/refs/heads/main/docker-compose.yml
  
  echo "   - 正在自动修复 docker-compose.yml 中的格式错误..."
  sed -i '/\/opt\/remnawave\/nginx/d' docker-compose.yml
fi

if [ ! -f .env ]; then
  curl -o .env https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample
fi

#------------------------#
# 5. 配置 .env 并启动后端 
#------------------------#
echo ">>> [5/8] 正在强制生成新密钥并配置后端..."

# 强制替换安全密钥
sed -i "s/^JWT_AUTH_SECRET=.*/JWT_AUTH_SECRET=$(openssl rand -hex 64)/" .env
sed -i "s/^JWT_API_TOKENS_SECRET=.*/JWT_API_TOKENS_SECRET=$(openssl rand -hex 64)/" .env
sed -i "s/^METRICS_PASS=.*/METRICS_PASS=$(openssl rand -hex 64)/" .env
sed -i "s/^WEBHOOK_SECRET_HEADER=.*/WEBHOOK_SECRET_HEADER=$(openssl rand -hex 64)/" .env

# 强制重置数据库密码
pw=$(openssl rand -hex 24)
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$pw/" .env
sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:\)[^@]*\(@.*\)|\1$pw\2|" .env

# 设置订阅域名
if grep -q "^SUB_PUBLIC_DOMAIN=" .env; then
  sed -i "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=${SUB_DOMAIN}/api/sub|" .env
else
  echo "SUB_PUBLIC_DOMAIN=${SUB_DOMAIN}/api/sub" >> .env
fi

# === 核心修复 1: 强制后端监听 0.0.0.0 防止 Nginx 连不上 (Connection refused) ===
if ! grep -q "^HOST=" .env; then
  echo "HOST=0.0.0.0" >> .env
else
  sed -i "s/^HOST=.*/HOST=0.0.0.0/" .env
fi

if ! grep -q "^APP_HOST=" .env; then
  echo "APP_HOST=0.0.0.0" >> .env
else
  sed -i "s/^APP_HOST=.*/APP_HOST=0.0.0.0/" .env
fi

echo "   - 正在启动后端容器以应用新配置..."
docker compose down >/dev/null 2>&1 || true
docker compose up -d
echo ">>> Remnawave 后端容器已成功启动。"

#------------------------#
# 6. 申请 SSL 证书
#------------------------#
echo ">>> [6/8] 配置 acme.sh 并申请证书..."

docker network create remnawave-network >/dev/null 2>&1 || true

if [ ! -d "$HOME/.acme.sh" ]; then
  curl https://get.acme.sh | sh -s email="$EMAIL"
fi
ACME_SH="$HOME/.acme.sh/acme.sh"
mkdir -p "$NGINX_DIR"

echo "   - 切换 CA 为 Let's Encrypt..."
$ACME_SH --set-default-ca --server letsencrypt
$ACME_SH --register-account -m "$EMAIL" || true

docker stop remnawave-nginx >/dev/null 2>&1 || true

echo "   - 开始申请证书 (Standalone 模式)..."
$ACME_SH --issue --standalone -d "$MAIN_DOMAIN" \
  --key-file "$NGINX_DIR/privkey.key" \
  --fullchain-file "$NGINX_DIR/fullchain.pem" \
  --force

if [ ! -f "$NGINX_DIR/fullchain.pem" ]; then
    echo "❌ 证书申请失败！请确认域名解析正确并在云服务商后台开放了 80 端口。"
    exit 1
fi
echo "✅ 证书申请成功。"

#------------------------#
# 7. 生成 Nginx 配置
#------------------------#
echo ">>> [7/8] 生成 Nginx 配置文件..."

cat > "$NGINX_DIR/nginx.conf" <<EOF
upstream remnawave {
    server remnawave:3000;
}

server {
    listen 80;
    listen [::]:80;
    server_name $MAIN_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    server_name $MAIN_DOMAIN;

    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        # === 核心修复 2: 强制声明 https，防止后端安全拦截 (Empty reply / 502) ===
        proxy_set_header X-Forwarded-Proto https; 
        
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
    
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;
    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.key";
}
EOF

#------------------------#
# 8. 启动 Nginx
#------------------------#
echo ">>> [8/8] 启动 Nginx 反代容器..."

cat > "$NGINX_DIR/docker-compose.yml" <<'EOF'
services:
  remnawave-nginx:
    image: nginx:alpine
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
      - ./privkey.key:/etc/nginx/ssl/privkey.key:ro
    restart: always
    ports:
      - '0.0.0.0:80:80'
      - '0.0.0.0:443:443'
    networks:
      - remnawave-network

networks:
  remnawave-network:
    name: remnawave-network
    external: true
EOF

cd "$NGINX_DIR"
docker compose down --remove-orphans >/dev/null 2>&1 || true
docker compose up -d

echo
echo "=========================================="
echo " ✅ 修复与安装全部完成！"
echo " 面板地址：https://$MAIN_DOMAIN"
echo " 订阅域名：$SUB_DOMAIN"
echo "=========================================="
