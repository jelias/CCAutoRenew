# CCAutoRenew Docker Setup

## Files Created

- `Dockerfile` - Multi-stage build with Node.js, Claude CLI, ccusage
- `docker-compose.yml` - Two services: account-a (6am-17:00) and account-b (9am-17:00)
- `docker-entrypoint.sh` - Configures start/stop times and starts daemon
- `.env.example` - Template for API keys
- `.dockerignore` - Excludes test files from build

## Setup

1. Copy `.env.example` to `.env` and add your API keys:
   ```bash
   cp .env.example .env
   nano .env
   ```

2. Get API keys from https://console.anthropic.com/

3. Build and deploy to RPi:
   ```bash
   # Build locally
   docker build -t claude-renewal .

   # Or use docker-compose to build both
   docker-compose build

   # Save and transfer to RPi
   docker save claude-renewal-account-a claude-renewal-account-b -o claude-renewal.tar
   scp claude-renewal.tar user@rpi:~/

   # On RPi
   docker load -i claude-renewal.tar
   docker-compose up -d
   ```

4. Check status:
   ```bash
   docker exec claude-renewal-account-a ./claude-daemon-manager.sh status
   docker exec claude-renewal-account-b ./claude-daemon-manager.sh status
   ```

5. View logs:
   ```bash
   docker logs claude-renewal-account-a
   docker logs claude-renewal-account-b
   ```

## Schedule

- **Account A**: Starts at 6:00 AM, resets ~11am/4pm/9pm
- **Account B**: Starts at 9:00 AM, resets ~2pm/7pm/12am
