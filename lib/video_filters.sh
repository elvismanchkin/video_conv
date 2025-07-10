#!/bin/bash
# Video filters and processing functions

# Build video filter chain based on options
# Args: input_file output_array_name
build_video_filters() {
    local input_file="$1"
    local -n filter_chain=$2

    filter_chain=()
    local filters=()

    # Get video properties for filter decisions
    local -A video_info
    local analysis_output
    if ! analysis_output=$(analyze_video_file "$input_file"); then
        log_error "Failed to analyze video for filters"
        return 1
    fi
    eval "$(echo $analysis_output | sed 's/\([^ ]*\)/video_info[\1/g;s/=/]=/g')"

    # Scaling filter
    if [[ "${SCALE_MODE:-none}" != "none" ]]; then
        local scale_filter
        if build_scale_filter "${video_info[width]:-}" "${video_info[height]:-}" scale_filter; then
            filters+=("$scale_filter")
        fi
    fi

    # Deinterlacing filter
    if [[ "${DEINTERLACE:-false}" == "true" ]]; then
        filters+=("yadif=1:1:0")
    fi

    # Denoising filter
    if [[ "${DENOISE:-false}" == "true" ]]; then
        filters+=("nlmeans=10:7:5:3")
    fi

    # Sharpening filter
    if [[ "${SHARPEN:-false}" == "true" ]]; then
        filters+=("unsharp=3:3:1.5:3:3:0.5")
    fi

    # Combine all filters
    if [[ ${#filters[@]} -gt 0 ]]; then
        filter_chain+=("-vf" "$(IFS=,; echo "${filters[*]}")")
    fi

    log_debug "Video filters: ${filter_chain[*]}"
    return 0
}

# Build scaling filter based on mode and current resolution
# Args: current_width current_height output_filter_name
build_scale_filter() {
    local current_width="$1"
    local current_height="$2"
    local -n scale_filter=$3

    case "${SCALE_MODE:-}" in
        1080p|1920x1080)
            scale_filter="scale=1920:1080:flags=lanczos"
            ;;
        720p|1280x720)
            scale_filter="scale=1280:720:flags=lanczos"
            ;;
        480p|854x480)
            scale_filter="scale=854:480:flags=lanczos"
            ;;
        4k|3840x2160)
            scale_filter="scale=3840:2160:flags=lanczos"
            ;;
        custom)
            if [[ -n "${CUSTOM_SCALE:-}" ]]; then
                scale_filter="scale=${CUSTOM_SCALE}:flags=lanczos"
            else
                log_warn "Custom scale mode specified but no dimensions provided"
                return 1
            fi
            ;;
        *)
            log_warn "Unknown scale mode: ${SCALE_MODE:-}"
            return 1
            ;;
    esac

    return 0
}

# Build subtitle filter based on mode
# Args: input_file output_array_name
build_subtitle_filters() {
    local input_file="$1"
    local _subtitle_filters=()

    case "${SUBTITLE_MODE:-copy}" in
        burn)
            # Burn subtitles into video
            local subtitle_file
            if find_subtitle_file "$input_file" subtitle_file; then
                _subtitle_filters+=("-vf" "subtitles=$subtitle_file")
            else
                log_warn "No subtitle file found for burning"
            fi
            ;;
        extract)
            # Extract subtitles to separate files
            extract_subtitles "$input_file"
            ;;
        none)
            # Remove all subtitles
            _subtitle_filters+=("-sn")
            ;;
        copy|*)
            # Default: copy subtitles as-is
            ;;
    esac

    # Return array as a string
    echo "${_subtitle_filters[@]}"
    return 0
}

# Find subtitle file for video
# Args: video_file output_subtitle_file_name
find_subtitle_file() {
    local video_file="$1"
    local -n subtitle_file=$2

    local base_name="${video_file%.*}"
    local subtitle_extensions=("srt" "ass" "ssa" "sub" "vtt")

    for ext in "${subtitle_extensions[@]}"; do
        local potential_subtitle="${base_name}.${ext}"
        if [[ -f "$potential_subtitle" ]]; then
            subtitle_file="$potential_subtitle"
            return 0
        fi
    done

    return 1
}

# Extract subtitles from video file
# Args: video_file
extract_subtitles() {
    local video_file="$1"
    local base_name="${video_file%.*}"

    log_info "Extracting subtitles from: $(basename "$video_file")"

    # Extract all subtitle streams
    if ffmpeg -i "$video_file" -map 0:s:0 "${base_name}.srt" 2>/dev/null; then
        log_info "    Extracted: $(basename "${base_name}.srt")"
    fi

    # Extract additional subtitle streams if they exist
    local subtitle_count
    subtitle_count=$(ffprobe -v quiet -select_streams s -show_entries stream=index -of csv=p=0 "$video_file" | wc -l)

    for ((i=1; i<subtitle_count; i++)); do
        if ffmpeg -i "$video_file" -map 0:s:$i "${base_name}_${i}.srt" 2>/dev/null; then
            log_info "    Extracted: $(basename "${base_name}_${i}.srt")"
        fi
    done
}

# Build metadata handling arguments
# Args: output_array_name
build_metadata_args() {
    local _metadata_args=()

    case "${METADATA_MODE:-copy}" in
        strip)
            _metadata_args+=("-map_metadata" "-1")
            ;;
        minimal)
            # Keep only essential metadata
            _metadata_args+=("-map_metadata" "0" "-metadata" "title=" "-metadata" "artist=" "-metadata" "album=")
            ;;
        copy|*)
            # Default: copy all metadata
            _metadata_args+=("-map_metadata" "0")
            ;;
    esac

    echo "${_metadata_args[@]}"
    return 0
}

