#!/bin/bash

# ==============================================================================
# Self-Contained GPU Video Converter (v11)
#
# FEATURES:
# - Enhanced hardware detection with better fallback chains
# - Reduced verbosity with focused output
# - Improved VAAPI, NVENC, and QSV support
# - Better AMD APU and Intel iGPU detection
# - Automatic quality optimization per hardware type
#
# USAGE: ./cvrt_v11.sh [--replace] [--debug] [/path/to/directory]
#
# SETUP REQUIREMENTS:
#
# Ubuntu/Debian:
#   sudo apt update && sudo apt install ffmpeg vainfo jq
#   # For AMD: sudo apt install mesa-va-drivers
#   # For Intel: sudo apt install intel-media-va-driver
#   # For NVIDIA: sudo apt install libnvidia-encode-470 (or current driver version)
#
# Fedora:
#   sudo dnf install ffmpeg libva-utils jq mesa-va-drivers
#   # For better AMD support: sudo dnf install mesa-va-drivers-freeworld
#   # For Intel: sudo dnf install intel-media-driver
#   # For NVIDIA: Enable RPM Fusion, then: sudo dnf install nvidia-driver
#
# openSUSE:
#   sudo zypper install ffmpeg libva-utils jq libva-mesa-driver
#   # For Intel: sudo zypper install intel-media-driver
#   # For NVIDIA: sudo zypper install nvidia-video-G06 (or G05 for older cards)
#
# Arch Linux:
#   sudo pacman -S ffmpeg libva-utils jq libva-mesa-driver
#   # For Intel: sudo pacman -S intel-media-driver
#   # For NVIDIA: sudo pacman -S nvidia-utils
#
# Void Linux:
#   sudo xbps-install -S ffmpeg libva-utils jq mesa-vaapi-drivers
#   # For Intel: sudo xbps-install -S intel-media-driver
#   # For NVIDIA: sudo xbps-install -S nvidia
#
# ==============================================================================

# --- Configuration ---
QUALITY_PARAM=24
STEREO_BITRATE="192k"
DEBUG_MODE=false

# --- Hardware Detection Results ---
declare -A HW_SUPPORT
declare -A HW_DEVICES
declare -A ENCODER_CAPS
BEST_ENCODER=""
FALLBACK_ENCODER=""

# --- Argument Parsing ---
REPLACE_SOURCE=false
WORKDIR="."

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--replace)
            REPLACE_SOURCE=true
            echo "⚠️ Replace mode enabled"
            shift
            ;;
        -d|--debug)
            DEBUG_MODE=true
            echo "🔍 Debug mode enabled"
            shift
            ;;
        -*)
            echo "Unknown option $1"
            exit 1
            ;;
        *)
            WORKDIR="$1"
            shift
            ;;
    esac
done

if [ ! -d "$WORKDIR" ]; then
    echo "Error: Directory '$WORKDIR' not found."
    exit 1
fi

cd "$WORKDIR" || { echo "Error: Could not change to directory '$WORKDIR'."; exit 1; }

# --- Debug Output Function ---
debug_echo() {
    [ "$DEBUG_MODE" = true ] && echo "🔍 DEBUG: $*"
}

# --- Hardware Detection Functions ---
detect_cpu_info() {
    CPU_INFO=$(lscpu 2>/dev/null || cat /proc/cpuinfo 2>/dev/null)
    CPU_CORES=$(nproc 2>/dev/null || echo "4")
    
    if echo "$CPU_INFO" | grep -qi "AMD"; then
        CPU_VENDOR="AMD"
        CPU_MODEL=$(echo "$CPU_INFO" | grep -i "model name" | head -1 | cut -d: -f2 | xargs)
        # Better AMD APU detection
        if echo "$CPU_MODEL" | grep -qi "G\|APU\|PRO.*G\|GE\|Ryzen.*[0-9]G"; then
            HW_SUPPORT["AMD_INTEGRATED"]="true"
            debug_echo "AMD APU detected: $CPU_MODEL"
        fi
    elif echo "$CPU_INFO" | grep -qi "Intel"; then
        CPU_VENDOR="Intel"
        CPU_MODEL=$(echo "$CPU_INFO" | grep -i "model name" | head -1 | cut -d: -f2 | xargs)
        # Intel integrated graphics detection
        if lspci 2>/dev/null | grep -qi "Intel.*Graphics\|Intel.*Display\|Intel.*UHD\|Intel.*Iris"; then
            HW_SUPPORT["INTEL_INTEGRATED"]="true"
            debug_echo "Intel iGPU detected: $CPU_MODEL"
        fi
    else
        CPU_VENDOR="Unknown"
        CPU_MODEL="Unknown"
    fi
}

