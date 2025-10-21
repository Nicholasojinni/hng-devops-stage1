#!/bin/bash
# ============================================
# HNG DevOps Stage 1 - Automated Deployment Script
# Author: Ojinni Oluwafemi Nicholas
# ============================================

set -e
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

trap 'log "❌ ERROR on line $LINENO"; exit 1' ERR

read -p "Enter GitHub repo URL: " GIT_URL
read -p "Enter your Personal Access Token: " PAT
read -p "Enter branch name (default: main): " BRANCH
read -p "Enter Remote Server Username: " SSH_USER
read -p "Enter Remote Server IP Address: " SERVER_IP
read -p "Enter path to SSH Key (e.g. ~/.ssh/hng-key.pem): " SSH_KEY
read -p "Enter Application internal port (default: 80): " APP_PORT

BRANCH=${BRANCH:-main}
APP_PORT=${APP_PORT:-80}

log "Cloning repository..."
if [ -d "repo" ]; then
  cd repo && git pull origin "$BRANCH"
else
  git clone -b "$BRANCH" https://${PAT}@${GIT_URL#https://} repo
  cd repo
fi

if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
  log "✅ Docker setup files found"
else
  log "❌ No Dockerfile or docker-compose.yml found!"
  exit 1
fi

log "Testing SSH connection..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "echo '✅ SSH connected successfully'"

log "Preparing remote environment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
sudo apt update -y
sudo apt install -y docker.io docker-compose nginx
sudo usermod -aG docker $SSH_USER
sudo systemctl enable docker nginx
sudo systemctl start docker nginx
docker --version
nginx -v
EOF

log "Deploying Docker container..."
scp -i "$SSH_KEY" -r . "$SSH_USER@$SERVER_IP:/home/$SSH_USER/app"

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
cd /home/$SSH_USER/app
docker stop hng-app || true
docker rm hng-app || true
docker build -t hng-app .
docker run -d -p $APP_PORT:$APP_PORT --name hng-app hng-app
EOF

log "Configuring Nginx..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
sudo bash -c 'cat > /etc/nginx/sites-available/hng_app <<EOL
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOL'
sudo ln -sf /etc/nginx/sites-available/hng_app /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
EOF

log "Validating deployment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
docker ps
curl -I localhost
EOF

log "✅ Deployment completed successfully!"