# Build performance optimization arguments
# Args: output_array_name
build_performance_args() {
    local _perf_args=()

    # Thread count
    if [[ -n "${THREAD_COUNT:-}" && "$THREAD_COUNT" != "0" ]]; then
        _perf_args+=("-threads" "$THREAD_COUNT")
    else
        # Auto-detect optimal thread count
        local optimal_threads
        optimal_threads=$(get_optimal_thread_count)
        _perf_args+=("-threads" "$optimal_threads")
    fi

    # Buffer size
    if [[ -n "${BUFFER_SIZE_MB:-}" ]]; then
        _perf_args+=("-bufsize" "${BUFFER_SIZE_MB}M")
    fi

    # Memory limit
    if [[ -n "${MAX_MEMORY_GB:-}" ]]; then
        _perf_args+=("-max_muxing_queue_size" "$((MAX_MEMORY_GB * 1024))")
    fi

    echo "${_perf_args[@]}"
    return 0
}

# Get optimal thread count based on system
get_optimal_thread_count() {
    local cpu_cores
    cpu_cores=$(get_cpu_cores)

    # Use 75% of available cores for encoding
    local optimal_threads=$((cpu_cores * 3 / 4))

    # Ensure minimum of 2 threads
    [[ $optimal_threads -lt 2 ]] && optimal_threads=2

    # Ensure maximum of 16 threads to prevent system overload
    [[ $optimal_threads -gt 16 ]] && optimal_threads=16

    echo "$optimal_threads"
}

# Validate filter compatibility with encoder
# Args: encoder_name filter_chain
# Returns: 0 if compatible, 1 if incompatible (will cause failure), 2 if suboptimal
validate_filter_compatibility() {
    local encoder="$1"
    # shellcheck disable=SC2178
    local filter_chain="$2"
    # shellcheck disable=SC2128
    local compatibility_issues=()
    local fatal_issues=()
    local suboptimal_issues=()

    # Check for hardware-specific filter limitations
    case "$encoder" in
        NVENC)
            # NVENC has limited filter support
            # shellcheck disable=SC2128
            if [[ "$filter_chain" == *"yadif"* ]]; then
                suboptimal_issues+=("Deinterlacing (yadif) may not work optimally with NVENC")
            fi
            # shellcheck disable=SC2128
            if [[ "$filter_chain" == *"nlmeans"* ]]; then
                suboptimal_issues+=("Denoising (nlmeans) may not work optimally with NVENC")
            fi
            # shellcheck disable=SC2128
            if [[ "$filter_chain" == *"unsharp"* ]]; then
                suboptimal_issues+=("Sharpening (unsharp) may not work optimally with NVENC")
            fi
            # shellcheck disable=SC2128
            if [[ "$filter_chain" == *"subtitles"* ]]; then
                suboptimal_issues+=("Subtitle burning may not work optimally with NVENC")
            fi
            ;;
        QSV)
            # QSV supports most filters but has some limitations
            # shellcheck disable=SC2128
            if [[ "$filter_chain" == *"nlmeans"* ]]; then
                suboptimal_issues+=("Denoising (nlmeans) may not work optimally with QSV")
            fi
            # shellcheck disable=SC2128
            if [[ "$filter_chain" == *"subtitles"* ]]; then
                suboptimal_issues+=("Subtitle burning may not work optimally with QSV")
            fi
            ;;
        VAAPI)
            # VAAPI has good filter support but some limitations
            # shellcheck disable=SC2128
            if [[ "$filter_chain" == *"nlmeans"* ]]; then
                suboptimal_issues+=("Denoising (nlmeans) may not work optimally with VAAPI")
            fi
            # shellcheck disable=SC2128
            if [[ "$filter_chain" == *"subtitles"* ]]; then
                suboptimal_issues+=("Subtitle burning may not work optimally with VAAPI")
            fi
            ;;
        SOFTWARE)
            # Software encoding supports all filters
            ;;
        *)
            log_warn "Unknown encoder: $encoder, assuming full filter support"
            ;;
    esac

    # Check for known fatal combinations
    # shellcheck disable=SC2128
    if [[ "$encoder" == "NVENC" && "$filter_chain" == *"yadif"* && "$filter_chain" == *"nlmeans"* ]]; then
        fatal_issues+=("NVENC + Deinterlacing + Denoising combination is known to fail")
    fi

    # Report issues
    if [[ ${#fatal_issues[@]} -gt 0 ]]; then
        echo
        echo "❌ FATAL: Incompatible filter/encoder combination detected!"
        echo "========================================================"
        for issue in "${fatal_issues[@]}"; do
            echo "  • $issue"
        done
        echo
        echo "This combination will likely fail. Consider:"
        echo "  • Using --cpu for software encoding"
        echo "  • Removing problematic filters"
        echo "  • Using a different encoder"
        echo
        return 1
    fi

    if [[ ${#suboptimal_issues[@]} -gt 0 ]]; then
        echo
        echo "⚠️  WARNING: Suboptimal filter/encoder combination detected"
        echo "=========================================================="
        for issue in "${suboptimal_issues[@]}"; do
            echo "  • $issue"
        done
        echo
        echo "These filters may not work as expected with $encoder."
        echo "Consider using --cpu for software encoding if you need these filters."
        echo
        return 2
    fi

    return 0
}
