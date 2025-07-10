#!/bin/bash

set -uo pipefail
[[ "${CVRT_DEBUG:-}" == "true" ]] && set -x

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do
    SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    [[ $SCRIPT_SOURCE != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
cd_script_dir="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
readonly SCRIPT_DIR="$cd_script_dir"
readonly LIB_DIR="${SCRIPT_DIR}/lib"
readonly CONFIG_DIR="${SCRIPT_DIR}/config"

source "${CONFIG_DIR}/defaults.conf"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/hardware.sh"
source "${LIB_DIR}/encoders.sh"
source "${LIB_DIR}/video_analysis.sh"
source "${LIB_DIR}/audio_processing.sh"
source "${LIB_DIR}/video_filters.sh"

WORK_DIR="."
REPLACE_SOURCE=false
DEBUG_MODE=false
FORCE_ENCODER=""

OUTPUT_FORMAT="${DEFAULT_OUTPUT_FORMAT}"
VIDEO_CODEC="${DEFAULT_VIDEO_CODEC}"
AUDIO_CODEC="${DEFAULT_AUDIO_CODEC}"
ENCODING_PRESET="${DEFAULT_PRESET}"
SCALE_MODE="${DEFAULT_SCALE_MODE}"
DEINTERLACE="${DEFAULT_DEINTERLACE}"
DENOISE="${DEFAULT_DENOISE}"
SHARPEN="${DEFAULT_SHARPEN}"
SUBTITLE_MODE="${DEFAULT_SUBTITLE_MODE}"
METADATA_MODE="${DEFAULT_METADATA_MODE}"
THREAD_COUNT="${DEFAULT_THREADS}"
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
    local current
    current=$(get_stat "$1")
    set_stat "$1" $((current + 1))
}
STATS_SUCCESS=0
STATS_FAILED=0
STATS_SKIPPED=0

parse_arguments() {
    local short_opts="rdh"
    local long_opts="replace,debug,help,gpu,cpu,nvenc,vaapi,qsv,format:,codec:,audio-codec:,quality:,preset:,scale:,deinterlace,denoise,sharpen,subtitles:,metadata:,threads:,list-formats,list-codecs"
    if command -v getopt >/dev/null 2>&1; then
        local parsed_opts
        if ! parsed_opts=$(getopt -o "$short_opts" --long "$long_opts" -- "$@"); then
            log_error "Invalid arguments provided"
            show_usage
            exit 1
        fi
        eval set -- "$parsed_opts"
        while true; do
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
                --format)
                    OUTPUT_FORMAT="$2"
                    # Validate format immediately
                    local valid_format=false
                    for format in "${SUPPORTED_OUTPUT_FORMATS[@]}"; do
                        if [[ "$OUTPUT_FORMAT" == "$format" ]]; then
                            valid_format=true
                            break
                        fi
                    done
                    if [[ "$valid_format" == false ]]; then
                        log_error "Invalid output format: $OUTPUT_FORMAT"
                        log_info "Supported formats: ${SUPPORTED_OUTPUT_FORMATS[*]}"
                        exit 1
                    fi
                    log_info "Output format: $OUTPUT_FORMAT"
                    shift 2
                    ;;
                --codec)
                    VIDEO_CODEC="$2"
                    # Validate video codec immediately
                    local valid_codec=false
                    for codec in "${SUPPORTED_VIDEO_CODECS[@]}"; do
                        if [[ "$VIDEO_CODEC" == "$codec" ]]; then
                            valid_codec=true
                            break
                        fi
                    done
                    if [[ "$valid_codec" == false ]]; then
                        log_error "Invalid video codec: $VIDEO_CODEC"
                        log_info "Supported codecs: ${SUPPORTED_VIDEO_CODECS[*]}"
                        exit 1
                    fi
                    log_info "Video codec: $VIDEO_CODEC"
                    shift 2
                    ;;
                --audio-codec)
                    AUDIO_CODEC="$2"
                    # Validate audio codec immediately
                    local valid_audio_codec=false
                    for codec in "${SUPPORTED_AUDIO_CODECS[@]}"; do
                        if [[ "$AUDIO_CODEC" == "$codec" ]]; then
                            valid_audio_codec=true
                            break
                        fi
                    done
                    if [[ "$valid_audio_codec" == false ]]; then
                        log_error "Invalid audio codec: $AUDIO_CODEC"
                        log_info "Supported audio codecs: ${SUPPORTED_AUDIO_CODECS[*]}"
                        exit 1
                    fi
                    log_info "Audio codec: $AUDIO_CODEC"
                    shift 2
                    ;;
                --quality)
                    QUALITY_PARAM="$2"
                    log_info "Quality setting: $QUALITY_PARAM"
                    shift 2
                    ;;
                --preset)
                    ENCODING_PRESET="$2"
                    log_info "Encoding preset: $ENCODING_PRESET"
                    shift 2
                    ;;
                --scale)
                    SCALE_MODE="$2"
                    log_info "Scale mode: $SCALE_MODE"
                    shift 2
                    ;;
                --deinterlace)
                    DEINTERLACE=true
                    log_info "Deinterlacing enabled"
                    shift
                    ;;
                --denoise)
                    DENOISE=true
                    log_info "Denoising enabled"
                    shift
                    ;;
                --sharpen)
                    SHARPEN=true
                    log_info "Sharpening enabled"
                    shift
                    ;;
                --subtitles)
                    SUBTITLE_MODE="$2"
                    log_info "Subtitle mode: $SUBTITLE_MODE"
                    shift 2
                    ;;
                --metadata)
                    METADATA_MODE="$2"
                    log_info "Metadata mode: $METADATA_MODE"
                    shift 2
                    ;;
                --threads)
                    THREAD_COUNT="$2"
                    log_info "Thread count: $THREAD_COUNT"
                    shift 2
                    ;;
                --list-formats)
                    list_supported_formats
                    exit 0
                    ;;
                --list-codecs)
                    list_supported_codecs
                    exit 0
                    ;;
                -h|--help)
                    show_usage
                    exit 0
                    ;;
                --)
                    shift
                    break
                    ;;
                *)
                    log_error "Unknown option: $1"
                    show_usage
                    exit 1
                    ;;
            esac
        done
        if [[ $# -gt 0 ]]; then
            WORK_DIR="$1"
            shift
        fi
        if [[ $# -gt 0 ]]; then
            log_error "Unexpected arguments: $*"
            show_usage
            exit 1
        fi
    else
        log_warn "getopt not available, using legacy argument parsing"
        parse_arguments_legacy "$@"
    fi
    validate_parsed_arguments
}

parse_arguments_legacy() {
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
            --format)
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    OUTPUT_FORMAT="$2"
                    # Validate format immediately
                    local valid_format=false
                    for format in "${SUPPORTED_OUTPUT_FORMATS[@]}"; do
                        if [[ "$OUTPUT_FORMAT" == "$format" ]]; then
                            valid_format=true
                            break
                        fi
                    done
                    if [[ "$valid_format" == false ]]; then
                        log_error "Invalid output format: $OUTPUT_FORMAT"
                        log_info "Supported formats: ${SUPPORTED_OUTPUT_FORMATS[*]}"
                        exit 1
                    fi
                    log_info "Output format: $OUTPUT_FORMAT"
                    shift 2
                else
                    log_error "Missing format argument"
                    show_usage
                    exit 1
                fi
                ;;
            --codec)
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    VIDEO_CODEC="$2"
                    # Validate video codec immediately
                    local valid_codec=false
                    for codec in "${SUPPORTED_VIDEO_CODECS[@]}"; do
                        if [[ "$VIDEO_CODEC" == "$codec" ]]; then
                            valid_codec=true
                            break
                        fi
                    done
                    if [[ "$valid_codec" == false ]]; then
                        log_error "Invalid video codec: $VIDEO_CODEC"
                        log_info "Supported codecs: ${SUPPORTED_VIDEO_CODECS[*]}"
                        exit 1
                    fi
                    log_info "Video codec: $VIDEO_CODEC"
                    shift 2
                else
                    log_error "Missing codec argument"
                    show_usage
                    exit 1
                fi
                ;;
            --audio-codec)
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    AUDIO_CODEC="$2"
                    # Validate audio codec immediately
                    local valid_audio_codec=false
                    for codec in "${SUPPORTED_AUDIO_CODECS[@]}"; do
                        if [[ "$AUDIO_CODEC" == "$codec" ]]; then
                            valid_audio_codec=true
                            break
                        fi
                    done
                    if [[ "$valid_audio_codec" == false ]]; then
                        log_error "Invalid audio codec: $AUDIO_CODEC"
                        log_info "Supported audio codecs: ${SUPPORTED_AUDIO_CODECS[*]}"
                        exit 1
                    fi
                    log_info "Audio codec: $AUDIO_CODEC"
                    shift 2
                else
                    log_error "Missing audio codec argument"
                    show_usage
                    exit 1
                fi
                ;;
            --quality)
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    QUALITY_PARAM="$2"
                    log_info "Quality setting: $QUALITY_PARAM"
                    shift 2
                else
                    log_error "Missing quality argument"
                    show_usage
                    exit 1
                fi
                ;;
            --preset)
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    ENCODING_PRESET="$2"
                    log_info "Encoding preset: $ENCODING_PRESET"
                    shift 2
                else
                    log_error "Missing preset argument"
                    show_usage
                    exit 1
                fi
                ;;
            --scale)
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    SCALE_MODE="$2"
                    log_info "Scale mode: $SCALE_MODE"
                    shift 2
                else
                    log_error "Missing scale argument"
                    show_usage
                    exit 1
                fi
                ;;
            --deinterlace)
                DEINTERLACE=true
                log_info "Deinterlacing enabled"
                shift
                ;;
            --denoise)
                DENOISE=true
                log_info "Denoising enabled"
                shift
                ;;
            --sharpen)
                SHARPEN=true
                log_info "Sharpening enabled"
                shift
                ;;
            --subtitles)
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    SUBTITLE_MODE="$2"
                    log_info "Subtitle mode: $SUBTITLE_MODE"
                    shift 2
                else
                    log_error "Missing subtitle mode argument"
                    show_usage
                    exit 1
                fi
                ;;
            --metadata)
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    METADATA_MODE="$2"
                    log_info "Metadata mode: $METADATA_MODE"
                    shift 2
                else
                    log_error "Missing metadata mode argument"
                    show_usage
                    exit 1
                fi
                ;;
            --threads)
                if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                    THREAD_COUNT="$2"
                    log_info "Thread count: $THREAD_COUNT"
                    shift 2
                else
                    log_error "Missing thread count argument"
                    show_usage
                    exit 1
                fi
                ;;
            --list-formats)
                list_supported_formats
                exit 0
                ;;
            --list-codecs)
                list_supported_codecs
                exit 0
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -* )
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

