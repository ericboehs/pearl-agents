#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# PEARL network firewall — iptables-based domain whitelisting
# Adapted from the Claude Code devcontainer's init-firewall.sh
# https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh

log() { echo "[firewall] $*" >&2; }

# Quick capability check — routed through this script so only
# init-firewall.sh needs to be in the sudoers allowlist.
if [[ "${1:-}" == "--check" ]]; then
  # stdout suppressed; stderr preserved so the caller can inspect error messages
  iptables -L -n >/dev/null
  exit $?
fi

# Prevent re-invocation — an agent could re-run this script with a crafted
# ANTHROPIC_BASE_URL to open extra host ports.
LOCK_FILE="/var/run/firewall-initialized"
if [[ -f "$LOCK_FILE" ]]; then
  log "ERROR: Firewall already initialized. Re-initialization is not permitted."
  exit 1
fi

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
# DNS — UDP is stateless so an explicit INPUT rule is required; TCP is needed for large responses
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -p tcp --sport 53 -m state --state ESTABLISHED -j ACCEPT
# SSH
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
# Localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# ── Create ipset for allowed IPs ────────────────────────────────────
ipset create allowed-domains hash:net

# ── GitHub IPs (dynamic via API) ────────────────────────────────────
# Two /22 ranges (185.199.108.0/22, 192.30.252.0/22) are excluded because they
# also cover GitHub Pages IPs — any Pages-hosted site would pass the firewall.
# Domains in those ranges (raw.githubusercontent.com, etc.) are resolved via
# DNS below instead.
log "Fetching GitHub IP ranges..."
gh_ranges=$(curl -sf https://api.github.com/meta) || {
  log "ERROR: Failed to fetch GitHub IP ranges"
  exit 1
}

if ! echo "$gh_ranges" | jq -e '(.web | type == "array" and length > 0) and (.api | type == "array" and length > 0) and (.git | type == "array" and length > 0)' >/dev/null; then
  log "ERROR: GitHub API response missing or malformed .web/.api/.git fields"
  exit 1
fi

log "Processing GitHub IPs..."
github_cidrs=$(echo "$gh_ranges" | jq -r '
  [(.web + .api + .git)[] | select(test("^[0-9.]+/"))] | unique
  | map(select(. != "185.199.108.0/22" and . != "192.30.252.0/22"))
  | .[]') || {
  log "ERROR: Failed to extract CIDR ranges from GitHub API response"
  exit 1
}
github_cidrs=$(echo "$github_cidrs" | aggregate -q) || {
  log "ERROR: aggregate failed to process GitHub CIDR ranges"
  exit 1
}
if [[ -z "$github_cidrs" ]]; then
  log "ERROR: No IPv4 CIDR ranges found in GitHub API response after filtering"
  exit 1
fi
while read -r cidr; do
  if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    log "ERROR: Invalid CIDR range from GitHub meta: $cidr"
    exit 1
  fi
  ipset add allowed-domains "$cidr"
done <<< "$github_cidrs"

# ── Core whitelist (all agents) ─────────────────────────────────────
CORE_DOMAINS=(
  # GitHub content domains — their IPs currently fall in the excluded /22
  # ranges, so they must be resolved individually via DNS
  "raw.githubusercontent.com"
  "objects.githubusercontent.com"
  # npm
  "registry.npmjs.org"
  # Claude CLI dependencies
  "api.anthropic.com"
  "sentry.io"
  "statsig.anthropic.com"
  "statsig.com"
)

# ── Per-agent whitelist ─────────────────────────────────────────────
AGENT_DOMAINS=()
if [[ -f /firewall/domains.txt ]]; then
  while IFS= read -r line; do
    # Strip inline comments (everything after #) and trim surrounding whitespace
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
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
    if ! out=$(ipset add allowed-domains "$ip" 2>&1); then
      [[ "$out" == *"already added"* ]] || { log "ERROR: Failed to add $ip to ipset: $out"; exit 1; }
    fi
  done <<< "$ips"
done

# ── Host network access ────────────────────────────────────────────
HOST_IP=$(ip route show default | awk '/^default via/ {print $3; exit}')
if [[ -z "$HOST_IP" ]]; then
  log "ERROR: Failed to detect host IP from 'ip route show default'"
  exit 1
