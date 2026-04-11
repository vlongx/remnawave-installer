#!/usr/bin/env bash
# Remnawave 一键安装脚本（修正版 / 官方结构优化版）

set -Eeuo pipefail

INSTALL_DIR="/opt/remnawave"
CERT_DIR="/etc/nginx/ssl/remnawave"
NGINX_CONF="/etc/nginx/sites-available/remnawave.conf"

log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
die()  { err "$*"; exit 1; }

trap 'err "脚本在第 $LINENO 行执行失败。"; exit 1' ERR

require_root() {
  [[ $EUID -eq 0 ]] || die "请使用 root 运行本脚本（例如：sudo bash install.sh）"
}

require_debian() {
  command -v apt-get >/dev/null 2>&1 || die "当前脚本仅支持 Debian/Ubuntu 系"
}

backup_if_exists() {
  local f="$1"
  [[ -e "$f" ]] && cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
}

set_kv() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

main() {
  require_root
  require_debian

  echo "=========================================="
  echo " Remnawave 一键安装脚本（修正版）"
  echo "=========================================="
  echo "注意事项："
  echo "1. 请确保域名已解析到本机 IP。"
  echo "2. 云厂商安全组请放行 80 和 443 端口。"
  echo "3. 本脚本按官方结构部署面板，并通过 Nginx 反代。"
  echo "=========================================="
  echo

  read -rp "请输入【面板访问域名】（例如 panel.example.com）: " MAIN_DOMAIN
  [[ -n "${MAIN_DOMAIN}" ]] || die "面板域名不能为空"

  read -rp "请输入【订阅域名】（留空则与面板域名相同）: " SUB_DOMAIN
  SUB_DOMAIN="${SUB_DOMAIN:-$MAIN_DOMAIN}"

  read -rp "请输入【证书邮箱】（例如 admin@example.com）: " EMAIL
  [[ -n "${EMAIL}" ]] || die "证书邮箱不能为空"

  echo
  echo "面板域名: $MAIN_DOMAIN"
  echo "订阅域名: $SUB_DOMAIN"
  echo "证书邮箱: $EMAIL"
  echo

  log "更新软件源并安装依赖..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl socat cron openssl ca-certificates nginx ufw

  if ! command -v docker >/dev/null 2>&1; then
    log "未检测到 Docker，开始安装..."
    curl -fsSL https://get.docker.com | sh
  else
    log "Docker 已安装，跳过安装。"
  fi

  systemctl enable --now docker

  if ! docker compose version >/dev/null 2>&1; then
    log "安装 docker compose 插件..."
    apt-get install -y docker-compose-plugin
  fi

  log "准备 Remnawave 目录..."
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  backup_if_exists "$INSTALL_DIR/docker-compose.yml"
  backup_if_exists "$INSTALL_DIR/.env"

  log "下载官方 docker-compose 与 .env.sample..."
  curl -fsSL https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml -o docker-compose.yml

  if [[ ! -f .env ]]; then
    curl -fsSL https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample -o .env
  fi

  log "写入 .env 配置..."
  set_kv .env FRONT_END_DOMAIN "$MAIN_DOMAIN"
  set_kv .env PANEL_DOMAIN "$MAIN_DOMAIN"
  set_kv .env SUB_PUBLIC_DOMAIN "${SUB_DOMAIN}/api/sub"

  set_kv .env JWT_AUTH_SECRET "$(openssl rand -hex 64)"
  set_kv .env JWT_API_TOKENS_SECRET "$(openssl rand -hex 64)"
  set_kv .env METRICS_PASS "$(openssl rand -hex 64)"
  set_kv .env WEBHOOK_SECRET_HEADER "$(openssl rand -hex 64)"

  DB_PASS="$(openssl rand -hex 24)"
  set_kv .env POSTGRES_PASSWORD "$DB_PASS"

  if grep -q '^DATABASE_URL=' .env; then
    sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:\)[^@]*\(@.*\)|\1${DB_PASS}\2|" .env
  else
    echo "DATABASE_URL=\"postgresql://postgres:${DB_PASS}@remnawave-db:5432/postgres\"" >> .env
  fi

  log "启动 Remnawave 容器..."
  docker compose down --remove-orphans >/dev/null 2>&1 || true
  docker compose up -d

  log "等待 Remnawave 后端启动..."
  for _ in $(seq 1 40); do
    if curl -fsS http://127.0.0.1:3000 >/dev/null 2>&1; then
      break
    fi
    sleep 3
  done

  if ! curl -fsS http://127.0.0.1:3000 >/dev/null 2>&1; then
    docker compose ps || true
    docker compose logs --tail=100 || true
    die "Remnawave 未能在 127.0.0.1:3000 正常启动，请检查上方日志。"
  fi

  log "安装 acme.sh..."
  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    curl https://get.acme.sh | sh -s email="$EMAIL"
  fi
  ACME_SH="/root/.acme.sh/acme.sh"

  mkdir -p "$CERT_DIR"
  systemctl stop nginx >/dev/null 2>&1 || true

  DOMAIN_ARGS=(-d "$MAIN_DOMAIN")
  if [[ "$SUB_DOMAIN" != "$MAIN_DOMAIN" ]]; then
    DOMAIN_ARGS+=(-d "$SUB_DOMAIN")
  fi

  log "切换默认证书 CA 到 Let's Encrypt..."
  "$ACME_SH" --set-default-ca --server letsencrypt
  "$ACME_SH" --register-account -m "$EMAIL" || true

  log "申请/更新 SSL 证书..."
  "$ACME_SH" --issue --standalone "${DOMAIN_ARGS[@]}" --keylength ec-256 --force

  "$ACME_SH" --install-cert -d "$MAIN_DOMAIN" --ecc \
    --fullchain-file "$CERT_DIR/fullchain.cer" \
    --key-file "$CERT_DIR/privkey.key"

  log "生成 Nginx 配置..."
  cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $MAIN_DOMAIN $SUB_DOMAIN;

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $MAIN_DOMAIN $SUB_DOMAIN;

    ssl_certificate     $CERT_DIR/fullchain.cer;
    ssl_certificate_key $CERT_DIR/privkey.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_tickets off;

    client_max_body_size 20m;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300;
        proxy_send_timeout 300;
    }
}
EOF

  rm -f /etc/nginx/sites-enabled/default
  ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/remnawave.conf

  log "测试并启动 Nginx..."
  nginx -t
  systemctl enable --now nginx
  systemctl restart nginx

  if ufw status 2>/dev/null | grep -q "Status: active"; then
    log "检测到 UFW 已启用，仅放行 80/443..."
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
  else
    warn "UFW 未启用，跳过防火墙规则调整。"
  fi

  echo
  echo "=========================================="
  echo " ✅ 安装完成"
  echo " 面板地址: https://$MAIN_DOMAIN"
  echo " 订阅地址: https://$SUB_DOMAIN/api/sub"
  echo " 安装目录: $INSTALL_DIR"
  echo "=========================================="
}

main "$@"