detect_gpu_hardware() {
    # NVIDIA detection
    if command -v nvidia-smi &>/dev/null; then
        NVIDIA_INFO=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | head -1)
        if [ -n "$NVIDIA_INFO" ]; then
            HW_SUPPORT["NVIDIA"]="true"
            debug_echo "NVIDIA GPU: $NVIDIA_INFO"
        fi
    fi
    
    # AMD discrete GPU detection
    if lspci 2>/dev/null | grep -qi "AMD.*Radeon\|AMD.*Graphics\|AMD.*RX\|AMD.*Pro"; then
        AMD_GPU_INFO=$(lspci 2>/dev/null | grep -i "AMD.*Radeon\|AMD.*Graphics\|AMD.*RX\|AMD.*Pro" | head -1 | sed 's/.*: //')
        HW_SUPPORT["AMD_DISCRETE"]="true"
        debug_echo "AMD GPU: $AMD_GPU_INFO"
    fi
    
    # Intel discrete GPU detection (Arc, etc.)
    if lspci 2>/dev/null | grep -qi "Intel.*Arc\|Intel.*Xe"; then
        INTEL_GPU_INFO=$(lspci 2>/dev/null | grep -i "Intel.*Arc\|Intel.*Xe" | head -1 | sed 's/.*: //')
        HW_SUPPORT["INTEL_DISCRETE"]="true"
        debug_echo "Intel dGPU: $INTEL_GPU_INFO"
    fi
}

detect_vaapi_support() {
    # Test multiple render devices for best compatibility
    for device in /dev/dri/renderD*; do
        if [ -c "$device" ]; then
            debug_echo "Testing VAAPI: $device"
            
            if command -v vainfo &>/dev/null; then
                VAAPI_INFO=$(vainfo --display drm --device "$device" 2>/dev/null)
                if [ $? -eq 0 ]; then
                    HW_DEVICES["VAAPI"]="$device"
                    debug_echo "VAAPI info for $device:"
                    debug_echo "$VAAPI_INFO"
                    
                    # Check encoding capabilities
                    if echo "$VAAPI_INFO" | grep -q "VAProfileHEVCMain.*VAEntrypointEncSlice"; then
                        ENCODER_CAPS["VAAPI_HEVC"]="true"
                        debug_echo "VAAPI HEVC encoding detected"
                        
                        # 10-bit support check
                        if echo "$VAAPI_INFO" | grep -q "VAProfileHEVCMain10.*VAEntrypointEncSlice"; then
                            ENCODER_CAPS["VAAPI_HEVC_10BIT"]="true"
                            debug_echo "VAAPI HEVC 10-bit encoding detected"
                        fi
                    fi
                    
                    # H.264 fallback
                    if echo "$VAAPI_INFO" | grep -qi "VAEntrypointEncSlice.*H264"; then
                        ENCODER_CAPS["VAAPI_H264"]="true"
                    fi
                    
                    # AV1 encoding support (newer AMD/Intel)
                    if echo "$VAAPI_INFO" | grep -qi "VAEntrypointEncSlice.*AV1"; then
                        ENCODER_CAPS["VAAPI_AV1"]="true"
                    fi
                    
                    break
                fi
            fi
        fi
    done
}

detect_nvenc_support() {
    if [ "${HW_SUPPORT[NVIDIA]}" = "true" ]; then
        # Quick NVENC capability test
        if ffmpeg -f lavfi -i testsrc2=duration=1:size=320x240:rate=1 -c:v h264_nvenc -f null - &>/dev/null; then
            ENCODER_CAPS["NVENC_H264"]="true"
            
            # HEVC test
            if ffmpeg -f lavfi -i testsrc2=duration=1:size=320x240:rate=1 -c:v hevc_nvenc -f null - &>/dev/null; then
                ENCODER_CAPS["NVENC_HEVC"]="true"
                
                # 10-bit test
                if ffmpeg -f lavfi -i testsrc2=duration=1:size=320x240:rate=1 -c:v hevc_nvenc -profile:v main10 -f null - &>/dev/null; then
                    ENCODER_CAPS["NVENC_HEVC_10BIT"]="true"
                fi
                
                # AV1 encoding (RTX 40 series and newer)
                if ffmpeg -f lavfi -i testsrc2=duration=1:size=320x240:rate=1 -c:v av1_nvenc -f null - &>/dev/null; then
                    ENCODER_CAPS["NVENC_AV1"]="true"
                fi
            fi
        fi
    fi
}

