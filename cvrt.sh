#!/bin/bash

# ==============================================================================
# Self-Contained GPU Video Converter (v7.0)
#
# NEW in v7.0:
# - Comprehensive hardware detection and capability analysis
# - Auto-detection of optimal encoding settings based on hardware
# - Per-file analysis and encoding parameter optimization
# - Fallback chain: GPU -> CPU with hardware-specific optimizations
# - Support for Intel QSV, AMD VAAPI, and NVIDIA NVENC
#
# USAGE: ./cvrt_v7.sh [--replace] [--debug] [/path/to/directory]
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
            echo "⚠️ Replace mode enabled. Source files will be overwritten on success."
            shift
            ;;
        -d|--debug)
            DEBUG_MODE=true
            echo "🔍 Debug mode enabled."
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
    echo "--- 🔍 Analyzing CPU Capabilities ---"
    
    CPU_INFO=$(lscpu 2>/dev/null || cat /proc/cpuinfo 2>/dev/null)
    CPU_CORES=$(nproc 2>/dev/null || echo "4")
    
    if echo "$CPU_INFO" | grep -qi "AMD"; then
        CPU_VENDOR="AMD"
        CPU_MODEL=$(echo "$CPU_INFO" | grep -i "model name" | head -1 | cut -d: -f2 | xargs)
        # Check for integrated graphics
        if echo "$CPU_MODEL" | grep -qi "G\|APU"; then
            HW_SUPPORT["AMD_INTEGRATED"]="true"
            debug_echo "AMD APU with integrated graphics detected"
        fi
    elif echo "$CPU_INFO" | grep -qi "Intel"; then
        CPU_VENDOR="Intel"
        CPU_MODEL=$(echo "$CPU_INFO" | grep -i "model name" | head -1 | cut -d: -f2 | xargs)
        # Check for integrated graphics
        if lspci 2>/dev/null | grep -qi "Intel.*Graphics\|Intel.*Display"; then
            HW_SUPPORT["INTEL_INTEGRATED"]="true"
            debug_echo "Intel CPU with integrated graphics detected"
        fi
    else
        CPU_VENDOR="Unknown"
        CPU_MODEL="Unknown"
    fi
    
    echo "   CPU: $CPU_VENDOR - $CPU_MODEL"
    echo "   Cores: $CPU_CORES"
}

detect_gpu_hardware() {
    echo "--- 🔍 Analyzing GPU Hardware ---"
    
    # Check for NVIDIA GPUs
    if command -v nvidia-smi &>/dev/null; then
        NVIDIA_INFO=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader,nounits 2>/dev/null)
        if [ -n "$NVIDIA_INFO" ]; then
            HW_SUPPORT["NVIDIA"]="true"
            echo "   ✅ NVIDIA GPU detected: $NVIDIA_INFO"
            debug_echo "NVIDIA driver and nvidia-smi available"
        fi
    fi
    
    # Check for AMD GPUs via lspci
    if lspci 2>/dev/null | grep -qi "AMD.*Radeon\|AMD.*Graphics"; then
        AMD_GPU_INFO=$(lspci 2>/dev/null | grep -i "AMD.*Radeon\|AMD.*Graphics" | head -1)
        HW_SUPPORT["AMD_DISCRETE"]="true"
        echo "   ✅ AMD GPU detected: $AMD_GPU_INFO"
        debug_echo "AMD discrete GPU found via lspci"
    fi
    
    # Check for Intel GPUs
    if lspci 2>/dev/null | grep -qi "Intel.*Graphics\|Intel.*Display"; then
        INTEL_GPU_INFO=$(lspci 2>/dev/null | grep -i "Intel.*Graphics\|Intel.*Display" | head -1)
        HW_SUPPORT["INTEL_GPU"]="true"
        echo "   ✅ Intel GPU detected: $INTEL_GPU_INFO"
        debug_echo "Intel GPU found via lspci"
    fi
}

