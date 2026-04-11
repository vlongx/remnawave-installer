#!/usr/bin/env bash
# Remnawave 一键安装脚本（最终稳定版 / Docker链自动修复版）
# 适用：Debian / Ubuntu
# 功能：
# 1. 安装 Docker / Compose / Nginx / acme.sh
# 2. 自动修复 Docker bridge/iptables/forward 常见故障
# 3. 按 Remnawave 官方方式下载 docker-compose-prod.yml 与 .env.sample
# 4. 自动生成安全密钥并配置 FRONT_END_DOMAIN / SUB_PUBLIC_DOMAIN
# 5. 启动 Remnawave
# 6. 申请 Let's Encrypt 证书
# 7. 配置 Nginx HTTPS 反代

set -Eeuo pipefail

INSTALL_DIR="/opt/remnawave"
NGINX_SITE="/etc/nginx/sites-available/remnawave.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/remnawave.conf"
CERT_DIR="/etc/nginx/ssl/remnawave"
SYSCTL_FILE="/etc/sysctl.d/99-remnawave-docker.conf"

green()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
yellow() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
red()    { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
die()    { red "$*"; exit 1; }

trap 'red "脚本在第 $LINENO 行执行失败。"; exit 1' ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请使用 root 运行本脚本（例如：sudo bash install.sh）"
}

require_apt() {
  command -v apt-get >/dev/null 2>&1 || die "当前脚本仅支持 Debian/Ubuntu 系统"
}

