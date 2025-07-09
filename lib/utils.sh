#!/bin/bash

# Logging configuration
LOG_LEVEL=${CVRT_LOG_LEVEL:-INFO}

# Log level function for bash 3.2 compatibility
get_log_level_value() {
    case "$1" in
        DEBUG) echo 0 ;;
        INFO) echo 1 ;;
        WARN) echo 2 ;;
        ERROR) echo 3 ;;
        *) echo 1 ;;
    esac
}

# Set logging level
# Args: level (DEBUG|INFO|WARN|ERROR)
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
    local current_level_num=$(get_log_level_value "$LOG_LEVEL")
    local msg_level_num=$(get_log_level_value "$msg_level")
    [[ $msg_level_num -ge $current_level_num ]]
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

# Check if command exists
# Args: command_name
command_exists() {
    command -v "$1" &>/dev/null
}

# Check all required dependencies
# Returns: 0 if all found, 1 if missing dependencies
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
        log_error "Please install them using your package manager"
        return 1
    fi

    # Check optional tools
    for tool in "${OPTIONAL_TOOLS[@]}"; do
        if ! command_exists "$tool"; then
            log_debug "Optional tool not found: $tool"
        fi
    done

    return 0
}

get_cpu_cores() {
    nproc 2>/dev/null || echo "4"
}

# Get available RAM in /dev/shm (GB)
get_ram_disk_space() {
    if [[ -d "$RAM_DISK_PATH" ]]; then
        df -BG "$RAM_DISK_PATH" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//' || echo "0"
    else
        echo "0"
    fi
}

# Check if RAM disk can be used for a file
# Args: file_path
can_use_ram_disk() {
    local file="$1"
    local available_gb
    local required_gb

    available_gb=$(get_ram_disk_space)
    if [[ $available_gb -lt $MIN_RAM_DISK_GB ]]; then
        return 1
    fi

    # Get file size in GB (rounded up)
    required_gb=$(du -BG "$file" 2>/dev/null | cut -f1 | sed 's/G//' || echo "999")

    [[ $available_gb -gt $required_gb ]]
}

# Create temporary file path
# Args: original_file_path [use_ram_disk]
create_temp_path() {
    local original="$1"
    local use_ram_disk="${2:-false}"
    local base_name
    local temp_dir

    base_name=$(basename "$original")

    if [[ "$use_ram_disk" == true && -d "$RAM_DISK_PATH" ]]; then
        temp_dir="$RAM_DISK_PATH"
    else
        temp_dir="$(dirname "$original")"
    fi

    printf "%s/%s-%d_%s" "$temp_dir" "$TEMP_FILE_PREFIX" "$$" "$base_name"
}

# Clean up temporary files
# Args: temp_file_path
cleanup_temp_file() {
    local temp_file="$1"
    if [[ -f "$temp_file" ]]; then
        rm -f "$temp_file"
        log_debug "Cleaned up temporary file: $temp_file"
    fi
}

# Get file size in bytes
# Args: file_path
get_file_size() {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo "0"
}

# Safe move operation with validation
# Args: source_path destination_path
safe_move() {
    local src="$1"
    local dst="$2"

    if [[ ! -f "$src" ]]; then
        log_error "Source file not found: $src"
        return 1
    fi

    if ! mv "$src" "$dst" 2>/dev/null; then
        log_error "Failed to move file: $src -> $dst"
        return 1
    fi

    log_debug "Successfully moved: $src -> $dst"
    return 0
}

# Validate video file existence and readability
# Args: file_path
validate_video_file() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file"
        return 1
    fi

    if [[ ! -r "$file" ]]; then
        log_error "File not readable: $file"
        return 1
    fi

    # Quick format check
    if ! ffprobe -v quiet -show_streams "$file" &>/dev/null; then
        log_error "Invalid or corrupted video file: $file"
        return 1
    fi

    return 0
}

# Parse resolution into complexity level
# Args: width height
get_complexity_level() {
    local width="$1"
    local height="$2"
    local pixels=$((width * height))

    if [[ $pixels -gt $HIGH_COMPLEXITY_THRESHOLD ]]; then
        echo "high"
    elif [[ $pixels -gt $MEDIUM_COMPLEXITY_THRESHOLD ]]; then
        echo "medium"
    else
        echo "low"
    fi
}
