#!/bin/bash
# =============================================================================
# JVM Diagnostics Script — Heap Dump & Thread Dump
# Target: Apache Tomcat / OpenJDK 19 (pre-prod & production)
# =============================================================================

set -euo pipefail

# --- Colour helpers -----------------------------------------------------------
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

# --- Configuration ------------------------------------------------------------
OUTPUT_DIR="/tmp"
THREAD_DUMP_SNAPSHOTS=3
THREAD_DUMP_INTERVAL=30
HEAP_SAFE_THRESHOLD=85   # percent — warn and abort above this

# =============================================================================
# STEP 1 — Find Tomcat PID and JVM path
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}====================================================${NC}"
echo -e "${BOLD}${CYAN}  JVM Diagnostics — Heap & Thread Dump              ${NC}"
echo -e "${BOLD}${CYAN}  Started: $(date)${NC}"
echo -e "${BOLD}${CYAN}====================================================${NC}"
echo ""

echo -e "${BOLD}[STEP 1] Detecting Tomcat process...${NC}"

TOMCAT_LINE=$(ps -ef | grep 'org.apache.catalina.startup.Bootstrap' | grep -v grep || true)

if [ -z "$TOMCAT_LINE" ]; then
  echo -e "${RED}ERROR: Tomcat does not appear to be running. Aborting.${NC}"
  exit 1
fi

PID=$(echo "$TOMCAT_LINE" | awk '{print $2}')
JAVA_BIN=$(echo "$TOMCAT_LINE" | awk '{print $8}')
JVM_BIN_DIR=$(dirname "$JAVA_BIN")

echo -e "  ${GREEN}✔ Tomcat is running${NC}"
echo -e "  PID      : ${BOLD}$PID${NC}"
echo -e "  Java bin : ${BOLD}$JAVA_BIN${NC}"
echo -e "  JVM dir  : ${BOLD}$JVM_BIN_DIR${NC}"

# Verify jmap and jstack exist in the same JVM bin dir
JMAP="$JVM_BIN_DIR/jmap"
JSTACK="$JVM_BIN_DIR/jstack"
JCMD="$JVM_BIN_DIR/jcmd"

for tool in "$JMAP" "$JSTACK" "$JCMD"; do
  if [ ! -f "$tool" ]; then
    echo -e "${RED}ERROR: Cannot find $tool — aborting.${NC}"
    exit 1
  fi
done

echo -e "  ${GREEN}✔ jmap, jstack, jcmd all found in JVM bin directory${NC}"

# =============================================================================
# STEP 2 — Check disk space
# =============================================================================
echo ""
echo -e "${BOLD}[STEP 2] Checking disk space on $OUTPUT_DIR...${NC}"

DISK_AVAIL_KB=$(df -k "$OUTPUT_DIR" | awk 'NR==2 {print $4}')
DISK_AVAIL_GB=$(awk "BEGIN {printf \"%.1f\", $DISK_AVAIL_KB/1024/1024}")
DISK_USE_PCT=$(df -k "$OUTPUT_DIR" | awk 'NR==2 {print $5}' | tr -d '%')

echo -e "  Available : ${BOLD}${DISK_AVAIL_GB} GB${NC}"
echo -e "  Used      : ${BOLD}${DISK_USE_PCT}%${NC}"

if [ "$DISK_USE_PCT" -ge 90 ]; then
  echo -e "${RED}ERROR: Disk is ${DISK_USE_PCT}% full — not safe to proceed. Aborting.${NC}"
  exit 1
elif [ "$DISK_USE_PCT" -ge 80 ]; then
  echo -e "${YELLOW}WARNING: Disk is ${DISK_USE_PCT}% full — proceed with caution.${NC}"
else
  echo -e "  ${GREEN}✔ Disk space is healthy${NC}"
fi

# =============================================================================
# STEP 3 — Check heap usage
# =============================================================================
echo ""
echo -e "${BOLD}[STEP 3] Checking current heap usage...${NC}"

HEAP_INFO=$(sudo "$JCMD" "$PID" GC.heap_info 2>/dev/null || true)

if [ -z "$HEAP_INFO" ]; then
  echo -e "${RED}ERROR: Could not retrieve heap info via jcmd. Try running with sudo.${NC}"
  exit 1
fi

