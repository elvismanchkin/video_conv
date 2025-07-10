#!/bin/bash
# Audio stream processing and conversion functions

# Process video file with encoder
# Args: input_file output_file file_analysis_array
process_with_encoder() {
    local input_file="$1"
    local output_file="$2"
    local -A file_data
    local analysis_output="$3"
    local container_format="$4"
    eval "$(echo $analysis_output | sed 's/\([^ ]*\)/file_data[\1/g;s/=/]=/g')"
    log_debug "Processing with encoder: $SELECTED_ENCODER"
    if needs_audio_processing "$analysis_output"; then
        log_info "    Converting 5.1 audio to stereo + encoding with $SELECTED_ENCODER"
        process_with_audio_conversion "$input_file" "$output_file" "$analysis_output" "$container_format"
    else
        log_info "    Encoding with $SELECTED_ENCODER"
        process_video_only "$input_file" "$output_file" "$analysis_output" "$container_format"
    fi
}

# Process video with audio conversion (5.1 to stereo)
# Args: input_file output_file file_analysis_array
process_with_audio_conversion() {
    local input_file="$1"
    local output_file="$2"
    local analysis_output="$3"
    local container_format="$4"
    local -A audio_data
    eval "$(echo $analysis_output | sed 's/\([^ ]*\)/audio_data[\1/g;s/=/]=/g')"

    local temp_dir
    local use_ram_disk=false

    # Determine if we can use RAM disk
    if can_use_ram_disk "$input_file"; then
        use_ram_disk=true
        temp_dir=$(mktemp -d -p "$RAM_DISK_PATH")
        log_debug "Using RAM disk for temporary files: $temp_dir"
    else
        temp_dir=$(mktemp -d)
        log_debug "Using regular disk for temporary files: $temp_dir"
    fi

    # Cleanup function
    cleanup_temp_dir() {
        if [[ -n "${temp_dir:-}" ]]; then
            rm -rf "$temp_dir"
            log_debug "Cleaned up temporary directory: $temp_dir"
        fi
    }
    trap cleanup_temp_dir EXIT

    # Convert 5.1 audio streams to stereo
    if ! convert_surround_audio "$input_file" "$temp_dir" "$analysis_output"; then
        log_error "Audio conversion failed"
        return 1
    fi

    # Encode video with converted audio
    if ! encode_with_converted_audio "$input_file" "$output_file" "$temp_dir" "$analysis_output" "$container_format"; then
        log_error "Video encoding with converted audio failed"
        return 1
    fi

    trap - EXIT
    cleanup_temp_dir
    return 0
}

