#!/bin/bash
# Optimized entrypoint for Canon CAPT driver container
# This container ONLY runs ccpd daemon - CUPS runs on host

set -e

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

log "=========================================="
log "Canon CAPT Driver Container Starting"
log "Container with minimal CUPS for ccpd"
log "=========================================="

# Set timezone
log "Setting timezone to ${TZ}..."
if [ -n "$TZ" ]; then
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime
    echo $TZ > /etc/timezone
fi

# Start minimal CUPS (only for ccpd validation, not for external jobs)
log "Starting minimal CUPS instance for ccpd validation..."
/usr/sbin/cupsd
sleep 2

# Verify CUPS is running
if ! pgrep -x cupsd > /dev/null; then
    error "Failed to start CUPS daemon"
    exit 1
fi
log "CUPS daemon started on 127.0.0.1:59631 (internal only)"

# Check for USB printer
log "Checking for USB printer device..."
MAX_WAIT=30
WAIT_COUNT=0

while [ ! -e "$DEVICE_PATH" ] && [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if [ $WAIT_COUNT -eq 0 ]; then
        warn "USB printer not found at $DEVICE_PATH"
        log "Waiting for printer to be connected (timeout: ${MAX_WAIT}s)..."
    fi
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ ! -e "$DEVICE_PATH" ]; then
    error "Printer device $DEVICE_PATH not found after ${MAX_WAIT}s"
    warn "Container will continue, but printing will fail until printer is connected"
    warn "Available USB devices:"
    lsusb | grep -i canon || echo "  No Canon devices found"
else
    log "Printer device found: $DEVICE_PATH"
    
    # Check device permissions
    if [ ! -r "$DEVICE_PATH" ] || [ ! -w "$DEVICE_PATH" ]; then
        error "Insufficient permissions for $DEVICE_PATH"
        ls -la "$DEVICE_PATH"
    else
        log "Device permissions: OK"
    fi
fi

# Register printer with ccpd
log "Registering printer with ccpd daemon..."

# First register with CUPS (required for ccpd validation)
log "Registering printer with CUPS..."
lpadmin -p $PRINTER_NAME \
    -P /usr/share/cups/model/CNCUPSLBP7018CCAPTK.ppd \
    -v ccp://localhost:59787 \
    -E 2>&1 | while read line; do
        log "  lpadmin: $line"
    done

# Verify CUPS registration
if lpstat -p $PRINTER_NAME > /dev/null 2>&1; then
    log "Printer registered with CUPS successfully"
else
    error "Failed to register printer with CUPS"
    lpstat -p
    exit 1
fi

# Now register with ccpd
log "Registering printer with ccpd..."
ccpdadmin -p $PRINTER_NAME \
    -P /usr/share/cups/model/CNCUPSLBP7018CCAPTK.ppd \
    -o $DEVICE_PATH 2>&1 | while read line; do
        log "  ccpdadmin: $line"
    done

# Verify registration
log "Verifying printer registration..."
if ccpdadmin 2>&1 | grep -q "$PRINTER_NAME"; then
    log "Printer $PRINTER_NAME registered successfully"
else
    error "Failed to register printer $PRINTER_NAME"
fi

# Start ccpd daemon
log "Starting ccpd daemon..."
ccpd &
CCPD_PID=$!

# Wait for ccpd to initialize
log "Waiting for ccpd to initialize..."
READY=false
MAX_INIT_WAIT=60
INIT_COUNT=0

while [ "$READY" = false ] && [ $INIT_COUNT -lt $MAX_INIT_WAIT ]; do
    sleep 2
    INIT_COUNT=$((INIT_COUNT + 2))
    
    if ccpdadmin 2>&1 | grep -q "localhost:59787"; then
        READY=true
        log "ccpd daemon initialized successfully (${INIT_COUNT}s)"
        break
    fi
    
    if [ $((INIT_COUNT % 10)) -eq 0 ]; then
        log "Still waiting for ccpd... (${INIT_COUNT}s/${MAX_INIT_WAIT}s)"
    fi
done

if [ "$READY" = false ]; then
    error "ccpd daemon failed to initialize after ${MAX_INIT_WAIT}s"
    ccpdadmin || true
    exit 1
fi

# Show final status
log "=========================================="
log "Container Status:"
log "  Printer: $PRINTER_NAME"
log "  Device: $DEVICE_PATH"
log "  ccpd PID: $CCPD_PID"
log "  UI Port: 59787"
log "  Data Port: 59687"
log "=========================================="
log "ccpd daemon status:"
ccpdadmin 2>&1 | while read line; do
    log "  $line"
done
log "=========================================="
log "Container ready - monitoring ccpd daemon"
log "=========================================="

# Function to handle graceful shutdown
shutdown() {
    log "Received shutdown signal"
    log "Stopping ccpd daemon..."
    kill -TERM $CCPD_PID 2>/dev/null || true
    wait $CCPD_PID 2>/dev/null || true
    log "Container stopped"
    exit 0
}

# Trap signals for graceful shutdown
trap shutdown SIGTERM SIGINT

# Monitor ccpd daemon and show activity
log "Monitoring ccpd activity..."
log "Printer is ready for jobs from host CUPS"

# Follow ccpd logs if they exist, otherwise just monitor the process
if [ -d /var/log/CCPD ]; then
    tail -f /var/log/CCPD/*.log 2>/dev/null &
    TAIL_PID=$!
fi

# Monitor ccpd process
while kill -0 $CCPD_PID 2>/dev/null; do
    sleep 5
    
    # Periodically check printer status
    if [ $((RANDOM % 12)) -eq 0 ]; then  # Roughly every minute
        STATUS=$(ccpdadmin 2>&1 || echo "ERROR")
        if echo "$STATUS" | grep -q "localhost:59787"; then
            log "Status check: Printer ready"
        else
            warn "Status check: Printer may have issues"
            echo "$STATUS"
        fi
    fi
done

# If we get here, ccpd died unexpectedly
error "ccpd daemon stopped unexpectedly"
exit 1
