#!/usr/bin/env bash
# Remnawave 一键安装脚本（最终版）
# 适用：Debian / Ubuntu
# 特性：
# - 使用官方 docker-compose-prod.yml 与 .env.sample
# - 自动修复 Docker bridge / iptables 常见问题
# - 自动避让本地端口冲突（3000/6767）
# - 自动申请 Let's Encrypt 证书
# - 自动配置 Nginx HTTPS 反向代理

set -Eeuo pipefail

INSTALL_DIR="/opt/remnawave"
NGINX_SITE="/etc/nginx/sites-available/remnawave.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/remnawave.conf"
CERT_DIR="/etc/nginx/ssl/remnawave"
SYSCTL_FILE="/etc/sysctl.d/99-remnawave-docker.conf"

info()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
die()   { error "$*"; exit 1; }

trap 'error "脚本在第 $LINENO 行执行失败。"; exit 1' ERR

require_root() {
  [[ "$EUID" -eq 0 ]] || die "请使用 root 运行本脚本（例如：sudo bash install.sh）"
}

require_apt() {
  command -v apt-get >/dev/null 2>&1 || die "当前脚本仅支持 Debian / Ubuntu"
}

backup_if_exists() {
  local f="$1"
  [[ -e "$f" ]] && cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
}

set_env_kv() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

port_in_use() {
  local port="$1"
  ss -lnt "( sport = :$port )" 2>/dev/null | grep -q ":$port"
}

find_free_port() {
  local start="$1"
  local p="$start"
  while port_in_use "$p"; do
    p=$((p + 1))
  done
  echo "$p"
}

install_base() {
  info "安装基础依赖..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl socat cron openssl ca-certificates gnupg lsb-release \
    nginx ufw iptables iproute2
}

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    info "未检测到 Docker，开始安装..."
    curl -fsSL https://get.docker.com | sh
  else
    info "Docker 已安装，跳过安装。"
  fi

  systemctl enable docker >/dev/null 2>&1 || true
  systemctl restart docker || true

  if ! docker compose version >/dev/null 2>&1; then
    info "安装 Docker Compose 插件..."
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
  fi
}

fix_kernel_network() {
  info "修复内核转发与 bridge 网络参数..."

  modprobe br_netfilter || true

  cat > "$SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF

  sysctl --system >/dev/null || true
  sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null || true
  sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null || true
  sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null || true

  iptables -P FORWARD ACCEPT || true
  ip6tables -P FORWARD ACCEPT || true
}

repair_docker_network() {
  info "检测并修复 Docker 网络链..."

  systemctl stop docker.service >/dev/null 2>&1 || true
  systemctl stop docker.socket >/dev/null 2>&1 || true

  rm -f /var/lib/docker/network/files/local-kv.db || true

  ip link show docker0 >/dev/null 2>&1 && ip link set docker0 down || true
  ip link delete docker0 type bridge >/dev/null 2>&1 || true

  iptables -t nat -N DOCKER >/dev/null 2>&1 || true
  iptables -t filter -N DOCKER-USER >/dev/null 2>&1 || true
  iptables -t filter -N DOCKER-FORWARD >/dev/null 2>&1 || true

  iptables -t filter -C FORWARD -j DOCKER-USER >/dev/null 2>&1 || iptables -t filter -I FORWARD 1 -j DOCKER-USER || true
  iptables -t filter -C FORWARD -j DOCKER-FORWARD >/dev/null 2>&1 || iptables -t filter -A FORWARD -j DOCKER-FORWARD || true
  iptables -t filter -C DOCKER-USER -j RETURN >/dev/null 2>&1 || iptables -t filter -A DOCKER-USER -j RETURN || true

  systemctl start docker.socket >/dev/null 2>&1 || true
  systemctl start docker.service
  sleep 5

  docker network inspect bridge >/dev/null 2>&1 || true
}

prepare_project() {
  info "准备 Remnawave 目录与配置..."
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  backup_if_exists "$INSTALL_DIR/docker-compose.yml"
  backup_if_exists "$INSTALL_DIR/.env"

  info "下载官方 docker-compose 与 .env.sample..."
  curl -fsSL https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml -o docker-compose.yml

  if [[ ! -f .env ]]; then
    curl -fsSL https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample -o .env
  fi
}

select_ports() {
  APP_PORT="$(find_free_port 3000)"
  DB_PORT="$(find_free_port 6767)"

  if [[ "$APP_PORT" != "3000" ]]; then
    warn "127.0.0.1:3000 已被占用，自动改用 127.0.0.1:${APP_PORT}"
  fi

  if [[ "$DB_PORT" != "6767" ]]; then
    warn "127.0.0.1:6767 已被占用，自动改用 127.0.0.1:${DB_PORT}"
  fi
}

patch_compose_ports() {
  info "调整 docker-compose 端口绑定..."

  sed -i -E "s|127\.0\.0\.1:3000:3000|127.0.0.1:${APP_PORT}:3000|g" docker-compose.yml
  sed -i -E "s|127\.0\.0\.1:6767:5432|127.0.0.1:${DB_PORT}:5432|g" docker-compose.yml
}

