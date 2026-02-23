#!/bin/bash

# Ghost Chat Firewall Configuration
# Run with: sudo bash firewall.sh

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Ghost Chat Firewall Setup ===${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (sudo)${NC}"
  exit 1
fi

# Flush existing rules
echo -e "${YELLOW}Flushing existing rules...${NC}"
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

# Default policies
echo -e "${YELLOW}Setting default policies...${NC}"
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# SSH (port 22) - IMPORTANT: Don't lock yourself out!
# Consider changing to a non-standard port for security
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# HTTP/HTTPS
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# TURN server ports
iptables -A INPUT -p tcp --dport 3478 -j ACCEPT
iptables -A INPUT -p udp --dport 3478 -j ACCEPT
iptables -A INPUT -p tcp --dport 5349 -j ACCEPT
iptables -A INPUT -p udp --dport 5349 -j ACCEPT

# TURN relay ports (UDP only for media)
iptables -A INPUT -p udp --dport 49152:65535 -j ACCEPT

# Rate limiting for TURN to prevent abuse
iptables -A INPUT -p udp --dport 3478 -m hashlimit \
  --hashlimit-above 50/sec --hashlimit-burst 100 \
  --hashlimit-mode srcip --hashlimit-name turn_limit \
  -j DROP

# Rate limiting for HTTP/HTTPS
iptables -A INPUT -p tcp --dport 80 -m hashlimit \
  --hashlimit-above 25/sec --hashlimit-burst 50 \
  --hashlimit-mode srcip --hashlimit-name http_limit \
  -j DROP

iptables -A INPUT -p tcp --dport 443 -m hashlimit \
  --hashlimit-above 25/sec --hashlimit-burst 50 \
  --hashlimit-mode srcip --hashlimit-name https_limit \
  -j DROP

# Drop invalid packets
iptables -A INPUT -m state --state INVALID -j DROP

# Log dropped packets (optional - can be noisy)
# iptables -A INPUT -j LOG --log-prefix "DROPPED: " --log-level 4

# Save rules
echo -e "${YELLOW}Saving rules...${NC}"

# For Debian/Ubuntu
if command -v netfilter-persistent &> /dev/null; then
  netfilter-persistent save
elif [ -d /etc/iptables ]; then
  iptables-save > /etc/iptables/rules.v4
else
  echo -e "${YELLOW}Please manually save iptables rules for your distribution${NC}"
fi

echo -e "${GREEN}=== Firewall Setup Complete ===${NC}"
echo ""
echo "Current rules:"
iptables -L -n --line-numbers

echo ""
echo -e "${YELLOW}IMPORTANT: Make sure you can still access SSH before closing this session!${NC}"