detect_vaapi_support() {
    echo "--- 🔍 Testing VAAPI Support ---"
    
    # Find available render devices
    for device in /dev/dri/renderD*; do
        if [ -c "$device" ]; then
            debug_echo "Testing VAAPI device: $device"
            
            # Test VAAPI functionality
            if command -v vainfo &>/dev/null; then
                VAAPI_INFO=$(vainfo --display drm --device "$device" 2>/dev/null)
                if [ $? -eq 0 ]; then
                    HW_DEVICES["VAAPI"]="$device"
                    
                    # Check for HEVC encoding support
                    if echo "$VAAPI_INFO" | grep -qi "VAEntrypointEncSlice.*HEVC\|VAEntrypointEncSliceLP.*HEVC"; then
                        ENCODER_CAPS["VAAPI_HEVC"]="true"
                        echo "   ✅ VAAPI HEVC encoding supported on $device"
                        
                        # Check for 10-bit support
                        if echo "$VAAPI_INFO" | grep -qi "VAProfileHEVCMain10"; then
                            ENCODER_CAPS["VAAPI_HEVC_10BIT"]="true"
                            echo "   ✅ VAAPI 10-bit HEVC encoding supported"
                        fi
                    fi
                    
                    # Check for H.264 encoding as fallback
                    if echo "$VAAPI_INFO" | grep -qi "VAEntrypointEncSlice.*H264"; then
                        ENCODER_CAPS["VAAPI_H264"]="true"
                        echo "   ✅ VAAPI H.264 encoding supported"
                    fi
                    
                    break
                fi
            fi
        fi
    done
    
    [ -z "${HW_DEVICES[VAAPI]}" ] && echo "   ❌ No working VAAPI devices found"
}

detect_nvenc_support() {
    echo "--- 🔍 Testing NVENC Support ---"
    
    if [ "${HW_SUPPORT[NVIDIA]}" = "true" ]; then
        # Test NVENC with a simple probe
        if ffmpeg -f lavfi -i testsrc2=duration=1:size=320x240:rate=1 -c:v h264_nvenc -f null - &>/dev/null; then
            ENCODER_CAPS["NVENC_H264"]="true"
            echo "   ✅ NVENC H.264 encoding supported"
            
            # Test HEVC NVENC
            if ffmpeg -f lavfi -i testsrc2=duration=1:size=320x240:rate=1 -c:v hevc_nvenc -f null - &>/dev/null; then
                ENCODER_CAPS["NVENC_HEVC"]="true"
                echo "   ✅ NVENC HEVC encoding supported"
                
                # Test 10-bit support
                if ffmpeg -f lavfi -i testsrc2=duration=1:size=320x240:rate=1 -c:v hevc_nvenc -profile:v main10 -f null - &>/dev/null; then
                    ENCODER_CAPS["NVENC_HEVC_10BIT"]="true"
                    echo "   ✅ NVENC 10-bit HEVC encoding supported"
                fi
            fi
        else
            echo "   ❌ NVENC not available or not working"
        fi
    fi
}

detect_qsv_support() {
    echo "--- 🔍 Testing Intel QSV Support ---"
    
    if [ "${HW_SUPPORT[INTEL_GPU]}" = "true" ] || [ "${HW_SUPPORT[INTEL_INTEGRATED]}" = "true" ]; then
        # Test QSV with a simple probe
        if ffmpeg -f lavfi -i testsrc2=duration=1:size=320x240:rate=1 -c:v h264_qsv -f null - &>/dev/null; then
            ENCODER_CAPS["QSV_H264"]="true"
            echo "   ✅ Intel QSV H.264 encoding supported"
            
            # Test HEVC QSV
            if ffmpeg -f lavfi -i testsrc2=duration=1:size=320x240:rate=1 -c:v hevc_qsv -f null - &>/dev/null; then
                ENCODER_CAPS["QSV_HEVC"]="true"
                echo "   ✅ Intel QSV HEVC encoding supported"
                
                # Test 10-bit support
                if ffmpeg -f lavfi -i testsrc2=duration=1:size=320x240:rate=1 -c:v hevc_qsv -profile:v main10 -f null - &>/dev/null; then
                    ENCODER_CAPS["QSV_HEVC_10BIT"]="true"
                    echo "   ✅ Intel QSV 10-bit HEVC encoding supported"
                fi
            fi
        else
            echo "   ❌ Intel QSV not available or not working"
        fi
    fi
}

