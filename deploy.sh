#!/bin/bash
# ============================================
# HNG DevOps Stage 1 - Automated Deployment Script
# Author: Nicholas Ojinni
# ============================================

set -eu
set -x

# Create timestamped log file
LOGFILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

# Error trap
trap 'echo "[ERROR] Script failed at line $LINENO" >&2' ERR

echo "[INFO] === STARTING DEPLOYMENT ==="

########################################
# 1. Collect Parameters
########################################

echo "Git Repository URL:"
read REPO_URL

echo "Personal Access Token (PAT):"
read PAT

echo "Branch name [default: main]:"
read BRANCH
if [ -z "$BRANCH" ]; then
  BRANCH="main"
fi

echo "Remote SSH Username:"
read SSH_USER

echo "Remote Server IP:"
read SERVER_IP

echo "SSH Key Path:"
read SSH_KEY

echo "Application internal port (e.g., 3000):"
read APP_PORT

# Extract repo name
REPO_NAME=$(basename "$REPO_URL" .git)

########################################
# 2. Clone or Update Repository
########################################

if [ -d "$REPO_NAME" ]; then
  echo "[INFO] Repo exists. Pulling latest changes..."
  cd "$REPO_NAME"
  git pull origin "$BRANCH"
else
  echo "[INFO] Cloning repository..."
  git clone "https://${PAT}@${REPO_URL#https://}" --branch "$BRANCH"
  cd "$REPO_NAME"
fi

########################################
# 3. Verify Docker Config
########################################

if [ ! -f "Dockerfile" ] && [ ! -f "docker-compose.yml" ]; then
  echo "[ERROR] No Docker configuration found."
  exit 2
fi

########################################
# 4. Test SSH Connection
########################################

echo "[INFO] Testing SSH connection..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" "echo 'SSH connection OK'" || exit 3

########################################
# 5. Prepare Remote Environment
########################################

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
set -eu
echo "[INFO] Updating system..."
sudo apt update && sudo apt upgrade -y

echo "[INFO] Installing dependencies..."
sudo apt install -y ca-certificates curl gnupg nginx

echo "[INFO] Adding Docker’s official GPG key..."
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "[INFO] Setting up Docker repository..."
echo \
  "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "[INFO] Installing Docker..."
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "[INFO] Enabling and starting Docker & Nginx..."
sudo usermod -aG docker \$USER
sudo systemctl enable docker nginx
sudo systemctl start docker nginx
EOF

########################################
# 6. Transfer Files
########################################

echo "[INFO] Copying project files..."
scp -i "$SSH_KEY" -r $(ls -A | grep -v -E 'node_modules|package.json|package-lock.json|.git') "$SSH_USER@$SERVER_IP:/home/$SSH_USER/$REPO_NAME"

########################################
# 7. Deploy Application
########################################

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
cd "$REPO_NAME"
if [ -f "docker-compose.yml" ]; then
  echo "[INFO] Using docker-compose..."
  docker-compose down
  docker-compose up -d
else
  echo "[INFO] Building Docker image..."
  docker stop app 2>/dev/null || true
  docker rm -f app 2>/dev/null || true
  docker build -t app .
  docker run -d --name app -p $APP_PORT:$APP_PORT app
fi
EOF

########################################
# 8. Configure Nginx
########################################

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
sudo sh -c 'cat > /etc/nginx/sites-available/app.conf' <<NGINX
server {
  listen 80;
  location / {
    proxy_pass http://localhost:$APP_PORT;
  }
}
NGINX
sudo ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf
sudo nginx -t
sudo systemctl restart nginx
EOF

########################################
# 9. Optional: Enable SSL (Certbot or Self-signed)
########################################

echo "Enable SSL? (y/n)"
read ENABLE_SSL

if [ "$ENABLE_SSL" = "y" ] || [ "$ENABLE_SSL" = "Y" ]; then
  echo "Domain name for SSL (e.g., example.com):"
  read DOMAIN_NAME

  echo "Use certbot (recommended) or self-signed? [certbot/self]"
  read SSL_TYPE

  echo "[INFO] Setting up SSL on remote server..."

  ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
set -eu

# install required packages
sudo apt update -y
sudo apt install -y openssl certbot python3-certbot-nginx

if [ "$SSL_TYPE" = "certbot" ]; then
  echo "[INFO] Requesting LetsEncrypt cert for $DOMAIN_NAME..."
  # certbot will attempt to obtain and install the cert via nginx plugin
  # this requires the domain to point to the server and ports 80/443 available
  sudo certbot --nginx -d $DOMAIN_NAME --non-interactive --agree-tos -m admin@$DOMAIN_NAME || echo "[WARN] Certbot step failed - check DNS or open ports 80/443"
else
  echo "[INFO] Generating self-signed cert for $DOMAIN_NAME..."
  sudo mkdir -p /etc/ssl/selfsigned
  sudo openssl req -x509 -nodes -days 365 \
    -subj "/CN=$DOMAIN_NAME" \
    -newkey rsa:2048 \
    -keyout /etc/ssl/selfsigned/$DOMAIN_NAME.key \
    -out /etc/ssl/selfsigned/$DOMAIN_NAME.crt

  # write nginx config for HTTPS (redirect http -> https)
  sudo sh -c 'cat > /etc/nginx/sites-available/app.conf' <<NGINX
server {
  listen 80;
  server_name $DOMAIN_NAME;
  return 301 https://\$host\$request_uri;
}
server {
  listen 443 ssl;
  server_name $DOMAIN_NAME;

  ssl_certificate     /etc/ssl/selfsigned/$DOMAIN_NAME.crt;
  ssl_certificate_key /etc/ssl/selfsigned/$DOMAIN_NAME.key;

  location / {
    proxy_pass http://localhost:$APP_PORT;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
  }
}
NGINX
fi

# test and reload nginx
sudo nginx -t
sudo systemctl restart nginx

EOF

  echo "[INFO] SSL setup attempted for $DOMAIN_NAME (type: $SSL_TYPE)"
else
  echo "[INFO] Skipping SSL setup."
fi


########################################
# 10. Final Checks
########################################

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" <<EOF
echo "[INFO] Docker containers:"
echo "[INFO] Docker images:"
docker images
echo "[INFO] Docker ps:"
docker ps 
echo "[INFO] Docker Logs:"
docker logs app || true
echo "[INFO] Checking app response..."
curl -I http://localhost:$APP_PORT || true
EOF

echo "[SUCCESS] Deployment completed successfully."