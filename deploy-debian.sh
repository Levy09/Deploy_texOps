#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# deploy-debian.sh — Instalação completa do TexOps em VM Debian/Ubuntu (do zero)
#
# Testado em: Debian 12 (Bookworm), Ubuntu 22.04 LTS, Ubuntu 24.04 LTS
# Requisitos mínimos: 2 vCPU · 2 GB RAM · 20 GB disco
# Uso: sudo bash deploy-debian.sh
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[OK]${NC}    $1"; }
step()  { echo -e "\n${CYAN}══ $1 ══${NC}"; }
warn()  { echo -e "${YELLOW}[AVISO]${NC} $1"; }
error() { echo -e "${RED}[ERRO]${NC}  $1"; exit 1; }

# ── Configurações ─────────────────────────────────────────────────────────────
APP_DIR="/opt/texops"
APP_USER="texops"
NODE_VERSION="20"
GIT_REPO="https://github.com/Levy09/TEXopsV.git"
DOMAIN=""   # Ex: texops.suaempresa.com.br  (deixe vazio para só HTTP/IP)
# ─────────────────────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || error "Execute como root: sudo bash deploy-debian.sh"

# ══ ETAPA 1: Sistema base ══════════════════════════════════════════════════════
step "1/9 — Atualizando sistema"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget git unzip build-essential python3 sqlite3 nginx ufw fail2ban
info "Pacotes instalados"

# ══ ETAPA 2: Node.js ══════════════════════════════════════════════════════════
step "2/9 — Instalando Node.js $NODE_VERSION"
if ! command -v node &>/dev/null || [[ "$(node -v | cut -d. -f1 | tr -d 'v')" -lt "$NODE_VERSION" ]]; then
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
    apt-get install -y nodejs
fi
info "Node.js $(node -v) / npm $(npm -v)"

npm install -g pm2 --silent
info "PM2 $(pm2 -v)"

# ══ ETAPA 3: Usuário e diretório ══════════════════════════════════════════════
step "3/9 — Criando usuário e diretório"
if ! id "$APP_USER" &>/dev/null; then
    useradd -r -m -s /bin/bash "$APP_USER"
    info "Usuário $APP_USER criado"
fi
mkdir -p "$APP_DIR" /var/log/texops
chown -R "$APP_USER:$APP_USER" "$APP_DIR" /var/log/texops
info "Diretório $APP_DIR pronto"

# ══ ETAPA 4: Clonar repositório ════════════════════════════════════════════════
step "4/9 — Clonando código do repositório"

if [[ -d "$APP_DIR/.git" ]]; then
    warn "Repositório já existe em $APP_DIR — fazendo git pull"
    sudo -u "$APP_USER" git -C "$APP_DIR" pull
else
    # Repo privado: pede token se necessário
    echo ""
    echo "  O repositório é privado ou público?"
    echo "  [1] Público  (clona sem autenticação)"
    echo "  [2] Privado  (precisa de Personal Access Token do GitHub)"
    echo ""
    read -rp "  Opção [1/2]: " REPO_TYPE

    if [[ "$REPO_TYPE" == "2" ]]; then
        read -rsp "  Cole seu GitHub Token (não aparece na tela): " GIT_TOKEN
        echo ""
        CLONE_URL="https://${GIT_TOKEN}@${GIT_REPO#https://}"
    else
        CLONE_URL="$GIT_REPO"
    fi

    sudo -u "$APP_USER" git clone "$CLONE_URL" "$APP_DIR"
    info "Código clonado para $APP_DIR"
fi

# ══ ETAPA 5: Dependências e build ══════════════════════════════════════════════
step "5/9 — Instalando dependências e buildando frontend"

cd "$APP_DIR"
info "Instalando dependências do frontend..."
sudo -u "$APP_USER" npm install --silent

info "Buildando React/Vite..."
sudo -u "$APP_USER" npm run build
info "Build frontend concluído → dist/"

cd "$APP_DIR/server"
info "Instalando dependências do backend..."
sudo -u "$APP_USER" npm install --silent --omit=dev
info "Dependências do backend instaladas"

# ══ ETAPA 6: Configurar .env ══════════════════════════════════════════════════
step "6/9 — Configurando variáveis de ambiente"

if [[ ! -f "$APP_DIR/server/.env" ]]; then
    JWT_SECRET=$(node -e "console.log(require('crypto').randomBytes(48).toString('hex'))")
    cat > "$APP_DIR/server/.env" << ENVEOF
NODE_ENV=production
PORT=3000
JWT_SECRET=$JWT_SECRET
DB_PATH=db/texops.db
ENVEOF
    chown "$APP_USER:$APP_USER" "$APP_DIR/server/.env"
    chmod 600 "$APP_DIR/server/.env"
    info ".env criado com JWT_SECRET gerado automaticamente"