determine_best_encoder() {
    echo "--- 🎯 Determining Optimal Encoder ---"
    
    # Priority order: NVENC > QSV > VAAPI > Software
    if [ "${ENCODER_CAPS[NVENC_HEVC]}" = "true" ]; then
        BEST_ENCODER="NVENC"
        echo "   🏆 Best encoder: NVIDIA NVENC"
    elif [ "${ENCODER_CAPS[QSV_HEVC]}" = "true" ]; then
        BEST_ENCODER="QSV"
        echo "   🏆 Best encoder: Intel QSV"
    elif [ "${ENCODER_CAPS[VAAPI_HEVC]}" = "true" ]; then
        BEST_ENCODER="VAAPI"
        echo "   🏆 Best encoder: AMD VAAPI"
    else
        BEST_ENCODER="SOFTWARE"
        echo "   🏆 Best encoder: Software (libx265)"
    fi
    
    # Determine fallback
    if [ "$BEST_ENCODER" != "SOFTWARE" ]; then
        FALLBACK_ENCODER="SOFTWARE"
        echo "   🔄 Fallback encoder: Software (libx265)"
    fi
}

# --- File Analysis Functions ---
analyze_video_file() {
    local file="$1"
    local -n analysis_result=$2
    
    debug_echo "Analyzing file: $file"
    
    # Get comprehensive video info
    local video_info=$(ffprobe -v quiet -print_format json -show_streams -show_format "$file" 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$video_info" ]; then
        echo "❌ Error: Could not analyze '$file'"
        return 1
    fi
    
    # Extract video stream info
    analysis_result["pix_fmt"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .pix_fmt // "unknown"' | head -1)
    analysis_result["bit_depth"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .bits_per_raw_sample // "unknown"' | head -1)
    analysis_result["width"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .width // "unknown"' | head -1)
    analysis_result["height"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .height // "unknown"' | head -1)
    analysis_result["codec"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .codec_name // "unknown"' | head -1)
    analysis_result["fps"]=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="video") | .r_frame_rate // "unknown"' | head -1)
    analysis_result["duration"]=$(echo "$video_info" | jq -r '.format.duration // "unknown"')
    
    # Audio analysis
    local audio_streams=$(echo "$video_info" | jq -r '.streams[] | select(.codec_type=="audio")')
    analysis_result["audio_channels"]=$(echo "$audio_streams" | jq -r '.channels // 0' | tr '\n' ',' | sed 's/,$//')
    analysis_result["audio_count"]=$(echo "$audio_streams" | jq -r '.index' | wc -l)
    
    # Determine if it's 10-bit
    if [[ "${analysis_result[pix_fmt]}" == *"10le"* ]] || [[ "${analysis_result[pix_fmt]}" == *"p010"* ]] || [[ "${analysis_result[bit_depth]}" == "10" ]]; then
        analysis_result["is_10bit"]="true"
    else
        analysis_result["is_10bit"]="false"
    fi
    
    # Determine complexity (affects encoding settings)
    local resolution_pixels=$((${analysis_result[width]} * ${analysis_result[height]}))
    if [ "$resolution_pixels" -gt 8000000 ]; then  # 4K+
        analysis_result["complexity"]="high"
    elif [ "$resolution_pixels" -gt 2000000 ]; then  # 1080p+
        analysis_result["complexity"]="medium"
    else
        analysis_result["complexity"]="low"
    fi
    
    debug_echo "File analysis complete: ${analysis_result[codec]} ${analysis_result[width]}x${analysis_result[height]} ${analysis_result[pix_fmt]} (${analysis_result[bit_depth]} bit)"
}

# --- Encoder Configuration Functions ---
get_encoder_args() {
    local encoder_type="$1"
    local file_analysis_ref=$2
    local -n encoder_args=$3
    
    local -A file_analysis
    # Copy associative array
    local key
    for key in $(eval echo \${!${file_analysis_ref}[@]}); do
        file_analysis["$key"]=$(eval echo \${${file_analysis_ref}[$key]})
    done
    
    case "$encoder_type" in
        "NVENC")
            encoder_args=("-c:v" "hevc_nvenc")
            
            if [ "${file_analysis[is_10bit]}" = "true" ]; then
                if [ "${ENCODER_CAPS[NVENC_HEVC_10BIT]}" = "true" ]; then
                    encoder_args+=("-profile:v" "main10" "-pix_fmt" "p010le")
                else
                    encoder_args+=("-profile:v" "main" "-pix_fmt" "yuv420p")
                fi
            else
                encoder_args+=("-profile:v" "main" "-pix_fmt" "yuv420p")
            fi
            
            # Quality settings based on complexity
            case "${file_analysis[complexity]}" in
                "high")
                    encoder_args+=("-cq" "$QUALITY_PARAM" "-preset" "slow" "-rc" "vbr")
                    ;;
                "medium")
                    encoder_args+=("-cq" "$QUALITY_PARAM" "-preset" "medium" "-rc" "vbr")
                    ;;
                *)
                    encoder_args+=("-cq" "$QUALITY_PARAM" "-preset" "fast" "-rc" "vbr")
                    ;;
            esac
            
            encoder_args+=("-b:v" "0" "-maxrate" "50M" "-bufsize" "100M")
            ;;
            
        "QSV")
            encoder_args=("-c:v" "hevc_qsv")
            
            if [ "${file_analysis[is_10bit]}" = "true" ]; then
                if [ "${ENCODER_CAPS[QSV_HEVC_10BIT]}" = "true" ]; then
                    encoder_args+=("-profile:v" "main10" "-pix_fmt" "p010le")
                else
                    encoder_args+=("-profile:v" "main" "-pix_fmt" "yuv420p")
                fi
            else
                encoder_args+=("-profile:v" "main" "-pix_fmt" "yuv420p")
            fi
            
            # Quality settings
            case "${file_analysis[complexity]}" in
                "high")
                    encoder_args+=("-global_quality" "$QUALITY_PARAM" "-preset" "slower")
                    ;;
                "medium")
                    encoder_args+=("-global_quality" "$QUALITY_PARAM" "-preset" "medium")
                    ;;
                *)
                    encoder_args+=("-global_quality" "$QUALITY_PARAM" "-preset" "fast")
                    ;;
            esac
            ;;
            
        "VAAPI")
            encoder_args=(
                "-init_hw_device" "vaapi=hw:${HW_DEVICES[VAAPI]}"
                "-filter_hw_device" "hw"
                "-c:v" "hevc_vaapi"
            )
            
            if [ "${file_analysis[is_10bit]}" = "true" ]; then
                if [ "${ENCODER_CAPS[VAAPI_HEVC_10BIT]}" = "true" ]; then
                    encoder_args+=("-vf" "format=p010le,hwupload" "-profile:v" "main10")
                else
                    encoder_args+=("-vf" "format=nv12,hwupload" "-profile:v" "main")
                fi
            else
                encoder_args+=("-vf" "format=nv12,hwupload" "-profile:v" "main")
            fi
            
            encoder_args+=("-qp" "$QUALITY_PARAM")
            
            # AMD-specific optimizations
            if [ "${HW_SUPPORT[AMD_DISCRETE]}" = "true" ] || [ "${HW_SUPPORT[AMD_INTEGRATED]}" = "true" ]; then
                encoder_args+=("-compression_level" "1")
                # Disable B-frames for problematic AMD encoders
                case "${file_analysis[complexity]}" in
                    "high")
                        encoder_args+=("-bf" "2")
                        ;;
                    *)
                        encoder_args+=("-bf" "0")
                        ;;
                esac
            fi
            ;;
            
        "SOFTWARE")
            encoder_args=("-c:v" "libx265")
            
            if [ "${file_analysis[is_10bit]}" = "true" ]; then
                encoder_args+=("-profile:v" "main10" "-pix_fmt" "yuv420p10le")
            else
                encoder_args+=("-profile:v" "main" "-pix_fmt" "yuv420p")
            fi
            
            encoder_args+=("-crf" "$QUALITY_PARAM")
            
            # Preset based on complexity and CPU cores
            case "${file_analysis[complexity]}" in
                "high")
                    if [ "$CPU_CORES" -gt 8 ]; then
                        encoder_args+=("-preset" "slow")
                    else
                        encoder_args+=("-preset" "medium")
                    fi
                    ;;
                "medium")
                    encoder_args+=("-preset" "medium")
                    ;;
                *)
                    encoder_args+=("-preset" "fast")
                    ;;
            esac
            
            # CPU-specific optimizations
            if [ "$CPU_VENDOR" = "AMD" ]; then
                encoder_args+=("-x265-params" "pools=+")
            fi
            ;;
    esac
}

