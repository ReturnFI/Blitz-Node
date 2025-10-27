#!/bin/bash
CONFIG_FILE="/etc/hysteria/config.json"

define_colors() {
    green='\033[0;32m'
    cyan='\033[0;36m'
    red='\033[0;31m'
    yellow='\033[0;33m'
    LPurple='\033[1;35m'
    NC='\033[0m'
}

install_hysteria() {
    local port=$1
    local sni=$2
    local sha256
    local obfspassword
    local UUID
    local networkdef
    local panel_url
    local panel_key

    echo "Configuring Panel API..."
    read -p "Enter panel API domain and path (e.g., https://example.com/path/): " panel_url
    read -p "Enter panel API key: " panel_key
    
    if [[ -z "$panel_url" ]] || [[ -z "$panel_key" ]]; then
        echo -e "${red}Error:${NC} Panel URL and API key are required"
        exit 1
    fi
    
    panel_url="${panel_url%/}"
    
    echo "Installing Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/) >/dev/null 2>&1
    
    mkdir -p /etc/hysteria && cd /etc/hysteria/

    echo "Installing Python and dependencies..."
    apt-get update >/dev/null 2>&1
    apt-get install -y python3 python3-venv python3-pip >/dev/null 2>&1

    echo "Generating CA key and certificate..."
    openssl ecparam -genkey -name prime256v1 -out ca.key >/dev/null 2>&1
    openssl req -new -x509 -days 36500 -key ca.key -out ca.crt -subj "/CN=$sni" >/dev/null 2>&1
    
    if ! command -v jq &> /dev/null; then
        echo "Installing jq..."
        apt-get update >/dev/null 2>&1
        apt-get install -y jq >/dev/null 2>&1
    fi

    echo "Downloading geo data and config..."
    wget -O /etc/hysteria/config.json https://raw.githubusercontent.com/ReturnFI/Blitz/refs/heads/main/config.json >/dev/null 2>&1 || {
        echo -e "${red}Error:${NC} Failed to download config.json"
        exit 1
    }
    wget -O /etc/hysteria/geosite.dat https://raw.githubusercontent.com/Chocolate4U/Iran-v2ray-rules/release/geosite.dat >/dev/null 2>&1
    wget -O /etc/hysteria/geoip.dat https://raw.githubusercontent.com/Chocolate4U/Iran-v2ray-rules/release/geoip.dat >/dev/null 2>&1

    echo "Generating SHA-256 fingerprint..."
    sha256=$(openssl x509 -noout -fingerprint -sha256 -inform pem -in ca.crt | sed 's/.*=//' | tr '[:lower:]' '[:upper:]')

    if [[ ! $port =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        echo -e "${red}Error:${NC} Invalid port number. Please enter a number between 1 and 65535."
        exit 1
    fi
    
    if ss -tuln | grep -q ":$port "; then
        echo -e "${red}Error:${NC} Port $port is already in use. Please choose another port."
        exit 1
    fi

    if ! id -u hysteria &> /dev/null; then
        useradd -r -s /usr/sbin/nologin hysteria
    fi

    echo "Generating passwords and UUID..."
    obfspassword=$(openssl rand -base64 24)
    UUID=$(cat /proc/sys/kernel/random/uuid)
    
    networkdef=$(ip route | grep "^default" | awk '{print $5}')

    chown hysteria:hysteria /etc/hysteria/ca.key /etc/hysteria/ca.crt
    chmod 640 /etc/hysteria/ca.key /etc/hysteria/ca.crt

    echo "Customizing config.json..."
    jq --arg port "$port" \
       --arg sha256 "$sha256" \
       --arg obfspassword "$obfspassword" \
       --arg UUID "$UUID" \
       --arg networkdef "$networkdef" \
       '.listen = (":" + $port) |
        .tls.cert = "/etc/hysteria/ca.crt" |
        .tls.key = "/etc/hysteria/ca.key" |
        .tls.pinSHA256 = $sha256 |
        .obfs.salamander.password = $obfspassword |
        .trafficStats.secret = $UUID |
        .outbounds[0].direct.bindDevice = $networkdef' "$CONFIG_FILE" > "${CONFIG_FILE}.temp" && mv "${CONFIG_FILE}.temp" "$CONFIG_FILE" || {
        echo -e "${red}Error:${NC} Failed to customize config.json"
        exit 1
    }

    echo "Updating hysteria-server.service configuration..."
    if [[ -f /etc/systemd/system/hysteria-server.service ]]; then
        sed -i 's|/etc/hysteria/config.yaml|'"$CONFIG_FILE"'|g' /etc/systemd/system/hysteria-server.service
        [[ -f /etc/hysteria/config.yaml ]] && rm /etc/hysteria/config.yaml
    fi

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable hysteria-server.service >/dev/null 2>&1
    systemctl restart hysteria-server.service >/dev/null 2>&1
    sleep 2

    echo "Cloning Blitz Node repository..."
    if ! command -v git &> /dev/null; then
        apt-get install -y git >/dev/null 2>&1
    fi
    cd /etc/hysteria
    git clone https://github.com/ReturnFI/Blitz-Node.git . >/dev/null 2>&1 || {
        echo -e "${red}Error:${NC} Failed to clone Blitz Node repository"
        exit 1
    }
    
    echo "Setting up Python virtual environment and services..."
    python3 -m venv /etc/hysteria/blitz >/dev/null 2>&1
    /etc/hysteria/blitz/bin/pip install aiohttp >/dev/null 2>&1
    
    echo "Creating .env configuration file..."
    cat > /etc/hysteria/.env <<EOF