fi
if [[ ! "$HOST_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  log "ERROR: Unexpected value for host IP: '$HOST_IP' (expected an IP address)"
  exit 1
fi

# Unrestricted host access (opt-in via marker file)
if [[ -f /firewall/allow-host-access ]]; then
  # Allow both the container gateway and host.docker.internal (may differ on Docker Desktop)
  iptables -A INPUT -s "$HOST_IP" -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -d "$HOST_IP" -j ACCEPT
  HDI_IP=$(getent ahostsv4 host.docker.internal 2>/dev/null | awk '$2 == "STREAM" {print $1; exit}')
  if [[ -n "$HDI_IP" && "$HDI_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ && "$HDI_IP" != "$HOST_IP" ]]; then
    iptables -A INPUT -s "$HDI_IP" -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -d "$HDI_IP" -j ACCEPT
    log "Unrestricted host access enabled ($HOST_IP + $HDI_IP)"
  else
    [[ -z "$HDI_IP" ]] && log "WARNING: host.docker.internal could not be resolved — only gateway IP whitelisted"
    log "Unrestricted host access enabled ($HOST_IP)"
  fi
else
  # Only allow the specific proxy port when ANTHROPIC_BASE_URL points to a local host
  PROXY_URL="${ANTHROPIC_BASE_URL:-}"
  if [[ -n "$PROXY_URL" ]]; then
    # Extract host and port from URL (e.g. http://localhost:4141 or http://host.docker.internal:4141)
    PROXY_HOST=$(echo "$PROXY_URL" | sed -E 's|https?://([^:/]+).*|\1|')
    PROXY_PORT=$(echo "$PROXY_URL" | sed -nE 's|https?://[^/]*:([0-9]+).*|\1|p')

    # Only add rule if it points to a local host
    if [[ "$PROXY_HOST" == "localhost" || "$PROXY_HOST" == "127.0.0.1" || "$PROXY_HOST" == "host.docker.internal" ]]; then
      if [[ -n "$PROXY_PORT" && "$PROXY_PORT" =~ ^[0-9]+$ ]]; then
        # Resolve the proxy hostname to its actual IP — on Docker Desktop for Mac,
        # host.docker.internal (192.168.65.x) differs from the container gateway
        # (172.17.0.1), so we can't use HOST_IP from the default route.
        PROXY_IP=$(getent ahostsv4 "$PROXY_HOST" 2>/dev/null | awk '$2 == "STREAM" {print $1; exit}')
        if [[ -z "$PROXY_IP" ]]; then
          log "WARNING: Could not resolve $PROXY_HOST via getent, falling back to gateway $HOST_IP"
          PROXY_IP="$HOST_IP"
        fi
        if [[ ! "$PROXY_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
          log "ERROR: Resolved proxy IP '$PROXY_IP' is not a valid IPv4 address"
          exit 1
        fi
        iptables -A INPUT -s "$PROXY_IP" -p tcp --sport "$PROXY_PORT" -m state --state ESTABLISHED -j ACCEPT
        iptables -A OUTPUT -d "$PROXY_IP" -p tcp --dport "$PROXY_PORT" -j ACCEPT
        log "Proxy exception added: $PROXY_IP:$PROXY_PORT (ANTHROPIC_BASE_URL=$PROXY_HOST:$PROXY_PORT)"
      else
        log "ERROR: Could not parse port from ANTHROPIC_BASE_URL='$PROXY_URL' (expected http://host:PORT)"
        log "ERROR: The local proxy will be blocked by the firewall. Refusing to start."
        exit 1
      fi
    else
      log "ANTHROPIC_BASE_URL points to remote host ($PROXY_HOST) — no host network exception needed"
    fi
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
if ip6tables -P INPUT DROP 2>/dev/null; then
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT DROP
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT
  log "IPv6 blocked (all policies DROP)"
else
  log "WARNING: ip6tables not available — IPv6 traffic is NOT blocked"
fi

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

ENTRY_COUNT=$(ipset list allowed-domains | grep -cE '^[0-9]' || echo 0)
log "Firewall active — $ENTRY_COUNT IP(s) whitelisted, IPv4 + IPv6 locked down"

# Mark initialization complete to prevent re-invocation
touch "$LOCK_FILE"
