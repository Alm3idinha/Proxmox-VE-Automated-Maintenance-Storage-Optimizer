#!/bin/bash

# ==========================================
# CONFIGURATION & SAFETY
# ==========================================
LOG_DIR="/var/log/proxmox-maintenance"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
LOG_FILE="$LOG_DIR/maintenance-$TIMESTAMP.log"

# ANSI Color Codes
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Redirect output to console and the specific timestamped log file simultaneously
exec > >(tee -a "$LOG_FILE") 2>&1
echo -e "\n${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] === Proxmox Lab Maintenance & Optimization Started ===${NC}"

# ==========================================
# INTERACTIVE PROMPTS
# ==========================================
echo -e "\n${CYAN}--- Configuration Wizard ---${NC}"

read -p "Do you want to skip any specific CT or VM IDs or Names? (e.g. 100 web-server, or leave blank): " USER_SKIPS
ENABLE_AGENT_CHOICE="n"
read -p "Do you want to automatically enable and start 'qemu-guest-agent' on VMs where it's disabled? (y/N): " ENABLE_AGENT_CHOICE

# Function to convert names to IDs if necessary
resolve_to_id() {
    local target="$1"
    local type="$2" # "ct" or "vm"
    
    if [[ "$target" =~ ^[0-9]+$ ]]; then
        echo "$target"
        return
    fi
    
    if [ "$type" = "ct" ]; then
        pct list | awk -v name="$target" '$3 == name {print $1}'
    else
        qm list | awk -v name="$target" '$2 == name {print $1}'
    fi
}

# Resolve user skips into explicit IDs
RESOLVED_IGNORE_LIST=""
for item in $USER_SKIPS; do
    ct_id=$(resolve_to_id "$item" "ct")
    vm_id=$(resolve_to_id "$item" "vm")
    [ -n "$ct_id" ] && RESOLVED_IGNORE_LIST="$RESOLVED_IGNORE_LIST $ct_id"
    [ -n "$vm_id" ] && RESOLVED_IGNORE_LIST="$RESOLVED_IGNORE_LIST $vm_id"
    [ -z "$ct_id" ] && [ -z "$vm_id" ] && RESOLVED_IGNORE_LIST="$RESOLVED_IGNORE_LIST $item"
done

total_freed_kb=0

convert_size() {
    local kb=$1
    if [ $kb -ge 1048576 ]; then
        awk "BEGIN {printf \"%.2f GB\", $kb/1048576}"
    elif [ $kb -ge 1024 ]; then
        awk "BEGIN {printf \"%.2f MB\", $kb/1024}"
    else
        echo "${kb} KB"
    fi
}

# --- 1. HOST HEALTH CHECK ---
echo -e "\n${CYAN}[1/4] Checking Proxmox Host Storage & Pool Health...${NC}"
if command -v zpool &> /dev/null && zpool list &> /dev/null; then
    zpool status | grep -E "pool:|state:"
fi
df -h / | awk 'NR==2 {print "Host Root Disk - Used: " $5 " (Free: " $4 ")"}'

