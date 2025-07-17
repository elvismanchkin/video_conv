#!/bin/bash

LOG_LEVEL=${CVRT_LOG_LEVEL:-INFO}

get_log_level_value() {
    case "$1" in
        DEBUG) echo 0 ;;
        INFO) echo 1 ;;
        WARN) echo 2 ;;
        ERROR) echo 3 ;;
        *) echo 1 ;;
    esac
}

set_log_level() {
    local level="$1"
    case "$level" in
        DEBUG|INFO|WARN|ERROR)
            LOG_LEVEL="$level"
            ;;
    esac
}

should_log() {
    local msg_level="$1"
    local current_level_num
    current_level_num=$(get_log_level_value "$LOG_LEVEL")
    local msg_level_num
    msg_level_num=$(get_log_level_value "$msg_level")
    [[ "$msg_level_num" -ge "$current_level_num" ]]
}

log_debug() {
    should_log DEBUG && printf "[DEBUG] %s\n" "$*" >&2
}

log_info() {
    should_log INFO && printf "[INFO] %s\n" "$*"
}

log_warn() {
    should_log WARN && printf "[WARN] %s\n" "$*" >&2
}

log_error() {
    should_log ERROR && printf "[ERROR] %s\n" "$*" >&2
}

command_exists() {
    command -v "$1" &>/dev/null
}

check_dependencies() {
    local missing_tools=()
    local tool
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command_exists "$tool"; then
            missing_tools+=("$tool")
        fi
    done
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error ""
        log_error "Installation instructions:"
        for tool in "${missing_tools[@]}"; do
            case "$tool" in
                ffmpeg|ffprobe)
                    log_error "  $tool: Install ffmpeg package"
                    log_error "    Ubuntu/Debian: sudo apt install ffmpeg"
                    log_error "    Fedora/RHEL: sudo dnf install ffmpeg"
                    log_error "    Arch: sudo pacman -S ffmpeg"
                    log_error "    macOS: brew install ffmpeg"
                    ;;
                jq)
                    log_error "  $tool: Install jq package"
                    log_error "    Ubuntu/Debian: sudo apt install jq"
                    log_error "    Fedora/RHEL: sudo dnf install jq"
                    log_error "    Arch: sudo pacman -S jq"
                    log_error "    macOS: brew install jq"
                    ;;
                *)
                    log_error "  $tool: Install using your package manager"
                    ;;
            esac
        done
        log_error ""
        log_error "After installation, run the script again."
        return 1
    fi

    # Check optional tools and provide helpful warnings
    local missing_optional=()
    for tool in "${OPTIONAL_TOOLS[@]}"; do
        if ! command_exists "$tool"; then
            missing_optional+=("$tool")
        fi
    done

    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        log_warn "Optional tools not found: ${missing_optional[*]}"
        log_warn "Hardware acceleration may be limited. Install for better performance:"
        for tool in "${missing_optional[@]}"; do
            case "$tool" in
                vainfo)
                    log_warn "  vainfo: Install libva-utils for VAAPI support"
                    ;;
                nvidia-smi)
                    log_warn "  nvidia-smi: Install nvidia-driver for NVENC support"
                    ;;
            esac
        done
    fi
    return 0
}

get_cpu_cores() {
    nproc 2>/dev/null || echo "4"
}

# Check available disk space
check_disk_space() {
    local path="$1"
    local required_mb="${2:-1000}"  # Default 1GB

    if ! command_exists df; then
        log_warn "Cannot check disk space (df command not available)"
        return 0
    fi

    local available_mb
    available_mb=$(df -m "$path" | awk 'NR==2 {print $4}')

    if [[ -z "$available_mb" ]] || ! [[ "$available_mb" =~ ^[0-9]+$ ]]; then
        log_warn "Cannot determine available disk space"
        return 0
    fi

    if [[ "$available_mb" -lt "$required_mb" ]]; then
        log_error "Insufficient disk space: ${available_mb}MB available, ${required_mb}MB recommended"
        log_error "Free up space or use a different output directory"
        return 1
    fi

    log_debug "Disk space check passed: ${available_mb}MB available"
    return 0
}

# Provide error recovery suggestions
suggest_error_recovery() {
    local error_type="$1"
    local details="$2"

    log_error ""
    log_error "Troubleshooting suggestions:"

    case "$error_type" in
        "dependencies")
            log_error "  - Install missing tools using your package manager"
            log_error "  - Ensure ffmpeg is built with required codecs"
            log_error "  - Check that hardware drivers are installed"
            ;;
        "permissions")
            log_error "  - Check file/directory permissions"
            log_error "  - Ensure you have read/write access"
            log_error "  - Try running with elevated privileges if needed"
            ;;
        "hardware")
            log_error "  - Install GPU drivers (nvidia-driver, mesa-va-drivers)"
            log_error "  - Try --cpu flag for software encoding"
            log_error "  - Check hardware compatibility with ffmpeg"
            ;;
        "format")
            log_error "  - Verify file format is supported"
            log_error "  - Check file is not corrupted"
            log_error "  - Try different output format with --format"
            ;;
        "encoding")
            log_error "  - Try different encoder with --cpu, --nvenc, --vaapi"
            log_error "  - Check available disk space"
            log_error "  - Reduce quality with --quality parameter"
            ;;
        *)
            log_error "  - Run with --debug for detailed error information"
            log_error "  - Check the documentation for troubleshooting"
            ;;
    esac

    log_error "  - Use --help for command line options"
}

# Function to check if we can use a RAM disk for temporary processing
# This should be added to src/lib/utils.sh or the file where it's needed

can_use_ram_disk() {
    local min_size_mb=${1:-100}  # Default minimum size 100MB
    local tmpfs_path="/dev/shm"

    # Check if /dev/shm exists and is mounted
    if [[ ! -d "$tmpfs_path" ]]; then
        return 1
    fi

    # Check if it's actually a tmpfs mount
    if ! mount | grep -q "$tmpfs_path.*tmpfs"; then
        return 1
    fi

    # Check available space using df
    local available_kb
    available_kb=$(df "$tmpfs_path" 2>/dev/null | awk 'NR==2 {print $4}')

    if [[ -z "$available_kb" || ! "$available_kb" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    # Convert KB to MB and compare
    local available_mb=$((available_kb / 1024))

    if [[ "$available_mb" -gt "$min_size_mb" ]]; then
        return 0
    else
        return 1
    fi
}

# Alternative function that also checks for sufficient memory
can_use_ram_disk_with_memory_check() {
    local min_size_mb=${1:-100}
    local tmpfs_path="/dev/shm"

    # First check basic tmpfs availability
    if ! can_use_ram_disk "$min_size_mb"; then
        return 1
    fi

    # Check system memory (optional additional safety check)
    if command -v free >/dev/null 2>&1; then
        local available_mem_mb
        available_mem_mb=$(free -m | awk '/^Mem:/ {print $7}')

        # Only use ramdisk if we have plenty of free memory
        if [[ -n "$available_mem_mb" && "$available_mem_mb" -gt $((min_size_mb * 2)) ]]; then
            return 0
        else
            return 1
        fi
    fi

    # If free command not available, fall back to basic check
    return 0
}

# Usage examples:
# if can_use_ram_disk 200; then
#     temp_dir="/dev/shm/video_conv_$$"
#     mkdir -p "$temp_dir"
# else
#     temp_dir=$(mktemp -d)
# fi