# --- RAM Disk Check ---
check_ram_disk() {
    SHM_PATH="/dev/shm"
    CAN_USE_SHM=false
    if [ -d "$SHM_PATH" ]; then
        CAN_USE_SHM=true
        echo "ℹ️ RAM Disk ($SHM_PATH) is available for use."
    else
        echo "ℹ️ RAM Disk ($SHM_PATH) not found, will use standard disk for temp files."
    fi
}

# --- Main Hardware Detection ---
echo "==================== 🔍 HARDWARE ANALYSIS ===================="
detect_cpu_info
detect_gpu_hardware
detect_vaapi_support
detect_nvenc_support
detect_qsv_support
determine_best_encoder
check_ram_disk

echo
echo "==================== 📊 HARDWARE SUMMARY ===================="
echo "CPU: $CPU_VENDOR $CPU_MODEL ($CPU_CORES cores)"
echo "Best Encoder: $BEST_ENCODER"
[ -n "$FALLBACK_ENCODER" ] && echo "Fallback: $FALLBACK_ENCODER"
echo "RAM Disk: $([ "$CAN_USE_SHM" = true ] && echo "Available" || echo "Not available")"
echo

# --- File Processing ---
success_count=0
skipped_count=0
failed_count=0
file_list=$(ls *.mkv 2> /dev/null)
total_files=$(echo "$file_list" | wc -w)

