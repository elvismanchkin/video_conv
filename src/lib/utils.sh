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
        log_error "Please install them using your package manager"
        return 1
    fi
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
