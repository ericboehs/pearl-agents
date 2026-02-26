FROM pearl-base:latest

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
  build-essential ruby ruby-dev python3 python3-pip python3-venv \
  golang-go shellcheck \
  && rm -rf /var/lib/apt/lists/*

USER agent
