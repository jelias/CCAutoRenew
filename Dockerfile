FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
	curl \
	jq \
	ca-certificates \
	&& curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
	&& apt-get install -y nodejs \
	&& npm install -g ccusage@latest \
	&& curl -fsSL https://github.com/anthropic/claude-code/releases/download/v1.0.43/claude-code_1.0.43_linux_arm64.tar.gz -o claude.tar.gz \
	&& tar -xzf claude.tar.gz -C /usr/local/bin --strip-components=1 \
	&& rm claude.tar.gz \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . .

RUN chmod +x claude-auto-renew.sh claude-daemon-manager.sh claude-auto-renew-daemon.sh stop-daemon.sh

ENV ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}

RUN mkdir -p ~/.claude

RUN echo "Installation complete"

ENTRYPOINT ["/app/docker-entrypoint.sh"]