validate_parsed_arguments() {
    if [[ -n "$OUTPUT_FORMAT" ]]; then
        local valid_format=false
        for format in "${SUPPORTED_OUTPUT_FORMATS[@]}"; do
            if [[ "$OUTPUT_FORMAT" == "$format" ]]; then
                valid_format=true
                break
            fi
        done
        if [[ "$valid_format" == false ]]; then
            log_error "Invalid output format: $OUTPUT_FORMAT"
            log_info "Supported formats: ${SUPPORTED_OUTPUT_FORMATS[*]}"
            exit 1
        fi
    fi
    if [[ -n "$VIDEO_CODEC" ]]; then
        local valid_codec=false
        for codec in "${SUPPORTED_VIDEO_CODECS[@]}"; do
            if [[ "$VIDEO_CODEC" == "$codec" ]]; then
                valid_codec=true
                break
            fi
        done
        if [[ "$valid_codec" == false ]]; then
            log_error "Invalid video codec: $VIDEO_CODEC"
            log_info "Supported codecs: ${SUPPORTED_VIDEO_CODECS[*]}"
            exit 1
        fi
    fi
    if [[ -n "$AUDIO_CODEC" ]]; then
        local valid_audio_codec=false
        for codec in "${SUPPORTED_AUDIO_CODECS[@]}"; do
            if [[ "$AUDIO_CODEC" == "$codec" ]]; then
                valid_audio_codec=true
                break
            fi
        done
        if [[ "$valid_audio_codec" == false ]]; then
            log_error "Invalid audio codec: $AUDIO_CODEC"
            log_info "Supported audio codecs: ${SUPPORTED_AUDIO_CODECS[*]}"
            exit 1
        fi
    fi
    if [[ -n "$THREAD_COUNT" ]]; then
        if ! [[ "$THREAD_COUNT" =~ ^[0-9]+$ ]] || [[ "$THREAD_COUNT" -lt 0 ]]; then
            log_error "Invalid thread count: $THREAD_COUNT (must be 0 or a positive integer)"
            exit 1
        fi
    fi
    if [[ -n "${QUALITY_PARAM:-}" ]]; then
        if ! [[ "$QUALITY_PARAM" =~ ^[0-9]+$ ]] || [[ "$QUALITY_PARAM" -lt 1 ]] || [[ "$QUALITY_PARAM" -gt 1000 ]]; then
            log_error "Invalid quality parameter: $QUALITY_PARAM (must be between 1-1000)"
            exit 1
        fi
    fi
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
    --format        Specify output format (e.g., mp4, mkv, mov, webm)
    --codec         Force video codec (e.g., hevc, h264, av1, vp9)
    --audio-codec   Force audio codec (e.g., aac, opus, flac, mp3)
    --quality       Set quality parameter (1-1000, default: 24)
    --preset        Set encoding preset (encoder-specific, default: medium)
    --scale         Set scaling mode (e.g., none, 1080p, 720p, 480p, 4k)
    --deinterlace   Enable deinterlacing
    --denoise       Enable denoising
    --sharpen       Enable sharpening
    --subtitles     Set subtitle mode (e.g., copy, burn, extract, none)
    --metadata      Set metadata mode (e.g., copy, strip, minimal)
    --threads       Set thread count (0 = auto-detect)
    --list-formats  List supported output formats
    --list-codecs   List supported video/audio codecs
    -h, --help      Show this help

DIRECTORY:
    Target directory containing video files (default: current directory)

EXAMPLES:
    $0 /media/videos
    $0 --replace --debug .
    $0 --cpu /path/to/movies
    $0 --format mp4 --codec h264 /path/to/videos
    $0 --scale 1080p --deinterlace /path/to/videos
    $0 --list-formats
    $0 --list-codecs
EOF
}

