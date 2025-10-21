#!/bin/bash
# ============================================
# HNG DevOps Stage 1 - Automated Deployment Script
# Author: Nicholas Ojinni
# ============================================

set -e
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
trap 'log "❌ ERROR on line $LINENO"; exit 1' ERR

read -p "Enter GitHub repo URL (https): " GIT_URL
read -p "If repo is private enter PAT (or press Enter to skip): " PAT
read -p "Enter branch name (default: main): " BRANCH
read -p "Enter Remote Server Username (e.g., ubuntu): " SSH_USER
read -p "Enter Remote Server IP Address: " SERVER_IP
read -p "Enter path to SSH Key (e.g., ~/.ssh/hng-stage1-key.pem): " SSH_KEY
read -p "Enter Application internal port (default: 80): " APP_PORT

BRANCH=${BRANCH:-main}
APP_PORT=${APP_PORT:-80}

log "Cloning repository..."
# prepare clone URL
if [ -n "$PAT" ]; then
  CLONE_URL=$(echo "$GIT_URL" | sed -e "s#https://##")
  git clone -b "$BRANCH" "https://${PAT}@${CLONE_URL}" repo
else
  git clone -b "$BRANCH" "$GIT_URL" repo || { log "❌ Clone failed"; exit 1; }
fi
cd repo

# verify Dockerfile or docker-compose
if [ -f "./Dockerfile" ]; then
  log "✅ Dockerfile found"
elif [ -f "./docker-compose.yml" ]; then
  log "✅ docker-compose.yml found"
else
  log "❌ No Dockerfile or docker-compose.yml found in $(pwd)"
  exit 1
fi

log "Testing SSH connection..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "echo '✅ SSH connected successfully'"

log "Preparing remote environment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<'EOF'
sudo apt update -y
sudo apt install -y docker.io docker-compose-plugin nginx
sudo usermod -aG docker $USER || true
sudo systemctl enable --now docker nginx
EOF

log "Packaging app for transfer (excluding .git and logs)..."
# create a tar excluding .git to copy
cd ..
tar --exclude='./repo/.git' --exclude='deploy_*.log' -czf app.tar.gz repo

log "Transferring files to remote..."
scp -i "$SSH_KEY" app.tar.gz "$SSH_USER@$SERVER_IP:/home/$SSH_USER/"

log "Deploying on remote..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
cd /home/$SSH_USER
mkdir -p app
tar -xzf app.tar.gz -C app --strip-components=1
cd app
# if docker-compose file exists, prefer docker compose
if [ -f docker-compose.yml ]; then
  docker compose down || true
  docker compose up -d --build
else
  docker stop hng-app || true
  docker rm hng-app || true
  docker build -t hng-app .
  docker run -d -p $APP_PORT:$APP_PORT --name hng-app hng-app
fi
EOF

log "Configuring Nginx reverse proxy..."
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
curl -I localhost || true
EOF

log "✅ Deployment completed successfully!"
