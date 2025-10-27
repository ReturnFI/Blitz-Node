# Blitz Node - Hysteria2 Server Setup

Complete Hysteria2 node installation with panel integration, authentication, and traffic tracking.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/ReturnFI/Blitz-Node/refs/heads/main/install.sh | bash -s install 1239 bts.com
```

Replace:
- `1239` with your desired port
- `bts.com` with your domain for SNI

## Installation Steps

### 1. Run Installer

```bash
bash install.sh install <port> <sni>
```

The installer will:
- Install Hysteria2 server
- Generate SSL certificates
- Create Python virtual environment
- Clone Blitz-Node repository
- Setup systemd services
- Prompt for panel API credentials

### 2. Configure Panel API

During installation, provide:
- **Panel URL**: `https://your-panel.com/your-path/`
- **API Key**: Your panel authentication key

The installer automatically appends:
- `/api/v1/users/` for user authentication
- `/api/v1/config/ip/nodestraffic` for traffic reporting

## Uninstall

```bash
bash install.sh uninstall
```