echo "==================== 🎬 BATCH CONVERSION ===================="
echo "Found $total_files .mkv file(s) to process in: $(pwd)"
echo

# --- Main Processing Loop ---
for file in $file_list; do
    [ -f "$file" ] || continue
    echo "--- Processing: $file ---"

    # Analyze current file
    declare -A file_analysis
    if ! analyze_video_file "$file" file_analysis; then
        ((failed_count++))
        continue
    fi

    echo "   📹 ${file_analysis[codec]} ${file_analysis[width]}x${file_analysis[height]} (${file_analysis[bit_depth]} bit)"
    echo "   🎵 ${file_analysis[audio_count]} audio stream(s)"

    # Determine output path
    if [ "$REPLACE_SOURCE" = true ]; then
        final_destination_path="$file"
    else
        final_destination_path="${file%.*}-converted.mkv"
    fi

    # Determine working path (RAM disk or regular disk)
    USE_SHM_FOR_FILE=false
    if [ "$CAN_USE_SHM" = true ]; then
        available_kb=$(df -k "$SHM_PATH" | awk 'NR==2 {print $4}')
        required_kb=$(du -k "$file" | cut -f1)
        if (( available_kb > required_kb )); then
            USE_SHM_FOR_FILE=true
            ffmpeg_output_path="$SHM_PATH/conv-temp-$$_$(basename "$file")"
            echo "   💾 Using RAM disk for temporary output"
        else
            echo "   ⚠️ Not enough RAM disk space, using regular disk"
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
    get_encoder_args "$BEST_ENCODER" file_analysis encoder_args

    # Audio processing logic
    valid_audio_count=$(echo "${file_analysis[audio_channels]}" | tr ',' '\n' | grep -v "6" | wc -l)
    
    conversion_status=1
    
    if [ "$valid_audio_count" -eq 0 ]; then
        echo "   🔄 Converting 5.1 audio to stereo..."
        
        # 5.1 to stereo conversion (existing logic)
        mapfile -t five_one_indices < <(ffprobe -v quiet -print_format json -show_streams "$file" | \
                                          jq -r '.streams[] | select(.codec_type=="audio" and .channels==6) | .index')

        if [ ${#five_one_indices[@]} -eq 0 ]; then
            echo "   ⏭️ No audio streams found, skipping..."
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
            echo "   ❌ All audio conversions failed, skipping..."
            ((failed_count++))
            trap - EXIT
            rm -rf -- "$TEMP_DIR"
            continue
        fi
        
        echo "   🎬 Encoding with $BEST_ENCODER..."
        debug_echo "Encoder args: ${encoder_args[*]}"
        
        ffmpeg "${ffmpeg_inputs[@]}" "${map_args[@]}" -map_metadata 0 \
               "${encoder_args[@]}" -c:a copy -c:s copy -y "$ffmpeg_output_path" 2>/dev/null
        conversion_status=$?
        
        trap - EXIT
        rm -rf -- "$TEMP_DIR"

    else
        echo "   🎬 Encoding with $BEST_ENCODER (keeping original audio)..."
        debug_echo "Encoder args: ${encoder_args[*]}"
        
        # Keep existing non-5.1 tracks
        mapfile -t stream_indices < <(ffprobe -v quiet -print_format json -show_streams "$file" | \
                                      jq -r '.streams[] | select(.codec_type=="video" or .codec_type=="subtitle" or (.codec_type=="audio" and .channels!=6)) | .index')
        map_args=()
        for index in "${stream_indices[@]}"; do
            map_args+=("-map" "0:$index")
        done

        ffmpeg -i "$file" "${map_args[@]}" "${encoder_args[@]}" \
               -c:a copy -c:s copy -y "$ffmpeg_output_path" 2>/dev/null
        conversion_status=$?
    fi

    # Fallback to software encoding on failure
    if [ $conversion_status -ne 0 ] && [ "$BEST_ENCODER" != "SOFTWARE" ]; then
        echo "   ⚠️ $BEST_ENCODER failed, trying $FALLBACK_ENCODER..."
        
        declare -a fallback_args
        get_encoder_args "$FALLBACK_ENCODER" file_analysis fallback_args
        
        debug_echo "Fallback encoder args: ${fallback_args[*]}"
        
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
                   "${fallback_args[@]}" -c:a copy -c:s copy -y "$ffmpeg_output_path" 2>/dev/null
            conversion_status=$?
            
            trap - EXIT
            rm -rf -- "$TEMP_DIR"
        else
            ffmpeg -i "$file" "${map_args[@]}" "${fallback_args[@]}" \
                   -c:a copy -c:s copy -y "$ffmpeg_output_path" 2>/dev/null
            conversion_status=$?
        fi
    fi

    # Finalization
    if [ $conversion_status -eq 0 ]; then
        if [ "$ffmpeg_output_path" != "$final_destination_path" ]; then
            mv -f "$ffmpeg_output_path" "$final_destination_path"
            if [ $? -eq 0 ]; then
                [ "$REPLACE_SOURCE" = true ] && echo "   ✅ Source file replaced successfully" || echo "   ✅ Created: $final_destination_path"
                ((success_count++))
            else
                echo "   ❌ Failed to move temporary file"
                ((failed_count++))
            fi
        else
            echo "   ✅ Created: $final_destination_path"
            ((