# --- 2. LXC CONTAINERS MAINTENANCE ---
echo -e "\n${CYAN}[2/4] Processing LXC Containers...${NC}"
for vmid in $(pct list | awk 'NR>1 {print $1}'); do
    if [[ " $RESOLVED_IGNORE_LIST " =~ " $vmid " ]]; then
        echo -e "${YELLOW}[CT $vmid] Skipped due to interactive security configuration.${NC}"
        continue
    fi

    status=$(pct status "$vmid" | awk '{print $2}')
    was_off=0
    if [ "$status" = "stopped" ]; then
        echo -e "${BLUE}--- [CT $vmid] Status: Stopped. Temporarily starting... ---${NC}"
        pct start "$vmid"
        was_off=1
        sleep 3
    else
        echo -e "${BLUE}--- [CT $vmid] Status: Running. Starting maintenance... ---${NC}"
    fi
    
    space_before=$(pct exec "$vmid" -- df / | awk 'NR==2 {print $3}')
    
    echo -e "${BLUE}    -> Cleaning APT package cache (apt-get clean)...${NC}"
    pct exec "$vmid" -- apt-get clean > /dev/null 2>&1
    
    echo -e "${BLUE}    -> Removing orphaned packages & dependencies (--purge)...${NC}"
    pct exec "$vmid" -- apt-get autoremove --purge -y > /dev/null 2>&1
    
    echo -e "${BLUE}    -> Applying systemd journal log retention policy (keeping last 15 days)...${NC}"
    pct exec "$vmid" -- journalctl --vacuum-time=15d > /dev/null 2>&1
    
    echo -e "${BLUE}    -> Clearing temporary directories (/tmp and /var/tmp)...${NC}"
    pct exec "$vmid" -- rm -rf /tmp/* /var/tmp/*
    
    echo -e "${BLUE}    -> Running fstrim to release unused blocks back to the host...${NC}"
    pct exec "$vmid" -- fstrim -av > /dev/null 2>&1

    if pct exec "$vmid" -- command -v docker &> /dev/null; then
        echo -e "${BLUE}    -> Docker detected: Running system prune...${NC}"
        pct exec "$vmid" -- docker system prune -a --volumes -f > /dev/null 2>&1
    fi
    
    space_after=$(pct exec "$vmid" -- df / | awk 'NR==2 {print $3}')
    freed_kb=$((space_before - space_after))
    
    if [ $freed_kb -gt 0 ]; then
        total_freed_kb=$((total_freed_kb + freed_kb))
        echo -e "${GREEN}[CT $vmid] Completed successfully. Space cleaned: $(convert_size $freed_kb)${NC}"
    else
        echo -e "${GREEN}[CT $vmid] Completed. Space cleaned: 0 MB${NC}"
    fi
    
    if [ $was_off -eq 1 ]; then
        echo -e "${BLUE}--- [CT $vmid] Shutting down back (was originally stopped) ---${NC}"
        pct stop "$vmid"
    fi
done

# --- 3. VIRTUAL MACHINES MAINTENANCE ---
echo -e "\n${CYAN}[3/4] Processing Virtual Machines (VMs)...${NC}"
for vmid in $(qm list | awk 'NR>1 {print $1}'); do
    if [[ " $RESOLVED_IGNORE_LIST " =~ " $vmid " ]]; then
        echo -e "${YELLOW}[VM $vmid] Skipped due to interactive security configuration.${NC}"
        continue
    fi

    if [[ "$ENABLE_AGENT_CHOICE" =~ ^[Yy]$ ]]; then
        agent_enabled=$(qm config "$vmid" | grep -E '^agent:')
        if [ -z "$agent_enabled" ]; then
            echo -e "${BLUE}    -> Enabling qemu-guest-agent on VM $vmid...${NC}"
            qm set "$vmid" --agent 1 > /dev/null 2>&1
        fi
    fi

    status=$(qm status "$vmid" | awk '{print $2}')
    was_off=0
    if [ "$status" = "stopped" ]; then
        echo -e "${BLUE}--- [VM $vmid] Status: Stopped. Temporarily starting... ---${NC}"
        qm start "$vmid"
        was_off=1
        sleep 10
    else
        echo -e "${BLUE}--- [VM $vmid] Status: Running. Starting maintenance... ---${NC}"
    fi

    if [[ "$ENABLE_AGENT_CHOICE" =~ ^[Yy]$ ]]; then
        qm guest exec "$vmid" -- systemctl enable --now qemu-guest-agent > /dev/null 2>&1
    fi
    
    space_before=$(qm guest exec "$vmid" -- df / | grep -oP '"out-data":"[^"]*"' | awk -F'"' '{print $4}' | awk 'NR==2 {print $3}')
    
    echo -e "${BLUE}    -> [VM $vmid] Cleaning APT package cache...${NC}"
    qm guest exec "$vmid" -- apt-get clean > /dev/null 2>&1
    
    echo -e "${BLUE}    -> [VM $vmid] Removing orphaned packages (--purge)...${NC}"
    qm guest exec "$vmid" -- apt-get autoremove --purge -y > /dev/null 2>&1
    
    echo -e "${BLUE}    -> [VM $vmid] Applying systemd journal retention (15 days)...${NC}"
    qm guest exec "$vmid" -- journalctl --vacuum-time=15d > /dev/null 2>&1
    
    echo -e "${BLUE}    -> [VM $vmid] Clearing temporary files (/tmp and /var/tmp)...${NC}"
    qm guest exec "$vmid" -- rm -rf /tmp/* /var/tmp/* > /dev/null 2>&1
    
    echo -e "${BLUE}    -> [VM $vmid] Executing fstrim on virtual disks...${NC}"
    qm guest exec "$vmid" -- fstrim -av > /dev/null 2>&1

    if qm guest exec "$vmid" -- command -v docker &> /dev/null; then
        echo -e "${BLUE}    -> [VM $vmid] Docker detected: Running system prune...${NC}"
        qm guest exec "$vmid" -- docker system prune -a --volumes -f > /dev/null 2>&1
    fi
    
    space_after=$(qm guest exec "$vmid" -- df / | grep -oP '"out-data":"[^"]*"' | awk -F'"' '{print $4}' | awk 'NR==2 {print $3}')
    
    if [[ "$space_before" =~ ^[0-9]+$ ]] && [[ "$space_after" =~ ^[0-9]+$ ]]; then
        freed_kb=$((space_before - space_after))
        if [ $freed_kb -gt 0 ]; then
            total_freed_kb=$((total_freed_kb + freed_kb))
            echo -e "${GREEN}[VM $vmid] Completed successfully. Space cleaned: $(convert_size $freed_kb)${NC}"
        else
            echo -e "${GREEN}[VM $vmid] Completed. Space cleaned: 0 MB${NC}"
        fi
    else
        echo -e "${GREEN}[VM $vmid] Detailed cleanup successfully completed via QEMU guest agent.${NC}"
    fi
    
    if [ $was_off -eq 1 ]; then
        echo -e "${BLUE}--- [VM $vmid] Shutting down back (was originally stopped) ---${NC}"
        qm stop "$vmid"
    fi
done

# --- 4. FINAL REPORT ---
total_fmt=$(convert_size $total_freed_kb)
echo -e "\n${YELLOW}==================================================${NC}"
echo -e "${GREEN} Maintenance and Optimization successfully completed!${NC}"
echo -e "${GREEN} Total global space recovered: $total_fmt${NC}"
echo -e "${YELLOW} Execution report saved at: $LOG_FILE${NC}"
echo -e "${YELLOW}==================================================${NC}"