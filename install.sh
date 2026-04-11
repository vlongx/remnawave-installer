#!/usr/bin/env bash
# Remnawave 一键安装脚本（最终线性版）
# Debian / Ubuntu

set -uo pipefail

INSTALL_DIR="/opt/remnawave"
CERT_DIR="/etc/nginx/ssl/remnawave"
NGINX_SITE="/etc/nginx/sites-available/remnawave.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/remnawave.conf"
SYSCTL_FILE="/etc/sysctl.d/99-remnawave.conf"

info()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; exit 1; }
chk()   { [[ "${1:-1}" -eq 0 ]] || die "${2:-命令失败}"; }

# ─── 环境检查 ───────────────────────────────────────────────
[[ "${EUID:-1}" -eq 0 ]] || die "请使用 root 运行本脚本"
command -v apt-get >/dev/null 2>&1 || die "仅支持 Debian / Ubuntu"

# ─── 用户输入 ───────────────────────────────────────────────
read -rp "请输入【面板域名】（例如 panel.example.com）: " MAIN_DOMAIN
[[ -n "${MAIN_DOMAIN:-}" ]] || die "面板域名不能为空"

read -rp "请输入【订阅域名】（留空则与面板相同）: " SUB_DOMAIN
SUB_DOMAIN="${SUB_DOMAIN:-$MAIN_DOMAIN}"

read -rp "请输入【证书邮箱】（例如 admin@example.com）: " EMAIL
[[ -n "${EMAIL:-}" ]] || die "证书邮箱不能为空"

echo
echo "面板域名: $MAIN_DOMAIN"
echo "订阅域名: $SUB_DOMAIN"
echo "证书邮箱: $EMAIL"
echo

# ─── Step 1: 安装依赖 ────────────────────────────────────────
info "[1/9] 安装基础依赖..."
apt-get update -y
chk $? "apt-get update 失败"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl socat cron openssl ca-certificates gnupg \
  lsb-release nginx ufw git iproute2 iptables
chk $? "安装基础依赖失败"

# ─── Step 2: 安装 Docker ─────────────────────────────────────
info "[2/9] 检查 Docker..."
if ! command -v docker >/dev/null 2>&1; then
  info "未检测到 Docker，开始安装..."
  curl -fsSL https://get.docker.com | sh
  chk $? "Docker 安装失败"
else
  info "Docker 已安装，跳过。"
fi

systemctl enable docker >/dev/null 2>&1 || true

if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-plugin
  chk $? "Docker Compose 插件安装失败"
fi

# ─── Step 3: 内核网络参数 ────────────────────────────────────
info "[3/9] 修复内核网络参数..."
modprobe br_netfilter >/dev/null 2>&1 || true

tee "$SYSCTL_FILE" >/dev/null <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
vm.overcommit_memory=1
EOF

sysctl --system >/dev/null 2>&1 || true
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 || true
iptables -P FORWARD ACCEPT >/dev/null 2>&1 || true
ip6tables -P FORWARD ACCEPT >/dev/null 2>&1 || true

# ─── Step 4: 修复 Docker 网络链 ──────────────────────────────
info "[4/9] 修复 Docker 网络链..."
systemctl stop docker.socket  >/dev/null 2>&1 || true
systemctl stop docker.service >/dev/null 2>&1 || true
rm -f /var/lib/docker/network/files/local-kv.db >/dev/null 2>&1 || true
ip link set docker0 down >/dev/null 2>&1 || true
ip link delete docker0 type bridge >/dev/null 2>&1 || true

iptables -t nat    -N DOCKER         >/dev/null 2>&1 || true
iptables -t filter -N DOCKER-USER    >/dev/null 2>&1 || true
iptables -t filter -N DOCKER-FORWARD >/dev/null 2>&1 || true
iptables -t filter -C FORWARD -j DOCKER-USER    >/dev/null 2>&1 \
  || iptables -t filter -I FORWARD 1 -j DOCKER-USER    >/dev/null 2>&1 || true