else
    warn ".env já existe — mantendo configuração atual"
fi

# ══ ETAPA 7: Banco de dados ════════════════════════════════════════════════════
step "7/9 — Inicializando banco de dados"

cd "$APP_DIR/server"
if [[ ! -f "$APP_DIR/server/db/texops.db" ]]; then
    sudo -u "$APP_USER" node -e "require('./db/init'); console.log('Schema criado')"
    sudo -u "$APP_USER" node db/seed.js
    info "Banco inicializado com usuários padrão"
else
    warn "Banco já existe — mantendo dados atuais"
fi

# ══ ETAPA 8: PM2 ══════════════════════════════════════════════════════════════
step "8/9 — Configurando PM2"

cat > "$APP_DIR/ecosystem.config.cjs" << 'PM2'
module.exports = {
  apps: [{
    name:        "texops",
    script:      "server.js",
    cwd:         "/opt/texops/server",
    instances:   1,
    exec_mode:   "fork",
    watch:       false,
    max_memory_restart: "400M",
    env: {
      NODE_ENV: "production",
      PORT:     3000,
    },
    error_file:  "/var/log/texops/pm2-error.log",
    out_file:    "/var/log/texops/pm2-out.log",
    log_date_format: "YYYY-MM-DD HH:mm:ss",
    restart_delay: 3000,
    max_restarts:  10,
  }]
}
PM2

chown "$APP_USER:$APP_USER" "$APP_DIR/ecosystem.config.cjs"

# Para qualquer instância anterior
sudo -u "$APP_USER" pm2 delete texops 2>/dev/null || true

sudo -u "$APP_USER" pm2 start "$APP_DIR/ecosystem.config.cjs"
sudo -u "$APP_USER" pm2 save

# PM2 no boot
pm2 startup systemd -u "$APP_USER" --hp "/home/$APP_USER" | tail -1 | bash
info "PM2 configurado para iniciar com o sistema"

# Aguarda e testa
sleep 3
curl -sf http://localhost:3000/api/health > /dev/null && info "Servidor respondendo na porta 3000" || warn "Servidor ainda iniciando..."

# ══ ETAPA 9: Nginx + Firewall ══════════════════════════════════════════════════
step "9/9 — Configurando Nginx e Firewall"

if [[ -n "$DOMAIN" ]]; then
    # Com domínio
    cat > /etc/nginx/sites-available/texops << NGINX
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 55M;
    gzip on;
    gzip_types text/plain text/css application/json application/javascript;

    location / {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host       \$host;
        proxy_set_header X-Real-IP  \$remote_addr;
        proxy_read_timeout 300s;
        proxy_buffering off;
    }

    access_log /var/log/nginx/texops-access.log;
    error_log  /var/log/nginx/texops-error.log;
}
NGINX
    info "Nginx configurado para $DOMAIN"
else
    # Sem domínio — IP direto
    cat > /etc/nginx/sites-available/texops << 'NGINX'
server {
    listen 80 default_server;
    client_max_body_size 55M;
    gzip on;
    gzip_types text/plain text/css application/json application/javascript;

    location / {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host       $host;
        proxy_set_header X-Real-IP  $remote_addr;
        proxy_read_timeout 300s;
        proxy_buffering off;
    }

    access_log /var/log/nginx/texops-access.log;
    error_log  /var/log/nginx/texops-error.log;
}
NGINX
    info "Nginx configurado (HTTP — acesso por IP)"
fi

ln -sf /etc/nginx/sites-available/texops /etc/nginx/sites-enabled/texops
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx && systemctl enable nginx
info "Nginx ativo"

# SSL com Certbot (só se tiver domínio)
if [[ -n "$DOMAIN" ]]; then
    apt-get install -y -qq certbot python3-certbot-nginx
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "admin@$DOMAIN" || \
        warn "Certbot falhou — configure SSL manualmente depois"
fi

# Firewall
ufw --force reset > /dev/null
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw allow ssh
ufw allow http
[[ -n "$DOMAIN" ]] && ufw allow https
ufw --force enable
info "Firewall ativo"

# ══ RESUMO FINAL ══════════════════════════════════════════════════════════════
VM_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           ✅  TexOps instalado com sucesso!                 ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Acesso:   http://$VM_IP                                    ${NC}"
[[ -n "$DOMAIN" ]] && echo -e "${GREEN}║  Domínio:  https://$DOMAIN                                  ${NC}"
echo -e "${GREEN}║  Login:    admin  /  admin123  (TROQUE A SENHA!)            ║${NC}"
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}║  Comandos úteis:                                            ║${NC}"
echo -e "${GREEN}║    pm2 status          — ver status                        ║${NC}"
echo -e "${GREEN}║    pm2 logs texops     — ver logs                          ║${NC}"
echo -e "${GREEN}║    pm2 reload texops   — reload sem downtime               ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
