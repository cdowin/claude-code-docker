#!/bin/bash
set -euo pipefail

# Preserve Docker DNS NAT rules before flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush all rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
ipset destroy allowed-domains 2>/dev/null || true

# Restore Docker internal DNS
if [ -n "$DOCKER_DNS_RULES" ]; then
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# Allow localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT

# Create ipset for allowed IPs
ipset create allowed-domains hash:net

# Allow GitHub IP ranges (git push/pull/clone)
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta || true)
if [ -n "$gh_ranges" ]; then
    echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' 2>/dev/null | while read -r cidr; do
        ipset add allowed-domains "$cidr" 2>/dev/null || true
    done
fi

# Allow SSH for git operations
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT

# Allow Claude API + related services (plus any user-specified extras)
# Core: Claude API, platform, analytics
# Plugins: downloads.claude.ai (official marketplace CDN), storage.googleapis.com (GCS fallback)
# GitHub: git operations + API + CDN domains for third-party plugin marketplaces
# Feature flags: cdn.growthbook.io (controls plugin fallback behavior)
# Plugin deps: npm registry, PyPI for plugins that install dependencies
# Atlassian: api.atlassian.com for MCP/API access (instance-specific *.atlassian.net
# subdomains must be added via EXTRA_ALLOWED_DOMAINS since they can't be wildcarded here)
DOMAINS="
  api.anthropic.com claude.ai platform.claude.com statsig.anthropic.com sentry.io
  downloads.claude.ai storage.googleapis.com cdn.growthbook.io
  github.com api.github.com raw.githubusercontent.com objects.githubusercontent.com codeload.github.com
  registry.npmjs.org pypi.org files.pythonhosted.org
  api.atlassian.com atlassian.net
"
if [ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]; then
    DOMAINS="$DOMAINS $EXTRA_ALLOWED_DOMAINS"
fi
for domain in $DOMAINS; do
    ips=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]' || true)
    if [ -n "$ips" ]; then
        while read -r ip; do
            ipset add allowed-domains "$ip" 2>/dev/null || true
        done <<< "$ips"
    fi
done

# Allow host gateway (for Docker networking)
HOST_IP=$(ip route | grep default | cut -d" " -f3)
[ -n "$HOST_IP" ] && ipset add allowed-domains "$HOST_IP" 2>/dev/null || true

# Allow traffic to whitelisted IPs
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Allow established connections back in
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Default deny everything else outbound
iptables -A OUTPUT -j REJECT --reject-with icmp-port-unreachable

echo "Firewall configured. Only Claude API traffic allowed."