iptables -t filter -C FORWARD -j DOCKER-FORWARD >/dev/null 2>&1 \
  || iptables -t filter -A FORWARD -j DOCKER-FORWARD   >/dev/null 2>&1 || true
iptables -t filter -C DOCKER-USER -j RETURN >/dev/null 2>&1 \
  || iptables -t filter -A DOCKER-USER -j RETURN       >/dev/null 2>&1 || true

systemctl start docker.socket  >/dev/null 2>&1 || true
systemctl start docker.service
chk $? "Docker 启动失败"
sleep 4

# ─── Step 5: 下载配置文件 ────────────────────────────────────
info "[5/9] 准备 Remnawave 配置..."
mkdir -p "$INSTALL_DIR"
chk $? "无法创建目录 $INSTALL_DIR"
cd "$INSTALL_DIR" || die "无法进入目录 $INSTALL_DIR"

info "  下载 docker-compose.yml..."
curl -fL --connect-timeout 30 --max-time 120 \
  "https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml" \
  -o docker-compose.yml
chk $? "下载 docker-compose.yml 失败"
[[ -s docker-compose.yml ]] || die "docker-compose.yml 文件为空"
info "  docker-compose.yml 下载成功。"

info "  下载 .env.sample..."
curl -fL --connect-timeout 30 --max-time 120 \
  "https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample" \
  -o .env.download
chk $? "下载 .env.sample 失败"
[[ -s .env.download ]] || die ".env.sample 文件为空"
info "  .env.sample 下载成功。"

# 备份旧 .env，使用全新 .env
[[ -f .env ]] && cp -a .env ".env.bak.$(date +%Y%m%d%H%M%S)" || true
mv .env.download .env
chk $? "重命名 .env 失败"

# ─── Step 6: 端口 & 环境变量 ─────────────────────────────────
info "[6/9] 配置端口与环境变量..."

APP_PORT=3000
DB_PORT=6767

if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${APP_PORT}$" 2>/dev/null; then
  APP_PORT=3100
  warn "端口 3000 已占用，改用 3100"
fi
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${DB_PORT}$" 2>/dev/null; then
  DB_PORT=6868
  warn "端口 6767 已占用，改用 6868"
fi

sed -i -E "s|127\.0\.0\.1:3000-3001:3000-3001|127.0.0.1:${APP_PORT}-3001:3000-3001|g" docker-compose.yml
sed -i -E "s|127\.0\.0\.1:3000:3000|127.0.0.1:${APP_PORT}:3000|g"                     docker-compose.yml
sed -i -E "s|127\.0\.0\.1:6767:5432|127.0.0.1:${DB_PORT}:5432|g"                      docker-compose.yml

DB_PASS="$(openssl rand -hex 24)"

_kv() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" .env 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    printf '%s=%s\n' "$key" "$val" >> .env
  fi
}

_kv FRONT_END_DOMAIN       "$MAIN_DOMAIN"
_kv PANEL_DOMAIN           "$MAIN_DOMAIN"
_kv SUB_PUBLIC_DOMAIN      "${SUB_DOMAIN}/api/sub"
_kv JWT_AUTH_SECRET        "$(openssl rand -hex 64)"
_kv JWT_API_TOKENS_SECRET  "$(openssl rand -hex 64)"
_kv METRICS_PASS           "$(openssl rand -hex 32)"
_kv WEBHOOK_SECRET_HEADER  "$(openssl rand -hex 64)"
_kv POSTGRES_PASSWORD      "$DB_PASS"

if grep -qE '^DATABASE_URL=' .env 2>/dev/null; then
  sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:\)[^@]*\(@.*\)|\1${DB_PASS}\2|" .env
else
  printf 'DATABASE_URL="postgresql://postgres:%s@remnawave-db:5432/postgres"\n' "$DB_PASS" >> .env
fi

info "环境变量写入完成。"

