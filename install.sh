#!/usr/bin/env bash
# Remnawave 一键安装脚本（最终极简稳定版）
# Debian / Ubuntu
# 思路：不做复杂探测，不在安装阶段死等；只负责安装、启动、签证书、配置 Nginx。

set -Eeuo pipefail

INSTALL_DIR="/opt/remnawave"
NGINX_SITE="/etc/nginx/sites-available/remnawave.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/remnawave.conf"
CERT_DIR="/etc/nginx/ssl/remnawave"
SYSCTL_FILE="/etc/sysctl.d/99-remnawave-docker.conf"
TMP_DIR="/tmp/remnawave-installer.$$"

APP_PORT=""
DB_PORT=""
ACME_SH=""
DB_PASS=""

info()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
die()   { error "$*"; cleanup; exit 1; }

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请使用 root 运行本脚本"
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
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

port_in_use() {
  local port="$1"
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
}

find_free_port() {
  local p="$1"
  while port_in_use "$p"; do
    p=$((p + 1))
  done
  echo "$p"
}

retry_curl() {
  local url="$1"
  local dest="$2"
  local i
  for i in 1 2 3 4 5; do
    if curl -fL --connect-timeout 15 --max-time 120 --retry 3 --retry-all-errors -o "$dest" "$url"; then
      [[ -s "$dest" ]] && return 0
    fi
    warn "下载失败，第 ${i}/5 次重试: $url"
    sleep 2
  done
  return 1
}

download_backend_file() {
  local remote_file="$1"
  local dest="$2"
  local raw_url="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/${remote_file}"

  mkdir -p "$TMP_DIR"

  if retry_curl "$raw_url" "$dest"; then
    return 0
  fi

  warn "直接下载失败，切换 git clone 兜底..."
  rm -rf "$TMP_DIR/backend" >/dev/null 2>&1 || true

  if git clone --depth 1 https://github.com/remnawave/backend.git "$TMP_DIR/backend" >/dev/null 2>&1; then
    [[ -f "$TMP_DIR/backend/${remote_file}" ]] || die "官方仓库缺少文件: ${remote_file}"
    cp "$TMP_DIR/backend/${remote_file}" "$dest" || die "复制文件失败: ${remote_file}"
    [[ -s "$dest" ]] || die "文件为空: $dest"
    return 0
  fi

  die "下载官方文件失败: ${remote_file}"
}

install_base() {
  info "安装基础依赖..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl socat cron openssl ca-certificates gnupg lsb-release \
    nginx ufw iptables iproute2 git
}

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    info "未检测到 Docker，开始安装..."
    curl -fsSL https://get.docker.com | sh
  else
    info "Docker 已安装，跳过安装。"
  fi

  systemctl enable docker >/dev/null 2>&1 || true
  systemctl restart docker >/dev/null 2>&1 || true

  if ! docker compose version >/dev/null 2>&1; then
    info "安装 Docker Compose 插件..."
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
  fi
}

fix_kernel_network() {
  info "修复内核网络参数..."
  modprobe br_netfilter >/dev/null 2>&1 || true

  cat > "$SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
vm.overcommit_memory=1
EOF

  sysctl --system >/dev/null 2>&1 || true
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
  sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true
  sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null 2>&1 || true
  sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 || true

  iptables -P FORWARD ACCEPT >/dev/null 2>&1 || true
  ip6tables -P FORWARD ACCEPT >/dev/null 2>&1 || true
}

repair_docker_network() {
  info "修复 Docker 网络链..."
  systemctl stop docker.socket >/dev/null 2>&1 || true
  systemctl stop docker.service >/dev/null 2>&1 || true

  rm -f /var/lib/docker/network/files/local-kv.db >/dev/null 2>&1 || true

  ip link show docker0 >/dev/null 2>&1 && ip link set docker0 down >/dev/null 2>&1 || true
  ip link delete docker0 type bridge >/dev/null 2>&1 || true

  iptables -t nat -N DOCKER >/dev/null 2>&1 || true
  iptables -t filter -N DOCKER-USER >/dev/null 2>&1 || true
  iptables -t filter -N DOCKER-FORWARD >/dev/null 2>&1 || true

  iptables -t filter -C FORWARD -j DOCKER-USER >/dev/null 2>&1 || iptables -t filter -I FORWARD 1 -j DOCKER-USER >/dev/null 2>&1 || true
  iptables -t filter -C FORWARD -j DOCKER-FORWARD >/dev/null 2>&1 || iptables -t filter -A FORWARD -j DOCKER-FORWARD >/dev/null 2>&1 || true
  iptables -t filter -C DOCKER-USER -j RETURN >/dev/null 2>&1 || iptables -t filter -A DOCKER-USER -j RETURN >/dev/null 2>&1 || true

  systemctl start docker.socket >/dev/null 2>&1 || true
  systemctl start docker.service
  sleep 3
}

prepare_project() {
  info "准备 Remnawave 目录与配置..."
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  backup_if_exists "$INSTALL_DIR/docker-compose.yml"
  backup_if_exists "$INSTALL_DIR/.env"

  info "下载官方 docker-compose 与 .env.sample..."
  download_backend_file "docker-compose-prod.yml" "$INSTALL_DIR/docker-compose.yml"

  if [[ ! -f "$INSTALL_DIR/.env" ]]; then
    download_backend_file ".env.sample" "$INSTALL_DIR/.env"
  fi
}