detect_qsv_support() {
    if [ "${HW_SUPPORT[INTEL_INTEGRATED]}" = "true" ] || [ "${HW_SUPPORT[INTEL_DISCRETE]}" = "true" ]; then
        # QSV capability test
        if ffmpeg -f lavfi -i testsrc2=duration=1:size=320x240:rate=1 -c:v h264_qsv -f null - &>/dev/null; then
            ENCODER_CAPS["QSV_H264"]="true"
            
            # HEVC test
            if ffmpeg -f lavfi -i testsrc2=duration=1:size=320x240:rate=1 -c:v hevc_qsv -f null - &>/dev/null; then
                ENCODER_CAPS["QSV_HEVC"]="true"
                
                # 10-bit test
                if ffmpeg -f lavfi -i testsrc2=duration=1:size=320x240:rate=1 -c:v hevc_qsv -profile:v main10 -f null - &>/dev/null; then
                    ENCODER_CAPS["QSV_HEVC_10BIT"]="true"
                fi
                
                # AV1 encoding (Arc and newer Intel)
                if ffmpeg -f lavfi -i testsrc2=duration=1:size=320x240:rate=1 -c:v av1_qsv -f null - &>/dev/null; then
                    ENCODER_CAPS["QSV_AV1"]="true"
                fi
            fi
        fi
    fi
}

determine_best_encoder() {
    # Smart encoder selection with quality priority
    local encoder_score=0
    local best_score=0
    
    # NVENC scoring (high quality, fast)
    if [ "${ENCODER_CAPS[NVENC_HEVC]}" = "true" ]; then
        encoder_score=100
        [ "${ENCODER_CAPS[NVENC_HEVC_10BIT]}" = "true" ] && encoder_score=$((encoder_score + 20))
        [ "${ENCODER_CAPS[NVENC_AV1]}" = "true" ] && encoder_score=$((encoder_score + 30))
        if [ $encoder_score -gt $best_score ]; then
            BEST_ENCODER="NVENC"
            best_score=$encoder_score
        fi
    fi
    
    # QSV scoring (good quality, efficient)
    encoder_score=0
    if [ "${ENCODER_CAPS[QSV_HEVC]}" = "true" ]; then
        encoder_score=90
        [ "${ENCODER_CAPS[QSV_HEVC_10BIT]}" = "true" ] && encoder_score=$((encoder_score + 15))
        [ "${ENCODER_CAPS[QSV_AV1]}" = "true" ] && encoder_score=$((encoder_score + 25))
        if [ $encoder_score -gt $best_score ]; then
            BEST_ENCODER="QSV"
            best_score=$encoder_score
        fi
    fi
    
    # VAAPI scoring (variable quality, depends on driver)
    encoder_score=0
    if [ "${ENCODER_CAPS[VAAPI_HEVC]}" = "true" ]; then
        encoder_score=80
        [ "${ENCODER_CAPS[VAAPI_HEVC_10BIT]}" = "true" ] && encoder_score=$((encoder_score + 10))
        [ "${ENCODER_CAPS[VAAPI_AV1]}" = "true" ] && encoder_score=$((encoder_score + 20))
        if [ $encoder_score -gt $best_score ]; then
            BEST_ENCODER="VAAPI"
            best_score=$encoder_score
        fi
    fi
    
    # Software fallback
    if [ -z "$BEST_ENCODER" ]; then
        BEST_ENCODER="SOFTWARE"
    fi
    
    # Set fallback encoder
    if [ "$BEST_ENCODER" != "SOFTWARE" ]; then
        FALLBACK_ENCODER="SOFTWARE"
    fi
}

