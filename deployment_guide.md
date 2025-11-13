# Canon LBP7018C Hybrid Architecture - Complete Deployment Guide

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│  Orange Pi 2W (DietPi ARM)                          │
│                                                     │
│  ┌──────────────────────────────────────────────┐  │
│  │  CUPS Server (Native ARM)                    │  │
│  │  - Receives network print jobs               │  │
│  │  - Manages queue                             │  │
│  │  - Renders documents                         │  │
│  └────────────┬─────────────────────────────────┘  │
│               │ via custom backend                 │
│               ▼                                     │
│  ┌──────────────────────────────────────────────┐  │
│  │  Docker Container (i386 via QEMU)            │  │
│  │  - ccpd daemon ONLY                          │  │
│  │  - Canon CAPT driver                         │  │
│  │  - Minimal overhead                          │  │
│  └────────────┬─────────────────────────────────┘  │
└───────────────┼───────────────────────────────────┘
                │
                ▼
          [USB Printer LBP7018C]
```

## Prerequisites

Ensure your DietPi system has:
- CUPS installed (via DietPi-Software)
- Avahi daemon installed (via DietPi-Software)
- Docker installed (via DietPi-Software)
- Printer connected via USB

## Step-by-Step Deployment

### 1. Prepare Your Working Directory

```bash
# Create project directory
mkdir -p ~/cups-capt-hybrid
cd ~/cups-capt-hybrid

# Download all the files from the artifacts
# Place them in this directory:
# - host-setup.sh
# - Dockerfile (the optimized one)
# - entrypoint-optimized.sh
# - diagnostic-script.sh
# - this deployment guide
```

### 2. Run Host System Setup

```bash
# Make the host setup script executable
chmod +x host-setup.sh

# Run with sudo
sudo ./host-setup.sh
```

**Expected output:**
- CUPS configuration updated for network access
- Custom CAPT backend created at `/usr/lib/cups/backend/capt`
- Systemd service created for container management
- Monitoring tools installed
- CUPS restarted

**Verify:**
```bash
# Check CUPS is running
systemctl status cups

# Check backend exists
ls -la /usr/lib/cups/backend/capt

# Check monitoring tool
cups-capt-monitor
```

### 3. Build the Docker Image

```bash
cd ~/cups-capt-hybrid

# Ensure files are in place
ls -la
# Should show: Dockerfile, entrypoint-optimized.sh

# Build the optimized image
docker build -t capt-driver:optimized .
```

**Build time:** ~5-10 minutes (depending on network speed)

**Expected output:**
```
Successfully built [image-id]
Successfully tagged capt-driver:optimized:latest
```

**Verify:**
```bash
docker images | grep capt-driver
```

### 4. Start the Container Service

```bash
# Enable service to start on boot
sudo systemctl enable cups-capt-driver.service

# Start the service
sudo systemctl start cups-capt-driver.service

# Check status
sudo systemctl status cups-capt-driver.service
```

**Expected output:**
```
● cups-capt-driver.service - Canon CAPT Driver Container for CUPS
   Loaded: loaded
   Active: active (running)
```

**Verify container is running:**
```bash
docker ps | grep cups-capt-driver

# Check container logs
docker logs cups-capt-driver

# Should see:
# - Printer device found
# - ccpd daemon initialized successfully
# - Container ready - monitoring ccpd daemon
```

### 5. Verify USB Printer Detection

```bash
# Check USB devices
lsusb | grep -i canon

# Expected output (example):
# Bus 001 Device 003: ID 04a9:2676 Canon, Inc. LBP7018C

# Check if device node exists
ls -la /dev/usb/lp0

# Check container can see it
docker exec cups-capt-driver ls -la /dev/usb/lp0
```

**If printer not detected:**
```bash
# Check if usblp module is loaded (shouldn't be for CAPT)
lsmod | grep usblp

