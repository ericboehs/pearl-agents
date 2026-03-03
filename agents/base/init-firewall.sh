#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# PEARL network firewall — iptables-based domain whitelisting
# Adapted from the Claude Code devcontainer's init-firewall.sh
# https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh

log() { echo "[firewall] $*" >&2; }

# ── Preserve Docker DNS before flushing ─────────────────────────────
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
# Reset policies to ACCEPT first so flushing rules doesn't leave us with DROP+no-rules
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# Restore Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
  log "Restoring Docker DNS rules..."
  iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
  iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
  echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
  log "No Docker DNS rules to restore"
fi

# ── Baseline rules (before restrictions) ────────────────────────────
# DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
# SSH
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
# Localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# ── Create ipset for allowed IPs ────────────────────────────────────
ipset create allowed-domains hash:net

# ── GitHub IPs (dynamic via API) ────────────────────────────────────
log "Fetching GitHub IP ranges..."
gh_ranges=$(curl -sf https://api.github.com/meta) || {
  log "ERROR: Failed to fetch GitHub IP ranges"
  exit 1
}

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
  log "ERROR: GitHub API response missing required fields"
  exit 1
fi

log "Processing GitHub IPs..."
while read -r cidr; do
  if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    log "ERROR: Invalid CIDR range from GitHub meta: $cidr"
    exit 1
  fi
  ipset add allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# ── Core whitelist (all agents) ─────────────────────────────────────
CORE_DOMAINS=(
  "registry.npmjs.org"
  "api.anthropic.com"
  "sentry.io"
  "statsig.anthropic.com"
  "statsig.com"
)

# ── Per-agent whitelist ─────────────────────────────────────────────
AGENT_DOMAINS=()
if [[ -f /firewall/domains.txt ]]; then
  while IFS= read -r line; do
    # Skip comments and blank lines
    line="${line%%#*}"
    line="${line// /}"
    [[ -z "$line" ]] && continue
    AGENT_DOMAINS+=("$line")
  done < /firewall/domains.txt
  log "Loaded ${#AGENT_DOMAINS[@]} agent-specific domain(s)"
fi

# ── Resolve and add all domains ─────────────────────────────────────
ALL_DOMAINS=("${CORE_DOMAINS[@]}" "${AGENT_DOMAINS[@]}")

for domain in "${ALL_DOMAINS[@]}"; do
  log "Resolving $domain..."
  ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
  if [ -z "$ips" ]; then
    log "ERROR: Failed to resolve $domain"
    exit 1
  fi

  while read -r ip; do
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      log "ERROR: Invalid IP from DNS for $domain: $ip"
      exit 1
    fi
    ipset add allowed-domains "$ip" 2>/dev/null || true
  done <<< "$ips"
done

# ── Host network access ────────────────────────────────────────────
# Only allow host access when a local proxy is configured via ANTHROPIC_BASE_URL.
# We allow only the specific port to prevent access to other host services.
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
  log "ERROR: Failed to detect host IP"
  exit 1
fi

PROXY_URL="${ANTHROPIC_BASE_URL:-}"
if [[ -n "$PROXY_URL" ]]; then
  # Extract host and port from URL (e.g. http://localhost:4141 or http://host.docker.internal:4141)
  PROXY_HOST=$(echo "$PROXY_URL" | sed -E 's|https?://([^:/]+).*|\1|')
  PROXY_PORT=$(echo "$PROXY_URL" | sed -E 's|.*:([0-9]+).*|\1|')

  # Only add rule if it points to a local host
  if [[ "$PROXY_HOST" == "localhost" || "$PROXY_HOST" == "127.0.0.1" || "$PROXY_HOST" == "host.docker.internal" ]]; then
    if [[ "$PROXY_PORT" =~ ^[0-9]+$ ]]; then
      iptables -A INPUT -s "$HOST_IP" -p tcp --sport "$PROXY_PORT" -m state --state ESTABLISHED -j ACCEPT
      iptables -A OUTPUT -d "$HOST_IP" -p tcp --dport "$PROXY_PORT" -j ACCEPT
      log "Proxy exception added: $HOST_IP:$PROXY_PORT (ANTHROPIC_BASE_URL=$PROXY_HOST:$PROXY_PORT)"
    else
      log "WARNING: Could not parse port from ANTHROPIC_BASE_URL — host network access not granted"
    fi
  else
    log "ANTHROPIC_BASE_URL points to remote host ($PROXY_HOST) — no host network exception needed"
  fi
fi

# ── Set default policies to DROP ────────────────────────────────────
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow traffic to whitelisted IPs
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Reject everything else with immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# ── Block IPv6 entirely ─────────────────────────────────────────────
ip6tables -P INPUT DROP 2>/dev/null || true
ip6tables -P FORWARD DROP 2>/dev/null || true
ip6tables -P OUTPUT DROP 2>/dev/null || true
ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true

# ── Verification ────────────────────────────────────────────────────
log "Verifying firewall rules..."

if curl --connect-timeout 5 -sf https://example.com >/dev/null 2>&1; then
  log "ERROR: Firewall verification failed — able to reach example.com (should be blocked)"
  exit 1
fi
log "Blocked domain (example.com) correctly rejected"

if ! curl --connect-timeout 5 -sf https://api.github.com/zen >/dev/null 2>&1; then
  log "ERROR: Firewall verification failed — unable to reach api.github.com (should be allowed)"
  exit 1
fi
log "Allowed domain (api.github.com) correctly accessible"

log "Firewall active — $(ipset list allowed-domains | grep -c 'Members:' || true) rule set(s), IPv4 + IPv6 locked down"