analyze_video_file() {
    local file="$1"
    local -n analysis_result=$2
    
    debug_echo "Analyzing: $file"
    
    local video_info=$(ffprobe -v quiet -print_format json -show_streams -show_format "$file" 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$video_info" ]; then
        echo "❌ Cannot analyze '$file'"
        return 1
    fi
    
    # Extract key properties
    analysis_result["pix_fmt"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .pix_fmt // "unknown"' | head -1)
    analysis_result["bit_depth"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .bits_per_raw_sample // "8"' | head -1)
    analysis_result["width"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .width // "unknown"' | head -1)
    analysis_result["height"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .height // "unknown"' | head -1)
    analysis_result["codec"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .codec_name // "unknown"' | head -1)
    
    # Audio analysis
    local audio_streams=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="audio")')
    analysis_result["audio_channels"]=$(echo "$audio_streams" | jq -r '.channels // 0' | tr '\n' ',' | sed 's/,$//')
    analysis_result["audio_count"]=$(echo "$audio_streams" | jq -r '.index' | wc -l)
    
    # 10-bit detection
    if [[ "${analysis_result[pix_fmt]}" == *"10le"* ]] || [[ "${analysis_result[pix_fmt]}" == *"p010"* ]] || [[ "${analysis_result[bit_depth]}" == "10" ]]; then
        analysis_result["is_10bit"]="true"
    else
        analysis_result["is_10bit"]="false"
    fi
    
    # Resolution-based complexity
    local pixels=$((${analysis_result[width]} * ${analysis_result[height]}))
    if [ "$pixels" -gt 8000000 ]; then
        analysis_result["complexity"]="high"
    elif [ "$pixels" -gt 2000000 ]; then
        analysis_result["complexity"]="medium"
    else
        analysis_result["complexity"]="low"
    fi
}

get_encoder_args() {
    local encoder_type="$1"
    local is_10bit="$2"
    local complexity="$3"
    local -n encoder_args_ref=$4
    
    encoder_args_ref=()
    
    case "$encoder_type" in
        "NVENC")
            encoder_args_ref+=("-c:v" "hevc_nvenc")
            
            # Profile and pixel format
            if [ "$is_10bit" = "true" ] && [ "${ENCODER_CAPS[NVENC_HEVC_10BIT]}" = "true" ]; then
                encoder_args_ref+=("-profile:v" "main10" "-pix_fmt" "p010le")
            else
                encoder_args_ref+=("-profile:v" "main" "-pix_fmt" "yuv420p")
            fi
            
            # Quality optimization by complexity
            case "$complexity" in
                "high")
                    encoder_args_ref+=("-cq" "$QUALITY_PARAM" "-preset" "p4" "-rc" "vbr" "-multipass" "2")
                    ;;
                "medium")
                    encoder_args_ref+=("-cq" "$QUALITY_PARAM" "-preset" "p3" "-rc" "vbr")
                    ;;
                *)
                    encoder_args_ref+=("-cq" "$QUALITY_PARAM" "-preset" "p2" "-rc" "vbr")
                    ;;
            esac
            
            encoder_args_ref+=("-b:v" "0" "-maxrate" "50M" "-bufsize" "100M" "-spatial_aq" "1" "-temporal_aq" "1")
            ;;
            
        "QSV")
            encoder_args_ref+=("-c:v" "hevc_qsv")
            
            # Profile setup
            if [ "$is_10bit" = "true" ] && [ "${ENCODER_CAPS[QSV_HEVC_10BIT]}" = "true" ]; then
                encoder_args_ref+=("-profile:v" "main10" "-pix_fmt" "p010le")
            else
                encoder_args_ref+=("-profile:v" "main" "-pix_fmt" "nv12")
            fi
            
            # Quality settings
            case "$complexity" in
                "high")
                    encoder_args_ref+=("-global_quality" "$QUALITY_PARAM" "-preset" "veryslow" "-look_ahead" "1")
                    ;;
                "medium")
                    encoder_args_ref+=("-global_quality" "$QUALITY_PARAM" "-preset" "medium" "-look_ahead" "1")
                    ;;
                *)
                    encoder_args_ref+=("-global_quality" "$QUALITY_PARAM" "-preset" "fast")
                    ;;
            esac
            
            encoder_args_ref+=("-load_plugin" "hevc_hw")
            ;;
            
        "VAAPI")
            encoder_args_ref+=(
                "-init_hw_device" "vaapi=hw:${HW_DEVICES[VAAPI]}"
                "-filter_hw_device" "hw"
                "-c:v" "hevc_vaapi"
            )
            
            # Pixel format and profile
            if [ "$is_10bit" = "true" ] && [ "${ENCODER_CAPS[VAAPI_HEVC_10BIT]}" = "true" ]; then
                encoder_args_ref+=("-vf" "format=p010le,hwupload" "-profile:v" "main10")
            else
                encoder_args_ref+=("-vf" "format=nv12,hwupload" "-profile:v" "main")
            fi
            
            # Quality parameter and keyframes
            encoder_args_ref+=("-qp" "$QUALITY_PARAM" "-g" "250" "-keyint_min" "25")
            
            # Hardware-specific optimizations
            if [ "${HW_SUPPORT[AMD_DISCRETE]}" = "true" ] || [ "${HW_SUPPORT[AMD_INTEGRATED]}" = "true" ]; then
                # AMD VAAPI optimizations
                encoder_args_ref+=("-quality" "1" "-compression_level" "1")
                case "$complexity" in
                    "high")
                        encoder_args_ref+=("-bf" "3" "-refs" "3")
                        ;;
                    "medium")
                        encoder_args_ref+=("-bf" "2" "-refs" "2")
                        ;;
                    *)
                        encoder_args_ref+=("-bf" "0" "-refs" "1")
                        ;;
                esac
            elif [ "${HW_SUPPORT[INTEL_INTEGRATED]}" = "true" ] || [ "${HW_SUPPORT[INTEL_DISCRETE]}" = "true" ]; then
                # Intel VAAPI optimizations
                encoder_args_ref+=("-quality" "4")
                case "$complexity" in
                    "high")
                        encoder_args_ref+=("-bf" "4" "-refs" "4")
                        ;;
                    *)
                        encoder_args_ref+=("-bf" "2" "-refs" "2")
                        ;;
                esac
            fi
            ;;
            
        "SOFTWARE")
            encoder_args_ref+=("-c:v" "libx265")
            
            # Pixel format and profile
            if [ "$is_10bit" = "true" ]; then
                encoder_args_ref+=("-profile:v" "main10" "-pix_fmt" "yuv420p10le")
            else
                encoder_args_ref+=("-profile:v" "main" "-pix_fmt" "yuv420p")
            fi
            
            encoder_args_ref+=("-crf" "$QUALITY_PARAM")
            
            # CPU-optimized presets
            case "$complexity" in
                "high")
                    if [ "$CPU_CORES" -gt 12 ]; then
                        encoder_args_ref+=("-preset" "slow" "-x265-params" "pools=$CPU_CORES:frame-threads=4")
                    elif [ "$CPU_CORES" -gt 8 ]; then
                        encoder_args_ref+=("-preset" "medium" "-x265-params" "pools=$CPU_CORES:frame-threads=3")
                    else
                        encoder_args_ref+=("-preset" "medium" "-x265-params" "pools=$CPU_CORES:frame-threads=2")
                    fi
                    ;;
                "medium")
                    encoder_args_ref+=("-preset" "medium" "-x265-params" "pools=$CPU_CORES")
                    ;;
                *)
                    encoder_args_ref+=("-preset" "fast" "-x265-params" "pools=$CPU_CORES")
                    ;;
            esac
            
            # CPU vendor optimizations
            if [ "$CPU_VENDOR" = "AMD" ]; then
                encoder_args_ref+=("-x265-params" "pools=+:numa-pools=$(((CPU_CORES + 7) / 8))")
            fi
            ;;
    esac
}

