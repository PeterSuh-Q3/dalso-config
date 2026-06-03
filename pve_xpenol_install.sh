#!/bin/bash

# Color Palette
G='\033[1;32m'
R='\033[0;31m'
B='\033[0;34m'
Y='\033[0;33m'
N='\033[0m'

BACKTITLE="Xpenology VM Installer for Proxmox VE"
STEP_TOTAL=5
# CURRENT_STEP is set by the main loop (1-based) so wrappers can render "Step N/5".
CURRENT_STEP=1

# --- Helper Functions ---

# Display a message with a color
msg() {
    local text="$1"
    local color="$2"
    echo -e "${color}${text}${N}"
}

# Install necessary packages if they are not installed
install_package() {
    if ! dpkg -s "$1" &>/dev/null;
    then
        msg "Installing $1..." "$Y"
        apt-get update >/dev/null
        apt-get install -y "$1" >/dev/null
    fi
}

# --- Pure logic helpers (no whiptail / no network; unit-tested) ---

# Map a bootloader image name to its GitHub repo.
bootloader_repo() {
    case "$1" in
        m-shell) echo "PeterSuh-Q3/tinycore-redpill" ;;
        RR)      echo "RROrg/rr" ;;
        *)       return 1 ;;
    esac
}

# Build the release asset URL for a given image name + tag.
build_img_url() {
    local name="$1" tag="$2"
    case "$name" in
        m-shell) echo "https://github.com/PeterSuh-Q3/tinycore-redpill/releases/download/${tag}/tinycore-redpill.${tag}.m-shell.img.gz" ;;
        RR)      echo "https://github.com/RROrg/rr/releases/download/${tag}/rr-${tag}.img.zip" ;;
        *)       return 1 ;;
    esac
}

# Convert curl progress output (CR-separated) on stdin into integer percent values.
parse_gauge_pct() {
    stdbuf -oL tr '\r' '\n' | sed -un 's/.*\(^\|[^0-9]\)\([0-9]\{1,3\}\)\.[0-9]%.*/\2/p'
}

