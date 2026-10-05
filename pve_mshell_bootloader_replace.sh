#!/usr/bin/env bash
# Replace the m-shell USB boot image of an existing, stopped Proxmox VM.
set -Eeuo pipefail
umask 077

readonly REPO="PeterSuh-Q3/tinycore-redpill"
readonly BACKTITLE="m-shell bootloader image replacement"
declare -a LOOPS=() MOUNTS=()
WORK_DIR=""
PARTIAL_IMAGE=""
FINAL_IMAGE=""
COMMITTED=0
ORIGINAL_ARGS=""
ORIGINAL_CONFIG=""
NEW_ARGS=""
VMID=""
SOURCE_IMAGE=""
CONFIG_HASH=""
SOURCE_HASH=""
SOURCE_STAT=""
LOG_FILE=""

info() { printf '%s\n' "$*"; }
fail() { printf '오류: %s\n' "$*" >&2; exit 1; }

cleanup() {
    local rc=$? mountpoint loop cleanup_ok=1
    trap - EXIT
    for mountpoint in "${MOUNTS[@]}"; do
        if mountpoint -q -- "$mountpoint"; then
            umount -- "$mountpoint" || { printf '수동 마운트 해제 필요: %s\n' "$mountpoint" >&2; rc=1; cleanup_ok=0; }
        fi
    done
    for loop in "${LOOPS[@]}"; do
        if losetup "$loop" &>/dev/null; then
            losetup -d -- "$loop" || { printf '수동 loop 해제 필요: %s\n' "$loop" >&2; rc=1; cleanup_ok=0; }
        fi
    done
    if (( cleanup_ok && ! COMMITTED )); then
        [[ -z "$PARTIAL_IMAGE" ]] || rm -f -- "$PARTIAL_IMAGE"
        [[ -z "$FINAL_IMAGE" ]] || rm -f -- "$FINAL_IMAGE"
    fi
    if (( cleanup_ok )) && [[ -n "$WORK_DIR" ]]; then rm -rf -- "$WORK_DIR"; fi
    exit "$rc"
}
trap cleanup EXIT

require_tools() {
    local tool
    for tool in qm pvesh jq whiptail curl gzip losetup mount umount mountpoint \
        sha256sum sync mktemp stat realpath df awk sed grep cp mv date \
        hostname dirname chmod mkdir rm; do
        command -v "$tool" >/dev/null || fail "필요한 명령이 없습니다: $tool"
    done
    (( EUID == 0 )) || fail "Proxmox 호스트에서 root로 실행하세요."
    [[ -t 0 && -t 2 ]] || fail "대화형 터미널에서 실행하세요."
}