# ─── Step 7: 启动容器 ────────────────────────────────────────
info "[7/9] 启动 Remnawave 容器..."
docker compose down --remove-orphans >/dev/null 2>&1 || true
docker rm -f remnawave remnawave-db remnawave-redis >/dev/null 2>&1 || true

docker compose up -d
if [[ $? -ne 0 ]]; then
  warn "首次启动失败，重启 Docker 后重试..."
  systemctl restart docker
  sleep 5
  docker compose up -d
  chk $? "Remnawave 容器启动失败"
fi

info "等待容器就绪 (25秒)..."
sleep 25

for cname in remnawave remnawave-db remnawave-redis; do
  docker ps --filter "name=^${cname}$" --filter "status=running" \
    --format '{{.Names}}' 2>/dev/null | grep -qx "$cname" \
    || { docker compose logs --tail=80 "$cname" 2>/dev/null || true; die "${cname} 容器未运行"; }
done

info "所有容器运行正常。"

# ─── Step 8: 证书 & Nginx ────────────────────────────────────
info "[8/9] 申请 SSL 证书..."
if [[ ! -x /root/.acme.sh/acme.sh ]]; then
  curl https://get.acme.sh | sh -s email="$EMAIL"
  chk $? "acme.sh 安装失败"
fi
ACME=/root/.acme.sh/acme.sh
[[ -x "$ACME" ]] || die "acme.sh 不可用"

mkdir -p "$CERT_DIR"
systemctl stop nginx >/dev/null 2>&1 || true

"$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
"$ACME" --register-account -m "$EMAIL"        >/dev/null 2>&1 || true

DARGS=("-d" "$MAIN_DOMAIN")
[[ "$SUB_DOMAIN" != "$MAIN_DOMAIN" ]] && DARGS+=("-d" "$SUB_DOMAIN")

"$ACME" --issue --standalone "${DARGS[@]}" --keylength ec-256 --force
chk $? "证书申请失败（请确认域名 DNS 已解析到本机 IP 且 80 端口已放行）"

"$ACME" --install-cert -d "$MAIN_DOMAIN" --ecc \
  --fullchain-file "$CERT_DIR/fullchain.cer" \
  --key-file       "$CERT_DIR/privkey.key"
chk $? "证书安装失败"

[[ -f "$CERT_DIR/fullchain.cer" ]] || die "缺少 fullchain.cer"
[[ -f "$CERT_DIR/privkey.key"   ]] || die "缺少 privkey.key"
info "证书申请成功。"

info "写入 Nginx 配置..."
cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $MAIN_DOMAIN $SUB_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $MAIN_DOMAIN $SUB_DOMAIN;

    ssl_certificate     $CERT_DIR/fullchain.cer;
    ssl_certificate_key $CERT_DIR/privkey.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    location / {
        proxy_http_version 1.1;
        proxy_pass         http://127.0.0.1:${APP_PORT};
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   X-Forwarded-Host  \$host;
        proxy_set_header   X-Forwarded-Port  \$server_port;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
        proxy_read_timeout 300;
        proxy_send_timeout 300;
    }
}
EOF
chk $? "写入 Nginx 配置失败"

rm -f /etc/nginx/sites-enabled/default
ln -sf "$NGINX_SITE" "$NGINX_ENABLED"

nginx -t
chk $? "Nginx 配置测试失败"

systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx
chk $? "Nginx 启动失败"
info "Nginx 启动成功。"

# ─── Step 9: 防火墙 ──────────────────────────────────────────
info "[9/9] 防火墙..."
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  info "已放行 80/443。"
else
  warn "UFW 未启用，跳过。"
fi

# ─── 完成 ────────────────────────────────────────────────────
echo
echo "=========================================="
echo " ✅ 安装完成"
echo " 面板地址: https://$MAIN_DOMAIN"
echo " 订阅地址: https://$SUB_DOMAIN/api/sub"
echo " 本地端口: 127.0.0.1:${APP_PORT}"
echo " 安装目录: $INSTALL_DIR"
echo "=========================================="