list_supported_formats() {
    cat << EOF
Supported Input Formats:
$(printf "  %s\n" "${SUPPORTED_INPUT_EXTENSIONS[@]}")

Supported Output Formats:
$(printf "  %s\n" "${SUPPORTED_OUTPUT_FORMATS[@]}")

Default Output Format: $DEFAULT_OUTPUT_FORMAT
EOF
}

list_supported_codecs() {
    cat << EOF
Supported Video Codecs:
$(printf "  %s\n" "${SUPPORTED_VIDEO_CODECS[@]}")

Supported Audio Codecs:
$(printf "  %s\n" "${SUPPORTED_AUDIO_CODECS[@]}")

Default Video Codec: $DEFAULT_VIDEO_CODEC
Default Audio Codec: $DEFAULT_AUDIO_CODEC
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
    local analysis_output
    if ! analysis_output=$(analyze_video_file "$file"); then
        log_error "Failed to analyze: $file"
        increment_stat failed
        return 1
    fi
    eval "$(echo $analysis_output | sed 's/\([^ ]*\)/file_info[\1/g;s/=/]=/g')"
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
        local base_name="${file%.*}"
        output_path="${base_name}-converted.${OUTPUT_FORMAT}"
    fi
    if [[ "$DEBUG_MODE" == true ]]; then
        log_debug "File details: codec=${file_info[codec]}, width=${file_info[width]}, height=${file_info[height]}"
        log_debug "Selected encoder: $(get_selected_encoder)"
        log_debug "Output path: $output_path"
    fi
    # Validate that CONTAINER_FORMATS mapping exists for OUTPUT_FORMAT
    if [[ -z "${CONTAINER_FORMATS[$OUTPUT_FORMAT]:-}" ]]; then
        log_error "No container mapping found for output format: $OUTPUT_FORMAT"
        log_info "Check your SUPPORTED_OUTPUT_FORMATS and CONTAINER_FORMATS settings."
        exit 1
    fi
    if process_with_encoder "$file" "$output_path" "$analysis_output" "${CONTAINER_FORMATS[$OUTPUT_FORMAT]}"; then
        increment_stat success
        if [[ "$REPLACE_SOURCE" == true ]]; then
            log_info "    [SUCCESS] Replaced original"
        else
            log_info "    [SUCCESS] Created: $(basename "$output_path")"
        fi
    else
        increment_stat failed
        log_error "    [FAILED] Encoding failed"
        if [[ "$DEBUG_MODE" == true ]]; then
            log_debug "Check encoder settings and hardware compatibility"
        fi
    fi
    return 0
}