configure_env() {
  info "写入 Remnawave 环境变量..."

  set_env_kv .env FRONT_END_DOMAIN "$MAIN_DOMAIN"
  set_env_kv .env PANEL_DOMAIN "$MAIN_DOMAIN"
  set_env_kv .env SUB_PUBLIC_DOMAIN "${SUB_DOMAIN}/api/sub"

  set_env_kv .env JWT_AUTH_SECRET "$(openssl rand -hex 64)"
  set_env_kv .env JWT_API_TOKENS_SECRET "$(openssl rand -hex 64)"
  set_env_kv .env METRICS_PASS "$(openssl rand -hex 64)"
  set_env_kv .env WEBHOOK_SECRET_HEADER "$(openssl rand -hex 64)"

  DB_PASS="$(openssl rand -hex 24)"
  set_env_kv .env POSTGRES_PASSWORD "$DB_PASS"

  if grep -q '^DATABASE_URL=' .env; then
    sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:\)[^@]*\(@.*\)|\1${DB_PASS}\2|" .env
  else
    echo "DATABASE_URL=\"postgresql://postgres:${DB_PASS}@remnawave-db:5432/postgres\"" >> .env
  fi
}

start_stack() {
  info "启动 Remnawave 容器..."
  cd "$INSTALL_DIR"

  docker compose down --remove-orphans >/dev/null 2>&1 || true
  docker rm -f remnawave remnawave-db remnawave-redis >/dev/null 2>&1 || true

  docker compose up -d

  info "等待 Remnawave 服务启动..."
  local ok=0
  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:${APP_PORT}" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 3
  done

  if [[ "$ok" -ne 1 ]]; then
    warn "服务仍未就绪，输出最近日志："
    docker compose ps || true
    docker compose logs --tail=150 || true
    die "Remnawave 未能成功启动。"
  fi
}

install_acme() {
  info "安装 acme.sh..."
  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    curl https://get.acme.sh | sh -s email="$EMAIL"
  fi
  ACME_SH="/root/.acme.sh/acme.sh"
}

issue_cert() {
  info "申请 SSL 证书..."
  mkdir -p "$CERT_DIR"

  systemctl stop nginx >/dev/null 2>&1 || true

  "$ACME_SH" --set-default-ca --server letsencrypt
  "$ACME_SH" --register-account -m "$EMAIL" || true

  local args=()
  args+=(-d "$MAIN_DOMAIN")
  if [[ "$SUB_DOMAIN" != "$MAIN_DOMAIN" ]]; then
    args+=(-d "$SUB_DOMAIN")
  fi

  "$ACME_SH" --issue --standalone "${args[@]}" --keylength ec-256 --force
  "$ACME_SH" --install-cert -d "$MAIN_DOMAIN" --ecc \
    --fullchain-file "$CERT_DIR/fullchain.cer" \
    --key-file "$CERT_DIR/privkey.key"

  [[ -f "$CERT_DIR/fullchain.cer" ]] || die "证书安装失败：缺少 fullchain.cer"
  [[ -f "$CERT_DIR/privkey.key" ]] || die "证书安装失败：缺少 privkey.key"
}

write_nginx() {
  info "写入 Nginx 配置..."
  backup_if_exists "$NGINX_SITE"

  cat > "$NGINX_SITE" <<EOF
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
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port 443;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300;
        proxy_send_timeout 300;
    }
}
EOF

  rm -f /etc/nginx/sites-enabled/default
  ln -sf "$NGINX_SITE" "$NGINX_ENABLED"

  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      info "检测到 UFW 已启用，仅放行 80/443..."
      ufw allow 80/tcp >/dev/null 2>&1 || true
      ufw allow 443/tcp >/dev/null 2>&1 || true
    else
      warn "UFW 未启用，跳过 UFW 规则调整。"
    fi
  fi
}

main() {
  require_root
  require_apt

  echo "=========================================="
  echo " Remnawave 一键安装脚本（最终版）"
  echo "=========================================="
  echo "说明："
  echo "1. 使用官方 docker-compose-prod.yml"
  echo "2. 自动修复 Docker 网络链常见故障"
  echo "3. 自动避让 3000 / 6767 端口冲突"
  echo "4. 自动配置 Nginx + Let's Encrypt"
  echo "5. 不清空整机 iptables 规则"
  echo "=========================================="
  echo

  read -rp "请输入【面板访问域名】（例如 panel.example.com）: " MAIN_DOMAIN
  [[ -n "$MAIN_DOMAIN" ]] || die "面板域名不能为空"

  read -rp "请输入【订阅域名】（留空则与面板域名相同）: " SUB_DOMAIN
  SUB_DOMAIN="${SUB_DOMAIN:-$MAIN_DOMAIN}"

  read -rp "请输入【证书邮箱】（例如 admin@example.com）: " EMAIL
  [[ -n "$EMAIL" ]] || die "证书邮箱不能为空"

  echo
  echo "面板域名: $MAIN_DOMAIN"
  echo "订阅域名: $SUB_DOMAIN"
  echo "证书邮箱: $EMAIL"
  echo

  install_base
  install_docker
  fix_kernel_network
  repair_docker_network
  prepare_project
  select_ports
  patch_compose_ports
  configure_env
  start_stack
  install_acme
  issue_cert
  write_nginx
  open_firewall

  echo
  echo "=========================================="
  echo " ✅ 安装完成"
  echo " 面板地址: https://$MAIN_DOMAIN"
  echo " 订阅地址: https://$SUB_DOMAIN/api/sub"
  echo " 本地后端端口: 127.0.0.1:${APP_PORT}"
  echo " 本地数据库端口: 127.0.0.1:${DB_PORT}"
  echo " 安装目录: $INSTALL_DIR"
  echo "=========================================="
}

main "$@"