# If it's loaded, blacklist it
echo "blacklist usblp" | sudo tee /etc/modprobe.d/blacklist-usblp.conf
sudo update-initramfs -u
sudo reboot
```

### 6. Configure Printer in CUPS (Host)

You can add the printer via web interface or command line:

#### Option A: Web Interface (Recommended for first-time setup)

```bash
# Get your Orange Pi IP address
hostname -I

# Open in browser from another computer:
# http://[ORANGE_PI_IP]:631

# Navigate to: Administration > Add Printer
# You may need to login (create CUPS admin user):
sudo cupsctl --remote-admin
sudo cupsctl --share-printers
sudo cupsctl --remote-any

# In CUPS web interface:
# 1. Select "Other Network Printers" > "Canon CAPT Printer (Docker)"
# 2. Connection: capt://localhost/LBP7018C
# 3. Name: LBP7018C
# 4. Make: Canon
# 5. Model: Canon LBP7018C CAPT (en)
```

#### Option B: Command Line

```bash
# First, copy the PPD file from container to host
docker cp cups-capt-driver:/usr/share/cups/model/CNCUPSLBP7018CCAPTK.ppd /tmp/

# Add printer
sudo lpadmin -p LBP7018C \
  -v capt://localhost/LBP7018C \
  -P /tmp/CNCUPSLBP7018CCAPTK.ppd \
  -E \
  -o printer-is-shared=true \
  -o printer-error-policy=retry-job

# Set as default printer (optional)
sudo lpadmin -d LBP7018C

# Enable the printer
sudo cupsenable LBP7018C
sudo cupsaccept LBP7018C
```

### 7. Test Printing

```bash
# Test from host
echo "Test print from Orange Pi" | lp -d LBP7018C

# Check job status
lpstat -p LBP7018C
lpstat -t

# Print test page via CUPS
lp -d LBP7018C /usr/share/cups/data/testprint

# Check container is processing
docker logs cups-capt-driver -f
```

### 8. Run Diagnostic Tool

```bash
# Make diagnostic script executable
chmod +x diagnostic-script.sh

# Run while sending a test print
./diagnostic-script.sh

# In another terminal, send a print job:
echo "Diagnostic test" | lp -d LBP7018C

# Review the diagnostic report
cat /tmp/print-diagnostic-*.log
```

**What to look for in diagnostics:**
- Time from job detection to processing start
- Time in CUPS queue
- CPU usage during printing
- Container memory usage
- Any errors in CUPS logs

## Monitoring and Troubleshooting

### Check Overall Status

```bash
# Use the monitoring tool
sudo cups-capt-monitor

# This shows:
# - CUPS status
# - Container status
# - ccpd status
# - USB printer detection
# - Recent errors
# - Resource usage
```

### Check Logs

```bash
# Host CUPS logs
tail -f /var/log/cups/error_log
tail -f /var/log/cups/access_log

# Container logs
docker logs cups-capt-driver -f