# Accept only the canonical, unquoted raw-file mapping created by pve_xpenol_install.sh.
# This narrow parser prevents changing an unrelated file= argument.
parse_synoboot_args() {
    local args=$1 drive prefix suffix
    [[ "$args" != *$'\n'* ]] || return 1
    [[ "$args" == *'-device usb-storage,bus=xhci.0,drive=synoboot,bootindex=0'* ]] || return 1
    [[ "$args" == *'-drive if=none,id=synoboot,format=raw,file='* ]] || return 1
    prefix='-drive if=none,id=synoboot,format=raw,file='
    drive=${args#*"$prefix"}
    [[ "$drive" != "$args" ]] || return 1
    [[ "$drive" != *"$prefix"* ]] || return 1
    SOURCE_IMAGE=${drive%% *}
    [[ "$SOURCE_IMAGE" =~ ^/[A-Za-z0-9_./+:-]+\.img$ ]] || return 1
    suffix=${drive#"$SOURCE_IMAGE"}
    [[ -z "$suffix" || "$suffix" == ' '* ]] || return 1
    [[ "$args" != *'id=synoboot'*'id=synoboot'* ]] || return 1
    [[ "$args" != *'drive=synoboot'*'drive=synoboot'* ]] || return 1
    [[ -f "$SOURCE_IMAGE" && ! -L "$SOURCE_IMAGE" ]] || return 1
    return 0
}

get_args() {
    local config=$1
    sed -n 's/^args: //p' <<<"$config"
}

vm_config() { qm config "$VMID"; }
vm_stopped() { [[ $(qm status "$VMID") == 'status: stopped' ]]; }
vm_unlocked() { ! grep -q '^lock:' <<<"$1"; }

select_vm() {
    local node json vmid name status config args path choice
    local -a menu=()
    node=$(hostname)
    json=$(pvesh get "/nodes/$node/qemu" --output-format json) || fail "VM 목록을 가져오지 못했습니다."
    while IFS=$'\t' read -r vmid name status; do
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        config=$(qm config "$vmid" 2>/dev/null) || continue
        args=$(get_args "$config")
        [[ -n "$args" ]] || continue
        if parse_synoboot_args "$args"; then
            path=$SOURCE_IMAGE
            menu+=("$vmid" "${name:-VM} [$status] $path")
        fi
    done < <(jq -r '.[] | [.vmid, (.name // "VM"), (.status // "unknown")] | @tsv' <<<"$json")
    ((${#menu[@]})) || fail "이 노드에서 원본 스크립트 방식으로 연결된 m-shell 후보 VM을 찾지 못했습니다."
    choice=$(whiptail --backtitle "$BACKTITLE" --title "VM 선택" \
        --menu "부트로더 이미지를 교체할 VM을 선택하세요." 22 110 12 "${menu[@]}" 3>&1 1>&2 2>&3) || exit 0
    [[ "$choice" =~ ^[0-9]+$ ]] || fail "잘못된 VMID입니다."
    VMID=$choice
}

attach_p3() {
    local image=$1 mode=$2 loop backing p3 targetdir
    # shellcheck disable=SC2034 # The nameref writes the caller's mount path.
    local -n result_mount=$3
    if [[ "$mode" == ro ]]; then
        loop=$(losetup --find --show --partscan --read-only -- "$image") || return 1
    else
        loop=$(losetup --find --show --partscan -- "$image") || return 1
    fi
    LOOPS+=("$loop")
    backing=$(losetup --noheadings --output BACK-FILE -- "$loop" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ $(realpath -- "$backing") == "$(realpath -- "$image")" ]] || return 1
    p3="${loop}p3"
    [[ -b "$p3" ]] || return 1
    targetdir=$(mktemp -d "$WORK_DIR/mount.XXXXXX") || return 1
    if [[ "$mode" == ro ]]; then
        mount -o ro,nosuid,nodev,noexec -- "$p3" "$targetdir" || return 1
    else
        mount -o rw,nosuid,nodev,noexec -- "$p3" "$targetdir" || return 1
    fi
    MOUNTS+=("$targetdir")
    # shellcheck disable=SC2034 # The caller reads this through the nameref.
    result_mount=$targetdir
}

release_mount() {
    local mountdir=$1 loop=$2
    umount -- "$mountdir" || return 1
    losetup -d -- "$loop" || return 1
}

read_source_config() {
    local mountdir="" loop
    attach_p3 "$SOURCE_IMAGE" ro mountdir || fail "원본 이미지 P3를 읽기 전용으로 마운트하지 못했습니다."
    loop=${LOOPS[-1]}
    [[ -f "$mountdir/user_config.json" && ! -L "$mountdir/user_config.json" ]] || fail "원본 P3 루트에 /user_config.json이 없습니다."
    cp -- "$mountdir/user_config.json" "$WORK_DIR/user_config.json" || fail "원본 설정 복사 실패"
    jq -e 'type == "object"' "$WORK_DIR/user_config.json" >/dev/null || fail "원본 설정이 유효한 JSON 객체가 아닙니다."
    CONFIG_HASH=$(sha256sum "$WORK_DIR/user_config.json" | awk '{print $1}')
    release_mount "$mountdir" "$loop" || fail "원본 P3 마운트 해제 실패"
    SOURCE_STAT=$(stat -Lc '%d:%i:%s:%Y' -- "$SOURCE_IMAGE")
    SOURCE_HASH=$(sha256sum "$SOURCE_IMAGE" | awk '{print $1}')
}

release_tag() {
    local release tag
    release=$(curl -fsSL --retry 3 --connect-timeout 15 \
        "https://api.github.com/repos/$REPO/releases/latest") || return 1
    tag=$(jq -er '.tag_name | select(type == "string")' <<<"$release") || return 1
    [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    printf '%s\n' "$tag"
}

prepare_new_image() {
    local tag=$1 dir avail size archive url stamp
    dir=$(dirname -- "$SOURCE_IMAGE")
    [[ -w "$dir" ]] || fail "원본 이미지 디렉터리에 쓰기 권한이 없습니다: $dir"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    FINAL_IMAGE="$dir/m-shell-${VMID}-${tag}-${stamp}.img"
    PARTIAL_IMAGE="$FINAL_IMAGE.partial"
    [[ ! -e "$FINAL_IMAGE" && ! -e "$PARTIAL_IMAGE" ]] || fail "새 이미지 이름이 이미 존재합니다."
    archive="$WORK_DIR/download.img.gz"
    url="https://github.com/$REPO/releases/download/${tag}/alpine-redpill.${tag}.m-shell.img.gz"
    info "최신 m-shell 이미지 다운로드: $tag"
    curl -fL --retry 3 --connect-timeout 20 --output "$archive" "$url" || fail "이미지 다운로드 실패"
    gzip -t -- "$archive" || fail "압축 파일 검증 실패"
    avail=$(df -B1 --output=avail "$dir" | awk 'NR==2 {print $1}')
    size=$(gzip -l -- "$archive" | awk 'NR==2 {print $2}')
    [[ "$avail" =~ ^[0-9]+$ && "$size" =~ ^[0-9]+$ ]] || fail "여유 공간 확인 실패"
    # gzip -l can wrap at 4 GiB; the write itself is checked as well.
    (( avail > size + 104857600 )) || fail "새 이미지용 여유 공간이 부족합니다."
    gzip -cd -- "$archive" > "$PARTIAL_IMAGE" || fail "이미지 압축 해제 실패"
    [[ -s "$PARTIAL_IMAGE" ]] || fail "압축 해제된 이미지가 비어 있습니다."
}

copy_config_to_new_image() {
    local mountdir="" loop existing temporary verifydir="" verifyloop
    attach_p3 "$PARTIAL_IMAGE" rw mountdir || fail "새 이미지 P3를 쓰기 가능으로 마운트하지 못했습니다."
    loop=${LOOPS[-1]}
    existing="$mountdir/user_config.json"
    temporary="$mountdir/.user_config.json.new.$$"
    [[ ! -e "$temporary" ]] || fail "새 이미지 P3에 임시 파일이 이미 있습니다."
    cp -- "$WORK_DIR/user_config.json" "$temporary" || fail "새 P3로 설정 복사 실패"
    [[ $(sha256sum "$temporary" | awk '{print $1}') == "$CONFIG_HASH" ]] || fail "새 P3 설정 해시 불일치"
    if [[ -e "$existing" ]]; then
        [[ -f "$existing" && ! -L "$existing" ]] || fail "새 P3의 기존 설정 파일 형식이 예상과 다릅니다."
        mv -- "$existing" "$mountdir/.user_config.json.before-replace.$$" || fail "새 이미지의 기존 설정 백업 실패"
    fi
    mv -- "$temporary" "$existing" || fail "새 설정 파일 적용 실패"
    sync -f -- "$existing" || fail "새 설정 파일 기록 실패"
    [[ $(sha256sum "$existing" | awk '{print $1}') == "$CONFIG_HASH" ]] || fail "새 이미지 설정 검증 실패"
    release_mount "$mountdir" "$loop" || fail "새 이미지 P3 마운트 해제 실패"
    attach_p3 "$PARTIAL_IMAGE" ro verifydir || fail "새 이미지 P3 재검증용 마운트 실패"
    verifyloop=${LOOPS[-1]}
    [[ -f "$verifydir/user_config.json" ]] || fail "새 이미지에서 설정 파일을 다시 찾지 못했습니다."
    [[ $(sha256sum "$verifydir/user_config.json" | awk '{print $1}') == "$CONFIG_HASH" ]] || fail "재마운트 후 설정 해시 불일치"
    release_mount "$verifydir" "$verifyloop" || fail "재검증용 마운트 해제 실패"
    mv -- "$PARTIAL_IMAGE" "$FINAL_IMAGE" || fail "검증된 이미지의 최종 이름 적용 실패"
    PARTIAL_IMAGE=""
}

record_state() {
    local config=$1 tag=$2
    local logdir="/var/log/pve-mshell-bootloader-replace" stamp
    mkdir -p -- "$logdir" || fail "작업 기록 디렉터리 생성 실패"
    chmod 700 -- "$logdir" || fail "작업 기록 권한 설정 실패"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    LOG_FILE="$logdir/${VMID}-${stamp}.log"
    {
        printf 'VMID: %s\nRelease: %s\nOld image: %s\nNew image: %s\nConfig SHA256: %s\n' \
            "$VMID" "$tag" "$SOURCE_IMAGE" "$FINAL_IMAGE" "$CONFIG_HASH"
        printf 'Original args: %s\nNew args: %s\nOriginal qm config:\n%s\n' \
            "$ORIGINAL_ARGS" "$NEW_ARGS" "$config"
    } > "$LOG_FILE" || fail "작업 기록 저장 실패"
    chmod 600 -- "$LOG_FILE" || fail "작업 기록 권한 설정 실패"
}

confirm_change() {
    whiptail --backtitle "$BACKTITLE" --title "최종 확인" --yesno \
        "VMID: $VMID\n원본: $SOURCE_IMAGE\n새 이미지: $FINAL_IMAGE\n릴리스: $1\n설정 SHA-256: $CONFIG_HASH\n\n변경 전 args:\n$ORIGINAL_ARGS\n\n변경 후 args:\n$NEW_ARGS\n\nVM은 자동으로 시작하지 않습니다. 계속할까요?" \
        24 110
}

verify_unchanged() {
    local config args hash source_mount="" source_loop
    config=$(vm_config) || fail "VM 설정 재조회 실패"
    [[ "$config" == "$ORIGINAL_CONFIG" ]] || fail "작업 중 VM 설정이 변경되었습니다."
    args=$(get_args "$config")
    [[ "$args" == "$ORIGINAL_ARGS" ]] || fail "작업 중 VM의 args가 변경되었습니다."
    vm_stopped || fail "작업 중 VM이 실행 상태로 바뀌었습니다."
    vm_unlocked "$config" || fail "작업 중 VM이 잠겼습니다."
    [[ $(stat -Lc '%d:%i:%s:%Y' -- "$SOURCE_IMAGE") == "$SOURCE_STAT" ]] || fail "작업 중 원본 이미지가 변경되었습니다."
    hash=$(sha256sum "$SOURCE_IMAGE" | awk '{print $1}')
    [[ "$hash" == "$SOURCE_HASH" ]] || fail "작업 중 원본 이미지 내용이 변경되었습니다."
    attach_p3 "$SOURCE_IMAGE" ro source_mount || fail "원본 설정 재검증용 마운트 실패"
    source_loop=${LOOPS[-1]}
    [[ -f "$source_mount/user_config.json" ]] || fail "원본 설정 파일이 사라졌습니다."
    hash=$(sha256sum "$source_mount/user_config.json" | awk '{print $1}')
    [[ "$hash" == "$CONFIG_HASH" ]] || fail "작업 중 원본 설정 파일이 변경되었습니다."
    release_mount "$source_mount" "$source_loop" || fail "원본 설정 재검증용 마운트 해제 실패"
}

apply_change() {
    local after current
    if ! qm set "$VMID" --args "$NEW_ARGS"; then
        info "VM 설정 변경 실패. 원본 args 복원을 시도합니다."
        qm set "$VMID" --args "$ORIGINAL_ARGS" || true
        current=$(get_args "$(vm_config 2>/dev/null || true)")
        if [[ "$current" != "$ORIGINAL_ARGS" ]]; then
            COMMITTED=1 # The VM might reference the new image; preserve it.
            fail "자동 복원 실패. 원본 args는 $LOG_FILE에 있습니다."
        fi
        fail "VM 설정 변경 실패; 원본 args를 확인했습니다."
    fi
    COMMITTED=1 # Keep the new image until a rollback is confirmed.
    after=$(vm_config) || fail "설정 변경 후 VM 상태 조회 실패. 원본 args는 $LOG_FILE에 있습니다."
    current=$(get_args "$after")
    if [[ "$current" != "$NEW_ARGS" ]]; then
        qm set "$VMID" --args "$ORIGINAL_ARGS" || true
        current=$(get_args "$(vm_config 2>/dev/null || true)")
        [[ "$current" == "$ORIGINAL_ARGS" ]] || fail "VM 설정 검증 및 자동 복원 실패. 원본 args는 $LOG_FILE에 있습니다."
        COMMITTED=0
        fail "VM 설정 검증 실패; 원본 args를 복원했습니다."
    fi
    COMMITTED=1
}

main() {
    local config args tag source_prefix
    # `curl ... | sudo bash` uses stdin for the script itself. Restore it for whiptail.
    if [[ ! -t 0 ]]; then
        [[ -r /dev/tty ]] || fail "대화형 터미널이 필요합니다."
        exec </dev/tty || fail "터미널 입력을 열지 못했습니다."
    fi
    require_tools
    WORK_DIR=$(mktemp -d /tmp/pve-mshell-replace.XXXXXX) || fail "임시 디렉터리 생성 실패"
    select_vm
    config=$(vm_config) || fail "VM 설정을 읽지 못했습니다."
    ORIGINAL_CONFIG=$config
    args=$(get_args "$config")
    ORIGINAL_ARGS=$args
    parse_synoboot_args "$args" || fail "지원하는 synoboot 이미지 매핑을 찾지 못했습니다."
    vm_stopped || fail "VM을 먼저 종료하세요. 스크립트는 실행 중인 VM을 변경하지 않습니다."
    vm_unlocked "$config" || fail "잠긴 VM은 변경하지 않습니다."
    info "원본 이미지 P3의 /user_config.json을 읽는 중..."
    read_source_config
    tag=$(release_tag) || fail "최신 m-shell 릴리스 태그를 확인하지 못했습니다."
    prepare_new_image "$tag"
    copy_config_to_new_image
    source_prefix='-drive if=none,id=synoboot,format=raw,file='
    NEW_ARGS=${ORIGINAL_ARGS/"$source_prefix$SOURCE_IMAGE"/"$source_prefix$FINAL_IMAGE"}
    [[ "$NEW_ARGS" != "$ORIGINAL_ARGS" ]] || fail "VM 인수 변경 내용을 만들지 못했습니다."
    if ! confirm_change "$tag"; then info "사용자가 취소했습니다. VM 설정은 변경되지 않았습니다."; exit 0; fi
    verify_unchanged
    record_state "$config" "$tag"
    apply_change
    info "교체 완료. VM $VMID는 중지 상태입니다."
    info "원본 이미지: $SOURCE_IMAGE"
    info "새 이미지: $FINAL_IMAGE"
    info "복원용 설정 기록: $LOG_FILE"
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
