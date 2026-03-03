FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
  dumb-init git curl jq ripgrep \
  iptables ipset iproute2 dnsutils aggregate sudo \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# Scope credential helper to github.com only (prevents PAT leaking to other remotes)
RUN git config --system credential.https://github.com.helper \
      '!f() { if [ -n "$GITHUB_TOKEN" ]; then echo "password=$GITHUB_TOKEN"; else echo "GITHUB_TOKEN is not set" >&2; exit 1; fi; }; f' \
  && git config --system credential.https://github.com.username x-access-token \
  && git config --system safe.directory /workspace \
  && git config --system safe.directory /home/agent

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 init-firewall.sh /usr/local/bin/init-firewall.sh

RUN echo "agent ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/firewall \
  && chmod 440 /etc/sudoers.d/firewall

RUN useradd -m -s /bin/bash agent

# Pre-configure Claude CLI to skip onboarding and suppress npm-to-native warning
RUN mkdir -p /home/agent/.claude && \
    echo '{"hasCompletedOnboarding":true,"installMethod":"npm"}' > /home/agent/.claude.json && \
    chown -R agent:agent /home/agent/.claude /home/agent/.claude.json
ENV DISABLE_INSTALLATION_CHECKS=1

USER agent
WORKDIR /workspace

ENTRYPOINT ["dumb-init", "--", "entrypoint.sh"]
