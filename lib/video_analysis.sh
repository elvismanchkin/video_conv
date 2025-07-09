#!/bin/bash
# Video file analysis and metadata extraction

# Analyze video file and extract metadata
# Args: file_path output_array_name
analyze_video_file() {
    local file="$1"
    local -n analysis=$2

    log_debug "Analyzing video file: $file"

    # Validate file first
    if ! validate_video_file "$file"; then
        return 1
    fi

    # Get comprehensive video information
    local video_info
    if ! video_info=$(ffprobe -v quiet -print_format json -show_streams -show_format "$file" 2>/dev/null); then
        log_error "Failed to probe video file: $file"
        return 1
    fi

    # Extract video stream properties
    extract_video_properties "$video_info" analysis

    # Extract audio stream information
    extract_audio_properties "$video_info" analysis

    # Determine processing complexity
    analysis["complexity"]=$(get_complexity_level "${analysis[width]}" "${analysis[height]}")

    # Detect 10-bit content
    detect_bit_depth analysis

    log_debug "Analysis complete for: $file"
    return 0
}

# Extract video stream properties
# Args: video_info_json output_array_name
extract_video_properties() {
    local video_info="$1"
    local -n video_props=$2

    # Extract primary video stream data
    video_props["width"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .width // "unknown"' | head -1)
    video_props["height"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .height // "unknown"' | head -1)
    video_props["codec"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .codec_name // "unknown"' | head -1)
    video_props["pix_fmt"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .pix_fmt // "unknown"' | head -1)
    video_props["bit_depth"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .bits_per_raw_sample // "8"' | head -1)

    # Duration and frame rate
    video_props["duration"]=$(echo "$video_info" | jq -r '.format.duration // "unknown"')
    video_props["frame_rate"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .r_frame_rate // "unknown"' | head -1)

    # Bitrate information
    video_props["bitrate"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .bit_rate // "unknown"' | head -1)

    log_debug "Video properties extracted: ${video_props[width]}x${video_props[height]} ${video_props[codec]}"
}

# Extract audio stream information
# Args: video_info_json output_array_name
extract_audio_properties() {
    local video_info="$1"
    local -n audio_props=$2

    # Count audio streams
    local audio_count
    audio_count=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="audio") | .index' | wc -l)
    audio_props["audio_count"]="$audio_count"

    # Get channel information for all audio streams
    local channels_list
    channels_list=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="audio") | .channels // 0' | tr '\n' ',' | sed 's/,$//')
    audio_props["audio_channels"]="$channels_list"

    # Identify 5.1 surround streams
    local surround_count
    surround_count=$(echo "$channels_list" | tr ',' '\n' | grep -c "6" || true)
    audio_props["surround_count"]="$surround_count"

    # Identify stereo/mono streams
    local non_surround_count
    non_surround_count=$(echo "$channels_list" | tr ',' '\n' | grep -v "6" | grep -c "[12]" || true)
    audio_props["non_surround_count"]="$non_surround_count"

    log_debug "Audio properties: $audio_count total streams, $surround_count surround, $non_surround_count stereo/mono"
}

# Detect if content is 10-bit
# Args: analysis_array_name
detect_bit_depth() {
    local -n bit_analysis=$1

    local is_10bit="false"

    # Check pixel format for 10-bit indicators
    if [[ "${bit_analysis[pix_fmt]}" == *"10le"* ]] ||
       [[ "${bit_analysis[pix_fmt]}" == *"p010"* ]] ||
       [[ "${bit_analysis[pix_fmt]}" == *"yuv420p10"* ]]; then
        is_10bit="true"
    fi

    # Check explicit bit depth
    if [[ "${bit_analysis[bit_depth]}" == "10" ]]; then
        is_10bit="true"
    fi

    bit_analysis["is_10bit"]="$is_10bit"

    log_debug "10-bit content detection: $is_10bit (pix_fmt: ${bit_analysis[pix_fmt]}, bit_depth: ${bit_analysis[bit_depth]})"
}

# Check if file needs audio processing
# Args: analysis_array_name
needs_audio_processing() {
    local -n audio_check=$1

    # If no non-surround audio tracks exist, we need to convert 5.1 to stereo
    [[ "${audio_check[non_surround_count]}" == "0" && "${audio_check[surround_count]}" -gt "0" ]]
}

# Get video stream indices that need processing
# Args: file_path output_array_name
get_video_stream_indices() {
    local file="$1"
    local -n indices=$2

    mapfile -t indices < <(ffprobe -v quiet -print_format json -show_streams "$file" | \
                          jq -r '.streams[] | select(.codec_type=="video") | .index')

    log_debug "Video stream indices: ${indices[*]}"
}

# Get audio stream indices by channel count
# Args: file_path channel_count output_array_name
get_audio_streams_by_channels() {
    local file="$1"
    local target_channels="$2"
    local -n stream_indices=$3

    mapfile -t stream_indices < <(ffprobe -v quiet -print_format json -show_streams "$file" | \
                                 jq -r ".streams[] | select(.codec_type==\"audio\" and .channels==$target_channels) | .index")

    log_debug "Audio streams with $target_channels channels: ${stream_indices[*]}"
}

# Get all non-video, non-surround streams (audio + subtitles)
# Args: file_path output_array_name
get_keepable_stream_indices() {
    local file="$1"
    local -n keep_indices=$2

    mapfile -t keep_indices < <(ffprobe -v quiet -print_format json -show_streams "$file" | \
                               jq -r '.streams[] | select(
                                   .codec_type=="video" or
                                   .codec_type=="subtitle" or
                                   (.codec_type=="audio" and .channels!=6)
                               ) | .index')

    log_debug "Keepable stream indices: ${keep_indices[*]}"
}

# Estimate encoding time based on complexity and encoder
# Args: duration_seconds encoder_type complexity_level
estimate_encoding_time() {
    local duration="$1"
    local encoder="$2"
    local complexity="$3"

    # Base multipliers for different encoders
    local multiplier
    case "$encoder" in
        NVENC)
            case "$complexity" in
                high) multiplier="0.3" ;;
                medium) multiplier="0.2" ;;
                *) multiplier="0.1" ;;
            esac
            ;;
        QSV)
            case "$complexity" in
                high) multiplier="0.4" ;;
                medium) multiplier="0.3" ;;
                *) multiplier="0.2" ;;
            esac
            ;;
        VAAPI)
            case "$complexity" in
                high) multiplier="0.5" ;;
                medium) multiplier="0.4" ;;
                *) multiplier="0.3" ;;
            esac
            ;;
        SOFTWARE)
            case "$complexity" in
                high) multiplier="2.0" ;;
                medium) multiplier="1.5" ;;
                *) multiplier="1.0" ;;
            esac
            ;;
        *)
            multiplier="1.0"
            ;;
    esac

    # Calculate estimated time
    local estimated_seconds
    estimated_seconds=$(echo "$duration * $multiplier" | bc -l 2>/dev/null || echo "$duration")

    printf "%.0f" "$estimated_seconds"
}

# Validate video file format compatibility
# Args: file_path
is_supported_format() {
    local file="$1"
    local extension="${file##*.}"
    extension="${extension,,}"  # Convert to lowercase

    local supported_ext
    for supported_ext in "${SUPPORTED_EXTENSIONS[@]}"; do
        if [[ "$extension" == "$supported_ext" ]]; then
            return 0
        fi
    done

    return 1
}

# Check if file is already optimally encoded
# Args: analysis_array_name
is_already_optimized() {
    local -n opt_check=$1

    # Check if already HEVC with reasonable quality
    if [[ "${opt_check[codec]}" == "hevc" ]]; then
        # Could add more sophisticated checks here
        # For now, just check codec
        log_debug "File already uses HEVC codec"
        return 0
    fi

    return 1
}
