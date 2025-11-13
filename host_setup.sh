#!/bin/bash
# Host System Setup Script for Hybrid CUPS + Docker CAPT Architecture
# Run this on your DietPi system with sudo

set -e

echo "=================================================="
echo "Canon LBP7018C Hybrid Setup - Host Configuration"
echo "=================================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root (sudo)${NC}"
    exit 1
fi

echo -e "${GREEN}[1/7] Checking prerequisites...${NC}"
# Verify CUPS and Avahi are installed
if ! command -v cupsd &> /dev/null; then
    echo -e "${RED}CUPS is not installed. Please install it first using DietPi-Software.${NC}"
    exit 1
fi

if ! command -v avahi-daemon &> /dev/null; then
    echo -e "${RED}Avahi daemon is not installed. Please install it first using DietPi-Software.${NC}"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker is not installed. Please install it first using DietPi-Software.${NC}"
    exit 1
fi

echo -e "${GREEN}[2/7] Installing additional dependencies...${NC}"
apt-get update -qq
apt-get install -y socat netcat-openbsd

echo -e "${GREEN}[3/7] Configuring CUPS on host...${NC}"

# Backup original CUPS config
cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.backup.$(date +%Y%m%d_%H%M%S)

# Configure CUPS for network access
sed -i 's/Listen localhost:631/Listen 0.0.0.0:631/' /etc/cups/cupsd.conf
sed -i 's/Browsing Off/Browsing On/' /etc/cups/cupsd.conf

# Allow access from all locations
if ! grep -q "Allow All" /etc/cups/cupsd.conf; then
    sed -i '/<Location \/>/a\  Allow All' /etc/cups/cupsd.conf
    sed -i '/<Location \/admin>/a\  Allow All\n  Require user @SYSTEM' /etc/cups/cupsd.conf
    sed -i '/<Location \/admin\/conf>/a\  Allow All' /etc/cups/cupsd.conf
fi

# Add ServerAlias if not exists
if ! grep -q "ServerAlias" /etc/cups/cupsd.conf; then
    echo "ServerAlias *" >> /etc/cups/cupsd.conf
fi

# Set encryption to never (for local network)
if ! grep -q "DefaultEncryption Never" /etc/cups/cupsd.conf; then
    echo "DefaultEncryption Never" >> /etc/cups/cupsd.conf
fi

# Enable debug logging temporarily
sed -i 's/^LogLevel .*/LogLevel debug/' /etc/cups/cupsd.conf

echo -e "${GREEN}[4/7] Creating CAPT backend script...${NC}"

# Create directory for CAPT backend
mkdir -p /usr/lib/cups/backend

# Create the CAPT backend script that connects to Docker container
cat > /usr/lib/cups/backend/capt << 'EOF'
#!/bin/bash
# CUPS Backend for Canon CAPT Driver in Docker Container
# This script forwards print jobs to the ccpd daemon running in Docker

# CUPS backend protocol requires specific exit codes:
# 0 - Success
# 1 - Failure (will retry)
# 2 - Failure (will not retry)

CONTAINER_NAME="cups-capt-driver"
CCPD_PORT=59787