# Container ccpd logs (if available)
docker exec cups-capt-driver tail -f /var/log/CCPD/*.log
```

### Performance Optimization Tips

1. **Reduce CUPS Debug Logging (after testing):**
```bash
sudo sed -i 's/^LogLevel debug/LogLevel warn/' /etc/cups/cupsd.conf
sudo systemctl restart cups
```

2. **Check Docker Overhead:**
```bash
# Monitor container resource usage
docker stats cups-capt-driver

# If CPU is constantly high, QEMU is the bottleneck
```

3. **Test Direct Container Printing:**
```bash
# Bypass CUPS backend to isolate bottleneck
docker exec cups-capt-driver bash -c "echo 'Direct test' | lp -d LBP7018C"

# If this is fast, the issue is in the backend communication
# If this is slow, the issue is in ccpd or USB
```

4. **USB Troubleshooting:**
```bash
# Check USB transfer speed
docker exec cups-capt-driver dmesg | grep -i usb

# Monitor USB events
sudo udevadm monitor --environment --udev
```

## Expected Performance

### Current Setup (All-in-Container)
- Job submission to print start: **2-5 minutes** ❌

### Optimized Hybrid Architecture
- Job submission to print start: **15-45 seconds** ✅

### Breakdown:
- CUPS receives job: **< 1 second**
- CUPS processes/renders: **5-15 seconds** (native ARM)
- Backend sends to container: **< 1 second**
- ccpd processes: **10-30 seconds** (QEMU emulated)
- USB transmission: **< 5 seconds**

## Network Printing Setup

To print from other devices on your network:

### From Windows:
1. Open "Printers & scanners"
2. Add printer
3. "The printer that I want isn't listed"
4. Select "Select a shared printer by name"
5. Enter: `http://[ORANGE_PI_IP]:631/printers/LBP7018C`

### From macOS:
1. System Preferences > Printers & Scanners
2. Click "+" to add printer
3. Select "IP" tab
4. Address: `[ORANGE_PI_IP]`
5. Protocol: `Internet Printing Protocol - IPP`
6. Queue: `printers/LBP7018C`

### From Linux:
```bash
# Add printer
lpadmin -p LBP7018C_Remote \
  -v ipp://[ORANGE_PI_IP]:631/printers/LBP7018C \
  -m everywhere

# Or use CUPS web interface at:
# http://localhost:631
```

## Maintenance

### Update Container

```bash
# Rebuild with new changes
cd ~/cups-capt-hybrid
docker build -t capt-driver:optimized .

# Restart service (will use new image)
sudo systemctl restart cups-capt-driver.service
```

### Backup Configuration

```bash
# Backup CUPS config
sudo tar -czf cups-backup-$(date +%Y%m%d).tar.gz /etc/cups/

# Backup ccpd config from container
docker cp cups-capt-driver:/etc/ccpd.conf ~/ccpd.conf.backup
```

### Clean Up Old Containers

```bash
# Stop service
sudo systemctl stop cups-capt-driver.service

# Remove old containers
docker container prune -f

# Remove old images
docker image prune -a -f

# Restart service
sudo systemctl start cups-capt-driver.service
```

## Rollback Plan

If the hybrid setup doesn't work, you can revert:

```bash
# Stop new service
sudo systemctl stop cups-capt-driver.service
sudo systemctl disable cups-capt-driver.service

# Remove CAPT backend
sudo rm /usr/lib/cups/backend/capt

# Restore original CUPS config
sudo cp /etc/cups/cupsd.conf.backup.* /etc/cups/cupsd.conf
sudo systemctl restart cups

# Run your original container setup
docker run --rm --platform linux/386 -d \
  -p 631:631 \
  --device /dev/usb \
  -v /var/run/dbus:/var/run/dbus \
  -v /var/run/avahi-daemon/socket:/var/run/avahi-daemon/socket \
  --name cups \
  bfrankovskyi/cups-lbp7018
```

## Getting Help

If you encounter issues:

1. **Run diagnostics:**
   ```bash
   sudo cups-capt-monitor > system-status.log
   ./diagnostic-script.sh
   ```

2. **Collect logs:**
   ```bash
   sudo journalctl -u cups-capt-driver.service > service.log
   docker logs cups-capt-driver > container.log
   sudo cat /var/log/cups/error_log > cups-error.log
   ```

3. **Check these common issues:**
   - Is printer powered on?
   - Is USB cable connected properly?
   - Is container running? (`docker ps`)
   - Can container see USB device? (`docker exec cups-capt-driver ls -la /dev/usb/lp0`)
   - Is ccpd running? (`docker exec cups-capt-driver ccpdadmin`)

## Next Steps After Deployment

Once the system is working, you should:

1. **Measure actual performance improvement**
2. **Fine-tune based on diagnostic results**
3. **Consider further optimizations if needed**
4. **Set up automatic monitoring/alerting**

Would you like me to create any additional scripts or configuration files?
