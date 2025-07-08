#!/bin/bash

# Global hardware state
declare -g -A HW_SUPPORT=()
declare -g -A HW_DEVICES=()
declare -g -A ENCODER_CAPS=()
declare -g CPU_VENDOR=""
declare -g CPU_CORES=""
declare -g CPU_MODEL=""

detect_cpu_info() {
    log_debug "Detecting CPU information"

    CPU_CORES=$(get_cpu_cores)

    local cpu_info
    cpu_info=$(lscpu 2>/dev/null || cat /proc/cpuinfo 2>/dev/null)

    if echo "$cpu_info" | grep -qi "AMD"; then
        CPU_VENDOR="AMD"
        CPU_MODEL=$(echo "$cpu_info" | grep -i "model name" | head -1 | cut -d: -f2 | xargs)

        # AMD APU detection (integrated graphics)
        if echo "$CPU_MODEL" | grep -qi "G\|APU\|PRO.*G\|GE\|Ryzen.*[0-9]G"; then
            HW_SUPPORT["AMD_INTEGRATED"]="true"
            log_debug "AMD APU detected: $CPU_MODEL"
        fi

    elif echo "$cpu_info" | grep -qi "Intel"; then
        CPU_VENDOR="Intel"
        CPU_MODEL=$(echo "$cpu_info" | grep -i "model name" | head -1 | cut -d: -f2 | xargs)

        # Intel integrated graphics detection
        if lspci 2>/dev/null | grep -qi "Intel.*Graphics\|Intel.*Display\|Intel.*UHD\|Intel.*Iris"; then
            HW_SUPPORT["INTEL_INTEGRATED"]="true"
            log_debug "Intel iGPU detected: $CPU_MODEL"
        fi
    else
        CPU_VENDOR="Unknown"
        CPU_MODEL="Unknown"
    fi

    log_debug "CPU: $CPU_VENDOR $CPU_MODEL ($CPU_CORES cores)"
}

# Detect discrete GPU hardware
detect_gpu_hardware() {
    log_debug "Detecting GPU hardware"

    # NVIDIA detection
    if command_exists nvidia-smi; then
        local nvidia_info
        nvidia_info=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | head -1)
        if [[ -n "$nvidia_info" ]]; then
            HW_SUPPORT["NVIDIA"]="true"
            log_debug "NVIDIA GPU: $nvidia_info"
        fi
    fi

    # AMD discrete GPU detection
    if lspci 2>/dev/null | grep -qi "AMD.*Radeon\|AMD.*Graphics\|AMD.*RX\|AMD.*Pro"; then
        local amd_gpu_info
        amd_gpu_info=$(lspci 2>/dev/null | grep -i "AMD.*Radeon\|AMD.*Graphics\|AMD.*RX\|AMD.*Pro" | head -1 | sed 's/.*: //')
        HW_SUPPORT["AMD_DISCRETE"]="true"
        log_debug "AMD GPU: $amd_gpu_info"
    fi

    # Intel discrete GPU detection (Arc, etc.)
    if lspci 2>/dev/null | grep -qi "Intel.*Arc\|Intel.*Xe"; then
        local intel_gpu_info
        intel_gpu_info=$(lspci 2>/dev/null | grep -i "Intel.*Arc\|Intel.*Xe" | head -1 | sed 's/.*: //')
        HW_SUPPORT["INTEL_DISCRETE"]="true"
        log_debug "Intel dGPU: $intel_gpu_info"
    fi
}

# Test VAAPI support and capabilities
detect_vaapi_support() {
    log_debug "Testing VAAPI support"

    if ! command_exists vainfo; then
        log_debug "vainfo not available"
        return 1
    fi

    # Test available render devices
    local device
    for device in /dev/dri/renderD*; do
        if [[ -c "$device" ]]; then
            log_debug "Testing VAAPI device: $device"

            local vaapi_info
            if vaapi_info=$(vainfo --display drm --device "$device" 2>/dev/null); then
                HW_DEVICES["VAAPI"]="$device"
                log_debug "VAAPI working on: $device"

                # Check encoding capabilities
                if echo "$vaapi_info" | grep -q "VAProfileHEVCMain.*VAEntrypointEncSlice"; then
                    ENCODER_CAPS["VAAPI_HEVC"]="true"
                    log_debug "VAAPI HEVC encoding available"

                    # 10-bit support
                    if echo "$vaapi_info" | grep -q "VAProfileHEVCMain10.*VAEntrypointEncSlice"; then
                        ENCODER_CAPS["VAAPI_HEVC_10BIT"]="true"
                        log_debug "VAAPI HEVC 10-bit encoding available"
                    fi
                fi

                # H.264 fallback
                if echo "$vaapi_info" | grep -qi "VAEntrypointEncSlice.*H264"; then
                    ENCODER_CAPS["VAAPI_H264"]="true"
                    log_debug "VAAPI H.264 encoding available"
                fi

                # AV1 support (newer hardware)
                if echo "$vaapi_info" | grep -qi "VAEntrypointEncSlice.*AV1"; then
                    ENCODER_CAPS["VAAPI_AV1"]="true"
                    log_debug "VAAPI AV1 encoding available"
                fi

                return 0
            fi
        fi
    done

    return 1
}