# Function to check if container is running
check_container() {
    docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

# Function to send job to container
send_to_container() {
    local job_id="$1"
    local user="$2"
    local title="$3"
    local copies="$4"
    local options="$5"
    local filename="$6"
    
    # If no filename provided, read from stdin
    if [ -z "$filename" ] || [ "$filename" = "-" ]; then
        # Create temp file for stdin data
        filename="/tmp/cups-job-$$.tmp"
        cat > "$filename"
    fi
    
    # Check if container is running
    if ! check_container; then
        echo "ERROR: CAPT driver container is not running" >&2
        [ -f "/tmp/cups-job-$$.tmp" ] && rm -f "/tmp/cups-job-$$.tmp"
        exit 1
    fi
    
    # Copy file to container and print
    docker cp "$filename" "${CONTAINER_NAME}:/tmp/printjob.tmp"
    docker exec "${CONTAINER_NAME}" lp -d LBP7018C "/tmp/printjob.tmp"
    
    # Cleanup
    docker exec "${CONTAINER_NAME}" rm -f "/tmp/printjob.tmp"
    [ -f "/tmp/cups-job-$$.tmp" ] && rm -f "/tmp/cups-job-$$.tmp"
    
    exit 0
}

# CUPS backend discovery mode (no arguments)
if [ $# -eq 0 ]; then
    echo "network capt \"Unknown\" \"Canon CAPT Printer (Docker)\""
    exit 0
fi

# CUPS backend job processing mode (5 or 6 arguments)
if [ $# -eq 5 ] || [ $# -eq 6 ]; then
    send_to_container "$@"
else
    echo "ERROR: Invalid number of arguments" >&2
    exit 2
fi
EOF

chmod 755 /usr/lib/cups/backend/capt

echo -e "${GREEN}[5/7] Creating systemd service for container management...${NC}"

# Create systemd service to ensure container starts on boot
cat > /etc/systemd/system/cups-capt-driver.service << 'EOF'
[Unit]
Description=Canon CAPT Driver Container for CUPS
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/bin/docker stop cups-capt-driver
ExecStartPre=-/usr/bin/docker rm cups-capt-driver
ExecStart=/usr/bin/docker run -d \
    --name cups-capt-driver \
    --restart unless-stopped \
    --network host \
    --privileged \
    -v /dev/bus/usb:/dev/bus/usb \
    -v /var/run/dbus:/var/run/dbus \
    -v /var/run/avahi-daemon/socket:/var/run/avahi-daemon/socket \
    -e TZ=Europe/Amsterdam \
    capt-driver:optimized
ExecStop=/usr/bin/docker stop cups-capt-driver

[Install]
WantedBy=multi-user.target
EOF

echo -e "${GREEN}[6/7] Creating monitoring script...${NC}"

# Create a monitoring script to check system performance
cat > /usr/local/bin/cups-capt-monitor << 'EOF'
#!/bin/bash
# Monitoring script for CUPS + CAPT Docker setup

echo "=================================================="
echo "CUPS + CAPT Docker Status Monitor"
echo "=================================================="

echo ""
echo "=== Host CUPS Status ==="
systemctl status cups --no-pager | head -n 10

echo ""
echo "=== CUPS Queue Status ==="
lpstat -t

echo ""
echo "=== Docker Container Status ==="
if docker ps | grep -q cups-capt-driver; then
    echo "Container: RUNNING"
    docker stats cups-capt-driver --no-stream
else
    echo "Container: NOT RUNNING"
fi

echo ""
echo "=== Container ccpd Status ==="
if docker ps | grep -q cups-capt-driver; then
    docker exec cups-capt-driver ccpdadmin
else
    echo "Container not running"
fi

echo ""
echo "=== USB Printer Detection ==="
lsusb | grep -i canon || echo "No Canon printer detected"

echo ""
echo "=== Recent CUPS Errors ==="
tail -n 20 /var/log/cups/error_log

echo ""
echo "=== Container Logs (last 20 lines) ==="
docker logs cups-capt-driver --tail 20

echo ""
echo "=== System Resources ==="
echo "CPU Usage:"
top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1"%"}'
echo "Memory Usage:"
free -h | grep Mem | awk '{print $3 "/" $2}'
echo "Docker Container Memory:"
docker stats cups-capt-driver --no-stream --format "{{.MemUsage}}"
EOF

chmod +x /usr/local/bin/cups-capt-monitor

echo -e "${GREEN}[7/7] Restarting CUPS service...${NC}"
systemctl restart cups
systemctl enable cups

echo ""
echo -e "${GREEN}=================================================="
echo "Host Setup Complete!"
echo "==================================================${NC}"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Build the Docker image using the provided Dockerfile"
echo "2. Run: systemctl enable cups-capt-driver.service"
echo "3. Run: systemctl start cups-capt-driver.service"
echo "4. Add printer in CUPS using the 'capt' backend"
echo "5. Monitor with: cups-capt-monitor"
echo ""
echo -e "${YELLOW}To add the printer after container is running:${NC}"
echo "lpadmin -p LBP7018C -v capt://localhost/LBP7018C -P /usr/share/ppd/LBP7018C.ppd -E"
echo ""
