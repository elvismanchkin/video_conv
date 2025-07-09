#!/bin/bash

# GPU Video Converter - Main Script
# Self-contained video converter with hardware acceleration

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR="${SCRIPT_DIR}/lib"
readonly CONFIG_DIR="${SCRIPT_DIR}/config"

source "${CONFIG_DIR}/defaults.conf"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/hardware.sh"
source "${LIB_DIR}/encoders.sh"
source "${LIB_DIR}/video_analysis.sh"
source "${LIB_DIR}/audio_processing.sh"

WORK_DIR="."
REPLACE_SOURCE=false
DEBUG_MODE=false
FORCE_ENCODER=""
# Using function approach for STATS to be compatible with bash 3.2
get_stat() {
    case "$1" in
        success) echo "${STATS_SUCCESS:-0}" ;;
        failed) echo "${STATS_FAILED:-0}" ;;
        skipped) echo "${STATS_SKIPPED:-0}" ;;
    esac
}
set_stat() {
    case "$1" in
        success) STATS_SUCCESS="$2" ;;
        failed) STATS_FAILED="$2" ;;
        skipped) STATS_SKIPPED="$2" ;;
    esac
}
increment_stat() {
    local current=$(get_stat "$1")
    set_stat "$1" $((current + 1))
}
STATS_SUCCESS=0
STATS_FAILED=0
STATS_SKIPPED=0

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -r|--replace)
                REPLACE_SOURCE=true
                log_info "Replace mode enabled"
                shift
                ;;
            -d|--debug)
                DEBUG_MODE=true
                set_log_level DEBUG
                log_info "Debug mode enabled"
                shift
                ;;
            --gpu|--cpu|--nvenc|--vaapi|--qsv)
                FORCE_ENCODER="${1#--}"
                FORCE_ENCODER="${FORCE_ENCODER^^}"
                log_info "Forced encoder: ${FORCE_ENCODER}"
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                WORK_DIR="$1"
                shift
                ;;
        esac
    done
}

show_usage() {
    cat << EOF
GPU Video Converter v8.0

USAGE: $0 [OPTIONS] [DIRECTORY]

OPTIONS:
    -r, --replace    Replace original files (destructive)
    -d, --debug      Enable debug output
    --gpu           Auto-select best GPU encoder
    --cpu           Force software encoding
    --nvenc         Force NVIDIA NVENC
    --vaapi         Force AMD/Intel VAAPI
    --qsv           Force Intel Quick Sync
    -h, --help      Show this help

DIRECTORY:
    Target directory containing .mkv files (default: current directory)

EXAMPLES:
    $0 /media/videos
    $0 --replace --debug .
    $0 --cpu /path/to/movies
EOF
}

validate_directory() {
    local dir="$1"

    if [[ ! -d "$dir" ]]; then
        log_error "Directory not found: $dir"
        return 1
    fi

    if ! cd "$dir" 2>/dev/null; then
        log_error "Cannot access directory: $dir"
        return 1
    fi
    
    return 0
}

process_video_file() {
    local file="$1"
    local -A file_info

    log_info "Processing: $file"

    if ! analyze_video_file "$file" file_info; then
        log_error "Failed to analyze: $file"
        increment_stat failed
        return 1
    fi

    printf "    %s %dx%d (%dbit) | %d audio tracks\n" \
        "${file_info[codec]}" \
        "${file_info[width]}" \
        "${file_info[height]}" \
        "${file_info[bit_depth]}" \
        "${file_info[audio_count]}"

    local output_path
    if [[ "$REPLACE_SOURCE" == true ]]; then
        output_path="$file"
    else
        output_path="${file%.*}-converted.mkv"
    fi

    if process_with_encoder "$file" "$output_path" file_info; then
        increment_stat success
        if [[ "$REPLACE_SOURCE" == true ]]; then
            log_info "    [SUCCESS] Replaced original"
        else
            log_info "    [SUCCESS] Created: $(basename "$output_path")"
        fi
    else
        increment_stat failed
        log_error "    [FAILED] Encoding failed"
    fi

    return 0
}

process_all_files() {
    local -a mkv_files
    mapfile -t mkv_files < <(find . -maxdepth 1 -name "*.mkv" -type f 2>/dev/null)

    local total_files=${#mkv_files[@]}

    if [[ $total_files -eq 0 ]]; then
        log_warn "No .mkv files found in: $(pwd)"
        return 0
    fi

    log_info "Found $total_files .mkv file(s) in: $(pwd)"
    echo

    local file
    for file in "${mkv_files[@]}"; do
        process_video_file "$file"
        echo
    done
}

show_final_stats() {
    local success_count=$(get_stat success)
    local failed_count=$(get_stat failed)
    local skipped_count=$(get_stat skipped)
    local total=$((success_count + failed_count + skipped_count))

    printf "\n[RESULTS] Success: %d | Failed: %d | Skipped: %d | Total: %d\n" \
        "$success_count" \
        "$failed_count" \
        "$skipped_count" \
        "$total"

    if [[ $success_count -gt 0 ]]; then
        local encoder_used
        encoder_used=$(get_selected_encoder)
        log_info "Conversion completed using: $encoder_used"
    fi

    if [[ $failed_count -gt 0 ]]; then
        log_warn "Some files failed. Run with --debug for details."
    fi
}

main() {
    log_info "GPU Video Converter v8.0"

    parse_arguments "$@"

    check_dependencies || exit 1
    validate_directory "$WORK_DIR" || exit 1

    log_info "Detecting hardware capabilities..."
    detect_all_hardware

    select_best_encoder "$FORCE_ENCODER"
    display_hardware_summary

    process_all_files

    show_final_stats

    return 0
}

main "$@"