select_ports() {
  APP_PORT="$(find_free_port 3000)"
  DB_PORT="$(find_free_port 6767)"

  [[ "$APP_PORT" != "3000" ]] && warn "127.0.0.1:3000 已占用，改用 ${APP_PORT}"
  [[ "$DB_PORT" != "6767" ]] && warn "127.0.0.1:6767 已占用，改用 ${DB_PORT}"
}

patch_compose_ports() {
  info "调整 docker-compose 端口绑定..."
  cd "$INSTALL_DIR"

  sed -i -E "s|127\.0\.0\.1:3000-3001:3000-3001|127.0.0.1:${APP_PORT}-3001:3000-3001|g" docker-compose.yml
  sed -i -E "s|127\.0\.0\.1:3000:3000|127.0.0.1:${APP_PORT}:3000|g" docker-compose.yml
  sed -i -E "s|127\.0\.0\.1:6767:5432|127.0.0.1:${DB_PORT}:5432|g" docker-compose.yml
}

configure_env() {
  info "写入 Remnawave 环境变量..."
  cd "$INSTALL_DIR"

  set_env_kv .env FRONT_END_DOMAIN "$MAIN_DOMAIN"
  set_env_kv .env PANEL_DOMAIN "$MAIN_DOMAIN"
  set_env_kv .env SUB_PUBLIC_DOMAIN "${SUB_DOMAIN}/api/sub"
  set_env_kv .env JWT_AUTH_SECRET "$(openssl rand -hex 64)"
  set_env_kv .env JWT_API_TOKENS_SECRET "$(openssl rand -hex 64)"
  set_env_kv .env METRICS_PASS "$(openssl rand -hex 32)"
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

  if ! docker compose up -d; then
    warn "首次启动失败，尝试修复 Docker 网络后重试..."
    repair_docker_network
    docker compose up -d || die "Remnawave 启动失败"
  fi

  sleep 8

  docker ps --format '{{.Names}}' | grep -qx 'remnawave' || die "remnawave 容器未运行"
  docker ps --format '{{.Names}}' | grep -qx 'remnawave-db' || die "remnawave-db 容器未运行"
  docker ps --format '{{.Names}}' | grep -qx 'remnawave-redis' || die "remnawave-redis 容器未运行"
}

install_acme() {
  info "安装 acme.sh..."
  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    curl https://get.acme.sh | sh -s email="$EMAIL"
  fi
  ACME_SH="/root/.acme.sh/acme.sh"
  [[ -x "$ACME_SH" ]] || die "acme.sh 安装失败"
}

issue_cert() {
  info "申请 SSL 证书..."
  mkdir -p "$CERT_DIR"

  systemctl stop nginx >/dev/null 2>&1 || true

  "$ACME_SH" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "$ACME_SH" --register-account -m "$EMAIL" >/dev/null 2>&1 || true

  local args=()
  args+=(-d "$MAIN_DOMAIN")
  if [[ "$SUB_DOMAIN" != "$MAIN_DOMAIN" ]]; then
    args+=(-d "$SUB_DOMAIN")
  fi

  "$ACME_SH" --issue --standalone "${args[@]}" --keylength ec-256 --force
  "$ACME_SH" --install-cert -d "$MAIN_DOMAIN" --ecc \
    --fullchain-file "$CERT_DIR/fullchain.cer" \
    --key-file "$CERT_DIR/privkey.key"

  [[ -f "$CERT_DIR/fullchain.cer" ]] || die "证书安装失败"
  [[ -f "$CERT_DIR/privkey.key" ]] || die "证书安装失败"
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

    location / {
        proxy_http_version 1.1;
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_read_timeout 300;
        proxy_send_timeout 300;
    }
}
EOF

  rm -f /etc/nginx/sites-enabled/default
  ln -sf "$NGINX_SITE" "$NGINX_ENABLED"

  nginx -t || die "Nginx 配置测试失败"
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx || die "Nginx 启动失败"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      info "放行 80/443..."
      ufw allow 80/tcp >/dev/null 2>&1 || true
      ufw allow 443/tcp >/dev/null 2>&1 || true
    else
      warn "UFW 未启用，跳过。"
    fi
  fi
}

show_result() {
  echo
  echo "=========================================="
  echo " ✅ 安装流程执行完成"
  echo " 面板地址: https://$MAIN_DOMAIN"
  echo " 订阅地址: https://$SUB_DOMAIN/api/sub"
  echo " 本地后端端口: 127.0.0.1:${APP_PORT}"
  echo " 本地数据库端口: 127.0.0.1:${DB_PORT}"
  echo " 安装目录: $INSTALL_DIR"
  echo "=========================================="
  echo
  echo "可自行检查："
  echo "docker ps"
  echo "docker compose -f $INSTALL_DIR/docker-compose.yml logs --tail=100 remnawave"
  echo "nginx -t"
  echo "systemctl status nginx"
}

main() {
  require_root
  require_apt

  echo "=========================================="
  echo " Remnawave 一键安装脚本（最终极简稳定版）"
  echo "=========================================="

  read -rp "请输入【面板访问域名】（例如 panel.example.com）: " MAIN_DOMAIN
  [[ -n "${MAIN_DOMAIN}" ]] || die "面板域名不能为空"

  read -rp "请输入【订阅域名】（留空则与面板域名相同）: " SUB_DOMAIN
  SUB_DOMAIN="${SUB_DOMAIN:-$MAIN_DOMAIN}"

  read -rp "请输入【证书邮箱】（例如 admin@example.com）: " EMAIL
  [[ -n "${EMAIL}" ]] || die "证书邮箱不能为空"

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
  show_result
}

main "$@"