process_all_files() {
    local -a video_files=()
    log_debug "Searching for video files in: $(pwd)"
    local search_pattern=""
    for ext in "${SUPPORTED_INPUT_EXTENSIONS[@]}"; do
        [[ -n "$search_pattern" ]] && search_pattern+=" -o"
        search_pattern+=" -name \"*.$ext\""
    done
    if [[ "$(uname)" == "Darwin" ]]; then
        for ext in "${SUPPORTED_INPUT_EXTENSIONS[@]}"; do
            while IFS= read -r file; do
                [[ -f "$file" ]] && video_files+=("$file")
            done < <(ls -1 ./*."$ext" 2>/dev/null || true)
        done
        log_debug "macOS file search completed"
    else
        local find_cmd="find . -maxdepth 1 -type f \("
        local first=true
        for ext in "${SUPPORTED_INPUT_EXTENSIONS[@]}"; do
            if [[ "$first" == true ]]; then
                find_cmd+=" -name \"*.$ext\""
                first=false
            else
                find_cmd+=" -o -name \"*.$ext\""
            fi
        done
        find_cmd+=" \)"
        mapfile -t video_files < <(eval "$find_cmd" 2>/dev/null)
        log_debug "Linux file search completed"
    fi
    log_debug "Found ${#video_files[@]} video files"
    local total_files=${#video_files[@]}
    if [[ $total_files -eq 0 ]]; then
        log_warn "No supported video files found in: $(pwd)"
        log_info "Supported formats: ${SUPPORTED_INPUT_EXTENSIONS[*]}"
        return 0
    fi
    log_info "Found $total_files video file(s) in: $(pwd)"
    echo
    local file
    for file in "${video_files[@]}"; do
        process_video_file "$file"
        echo
    done
}

show_final_stats() {
    local success_count
    success_count=$(get_stat success)
    local failed_count
    failed_count=$(get_stat failed)
    local skipped_count
    skipped_count=$(get_stat skipped)
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
    set +e
    trap 'log_error "Script error at line $LINENO"; exit 1' ERR
    parse_arguments "$@"
    check_dependencies || exit 1
    validate_directory "$WORK_DIR" || exit 1
    log_info "Detecting hardware capabilities..."
    if ! detect_all_hardware; then
        log_warn "Hardware detection had issues, but continuing with available options"
    fi
    select_best_encoder "$FORCE_ENCODER" || {
        log_error "Failed to select encoder"
        return 1
    }
    display_hardware_summary
    if [[ -z "$(get_selected_encoder)" ]]; then
        log_error "No valid encoder selected"
        return 1
    fi
    if [[ "$DEBUG_MODE" == true ]]; then
        log_debug "Starting file processing with encoder: $(get_selected_encoder)"
    fi
    process_all_files
    show_final_stats
    return 0
}

main "$@"