backup_file() {
  local f="$1"
  if [[ -e "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

set_env_kv() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

install_base_packages() {
  green "安装基础依赖..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl socat cron openssl ca-certificates gnupg lsb-release \
    nginx ufw iptables iproute2
}

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    green "未检测到 Docker，开始安装..."
    curl -fsSL https://get.docker.com | sh
  else
    green "Docker 已安装，跳过安装。"
  fi

  systemctl enable docker
  systemctl restart docker || true

  if ! docker compose version >/dev/null 2>&1; then
    green "安装 Docker Compose 插件..."
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
  fi
}

fix_kernel_networking() {
  green "修复内核转发与 bridge 网络参数..."

  modprobe br_netfilter || true

  cat > "$SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF

  sysctl --system >/dev/null

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
  sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null || true
  sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null || true

  iptables -P FORWARD ACCEPT || true
  ip6tables -P FORWARD ACCEPT || true
}

repair_docker_network() {
  green "检测并修复 Docker 网络链..."

  systemctl stop docker || true

  rm -f /var/lib/docker/network/files/local-kv.db || true

  ip link show docker0 >/dev/null 2>&1 && ip link set docker0 down || true
  ip link delete docker0 type bridge >/dev/null 2>&1 || true

  iptables -t nat -N DOCKER >/dev/null 2>&1 || true
  iptables -t filter -N DOCKER-USER >/dev/null 2>&1 || true
  iptables -t filter -N DOCKER-FORWARD >/dev/null 2>&1 || true

  iptables -t filter -C FORWARD -j DOCKER-USER >/dev/null 2>&1 || iptables -t filter -I FORWARD 1 -j DOCKER-USER || true
  iptables -t filter -C FORWARD -j DOCKER-FORWARD >/dev/null 2>&1 || iptables -t filter -A FORWARD -j DOCKER-FORWARD || true

  iptables -t filter -C DOCKER-USER -j RETURN >/dev/null 2>&1 || iptables -t filter -A DOCKER-USER -j RETURN || true

  systemctl start docker
  sleep 5

  docker network inspect bridge >/dev/null 2>&1 || true

  if ! iptables -t filter -S DOCKER-FORWARD >/dev/null 2>&1; then
    yellow "Docker 未自动重建完整链，再次重启 Docker..."
    systemctl restart docker
    sleep 5
  fi

  docker network create remnawave-check-net >/dev/null 2>&1 || true
  docker network rm remnawave-check-net >/dev/null 2>&1 || true
}

prepare_remnawave() {
  green "准备 Remnawave 目录与配置..."
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  backup_file "$INSTALL_DIR/docker-compose.yml"
  backup_file "$INSTALL_DIR/.env"

  green "下载官方 docker-compose 与 .env.sample..."
  curl -fsSL https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml -o docker-compose.yml

  if [[ ! -f .env ]]; then
    curl -fsSL https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample -o .env
  fi
}

configure_env() {
  green "写入 Remnawave 环境变量..."

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

start_remnawave() {
  green "启动 Remnawave 容器..."
  cd "$INSTALL_DIR"

  docker compose down --remove-orphans >/dev/null 2>&1 || true
  docker compose up -d

  green "等待服务启动..."
  local ok=0
  for _ in $(seq 1 50); do
    if curl -fsS http://127.0.0.1:3000 >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 3
  done

  if [[ "$ok" -ne 1 ]]; then
    yellow "127.0.0.1:3000 暂未响应，输出最近容器日志："
    docker compose ps || true
    docker compose logs --tail=120 || true
    die "Remnawave 启动失败，请根据日志排查。"
  fi
}

install_acme() {
  green "安装 acme.sh..."
  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    curl https://get.acme.sh | sh -s email="$EMAIL"
  fi
  ACME_SH="/root/.acme.sh/acme.sh"
}

issue_cert() {
  green "申请 SSL 证书..."
  mkdir -p "$CERT_DIR"

  systemctl stop nginx >/dev/null 2>&1 || true

  "$ACME_SH" --set-default-ca --server letsencrypt
  "$ACME_SH" --register-account -m "$EMAIL" || true

  local domain_args=()
  domain_args+=(-d "$MAIN_DOMAIN")
  if [[ "$SUB_DOMAIN" != "$MAIN_DOMAIN" ]]; then
    domain_args+=(-d "$SUB_DOMAIN")
  fi

  "$ACME_SH" --issue --standalone "${domain_args[@]}" --keylength ec-256 --force

  "$ACME_SH" --install-cert -d "$MAIN_DOMAIN" --ecc \
    --fullchain-file "$CERT_DIR/fullchain.cer" \
    --key-file "$CERT_DIR/privkey.key"

  [[ -f "$CERT_DIR/fullchain.cer" ]] || die "证书安装失败：未找到 fullchain.cer"
  [[ -f "$CERT_DIR/privkey.key" ]] || die "证书安装失败：未找到 privkey.key"
}

write_nginx() {
  green "写入 Nginx 配置..."
  backup_file "$NGINX_SITE"

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
        proxy_pass http://127.0.0.1:3000;
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
  systemctl enable nginx
  systemctl restart nginx
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      green "检测到 UFW 已启用，仅放行 80/443..."
      ufw allow 80/tcp >/dev/null 2>&1 || true
      ufw allow 443/tcp >/dev/null 2>&1 || true
    else
      yellow "UFW 未启用，跳过 UFW 规则调整。"
    fi
  fi
}

show_result() {
  echo
  echo "=========================================="
  echo " ✅ Remnawave 安装完成"
  echo " 面板地址: https://$MAIN_DOMAIN"
  echo " 订阅地址: https://$SUB_DOMAIN/api/sub"
  echo " 安装目录: $INSTALL_DIR"
  echo "=========================================="
}

main() {
  require_root
  require_apt

  echo "=========================================="
  echo " Remnawave 一键安装脚本（最终稳定版）"
  echo "=========================================="
  echo "说明："
  echo "1. 将使用官方 docker-compose-prod.yml"
  echo "2. 自动修复 Docker iptables / bridge 网络常见问题"
  echo "3. 自动配置 Nginx + Let's Encrypt"
  echo "4. 不会清空整机 iptables 规则"
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

  install_base_packages
  install_docker
  fix_kernel_networking
  repair_docker_network
  prepare_remnawave
  configure_env
  start_remnawave
  install_acme
  issue_cert
  write_nginx
  open_firewall
  show_result
}

main "$@"
