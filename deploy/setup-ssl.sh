#!/bin/bash

# Ghost Chat SSL Setup Script
# Run this script to obtain Let's Encrypt certificates

set -e

# Configuration
DOMAIN="kordar.ai"
EMAIL="admin@kordar.ai"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Ghost Chat SSL Setup ===${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (sudo)${NC}"
  exit 1
fi

# Create directories
echo -e "${YELLOW}Creating directories...${NC}"
mkdir -p ./ssl
mkdir -p ./certbot/conf
mkdir -p ./certbot/www

# Check if certbot is installed
if ! command -v certbot &> /dev/null; then
  echo -e "${YELLOW}Installing certbot...${NC}"
  apt-get update
  apt-get install -y certbot
fi

# Stop nginx if running (to free port 80)
echo -e "${YELLOW}Stopping nginx temporarily...${NC}"
docker-compose stop nginx 2>/dev/null || true

# Obtain certificate
echo -e "${YELLOW}Obtaining SSL certificate for ${DOMAIN}...${NC}"
certbot certonly --standalone \
  -d $DOMAIN \
  --non-interactive \
  --agree-tos \
  --email $EMAIL \
  --rsa-key-size 4096 \
  --preferred-challenges http

# Copy certificates to deploy directory
echo -e "${YELLOW}Copying certificates...${NC}"
cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem ./ssl/
cp /etc/letsencrypt/live/$DOMAIN/privkey.pem ./ssl/

# Set permissions
chmod 600 ./ssl/*.pem

# Create renewal hook
echo -e "${YELLOW}Setting up auto-renewal...${NC}"
cat > /etc/letsencrypt/renewal-hooks/deploy/ghost-chat.sh << 'EOF'
#!/bin/bash
cd /path/to/ghost-chat/deploy
cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem ./ssl/
cp /etc/letsencrypt/live/$DOMAIN/privkey.pem ./ssl/
docker-compose restart nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/ghost-chat.sh

# Add cron job for renewal
(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet") | crontab -

echo -e "${GREEN}=== SSL Setup Complete ===${NC}"
echo ""
echo "Next steps:"
echo "1. Update nginx.conf with your domain: sed -i 's/YOUR_DOMAIN.com/${DOMAIN}/g' nginx.conf"
echo "2. Update turnserver.conf with your domain and IP"
echo "3. Start services: docker-compose up -d"
echo ""
echo -e "${YELLOW}Remember to update YOUR_DOMAIN.com and YOUR_SERVER_PUBLIC_IP in config files!${NC}"
