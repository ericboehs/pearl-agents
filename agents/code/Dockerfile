FROM pearl-base:latest

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
  build-essential ruby ruby-dev python3 python3-pip python3-venv \
  golang-go shellcheck \
  && rm -rf /var/lib/apt/lists/*

# Playwright MCP: install package and Chromium with system deps
# Use the playwright CLI bundled with @playwright/mcp to ensure browser version matches
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers
RUN npm install -g @playwright/mcp@0.0.68 \
  && /usr/local/lib/node_modules/@playwright/mcp/node_modules/.bin/playwright install --with-deps chromium \
  && chown -R agent:agent $PLAYWRIGHT_BROWSERS_PATH \
  && rm -rf /var/lib/apt/lists/*

USER agent