echo "$HEAP_INFO"

# Parse total and used from heap info (values are in KB)
HEAP_TOTAL_K=$(echo "$HEAP_INFO" | grep -i 'heap' | head -1 | grep -oP 'total \K[0-9]+')
HEAP_USED_K=$(echo "$HEAP_INFO"  | grep -i 'heap' | head -1 | grep -oP 'used \K[0-9]+')

if [ -z "$HEAP_TOTAL_K" ] || [ -z "$HEAP_USED_K" ]; then
  echo -e "${YELLOW}WARNING: Could not parse heap values automatically — please review output above manually.${NC}"
  HEAP_PCT="unknown"
  ESTIMATED_SIZE_MB="unknown"
else
  HEAP_PCT=$(awk "BEGIN {printf \"%d\", ($HEAP_USED_K/$HEAP_TOTAL_K)*100}")
  ESTIMATED_SIZE_MB=$(awk "BEGIN {printf \"%d\", $HEAP_USED_K/1024}")
  ESTIMATED_SIZE_GB=$(awk "BEGIN {printf \"%.1f\", $HEAP_USED_K/1024/1024}")

  echo ""
  echo -e "  Heap total     : ${BOLD}$(awk "BEGIN {printf \"%.0f\", $HEAP_TOTAL_K/1024}") MB${NC}"
  echo -e "  Heap used      : ${BOLD}${ESTIMATED_SIZE_MB} MB${NC}"
  echo -e "  Usage          : ${BOLD}${HEAP_PCT}%${NC}"
  echo -e "  Estimated dump : ${BOLD}~${ESTIMATED_SIZE_MB} MB (~${ESTIMATED_SIZE_GB} GB)${NC}"

  if [ "$HEAP_PCT" -ge "$HEAP_SAFE_THRESHOLD" ]; then
    echo ""
    echo -e "${RED}  ✖ Heap is at ${HEAP_PCT}% — above the ${HEAP_SAFE_THRESHOLD}% safety threshold.${NC}"
    echo -e "${RED}    Taking a heap dump now risks destabilising the JVM.${NC}"
    echo -e "${RED}    Heap dump step will be SKIPPED. Thread dump will still proceed.${NC}"
    SKIP_HEAP=true
  else
    echo -e "  ${GREEN}✔ Heap usage is below ${HEAP_SAFE_THRESHOLD}% threshold — safe to proceed${NC}"
    SKIP_HEAP=false
  fi
fi

# =============================================================================
# CHECKPOINT — Confirm before proceeding
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}----------------------------------------------------${NC}"
echo -e "${BOLD}  CHECKPOINT — Review the above before proceeding${NC}"
if [ "${SKIP_HEAP:-false}" = false ]; then
  echo -e "  Heap dump file will be approx: ${BOLD}~${ESTIMATED_SIZE_MB} MB${NC}"
fi
echo -e "  Thread dump: ${BOLD}${THREAD_DUMP_SNAPSHOTS} snapshots, ${THREAD_DUMP_INTERVAL}s apart (~$((THREAD_DUMP_SNAPSHOTS * THREAD_DUMP_INTERVAL))s total)${NC}"
echo -e "  Output dir : ${BOLD}${OUTPUT_DIR}${NC}"
echo -e "${BOLD}${CYAN}----------------------------------------------------${NC}"
echo ""
read -rp "$(echo -e "${BOLD}Proceed? (yes/no): ${NC}")" CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
  echo -e "${YELLOW}Aborted by user.${NC}"
  exit 0
fi

# =============================================================================
# STEP 4 — Heap Dump
# =============================================================================
HEAP_FILE=""
if [ "${SKIP_HEAP:-false}" = false ]; then
  echo ""
  echo -e "${BOLD}[STEP 4] Taking heap dump...${NC}"
  HEAP_FILE="${OUTPUT_DIR}/heapdump-$(hostname)-$(date +%Y%m%d%H%M%S).hprof"
  echo -e "  Writing to: ${BOLD}${HEAP_FILE}${NC}"
  echo -e "  ${YELLOW}Note: JVM will pause briefly during capture — this is normal.${NC}"

  sudo "$JMAP" -dump:format=b,file="$HEAP_FILE" "$PID"

  if [ -f "$HEAP_FILE" ]; then
    ACTUAL_SIZE=$(du -sh "$HEAP_FILE" | awk '{print $1}')
    echo -e "  ${GREEN}✔ Heap dump complete — actual size: ${ACTUAL_SIZE}${NC}"
  else
    echo -e "${RED}  ✖ Heap dump file not found — something went wrong.${NC}"
  fi
