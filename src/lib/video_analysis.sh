#!/bin/bash
# Video file analysis and metadata extraction

# Analyze video file and extract metadata
# Args: file_path output_array_name
analyze_video_file() {
    local file="$1"

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

    # Check for empty or invalid JSON
    if [[ -z "$video_info" ]] || ! echo "$video_info" | jq empty >/dev/null 2>&1; then
        log_error "Invalid or empty ffprobe output for: $file"
        return 1
    fi

    # Extract video and audio properties as key-value pairs
    extract_video_properties "$video_info"
    extract_audio_properties "$video_info"

    # Determine processing complexity
    local width height
    width=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .width // ""' | head -1)
    height=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .height // ""' | head -1)
    local complexity
    complexity=$(get_complexity_level "$width" "$height")
    echo "complexity=$complexity"

    # Detect 10-bit content
    detect_bit_depth "$video_info"

    log_debug "Analysis complete for: $file"
    return 0
}

# Validate video file before analysis
validate_video_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        log_error "File not found or not a regular file: $file"
        return 1
    fi
    if ! is_supported_format "$file"; then
        log_error "Unsupported file extension: $file"
        return 1
    fi
    return 0
}

# Extract video stream properties
# Args: video_info_json output_array_name
extract_video_properties() {
    local video_info="$1"
    local width height codec pix_fmt bit_depth duration frame_rate bitrate
    width=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .width // ""' | head -1)
    height=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .height // ""' | head -1)
    codec=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .codec_name // ""' | head -1)
    pix_fmt=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .pix_fmt // ""' | head -1)
    bit_depth=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .bits_per_raw_sample // "8"' | head -1)
    duration=$(echo "$video_info" | jq -r '.format.duration // ""')
    frame_rate=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .r_frame_rate // ""' | head -1)
    bitrate=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .bit_rate // ""' | head -1)
    echo "width=$width height=$height codec=$codec pix_fmt=$pix_fmt bit_depth=$bit_depth duration=$duration frame_rate=$frame_rate bitrate=$bitrate"
    log_debug "Video properties extracted: ${width}x${height} ${codec}"
}

# Extract audio stream information
# Args: video_info_json output_array_name
extract_audio_properties() {
    local video_info="$1"
    local audio_count channels_list surround_count non_surround_count
    audio_count=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="audio") | .index' | wc -l)
    channels_list=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="audio") | .channels // 0' | tr '\n' ',' | sed 's/,$//')
    surround_count=$(echo "$channels_list" | tr ',' '\n' | grep -c "6" || true)
    non_surround_count=$(echo "$channels_list" | tr ',' '\n' | grep -v "6" | grep -c "[12]" || true)
    echo "audio_count=$audio_count audio_channels=$channels_list surround_count=$surround_count non_surround_count=$non_surround_count"
    log_debug "Audio properties: $audio_count total streams, $surround_count surround, $non_surround_count stereo/mono"
}

# Detect if content is 10-bit
# Args: analysis_array_name
detect_bit_depth() {
    local video_info="$1"
    local pix_fmt bit_depth is_10bit="false"
    pix_fmt=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .pix_fmt // ""' | head -1)
    bit_depth=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .bits_per_raw_sample // "8"' | head -1)
    if [[ "$pix_fmt" == *"10le"* ]] || [[ "$pix_fmt" == *"p010"* ]] || [[ "$pix_fmt" == *"yuv420p10"* ]]; then
        is_10bit="true"
    fi
    if [[ "$bit_depth" == "10" ]]; then
        is_10bit="true"
    fi
    echo "is_10bit=$is_10bit"
    log_debug "10-bit content detection: $is_10bit (pix_fmt: $pix_fmt, bit_depth: $bit_depth)"
}

# Check if file needs audio processing
# Args: analysis_array_name (key-value string)
needs_audio_processing() {
    local audio_count non_surround_count surround_count
    local input="$1"
    # Parse key-value pairs
    for kv in $input; do
        case $kv in
            audio_count=*) audio_count="${kv#audio_count=}" ;;
            non_surround_count=*) non_surround_count="${kv#non_surround_count=}" ;;
            surround_count=*) surround_count="${kv#surround_count=}" ;;
        esac
    done
    [[ "$non_surround_count" == "0" && "$surround_count" -gt "0" ]]
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
    for supported_ext in "${SUPPORTED_INPUT_EXTENSIONS[@]}"; do
        if [[ "$extension" == "$supported_ext" ]]; then
            return 0
        fi
    done

    return 1
}

# Check if file is already optimally encoded
# Args: analysis_array_name (key-value string)
is_already_optimized() {
    local codec
    local input="$1"
    for kv in $input; do
        case $kv in
            codec=*) codec="${kv#codec=}" ;;
        esac
    done
    # Check if already HEVC with reasonable quality
    if [[ "$codec" == "hevc" ]]; then
        log_debug "File already uses HEVC codec"
        return 0
    fi
    return 1
}

# Determine processing complexity based on resolution
get_complexity_level() {
    log_debug "get_complexity_level: argc=$# 1='$1' 2='$2'"
    local width="" height=""
    if (( $# >= 1 )); then width="$1"; fi
    if (( $# >= 2 )); then height="$2"; fi
    if ! [[ "$width" =~ ^[0-9]+$ ]] || ! [[ "$height" =~ ^[0-9]+$ ]]; then
        log_warn "Unknown or invalid video resolution: width='$width' height='$height'. Defaulting to medium complexity."
        echo "medium"
        return 0
    fi
    local pixels=$((width * height))
    if [[ "$pixels" -ge "${HIGH_COMPLEXITY_THRESHOLD:-8000000}" ]]; then
        echo "high"
    elif [[ "$pixels" -ge "${MEDIUM_COMPLEXITY_THRESHOLD:-2000000}" ]]; then
        echo "medium"
    else
        echo "low"
    fi
}
