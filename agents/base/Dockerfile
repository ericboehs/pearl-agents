FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
  dumb-init git curl jq ripgrep \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

RUN git config --system credential.helper \
      '!f() { echo "password=$GITHUB_TOKEN"; }; f' \
  && git config --system credential.https://github.com.username x-access-token \
  && git config --system safe.directory '*'

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

RUN useradd -m -s /bin/bash agent

# Pre-configure Claude CLI to skip onboarding and use npm install method
RUN mkdir -p /home/agent/.claude && \
    echo '{"hasCompletedOnboarding":true,"installMethod":"npm"}' > /home/agent/.claude.json && \
    chown -R agent:agent /home/agent/.claude /home/agent/.claude.json

USER agent
WORKDIR /workspace

ENTRYPOINT ["dumb-init", "--", "entrypoint.sh"]