else
  echo ""
  echo -e "${YELLOW}[STEP 4] Heap dump SKIPPED — heap usage too high.${NC}"
fi

# =============================================================================
# STEP 5 — Thread Dump (3 snapshots, 30 seconds apart)
# =============================================================================
echo ""
echo -e "${BOLD}[STEP 5] Taking thread dumps (${THREAD_DUMP_SNAPSHOTS} snapshots, ${THREAD_DUMP_INTERVAL}s apart)...${NC}"
THREAD_FILE="${OUTPUT_DIR}/threaddump-$(hostname)-$(date +%Y%m%d).txt"
echo -e "  Writing to: ${BOLD}${THREAD_FILE}${NC}"

for i in $(seq 1 "$THREAD_DUMP_SNAPSHOTS"); do
  echo -e "  Capturing snapshot ${i} of ${THREAD_DUMP_SNAPSHOTS} at $(date)..."
  echo "--- Snapshot $i at $(date) ---" >> "$THREAD_FILE"
  sudo "$JSTACK" -l "$PID" >> "$THREAD_FILE"
  echo "" >> "$THREAD_FILE"
  if [ "$i" -lt "$THREAD_DUMP_SNAPSHOTS" ]; then
    echo -e "  Waiting ${THREAD_DUMP_INTERVAL} seconds before next snapshot..."
    sleep "$THREAD_DUMP_INTERVAL"
  fi
done

if [ -f "$THREAD_FILE" ]; then
  THREAD_SIZE=$(du -sh "$THREAD_FILE" | awk '{print $1}')
  echo -e "  ${GREEN}✔ Thread dump complete — size: ${THREAD_SIZE}${NC}"
else
  echo -e "${RED}  ✖ Thread dump file not found — something went wrong.${NC}"
fi

# =============================================================================
# STEP 6 — Quick BLOCKED thread check
# =============================================================================
echo ""
echo -e "${BOLD}[STEP 6] Scanning for BLOCKED threads...${NC}"
BLOCKED=$(grep -c "BLOCKED" "$THREAD_FILE" 2>/dev/null || echo "0")

if [ "$BLOCKED" -gt 0 ]; then
  echo -e "${YELLOW}  ⚠ Found ${BLOCKED} BLOCKED thread entries — review below:${NC}"
  echo ""
  grep -A 5 "BLOCKED" "$THREAD_FILE"
else
  echo -e "  ${GREEN}✔ No BLOCKED threads found${NC}"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}====================================================${NC}"
echo -e "${BOLD}${CYAN}  SUMMARY${NC}"
echo -e "${BOLD}${CYAN}====================================================${NC}"
echo -e "  Completed  : $(date)"
echo -e "  Hostname   : $(hostname)"
echo -e "  PID        : $PID"

if [ -n "$HEAP_FILE" ] && [ -f "$HEAP_FILE" ]; then
  echo -e "  Heap dump  : ${GREEN}${HEAP_FILE}${NC} (${ACTUAL_SIZE})"
else
  echo -e "  Heap dump  : ${YELLOW}Skipped or not created${NC}"
fi

echo -e "  Thread dump: ${GREEN}${THREAD_FILE}${NC} (${THREAD_SIZE})"
echo -e "  BLOCKED    : ${BLOCKED} entries"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo -e "  1. Copy heap dump to your local machine for Eclipse MAT analysis:"
echo -e "     ${CYAN}scp $(whoami)@$(hostname):${HEAP_FILE:-/tmp/heapdump.hprof} .${NC}"
echo -e "  2. Review thread dump: ${CYAN}less ${THREAD_FILE}${NC}"
echo -e "  3. Clean up when done:"
if [ -n "$HEAP_FILE" ]; then
  echo -e "     ${CYAN}sudo rm ${HEAP_FILE}${NC}"
fi
echo -e "     ${CYAN}rm ${THREAD_FILE}${NC}"
echo -e "${BOLD}${CYAN}====================================================${NC}"
echo ""