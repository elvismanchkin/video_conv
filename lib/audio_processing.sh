#!/bin/bash
# Audio stream processing and conversion functions

# Process video file with encoder
# Args: input_file output_file file_analysis_array
process_with_encoder() {
    local input_file="$1"
    local output_file="$2"
    local -n file_data=$3

    log_debug "Processing with encoder: $SELECTED_ENCODER"

    # Determine if we need audio processing
    if needs_audio_processing file_data; then
        log_info "    Converting 5.1 audio to stereo + encoding with $SELECTED_ENCODER"
        process_with_audio_conversion "$input_file" "$output_file" file_data
    else
        log_info "    Encoding with $SELECTED_ENCODER"
        process_video_only "$input_file" "$output_file" file_data
    fi
}

# Process video with audio conversion (5.1 to stereo)
# Args: input_file output_file file_analysis_array
process_with_audio_conversion() {
    local input_file="$1"
    local output_file="$2"
    local -n audio_data=$3

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
    if ! convert_surround_audio "$input_file" "$temp_dir" audio_data; then
        log_error "Audio conversion failed"
        return 1
    fi

    # Encode video with converted audio
    if ! encode_with_converted_audio "$input_file" "$output_file" "$temp_dir" audio_data; then
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
    local -n conv_data=$3

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
    local -n encode_data=$4

    # Build FFmpeg inputs array
    local -a ffmpeg_inputs=("-i" "$input_file")
    local -a map_args=("-map" "0:v" "-map" "0:s?")  # Video and subtitles
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

    # Build final output path
    local final_output
    if [[ "$output_file" == "${input_file}" ]]; then
        final_output="${input_file%.*}-TEMP-$$.mkv"
    else
        final_output="$output_file"
    fi

    log_debug "Encoding with converted audio: ${#ffmpeg_inputs[@]} inputs"

    # Execute encoding
    if ffmpeg "${ffmpeg_inputs[@]}" \
              "${map_args[@]}" \
              -map_metadata 0 \
              "${encoder_args[@]}" \
              -c:a copy \
              -c:s copy \
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
            encode_with_fallback "$input_file" "$output_file" "$temp_dir" encode_data
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
    local -n video_data=$3

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

    # Build final output path
    local final_output
    if [[ "$output_file" == "${input_file}" ]]; then
        final_output="${input_file%.*}-TEMP-$$.mkv"
    else
        final_output="$output_file"
    fi

    log_debug "Encoding video-only: ${#map_args[@]} streams"

    # Execute encoding
    if ffmpeg -i "$input_file" \
              "${map_args[@]}" \
              "${encoder_args[@]}" \
              -c:a copy \
              -c:s copy \
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
            encode_video_with_fallback "$input_file" "$output_file" video_data
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
    local -n fallback_data=$4

    log_debug "Using fallback encoder: $FALLBACK_ENCODER"

    # Get fallback encoder arguments
    local -a fallback_args
    get_encoder_arguments "$FALLBACK_ENCODER" \
                         "${fallback_data[is_10bit]}" \
                         "${fallback_data[complexity]}" \
                         fallback_args

    # Rebuild inputs and maps (same as primary attempt)
    local -a ffmpeg_inputs=("-i" "$input_file")
    local -a map_args=("-map" "0:v" "-map" "0:s?")
    local audio_input_counter=1

    local converted_audio
    for converted_audio in "$temp_dir"/audio_*.m4a; do
        if [[ -f "$converted_audio" ]]; then
            ffmpeg_inputs+=("-i" "$converted_audio")
            map_args+=("-map" "$audio_input_counter:a")
            ((audio_input_counter++))
        fi
    done

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
              -map_metadata 0 \
              "${fallback_args[@]}" \
              -c:a copy \
              -c:s copy \
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
    local -n fallback_video_data=$3

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
              "${fallback_args[@]}" \
              -c:a copy \
              -c:s copy \
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