check_ram_disk() {
    SHM_PATH="/dev/shm"
    CAN_USE_SHM=false
    if [ -d "$SHM_PATH" ]; then
        available_gb=$(df -BG "$SHM_PATH" | awk 'NR==2 {print $4}' | sed 's/G//')
        if [ "$available_gb" -gt 1 ]; then
            CAN_USE_SHM=true
        fi
    fi
}

# --- Hardware Detection ---
echo "🔍 Detecting hardware capabilities..."
detect_cpu_info
detect_gpu_hardware
detect_vaapi_support
detect_nvenc_support
detect_qsv_support
determine_best_encoder
check_ram_disk

# --- Hardware Summary ---
echo "📊 $CPU_VENDOR $CPU_CORES-core | Encoder: $BEST_ENCODER"
[ -n "$FALLBACK_ENCODER" ] && echo "   Fallback: $FALLBACK_ENCODER"
echo

# --- File Processing ---
success_count=0
skipped_count=0
failed_count=0
file_list=$(ls *.mkv 2> /dev/null)
total_files=$(echo "$file_list" | wc -w)

echo "🎬 Processing $total_files .mkv file(s) in: $(pwd)"
echo

# --- Main Processing Loop ---
for file in $file_list; do
    [ -f "$file" ] || continue
    
    # Analyze file
    declare -A file_analysis
    if ! analyze_video_file "$file" file_analysis; then
        ((failed_count++))
        continue
    fi

    echo "📹 $file"
    echo "   ${file_analysis[codec]} ${file_analysis[width]}x${file_analysis[height]} (${file_analysis[bit_depth]}bit) | ${file_analysis[audio_count]} audio tracks"

    # Output path logic
    if [ "$REPLACE_SOURCE" = true ]; then
        final_destination_path="$file"
    else
        final_destination_path="${file%.*}-converted.mkv"
    fi

    # RAM disk usage
    USE_SHM_FOR_FILE=false
    if [ "$CAN_USE_SHM" = true ]; then
        available_kb=$(df -k "$SHM_PATH" | awk 'NR==2 {print $4}')
        required_kb=$(du -k "$file" | cut -f1)
        if (( available_kb > required_kb )); then
            USE_SHM_FOR_FILE=true
            ffmpeg_output_path="$SHM_PATH/conv-temp-$$_$(basename "$file")"
        fi
    fi

    if [ "$USE_SHM_FOR_FILE" != true ]; then
        if [ "$REPLACE_SOURCE" = true ]; then
            ffmpeg_output_path="${file%.*}-TEMP-$$.mkv"
        else
            ffmpeg_output_path="$final_destination_path"
        fi
    fi

    # Get encoder arguments
    declare -a encoder_args
    get_encoder_args "$BEST_ENCODER" "${file_analysis[is_10bit]}" "${file_analysis[complexity]}" encoder_args

    # Audio processing
    valid_audio_count=$(echo "${file_analysis[audio_channels]}" | tr ',' '\n' | grep -v "6" | wc -l)
    
    conversion_status=1
    
    if [ "$valid_audio_count" -eq 0 ]; then
        echo "   🔄 Converting 5.1→stereo + encoding with $BEST_ENCODER..."
        
        # 5.1 to stereo conversion
        mapfile -t five_one_indices < <(ffprobe -v quiet -print_format json -show_streams "$file" | \
                                          jq -r '.streams[] | select(.codec_type=="audio" and .channels==6) | .index')

        if [ ${#five_one_indices[@]} -eq 0 ]; then
            echo "   ⏭️ No audio streams found"
            ((skipped_count++))
            continue
        fi

        TEMP_DIR_BASE=""
        [ "$USE_SHM_FOR_FILE" = true ] && TEMP_DIR_BASE="$SHM_PATH"
        
        if [ -n "$TEMP_DIR_BASE" ]; then
            TEMP_DIR=$(mktemp -d -p "$TEMP_DIR_BASE")
        else
            TEMP_DIR=$(mktemp -d)
        fi
        trap 'rm -rf -- "$TEMP_DIR"' EXIT

        ffmpeg_inputs=("-i" "$file")
        map_args=("-map" "0:v" "-map" "0:s?")
        audio_input_counter=1

        for index in "${five_one_indices[@]}"; do
            output_audio="$TEMP_DIR/audio_$index.m4a"
            ffmpeg -y -i "$file" -map "0:$index" -c:a aac -ac 2 -b:a "$STEREO_BITRATE" "$output_audio" &> /dev/null
            if [ $? -eq 0 ]; then
                ffmpeg_inputs+=("-i" "$output_audio")
                map_args+=("-map" "$audio_input_counter:a")
                ((audio_input_counter++))
            fi
        done

        if [ $audio_input_counter -eq 1 ]; then
            echo "   ❌ Audio conversion failed"
            ((failed_count++))
            trap - EXIT
            rm -rf -- "$TEMP_DIR"
            continue
        fi
        
        debug_echo "Encoder: ${encoder_args[*]}"
        
        ffmpeg "${ffmpeg_inputs[@]}" "${map_args[@]}" -map_metadata 0 \
               "${encoder_args[@]}" -c:a copy -c:s copy -y "$ffmpeg_output_path"
        conversion_status=$?
        
        trap - EXIT
        rm -rf -- "$TEMP_DIR"

    else
        echo "   🔄 Encoding with $BEST_ENCODER..."
        debug_echo "Encoder: ${encoder_args[*]}"
        
        # Keep non-5.1 tracks
        mapfile -t stream_indices < <(ffprobe -v quiet -print_format json -show_streams "$file" | \
                                      jq -r '.streams[] | select(.codec_type=="video" or .codec_type=="subtitle" or (.codec_type=="audio" and .channels!=6)) | .index')
        map_args=()
        for index in "${stream_indices[@]}"; do
            map_args+=("-map" "0:$index")
        done

        ffmpeg -i "$file" "${map_args[@]}" "${encoder_args[@]}" \
               -c:a copy -c:s copy -y "$ffmpeg_output_path"
        conversion_status=$?
    fi

    # Fallback to software encoding
    if [ $conversion_status -ne 0 ] && [ "$BEST_ENCODER" != "SOFTWARE" ]; then
        echo "   ⚠️ Hardware encoding failed, trying software..."
        
        declare -a fallback_args
        get_encoder_args "$FALLBACK_ENCODER" "${file_analysis[is_10bit]}" "${file_analysis[complexity]}" fallback_args
        
        debug_echo "Fallback: ${fallback_args[*]}"
        
        if [ "$valid_audio_count" -eq 0 ]; then
            # Retry 5.1 conversion with software
            TEMP_DIR_BASE=""
            [ "$USE_SHM_FOR_FILE" = true ] && TEMP_DIR_BASE="$SHM_PATH"
            
            if [ -n "$TEMP_DIR_BASE" ]; then
                TEMP_DIR=$(mktemp -d -p "$TEMP_DIR_BASE")
            else
                TEMP_DIR=$(mktemp -d)
            fi
            trap 'rm -rf -- "$TEMP_DIR"' EXIT

            ffmpeg_inputs=("-i" "$file")
            map_args=("-map" "0:v" "-map" "0:s?")
            audio_input_counter=1

            for index in "${five_one_indices[@]}"; do
                output_audio="$TEMP_DIR/audio_$index.m4a"
                ffmpeg -y -i "$file" -map "0:$index" -c:a aac -ac 2 -b:a "$STEREO_BITRATE" "$output_audio" &> /dev/null
                if [ $? -eq 0 ]; then
                    ffmpeg_inputs+=("-i" "$output_audio")
                    map_args+=("-map" "$audio_input_counter:a")
                    ((audio_input_counter++))
                fi
            done

            ffmpeg "${ffmpeg_inputs[@]}" "${map_args[@]}" -map_metadata 0 \
                   "${fallback_args[@]}" -c:a copy -c:s copy -y "$ffmpeg_output_path"
            conversion_status=$?
            
            trap - EXIT
            rm -rf -- "$TEMP_DIR"
        else
            ffmpeg -i "$file" "${map_args[@]}" "${fallback_args[@]}" \
                   -c:a copy -c:s copy -y "$ffmpeg_output_path"
            conversion_status=$?
        fi
    fi

    # Finalization
    if [ $conversion_status -eq 0 ]; then
        if [ "$ffmpeg_output_path" != "$final_destination_path" ]; then
            mv -f "$ffmpeg_output_path" "$final_destination_path"
            if [ $? -eq 0 ]; then
                [ "$REPLACE_SOURCE" = true ] && echo "   ✅ Replaced original" || echo "   ✅ Created: $(basename "$final_destination_path")"
                ((success_count++))
            else
                echo "   ❌ Move failed"
                ((failed_count++))
            fi
        else
            echo "   ✅ Created: $(basename "$final_destination_path")"
            ((success_count++))
        fi
    else
        echo "   ❌ Encoding failed"
        rm -f "$ffmpeg_output_path"
        ((failed_count++))
    fi
    
    unset file_analysis
    echo
done

# --- Final Summary ---
echo "📊 Results: ✅ $success_count successful | ❌ $failed_count failed | ⏭️ $skipped_count skipped"

if [ $success_count -gt 0 ]; then
    echo "🎉 Conversion completed using: $BEST_ENCODER"
fi

if [ $failed_count -gt 0 ]; then
    echo "⚠️ Some files failed. Run with --debug for details."
fi