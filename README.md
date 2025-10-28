# Blitz Node - Hysteria2 Server Setup

Complete Hysteria2 node installation with panel integration, authentication, and traffic tracking.

## Installation Steps

### 1. Run Installer

Clone this repository:

```bash
git clone https://github.com/ReturnFI/Blitz-Node.git
cd Blitz-Node
```

Make the installer executable:

```bash
chmod +x install.sh
```

Run the installer:

```bash
./install.sh install <port> <sni>
```

   Example:

```bash
./install.sh install 1239 example.com
```

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