# Convert 5.1 surround audio streams to stereo
# Args: input_file temp_directory file_analysis_array
convert_surround_audio() {
    local input_file="$1"
    local temp_dir="$2"
    local analysis_output="$3"
    # If you need to use analysis data, eval it into an associative array as needed:
    local -A conv_data
    eval "$(echo $analysis_output | sed 's/\([^ ]*\)/conv_data[\1/g;s/=/]=/g')"

    log_debug "Converting 5.1 audio streams to stereo"

    # Get 5.1 audio stream indices
    local -a surround_indices
    get_audio_streams_by_channels "$input_file" 6 surround_indices

    if [[ ${#surround_indices[@]} -eq 0 ]]; then
        log_error "No 5.1 audio streams found"
        return 1
    fi

    # Convert each 5.1 stream
    local index
    local success_count=0
    for index in "${surround_indices[@]}"; do
        local output_audio="$temp_dir/audio_${index}.m4a"

        log_debug "Converting audio stream $index to stereo"

        if ffmpeg -y -v warning \
                  -i "$input_file" \
                  -map "0:$index" \
                  -c:a aac \
                  -ac 2 \
                  -b:a "$STEREO_BITRATE" \
                  "$output_audio" 2>/dev/null; then
            ((success_count++))
            log_debug "Successfully converted audio stream $index"
        else
            log_warn "Failed to convert audio stream $index"
            rm -f "$output_audio"
        fi
    done

    if [[ $success_count -eq 0 ]]; then
        log_error "No audio streams were successfully converted"
        return 1
    fi

    log_debug "Successfully converted $success_count audio streams"
    return 0
}

# Encode video with converted audio streams
# Args: input_file output_file temp_directory file_analysis_array
encode_with_converted_audio() {
    local input_file="$1"
    local output_file="$2"
    local temp_dir="$3"
    local analysis_output="$4"
    local container_format="$5"
    local -A encode_data
    eval "$(echo $analysis_output | sed 's/\([^ ]*\)/encode_data[\1/g;s/=/]=/g')"

    # Build FFmpeg inputs array
    local -a ffmpeg_inputs=("-i" "$input_file")
    local -a map_args=("-map" "0:v")  # Video (subtitles handled by subtitle filters)
    local audio_input_counter=1

    # Add converted audio files as inputs
    local converted_audio
    for converted_audio in "$temp_dir"/audio_*.m4a; do
        if [[ -f "$converted_audio" ]]; then
            ffmpeg_inputs+=("-i" "$converted_audio")
            map_args+=("-map" "$audio_input_counter:a")
            ((audio_input_counter++))
        fi
    done

    # Get encoder arguments
    local -a encoder_args
    get_encoder_arguments "$SELECTED_ENCODER" \
                         "${encode_data[is_10bit]}" \
                         "${encode_data[complexity]}" \
                         encoder_args

    # Build video filters
    local -a video_filters
    if ! build_video_filters "$input_file" video_filters; then
        log_warn "Failed to build video filters, proceeding without filters"
    fi

    # Build subtitle filters
    local -a subtitle_filters
    read -ra subtitle_filters <<< "$(build_subtitle_filters "$input_file")"

    # Build metadata arguments
    local -a metadata_args
    read -ra metadata_args <<< "$(build_metadata_args)"

    # Build performance arguments
    local -a perf_args
    read -ra perf_args <<< "$(build_performance_args)"

    # Validate filter compatibility
    if [[ ${#video_filters[@]} -gt 0 ]]; then
        local compatibility_result
        compatibility_result=$(validate_filter_compatibility "$SELECTED_ENCODER" "${video_filters[*]}")
        case $? in
            1)
                log_error "Fatal filter/encoder incompatibility detected. Aborting."
                return 1
                ;;
            2)
                log_warn "Suboptimal filter/encoder combination detected, but proceeding..."
                ;;
        esac
    fi

    # Build final output path
    local final_output
    if [[ "$output_file" == "${input_file}" ]]; then
        final_output="${input_file%.*}-TEMP-$$.mkv"
    else
        final_output="$output_file"
    fi

    log_debug "Encoding with converted audio: ${#ffmpeg_inputs[@]} inputs"
    log_debug "Video filters: ${video_filters[*]}"
    log_debug "Subtitle filters: ${subtitle_filters[*]}"
    log_debug "Metadata args: ${metadata_args[*]}"

    # Execute encoding
    if ffmpeg "${ffmpeg_inputs[@]}" \
              "${map_args[@]}" \
              "${video_filters[@]}" \
              "${subtitle_filters[@]}" \
              "${metadata_args[@]}" \
              "${perf_args[@]}" \
              -f "$container_format" \
              "${encoder_args[@]}" \
              -c:a copy \
              -y "$final_output" 2>/dev/null; then

        # Handle replacement if needed
        if [[ "$final_output" != "$output_file" ]]; then
            if safe_move "$final_output" "$output_file"; then
                return 0
            else
                rm -f "$final_output"
                return 1
            fi
        fi
        return 0
    else
        # Try fallback encoder if available
        if [[ -n "$FALLBACK_ENCODER" && "$SELECTED_ENCODER" != "$FALLBACK_ENCODER" ]]; then
            log_warn "Retrying with fallback encoder: $FALLBACK_ENCODER"
            encode_with_fallback "$input_file" "$output_file" "$temp_dir" "$analysis_output" "$container_format"
            return $?
        fi
        return 1
    fi
}

# Process video without audio conversion
# Args: input_file output_file file_analysis_array
process_video_only() {
    local input_file="$1"
    local output_file="$2"
    local analysis_output="$3"
    local container_format="$4"
    local -A video_data
    eval "$(echo $analysis_output | sed 's/\([^ ]*\)/video_data[\1/g;s/=/]=/g')"

    # Get streams to keep (non-5.1 audio + video + subtitles)
    local -a stream_indices
    get_keepable_stream_indices "$input_file" stream_indices

    # Build map arguments
    local -a map_args
    local index
    for index in "${stream_indices[@]}"; do
        map_args+=("-map" "0:$index")
    done

    # Get encoder arguments
    local -a encoder_args
    get_encoder_arguments "$SELECTED_ENCODER" \
                         "${video_data[is_10bit]}" \
                         "${video_data[complexity]}" \
                         encoder_args

    # Build video filters
    local -a video_filters
    if ! build_video_filters "$input_file" video_filters; then
        log_warn "Failed to build video filters, proceeding without filters"
    fi

    # Build subtitle filters
    local -a subtitle_filters
    read -ra subtitle_filters <<< "$(build_subtitle_filters "$input_file")"

    # Build metadata arguments
    local -a metadata_args
    read -ra metadata_args <<< "$(build_metadata_args)"

    # Build performance arguments
    local -a perf_args
    read -ra perf_args <<< "$(build_performance_args)"

    # Validate filter compatibility
    if [[ ${#video_filters[@]} -gt 0 ]]; then
        local compatibility_result
        compatibility_result=$(validate_filter_compatibility "$SELECTED_ENCODER" "${video_filters[*]}")
        case $? in
            1)
                log_error "Fatal filter/encoder incompatibility detected. Aborting."
                return 1
                ;;
            2)
                log_warn "Suboptimal filter/encoder combination detected, but proceeding..."
                ;;
        esac
    fi

    # Build final output path
    local final_output
    if [[ "$output_file" == "${input_file}" ]]; then
        final_output="${input_file%.*}-TEMP-$$.mkv"
    else
        final_output="$output_file"
    fi

    log_debug "Encoding video-only: ${#map_args[@]} streams"
    log_debug "Video filters: ${video_filters[*]}"
    log_debug "Subtitle filters: ${subtitle_filters[*]}"
    log_debug "Metadata args: ${metadata_args[*]}"

    # Execute encoding
    if ffmpeg -i "$input_file" \
              "${map_args[@]}" \
              "${video_filters[@]}" \
              "${subtitle_filters[@]}" \
              "${metadata_args[@]}" \
              "${perf_args[@]}" \
              -f "$container_format" \
              "${encoder_args[@]}" \
              -c:a copy \
              -y "$final_output" 2>/dev/null; then

        # Handle replacement if needed
        if [[ "$final_output" != "$output_file" ]]; then
            if safe_move "$final_output" "$output_file"; then
                return 0
            else
                rm -f "$final_output"
                return 1
            fi
        fi
        return 0
    else
        # Try fallback encoder if available
        if [[ -n "$FALLBACK_ENCODER" && "$SELECTED_ENCODER" != "$FALLBACK_ENCODER" ]]; then
            log_warn "Retrying with fallback encoder: $FALLBACK_ENCODER"
            encode_video_with_fallback "$input_file" "$output_file" "$analysis_output" "$container_format"
            return $?
        fi
        return 1
    fi
}

# Encode with fallback encoder (audio conversion path)
# Args: input_file output_file temp_directory file_analysis_array
encode_with_fallback() {
    local input_file="$1"
    local output_file="$2"
    local temp_dir="$3"
    local analysis_output="$4"
    local container_format="$5"
    local -A fallback_data
    eval "$(echo $analysis_output | sed 's/\([^ ]*\)/fallback_data[\1/g;s/=/]=/g')"

    log_debug "Using fallback encoder: $FALLBACK_ENCODER"

    # Get fallback encoder arguments
    local -a fallback_args
    get_encoder_arguments "$FALLBACK_ENCODER" \
                         "${fallback_data[is_10bit]}" \
                         "${fallback_data[complexity]}" \
                         fallback_args

    # Rebuild inputs and maps (same as primary attempt)
    local -a ffmpeg_inputs=("-i" "$input_file")
    local -a map_args=("-map" "0:v")  # Video (subtitles handled by subtitle filters)
    local audio_input_counter=1

    local converted_audio
    for converted_audio in "$temp_dir"/audio_*.m4a; do
        if [[ -f "$converted_audio" ]]; then
            ffmpeg_inputs+=("-i" "$converted_audio")
            map_args+=("-map" "$audio_input_counter:a")
            ((audio_input_counter++))
        fi
    done

    # Build video filters
    local -a video_filters
    if ! build_video_filters "$input_file" video_filters; then
        log_warn "Failed to build video filters, proceeding without filters"
    fi

    # Build subtitle filters
    local -a subtitle_filters
    read -ra subtitle_filters <<< "$(build_subtitle_filters "$input_file")"

    # Build metadata arguments
    local -a metadata_args
    read -ra metadata_args <<< "$(build_metadata_args)"

    # Build performance arguments
    local -a perf_args
    read -ra perf_args <<< "$(build_performance_args)"

    # Build final output path
    local final_output
    if [[ "$output_file" == "${input_file}" ]]; then
        final_output="${input_file%.*}-TEMP-$$.mkv"
    else
        final_output="$output_file"
    fi

    # Execute fallback encoding
    if ffmpeg "${ffmpeg_inputs[@]}" \
              "${map_args[@]}" \
              "${video_filters[@]}" \
              "${subtitle_filters[@]}" \
              "${metadata_args[@]}" \
              "${perf_args[@]}" \
              -f "$container_format" \
              "${fallback_args[@]}" \
              -c:a copy \
              -y "$final_output" 2>/dev/null; then

        if [[ "$final_output" != "$output_file" ]]; then
            safe_move "$final_output" "$output_file"
        else
            return 0
        fi
    else
        rm -f "$final_output"
        return 1
    fi
}

# Encode video with fallback encoder (video-only path)
# Args: input_file output_file file_analysis_array
encode_video_with_fallback() {
    local input_file="$1"
    local output_file="$2"
    local analysis_output="$3"
    local container_format="$4"
    local -A fallback_video_data
    eval "$(echo $analysis_output | sed 's/\([^ ]*\)/fallback_video_data[\1/g;s/=/]=/g')"

    log_debug "Using fallback encoder for video-only: $FALLBACK_ENCODER"

    # Get streams to keep
    local -a stream_indices
    get_keepable_stream_indices "$input_file" stream_indices

    # Build map arguments
    local -a map_args
    local index
    for index in "${stream_indices[@]}"; do
        map_args+=("-map" "0:$index")
    done

    # Get fallback encoder arguments
    local -a fallback_args
    get_encoder_arguments "$FALLBACK_ENCODER" \
                         "${fallback_video_data[is_10bit]}" \
                         "${fallback_video_data[complexity]}" \
                         fallback_args

    # Build video filters
    local -a video_filters
    if ! build_video_filters "$input_file" video_filters; then
        log_warn "Failed to build video filters, proceeding without filters"
    fi

    # Build subtitle filters
    local -a subtitle_filters
    read -ra subtitle_filters <<< "$(build_subtitle_filters "$input_file")"

    # Build metadata arguments
    local -a metadata_args
    read -ra metadata_args <<< "$(build_metadata_args)"

    # Build performance arguments
    local -a perf_args
    read -ra perf_args <<< "$(build_performance_args)"

    # Build final output path
    local final_output
    if [[ "$output_file" == "${input_file}" ]]; then
        final_output="${input_file%.*}-TEMP-$$.mkv"
    else
        final_output="$output_file"
    fi

    # Execute fallback encoding
    if ffmpeg -i "$input_file" \
              "${map_args[@]}" \
              "${video_filters[@]}" \
              "${subtitle_filters[@]}" \
              "${metadata_args[@]}" \
              "${perf_args[@]}" \
              -f "$container_format" \
              "${fallback_args[@]}" \
              -c:a copy \
              -y "$final_output" 2>/dev/null; then

        if [[ "$final_output" != "$output_file" ]]; then
            safe_move "$final_output" "$output_file"
        else
            return 0
        fi
    else
        rm -f "$final_output"
        return 1
    fi
}