# Test NVENC capabilities
detect_nvenc_support() {
    log_debug "Testing NVENC support"

    if [[ "${HW_SUPPORT[NVIDIA]:-}" != "true" ]]; then
        log_debug "No NVIDIA GPU detected"
        return 1
    fi

    # Quick capability tests using ffmpeg
    if test_encoder_capability "h264_nvenc"; then
        ENCODER_CAPS["NVENC_H264"]="true"
        log_debug "NVENC H.264 encoding available"

        if test_encoder_capability "hevc_nvenc"; then
            ENCODER_CAPS["NVENC_HEVC"]="true"
            log_debug "NVENC HEVC encoding available"

            # Test 10-bit support
            if test_encoder_capability "hevc_nvenc" "-profile:v main10"; then
                ENCODER_CAPS["NVENC_HEVC_10BIT"]="true"
                log_debug "NVENC HEVC 10-bit encoding available"
            fi

            # Test AV1 support (RTX 40 series and newer)
            if test_encoder_capability "av1_nvenc"; then
                ENCODER_CAPS["NVENC_AV1"]="true"
                log_debug "NVENC AV1 encoding available"
            fi
        fi
        return 0
    fi

    return 1
}

# Test Intel QSV capabilities
detect_qsv_support() {
    log_debug "Testing QSV support"

    if [[ "${HW_SUPPORT[INTEL_INTEGRATED]:-}" != "true" && "${HW_SUPPORT[INTEL_DISCRETE]:-}" != "true" ]]; then
        log_debug "No Intel GPU detected"
        return 1
    fi

    if test_encoder_capability "h264_qsv"; then
        ENCODER_CAPS["QSV_H264"]="true"
        log_debug "QSV H.264 encoding available"

        if test_encoder_capability "hevc_qsv"; then
            ENCODER_CAPS["QSV_HEVC"]="true"
            log_debug "QSV HEVC encoding available"

            # Test 10-bit support
            if test_encoder_capability "hevc_qsv" "-profile:v main10"; then
                ENCODER_CAPS["QSV_HEVC_10BIT"]="true"
                log_debug "QSV HEVC 10-bit encoding available"
            fi

            # Test AV1 support (Arc and newer Intel)
            if test_encoder_capability "av1_qsv"; then
                ENCODER_CAPS["QSV_AV1"]="true"
                log_debug "QSV AV1 encoding available"
            fi
        fi
        return 0
    fi

    return 1
}

# Test if an encoder works with given parameters
# Args: encoder_name [additional_params...]
test_encoder_capability() {
    local encoder="$1"
    shift
    local additional_params=("$@")

    log_debug "Testing encoder capability: $encoder ${additional_params[*]}"

    # Create minimal test encode
    if ffmpeg -f lavfi -i testsrc2=duration=1:size=320x240:rate=1 \
              -c:v "$encoder" "${additional_params[@]}" \
              -f null - &>/dev/null; then
        return 0
    fi

    return 1
}

# Run all hardware detection
detect_all_hardware() {
    log_debug "Starting comprehensive hardware detection"

    # Clear previous state
    HW_SUPPORT=()
    HW_DEVICES=()
    ENCODER_CAPS=()

    # Run detection functions
    detect_cpu_info
    detect_gpu_hardware
    detect_vaapi_support
    detect_nvenc_support
    detect_qsv_support

    log_debug "Hardware detection complete"
}

display_hardware_summary() {
    local gpu_info=""

    if [[ "${HW_SUPPORT[NVIDIA]:-}" == "true" ]]; then
        gpu_info="NVIDIA"
    elif [[ "${HW_SUPPORT[INTEL_DISCRETE]:-}" == "true" ]]; then
        gpu_info="Intel dGPU"
    elif [[ "${HW_SUPPORT[AMD_DISCRETE]:-}" == "true" ]]; then
        gpu_info="AMD dGPU"
    elif [[ "${HW_SUPPORT[INTEL_INTEGRATED]:-}" == "true" ]]; then
        gpu_info="Intel iGPU"
    elif [[ "${HW_SUPPORT[AMD_INTEGRATED]:-}" == "true" ]]; then
        gpu_info="AMD APU"
    else
        gpu_info="None"
    fi

    printf "[HARDWARE] %s %s-core | GPU: %s\n" "$CPU_VENDOR" "$CPU_CORES" "$gpu_info"
}

# Get list of available encoders
get_available_encoders() {
    local encoders=()

    [[ "${ENCODER_CAPS[NVENC_HEVC]:-}" == "true" ]] && encoders+=("NVENC")
    [[ "${ENCODER_CAPS[QSV_HEVC]:-}" == "true" ]] && encoders+=("QSV")
    [[ "${ENCODER_CAPS[VAAPI_HEVC]:-}" == "true" ]] && encoders+=("VAAPI")
    encoders+=("SOFTWARE")  # Always available

    printf "%s\n" "${encoders[@]}"
}

# Check if specific encoder is available
# Args: encoder_name
is_encoder_available() {
    local encoder="$1"

    case "$encoder" in
        NVENC)
            [[ "${ENCODER_CAPS[NVENC_HEVC]:-}" == "true" ]]
            ;;
        QSV)
            [[ "${ENCODER_CAPS[QSV_HEVC]:-}" == "true" ]]
            ;;
        VAAPI)
            [[ "${ENCODER_CAPS[VAAPI_HEVC]:-}" == "true" ]]
            ;;
        SOFTWARE)
            true  # Always available
            ;;
        *)
            false
            ;;
    esac
}
