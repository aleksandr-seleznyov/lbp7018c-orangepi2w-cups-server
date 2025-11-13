#!/bin/bash
# Diagnostic script to identify printing delays
# Run this while sending a test print job to track timing

set -e

OUTPUT_FILE="/tmp/print-diagnostic-$(date +%Y%m%d_%H%M%S).log"

echo "Canon LBP7018C Print Diagnostic Tool"
echo "====================================="
echo "Output will be saved to: $OUTPUT_FILE"
echo ""
echo "This script will monitor the complete print pipeline:"
echo "1. CUPS receives job (host)"
echo "2. Job queued and processed (host)"
echo "3. Sent to CAPT backend (host -> container)"
echo "4. ccpd processes job (container)"
echo "5. USB transmission (container -> printer)"
echo ""
echo "Send a print job NOW, then press Enter..."
read

{
    echo "=========================================="
    echo "Print Diagnostic Report"
    echo "Started: $(date)"
    echo "=========================================="
    echo ""

    # Function to log with timestamp
    log_time() {
        echo "[$(date +'%H:%M:%S.%3N')] $1"
    }

    log_time "Starting diagnostic monitoring..."

    # Monitor system resources in background
    (
        while true; do
            CPU=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
            MEM=$(free | grep Mem | awk '{print ($3/$2) * 100.0}')
            log_time "System: CPU=${CPU}% MEM=${MEM}%"
            
            if docker ps | grep -q cups-capt-driver; then
                DOCKER_CPU=$(docker stats cups-capt-driver --no-stream --format "{{.CPUPerc}}")
                DOCKER_MEM=$(docker stats cups-capt-driver --no-stream --format "{{.MemPerc}}")
                log_time "Docker: CPU=${DOCKER_CPU} MEM=${DOCKER_MEM}"
            fi
            
            sleep 2
        done
    ) &
    MONITOR_PID=$!

    # Monitor CUPS queue
    log_time "Monitoring CUPS queue..."
    LAST_JOB=""
    JOB_DETECTED=false
    JOB_STARTED=false
    JOB_COMPLETED=false
    START_TIME=""

    for i in {1..120}; do  # Monitor for 4 minutes max
        QUEUE_STATUS=$(lpstat -o 2>&1 || echo "")
        
        if [ -n "$QUEUE_STATUS" ] && [ "$JOB_DETECTED" = false ]; then
            JOB_DETECTED=true
            START_TIME=$(date +%s.%N)
            log_time "✓ Job detected in CUPS queue"
            log_time "Queue status: $QUEUE_STATUS"
        fi
        
        if [ "$JOB_DETECTED" = true ]; then
            # Check job progress
            JOB_INFO=$(lpstat -l -o 2>&1 || echo "")
            
            if echo "$JOB_INFO" | grep -q "processing"; then
                if [ "$JOB_STARTED" = false ]; then
                    JOB_STARTED=true
                    PROCESS_TIME=$(date +%s.%N)
                    DELTA=$(echo "$PROCESS_TIME - $START_TIME" | bc)
                    log_time "✓ Job processing started (${DELTA}s after detection)"
                fi
            fi
            
            # Check if job completed
            if [ -z "$QUEUE_STATUS" ] && [ "$JOB_DETECTED" = true ]; then
                JOB_COMPLETED=true
                END_TIME=$(date +%s.%N)
                TOTAL_TIME=$(echo "$END_TIME - $START_TIME" | bc)
                log_time "✓ Job completed and removed from queue"
                log_time "Total time in CUPS: ${TOTAL_TIME}s"
                break
            fi
            
            # Show detailed job status every 5 seconds
            if [ $((i % 5)) -eq 0 ]; then
                log_time "Job status: $JOB_INFO"
            fi
        fi
        
        sleep 1
    done

    # Check container logs for CAPT activity
    log_time ""
    log_time "Checking Docker container logs..."
    CONTAINER_LOGS=$(docker logs cups-capt-driver --tail 50 2>&1 || echo "Container not running")
    echo "$CONTAINER_LOGS" | while IFS= read -r line; do
        log_time "Container: $line"
    done

    # Check ccpd status
    log_time ""
    log_time "Checking ccpd status..."
    if docker ps | grep -q cups-capt-driver; then
        CCPD_STATUS=$(docker exec cups-capt-driver ccpdadmin 2>&1 || echo "Failed to get status")
        echo "$CCPD_STATUS" | while IFS= read -r line; do
            log_time "ccpd: $line"
        done
    else
        log_time "ERROR: Container not running"
    fi

    # Check USB communication
    log_time ""
    log_time "Checking USB devices..."
    lsusb | grep -i canon | while IFS= read -r line; do
        log_time "USB: $line"
    done

    # Check recent CUPS errors
    log_time ""
    log_time "Recent CUPS errors (last 20 lines)..."
    tail -n 20 /var/log/cups/error_log | while IFS= read -r line; do
        log_time "CUPS-Error: $line"
    done

    # Stop monitoring
    kill $MONITOR_PID 2>/dev/null || true

    # Summary
    log_time ""
    log_time "=========================================="
    log_time "Diagnostic Summary"
    log_time "=========================================="
    
    if [ "$JOB_DETECTED" = false ]; then
        log_time "❌ No print job detected in CUPS queue"
        log_time "   Check: Is the printer configured correctly?"
        log_time "   Run: lpstat -p -d"
    elif [ "$JOB_STARTED" = false ]; then
        log_time "❌ Job detected but never started processing"
        log_time "   This suggests a CUPS backend issue"
        log_time "   Check: /usr/lib/cups/backend/capt exists and is executable"
    elif [ "$JOB_COMPLETED" = false ]; then
        log_time "❌ Job started but didn't complete within 4 minutes"
        log_time "   This is your delay issue!"
        log_time "   Check container logs above for bottleneck"
    else
        log_time "✓ Job completed successfully"
        log_time "   Total time: ${TOTAL_TIME}s"
        if (( $(echo "$TOTAL_TIME > 30" | bc -l) )); then
            log_time "⚠ Time exceeds 30s - investigating..."
            log_time "   Likely causes:"
            log_time "   1. QEMU emulation overhead"
            log_time "   2. USB communication delays"
            log_time "   3. ccpd processing delays"
        fi
    fi

    log_time ""
    log_time "=========================================="
    log_time "Completed: $(date)"
    log_time "=========================================="

} 2>&1 | tee "$OUTPUT_FILE"

echo ""
echo "Diagnostic complete. Full report saved to:"
echo "$OUTPUT_FILE"
echo ""
echo "To view the report:"
echo "cat $OUTPUT_FILE"
echo ""
echo "To analyze timing:"
echo "grep '✓' $OUTPUT_FILE"