# Read disks/list JSON on stdin; emit "by_id_link \t model size (serial)" for unused disks only.
parse_disks() {
    "$JQ_CMD" -r '
        .[]
        | select((.used // "") == "")
        | select((.by_id_link // "") != "")
        | (.size // 0) as $b
        | (if $b >= 1099511627776 then (($b/1099511627776)*10|floor/10|tostring)+"T"
           else (($b/1073741824)*10|floor/10|tostring)+"G" end) as $sz
        | .by_id_link + "\t" + ((.model // "disk")|gsub("^ +| +$";"")) + " " + $sz + " (" + (.serial // "?") + ")"
    '
}

# --- Proxmox API Functions using whiptail ---

# Echoes chosen storage on stdout; rc 0=OK, 1=Back, 3=no-storage-error.
select_storage() {
    local prompt_text=$1 content_type=$2 default_item=$3
    local whiptail_options=()
    while IFS=$'\t' read -r name desc; do
        whiptail_options+=("$name" "$desc")
    done < <(pvesh get /nodes/$(hostname)/storage --output-format json | "$JQ_CMD" -r '
        .[] |
        select(
            (has("disable") | not) and
            (.content | contains("'"$content_type"'")) and
            .type != "nfs" and .type != "cifs" and
            has("total") and has("avail") and .avail > 0
        ) |
        .storage + "\t" + "[" + .type + "] " + ((.avail / 1073741824) | tostring | .[0:5]) + "G / " + ((.total / 1073741824) | tostring | .[0:5]) + "G"
    ')
    if [ ${#whiptail_options[@]} -eq 0 ]; then
        wt_msg "Storage" "No suitable storage with available space found for content type '$content_type'."
        return 3
    fi
    local out
    out=$(whiptail --backtitle "$BACKTITLE" --title "$(_wt_title "Storage")" \
        --cancel-button "$(_wt_cancel_label)" --default-item "$default_item" \
        --menu "$prompt_text" 20 78 10 "${whiptail_options[@]}" 3>&1 1>&2 2>&3)
    local rc=$?
    echo "$out"
    return $rc
}

# Echoes chosen bridge on stdout; rc 0=OK, 1=Back, 3=no-bridge-error.
select_bridge() {
    local prompt_text=$1 default_item=$2
    local whiptail_options=()
    while IFS=$'\t' read -r name desc; do
        whiptail_options+=("$name" "$desc")
    done < <(pvesh get /nodes/$(hostname)/network --output-format json | "$JQ_CMD" -r '.[] | select(.type == "bridge" and (has("disable") | not)) | .iface + "\t" + (.cidr // "no CIDR")')
    if [ ${#whiptail_options[@]} -eq 0 ]; then
        wt_msg "Network" "No active network bridge found."
        return 3
    fi
    local out
    out=$(whiptail --backtitle "$BACKTITLE" --title "$(_wt_title "Network")" \
        --cancel-button "$(_wt_cancel_label)" --default-item "$default_item" \
        --menu "$prompt_text" 20 78 10 "${whiptail_options[@]}" 3>&1 1>&2 2>&3)
    local rc=$?
    echo "$out"
    return $rc
}

# Resolve the single 'latest' tag via the releases/latest redirect. rc 1 on failure.
fetch_latest_tag() {
    local repo="$1" url
    url=$(curl -sfL -w '%{url_effective}' -o /dev/null "https://github.com/${repo}/releases/latest") || return 1
    echo "${url##*/}"
}

# --- Physical disk safety helpers (passthrough) ---

# True (rc 0) if a whole disk or any of its partitions is mounted or a member of LVM/ZFS/MD/swap.
disk_in_use() {  # $1 = /dev/sdX
    # Mounted? (whole disk or any partition). Single-column query avoids lsblk -r field collapse.
    if lsblk -nro MOUNTPOINT "$1" 2>/dev/null | grep -q .; then
        return 0
    fi
    # Member of LVM / ZFS / MD, or swap?
    if lsblk -nro FSTYPE "$1" 2>/dev/null | grep -Eq 'LVM2_member|zfs_member|linux_raid_member|swap'; then
        return 0
    fi
    return 1
}

# True (rc 0) if the by-id path already appears in any VM config.
disk_claimed_by_vm() {  # $1 = by-id path
    grep -qs -- "$1" /etc/pve/qemu-server/*.conf 2>/dev/null
}

# Emit "by_id \t label" for disks safe to pass through. Combines parse_disks (used filter)
# with live checks: exclude the root disk, mounted/member disks, and disks claimed by a VM.
passthrough_candidates() {
    local rootsrc rootdisk
    rootsrc=$(findmnt -no SOURCE / 2>/dev/null)
    rootdisk=$(lsblk -no PKNAME "$rootsrc" 2>/dev/null | head -1)   # e.g. "sda"
    local byid label devpath
    while IFS=$'\t' read -r byid label; do
        [ -z "$byid" ] && continue
        devpath=$(readlink -f "$byid" 2>/dev/null)
        [ -z "$devpath" ] && continue
        [ -n "$rootdisk" ] && [ "$(basename "$devpath")" = "$rootdisk" ] && continue
        disk_in_use "$devpath" && continue
        disk_claimed_by_vm "$byid" && continue
        printf '%s\t%s\n' "$byid" "$label"
    done < <(pvesh get /nodes/$(hostname)/disks/list --output-format json | parse_disks)
}


# --- whiptail wrappers (consistent branding + button labels) ---

# Title like "Step 2/5 · Data Disk"
_wt_title() { echo "Step ${CURRENT_STEP}/${STEP_TOTAL} · $1"; }

# Back button label: first step shows "Cancel", later steps show "Back".
_wt_cancel_label() { (( CURRENT_STEP <= 1 )) && echo "Cancel" || echo "Back"; }

# Input box. Args: section_title, prompt, default. Echoes value. rc 0=OK, 1=Back/Cancel.
wt_input() {
    local title="$1" prompt="$2" default="$3" out
    out=$(whiptail --backtitle "$BACKTITLE" --title "$(_wt_title "$title")" \
        --cancel-button "$(_wt_cancel_label)" \
        --inputbox "$prompt" 10 70 "$default" 3>&1 1>&2 2>&3)
    local rc=$?
    echo "$out"
    return $rc
}

# Menu. Args: section_title, prompt, default_item, then (tag label) pairs. Echoes tag. rc 0=OK,1=Back.
wt_menu() {
    local title="$1" prompt="$2" default_item="$3"; shift 3
    local out
    out=$(whiptail --backtitle "$BACKTITLE" --title "$(_wt_title "$title")" \
        --cancel-button "$(_wt_cancel_label)" \
        --default-item "$default_item" \
        --menu "$prompt" 20 78 10 "$@" 3>&1 1>&2 2>&3)
    local rc=$?
    echo "$out"
    return $rc
}

# Checklist (multi-select). Args: section_title, prompt, then (tag label status) triples.
# Echoes space-separated quoted tags chosen. rc 0=OK, 1=Back. Nothing is preselected by callers.
wt_checklist() {
    local title="$1" prompt="$2"; shift 2
    local out
    out=$(whiptail --backtitle "$BACKTITLE" --title "$(_wt_title "$title")" \
        --cancel-button "$(_wt_cancel_label)" \
        --checklist "$prompt" 20 78 10 "$@" 3>&1 1>&2 2>&3)
    local rc=$?
    echo "$out"
    return $rc
}

# Message box.
wt_msg() {
    whiptail --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" "${3:-12}" "${4:-70}"
}

# Yes/No. rc 0=yes, 1=no.
wt_yesno() {
    whiptail --backtitle "$BACKTITLE" --title "$1" --yesno "$2" "${3:-10}" "${4:-70}"
}

# Transient info (no buttons).
wt_infobox() {
    whiptail --backtitle "$BACKTITLE" --title "$1" --infobox "$2" "${3:-8}" "${4:-70}"
}

# Download with a real progress gauge; fall back to an infobox + blocking download if % parsing fails.
# Args: url, dest, label. rc 0 on success, non-zero on curl failure.
download_with_gauge() {
    local url="$1" dest="$2" label="$3" rc
    {
        curl --fail -kL "$url" -o "$dest" 2> >(parse_gauge_pct)
        echo $? > /tmp/.xpenol_dl_rc
    } | whiptail --backtitle "$BACKTITLE" --gauge "$label" 8 70 0
    rc=$(cat /tmp/.xpenol_dl_rc 2>/dev/null || echo 1)
    rm -f /tmp/.xpenol_dl_rc
    if (( rc != 0 )); then
        wt_infobox "Downloading" "Progress bar unavailable — downloading ${label}..."
        curl --fail -kL "$url" -o "$dest"; rc=$?
    fi
    return $rc
}


# --- Step functions: rc 0=next, 1=back, 2=cancel, 100=redisplay ---

step_core() {
    VMID=$(wt_input "Core VM" "Enter VM ID" "${VMID:-$(pvesh get /cluster/nextid)}") || return 1
    [ -n "$VMID" ] || { wt_msg "Invalid" "VM ID cannot be empty."; return 100; }
    VMNAME=$(wt_input "Core VM" "Enter VM Name" "${VMNAME:-Xpenology}") || return 1
    [ -n "$VMNAME" ] || { wt_msg "Invalid" "VM Name cannot be empty."; return 100; }
    CORES=$(wt_input "Core VM" "Enter CPU Cores" "${CORES:-2}") || return 1
    [[ "$CORES" =~ ^[0-9]+$ ]] || { wt_msg "Invalid" "Invalid number of cores."; return 100; }
    RAM=$(wt_input "Core VM" "Enter RAM in MB" "${RAM:-2048}") || return 1
    [[ "$RAM" =~ ^[0-9]+$ ]] || { wt_msg "Invalid" "Invalid RAM size."; return 100; }
    return 0
}

step_storage() {
    local choice default_bus
    case "$BUS_TYPE_PARAM" in scsi) default_bus=1 ;; sata) default_bus=2 ;; *) default_bus=1 ;; esac
    choice=$(wt_menu "Data Disk" "Select the disk bus type for the VM." "$default_bus" \
        "1" "VirtIO SCSI (DS3622xs+)" \
        "2" "SATA (SA6400, DS920+, etc)") || return 1
    case $choice in
        1) BUS_TYPE_PARAM="scsi" ;;
        2) BUS_TYPE_PARAM="sata" ;;
        *) return 100 ;;
    esac

    local mode_default
    case "$STORAGE_MODE" in passthrough) mode_default="passthrough" ;; *) mode_default="virtual" ;; esac
    local mode
    mode=$(wt_menu "Storage Mode" "Choose how the VM gets its data disk(s)." "$mode_default" \
        "virtual"     "Create a virtual data disk" \
        "passthrough" "Pass through physical disk(s)") || return 1
    case "$mode" in
        virtual)     STORAGE_MODE="virtual";     step_storage_virtual ;;
        passthrough) STORAGE_MODE="passthrough"; step_storage_passthrough ;;
        *) return 100 ;;
    esac
}

step_storage_virtual() {
    DISK_SIZE=$(wt_input "Data Disk" "Enter Data Disk Size in GB" "${DISK_SIZE:-32}") || return 1
    [[ "$DISK_SIZE" =~ ^[0-9]+$ ]] || { wt_msg "Invalid" "Invalid disk size."; return 100; }
    DATA_STORAGE=$(select_storage "Select storage for the DATA disk (${DISK_SIZE}G)." "images" "$DATA_STORAGE")
    case $? in 0) ;; 1) return 1 ;; *) return 100 ;; esac
    return 0
}

step_storage_passthrough() {
    local opts=() byid label total=0 shown=0
    while IFS=$'\t' read -r byid label; do
        [ -z "$byid" ] && continue
        opts+=("$byid" "$label" "off")
        shown=$((shown + 1))
    done < <(passthrough_candidates)
    total=$(pvesh get /nodes/$(hostname)/disks/list --output-format json | "$JQ_CMD" -r 'length')
    if (( shown == 0 )); then
        wt_msg "No free disks" "No unused physical disks were found. (All disks appear mounted, part of LVM/ZFS/RAID, the boot disk, or already attached to a VM.)"
        return 100
    fi
    if (( total > shown )); then
        wt_msg "Heads up" "$((total - shown)) disk(s) are hidden because they appear in use (boot/LVM/ZFS/RAID/mounted or claimed by a VM). Only safe, unused disks are listed."
    fi
    local selected
    selected=$(wt_checklist "Disk Passthrough" "Select physical disk(s) to pass through (space toggles):" "${opts[@]}") || return 1
    [ -n "$selected" ] || { wt_msg "Nothing selected" "Select at least one disk, or go Back to choose a virtual disk."; return 100; }
    PASSTHRU_DISKS=()
    eval "PASSTHRU_DISKS=($selected)"
    local list="" d
    for d in "${PASSTHRU_DISKS[@]}"; do list+=$'\n'"  • $d"; done
    if ! wt_yesno "Confirm passthrough" "These PHYSICAL disks will be attached to VM ${VMID} as-is. Make sure they are NOT used by the host or another VM — doing so can cause data loss.${list}\n\nProceed?" 18 74; then
        return 100
    fi
    return 0
}

step_network() {
    BRIDGE=$(select_bridge "Select the network bridge for the VM." "$BRIDGE")
    case $? in 0) ;; 1) return 1 ;; *) return 100 ;; esac
    return 0
}

step_bootloader() {
    local kind_default
    case "$IMAGE_NAME" in m-shell) kind_default=1 ;; RR) kind_default=2 ;; *) kind_default=1 ;; esac
    local choice
    choice=$(wt_menu "Bootloader" "Choose a bootloader image" "$kind_default" \
        "1" "m-shell" "2" "RR") || return 1
    case $choice in
        1) IMAGE_NAME="m-shell" ;;
        2) IMAGE_NAME="RR" ;;
        *) return 100 ;;
    esac

    local repo
    repo=$(bootloader_repo "$IMAGE_NAME")
    wt_infobox "Bootloader" "Resolving latest ${IMAGE_NAME} version..."
    IMG_TAG=$(fetch_latest_tag "$repo") || { wt_msg "Network" "Could not reach GitHub to resolve the latest version. Check connectivity and retry."; return 100; }
    [ -n "$IMG_TAG" ] || { wt_msg "Error" "Empty version tag resolved."; return 100; }
    IMG_URL=$(build_img_url "$IMAGE_NAME" "$IMG_TAG") || { wt_msg "Error" "Could not build download URL."; return 100; }

    prepare_bootloader || return 100
    return 0
}

step_confirm() {
    local choice storage_line
    while true; do
        if [ "$STORAGE_MODE" = "passthrough" ]; then
            storage_line="Storage ........ passthrough (${#PASSTHRU_DISKS[@]} disk(s))"
        else
            storage_line="Storage ........ virtual ${DISK_SIZE}G on ${DATA_STORAGE}"
        fi
        choice=$(whiptail --backtitle "$BACKTITLE" --title "$(_wt_title "Review & Create")" \
            --cancel-button "Back" \
            --menu "Review your configuration, then create the VM:" 22 78 12 \
            "create"  "==> Create VM now <==" \
            "VMID"    "VM ID .......... ${VMID}" \
            "VMNAME"  "VM Name ........ ${VMNAME}" \
            "CORES"   "CPU Cores ...... ${CORES}" \
            "RAM"     "RAM ............ ${RAM} MB" \
            "BUS"     "Disk Bus ....... ${BUS_TYPE_PARAM}" \
            "STORAGE" "$storage_line" \
            "BRIDGE"  "Network Bridge . ${BRIDGE}" \
            "BOOT"    "Bootloader ..... ${IMAGE_NAME} ${IMG_TAG}" \
            3>&1 1>&2 2>&3) || return 1
        case "$choice" in
            create)
                if [ "$STORAGE_MODE" = "passthrough" ] && (( ${#PASSTHRU_DISKS[@]} == 0 )); then
                    wt_msg "No data disk" "Passthrough mode is selected but no physical disks are chosen. Edit Storage to pick disk(s), or switch to a virtual disk."
                    continue
                fi
                return 0
                ;;
            VMID|VMNAME|CORES|RAM) step_core ;;
            BUS|STORAGE)           step_storage ;;
            BRIDGE)                step_network ;;
            BOOT)                  step_bootloader ;;
        esac
    done
}


# --- Lifecycle ---

BOOTLOADER_DIR="/var/lib/vz/template/iso"
IMG_PATH=""   # set in prepare_bootloader

cleanup() {
    rm -f "${BOOTLOADER_DIR}/${IMAGE_NAME}-${VMID}.img.gz" \
          "${BOOTLOADER_DIR}/${IMAGE_NAME}-${VMID}.img.zip" \
          "${BOOTLOADER_DIR}/rr.img" "${BOOTLOADER_DIR}/sha256sum" 2>/dev/null
}

abort() {
    cleanup
    msg "Canceled." "$R"
    exit 1
}

# Download + extract the selected bootloader. rc 0 on success.
prepare_bootloader() {
    mkdir -p "$BOOTLOADER_DIR"
    IMG_PATH="${BOOTLOADER_DIR}/${IMAGE_NAME}-${VMID}.img"
    while true; do
        if [[ "$IMG_URL" == *.zip ]]; then
            download_with_gauge "$IMG_URL" "${IMG_PATH}.zip" "Downloading ${IMAGE_NAME} ${IMG_TAG}..."
        else
            download_with_gauge "$IMG_URL" "${IMG_PATH}.gz" "Downloading ${IMAGE_NAME} ${IMG_TAG}..."
        fi
        if (( $? != 0 )); then
            if wt_yesno "Download failed" "Download failed. Retry?"; then continue; else cleanup; return 1; fi
        fi
        wt_infobox "Extracting" "Extracting ${IMAGE_NAME} image..."
        if [[ "$IMG_URL" == *.zip ]]; then
            unzip -o "${IMG_PATH}.zip" -d "$BOOTLOADER_DIR" >/dev/null 2>&1
            [ -f "${BOOTLOADER_DIR}/rr.img" ] && mv "${BOOTLOADER_DIR}/rr.img" "$IMG_PATH"
        else
            gunzip -f "${IMG_PATH}.gz"
        fi
        cleanup
        if [ -f "$IMG_PATH" ]; then return 0; fi
        if ! wt_yesno "Extract failed" "Could not find the .img after extraction. Retry?"; then return 1; fi
    done
}

# Create + configure the VM. Offers rollback on failure.
create_vm() {
    wt_infobox "Creating VM" "Creating VM ${VMID}..."
    if ! qm create "$VMID" --name "$VMNAME" --memory "$RAM" --cores "$CORES" --bios seabios --ostype l26; then
        rollback "VM creation failed."; exit 1
    fi
    if [ "$BUS_TYPE_PARAM" == "scsi" ]; then qm set "$VMID" --scsihw virtio-scsi-pci; fi
    if [ "$STORAGE_MODE" = "passthrough" ]; then
        local idx=0 disk
        for disk in "${PASSTHRU_DISKS[@]}"; do
            if ! qm set "$VMID" --"${BUS_TYPE_PARAM}${idx}" "$disk"; then
                rollback "Failed to pass through disk: $disk"; exit 1
            fi
            (( idx++ ))
        done
    else
        if ! qm set "$VMID" --"${BUS_TYPE_PARAM}0" "${DATA_STORAGE}:${DISK_SIZE},discard=on,ssd=1"; then
            rollback "Failed to attach data disk."; exit 1
        fi
    fi
    qm set "$VMID" --net0 virtio,bridge="$BRIDGE"
    local qm_args="-drive if=none,id=synoboot,format=raw,file=${IMG_PATH} -device qemu-xhci,id=xhci -device usb-storage,bus=xhci.0,drive=synoboot,bootindex=0"
    qm set "$VMID" --args "$qm_args"
    msg "VM configuration complete!" "$G"

    if wt_yesno "Start VM?" "Would you like to start the new virtual machine now?"; then
        qm start "$VMID"; VM_STATUS="Started"
    else
        VM_STATUS="Created (Not Started)"
    fi
    print_summary
}

rollback() {  # message
    wt_msg "Error" "$1"
    if wt_yesno "Rollback" "Destroy partially-created VM ${VMID}?"; then
        qm destroy "$VMID" --purge 2>/dev/null
    fi
}

print_summary() {
    msg "--- VM Summary ---" "$B"
    msg "VM ID: $VMID" "$G"
    msg "VM Name: $VMNAME" "$G"
    msg "Status: $VM_STATUS" "$G"
    msg "CPU Cores: $CORES" "$G"
    msg "RAM: $RAM MB" "$G"
    msg "Disk Bus: $BUS_TYPE_PARAM" "$G"
    msg "Network: $BRIDGE" "$G"
    msg "Bootloader: ${IMAGE_NAME} ${IMG_TAG} (attached from ${IMG_PATH})" "$G"
    if [ "$STORAGE_MODE" = "passthrough" ]; then
        msg "Data Disks (passthrough):" "$G"
        local d
        for d in "${PASSTHRU_DISKS[@]}"; do msg "  - $d" "$G"; done
    else
        msg "Data Disk: ${DISK_SIZE}G on $DATA_STORAGE" "$G"
    fi
    msg "------------------" "$B"
    msg "You can now manage the VM from the Proxmox web interface." "$Y"
}


# --- Main Logic ---

main() {
    if [ "$(id -u)" -ne 0 ]; then msg "This script must be run as root." "$R"; exit 1; fi
    install_package "jq";       JQ_CMD=$(which jq)
    install_package "unzip"
    install_package "whiptail"

    # Wizard state (declared here so a re-run starts clean).
    STORAGE_MODE="virtual"; PASSTHRU_DISKS=()
    trap cleanup EXIT INT TERM

    local steps=(step_core step_storage step_network step_bootloader step_confirm)
    local i=0
    while (( i >= 0 && i < ${#steps[@]} )); do
        CURRENT_STEP=$(( i + 1 ))
        "${steps[$i]}"; local rc=$?
        case $rc in
            0)   (( i++ )) ;;
            1)   (( i-- )) ;;
            2)   abort ;;
            100) ;;
        esac
        if (( i < 0 )); then abort; fi
    done
    create_vm
}

# Only run the wizard when executed directly, not when sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