PANEL_API_URL=${panel_url}/api/v1/users/
PANEL_TRAFFIC_URL=${panel_url}/api/v1/config/ip/nodestraffic
PANEL_API_KEY=${panel_key}
SYNC_INTERVAL=35
EOF
    chown hysteria:hysteria /etc/hysteria/.env
    chmod 600 /etc/hysteria/.env
    
    cat > /etc/systemd/system/hysteria-auth.service <<EOF
[Unit]
Description=Hysteria2 Auth Service
After=network.target

[Service]
Type=simple
User=hysteria
WorkingDirectory=/etc/hysteria
Environment="PATH=/etc/hysteria/blitz/bin"
EnvironmentFile=/etc/hysteria/.env
ExecStart=/etc/hysteria/blitz/bin/python3 /etc/hysteria/auth.py
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/hysteria-traffic.service <<EOF
[Unit]
Description=Hysteria2 Traffic Collector
After=network.target

[Service]
Type=simple
User=hysteria
WorkingDirectory=/etc/hysteria
Environment="PATH=/etc/hysteria/blitz/bin"
EnvironmentFile=/etc/hysteria/.env
ExecStart=/etc/hysteria/blitz/bin/python3 /etc/hysteria/traffic.py
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    chown hysteria:hysteria /etc/hysteria/blitz
    chmod 750 /etc/hysteria/blitz
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable hysteria-auth.service hysteria-traffic.service >/dev/null 2>&1
    systemctl start hysteria-auth.service hysteria-traffic.service >/dev/null 2>&1

    if systemctl is-active --quiet hysteria-server.service; then
        echo -e "${green}✓${NC} Hysteria2 installed successfully"
        echo -e "${cyan}Port:${NC} $port"
        echo -e "${cyan}SHA256:${NC} $sha256"
        echo -e "${cyan}Obfs Password:${NC} $obfspassword"
        echo ""
        echo -e "${green}✓${NC} Auth and Traffic services configured"
        echo -e "${green}✓${NC} Configuration saved to /etc/hysteria/.env"
        echo ""
        echo -e "Check service status:"
        echo -e "  systemctl status hysteria-auth"
        echo -e "  systemctl status hysteria-traffic"
        return 0
    else
        echo -e "${red}✗ Error:${NC} hysteria-server.service is not active"
        journalctl -u hysteria-server.service -n 20 --no-pager
        exit 1
    fi
}

uninstall_hysteria() {
    echo "Uninstalling Hysteria2..."
    
    if systemctl is-active --quiet hysteria-server.service; then
        systemctl stop hysteria-server.service >/dev/null 2>&1
        systemctl disable hysteria-server.service >/dev/null 2>&1
        echo -e "${green}✓${NC} Stopped hysteria-server service"
    fi
    
    for service in hysteria-auth hysteria-traffic; do
        if systemctl is-active --quiet $service.service; then
            systemctl stop $service.service >/dev/null 2>&1
            systemctl disable $service.service >/dev/null 2>&1
            echo -e "${green}✓${NC} Stopped $service service"
        fi
        if [[ -f /etc/systemd/system/$service.service ]]; then
            rm /etc/systemd/system/$service.service >/dev/null 2>&1
        fi
    done
    
    bash <(curl -fsSL https://get.hy2.sh/) --remove >/dev/null 2>&1
    echo -e "${green}✓${NC} Removed Hysteria2 binary"
    
    if [[ -d /etc/hysteria ]]; then
        rm -rf /etc/hysteria
        echo -e "${green}✓${NC} Removed /etc/hysteria directory"
    fi
    
    if id -u hysteria &> /dev/null; then
        userdel hysteria >/dev/null 2>&1
        echo -e "${green}✓${NC} Removed hysteria user"
    fi
    
    systemctl daemon-reload >/dev/null 2>&1
    echo -e "${green}✓${NC} Hysteria2 uninstalled successfully"
}

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  install <port> <sni>    Install Hysteria2 with specified port and SNI"
    echo "  uninstall               Uninstall Hysteria2 completely"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 install 1239 bts.com"
    echo "  $0 uninstall"
}

define_colors

case "${1:-}" in
    install)
        if [[ -z "$2" ]] || [[ -z "$3" ]]; then
            echo -e "${red}Error:${NC} Port and SNI required"
            show_usage
            exit 1
        fi
        if systemctl is-active --quiet hysteria-server.service; then
            echo -e "${red}✗ Error:${NC} Hysteria2 is already installed and running"
            exit 1
        fi
        install_hysteria "$2" "$3"
        ;;
    uninstall)
        if ! systemctl is-active --quiet hysteria-server.service && [[ ! -d /etc/hysteria ]]; then
            echo -e "${yellow}⚠${NC} Hysteria2 is not installed"
            exit 0
        fi
        uninstall_hysteria
        ;;
    -h|--help)
        show_usage
        ;;
    *)
        echo -e "${red}Error:${NC} Invalid option"
        show_usage
        exit 1
        ;;
esac