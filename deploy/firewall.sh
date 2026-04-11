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
iptables -F INPUT
# Don't flush FORWARD/NAT — Docker manages those chains

# Default policies
echo -e "${YELLOW}Setting default policies...${NC}"
iptables -P INPUT DROP
iptables -P OUTPUT ACCEPT

# === BASIC RULES ===

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Drop invalid packets early
iptables -A INPUT -m state --state INVALID -j DROP

# === GLOBAL RATE LIMITS (must come BEFORE port-specific ACCEPT rules) ===

# SYN flood protection
iptables -A INPUT -p tcp --syn -m hashlimit \
  --hashlimit-above 30/sec --hashlimit-burst 60 \
  --hashlimit-mode srcip --hashlimit-name syn_flood \
  -j DROP

# === SSH (rate limit + accept) ===
iptables -A INPUT -p tcp --dport 22 -m hashlimit \
  --hashlimit-above 4/min --hashlimit-burst 6 \
  --hashlimit-mode srcip --hashlimit-name ssh_limit \
  -j DROP
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# === PORT-SPECIFIC RATE LIMITS + ACCEPT ===
# IMPORTANT: Rate limit rules MUST come before their corresponding ACCEPT rules,
# otherwise traffic is accepted before the rate limit can trigger.

# HTTP rate limit + accept
iptables -A INPUT -p tcp --dport 80 -m hashlimit \
  --hashlimit-above 25/sec --hashlimit-burst 50 \
  --hashlimit-mode srcip --hashlimit-name http_limit \
  -j DROP
iptables -A INPUT -p tcp --dport 80 -j ACCEPT

# HTTPS rate limit + accept
iptables -A INPUT -p tcp --dport 443 -m hashlimit \
  --hashlimit-above 25/sec --hashlimit-burst 50 \
  --hashlimit-mode srcip --hashlimit-name https_limit \
  -j DROP
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# TURN UDP rate limit + accept
iptables -A INPUT -p udp --dport 3478 -m hashlimit \
  --hashlimit-above 50/sec --hashlimit-burst 100 \
  --hashlimit-mode srcip --hashlimit-name turn_limit \
  -j DROP
iptables -A INPUT -p tcp --dport 3478 -j ACCEPT
iptables -A INPUT -p udp --dport 3478 -j ACCEPT

# TURN TLS rate limit + accept
iptables -A INPUT -p tcp --dport 5349 -m hashlimit \
  --hashlimit-above 25/sec --hashlimit-burst 50 \
  --hashlimit-mode srcip --hashlimit-name turns_limit \
  -j DROP
iptables -A INPUT -p tcp --dport 5349 -j ACCEPT
iptables -A INPUT -p udp --dport 5349 -j ACCEPT

# TURN relay ports (UDP only for WebRTC media)
iptables -A INPUT -p udp --dport 49152:65535 -j ACCEPT

# Save rules
echo -e "${YELLOW}Saving rules...${NC}"

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
iptables -L INPUT -n --line-numbers -v

echo ""
echo -e "${YELLOW}IMPORTANT: Make sure you can still access SSH before closing this session!${NC}"