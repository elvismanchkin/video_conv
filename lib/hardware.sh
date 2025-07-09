#!/bin/bash

# Hardware Detection and Capabilities
# Compatible with bash 3.2+ and common Linux tools

# Initialize hardware capability variables
NVENC_AVAILABLE=false
VAAPI_AVAILABLE=false
QSV_AVAILABLE=false
CPU_CORES=0
CPU_VENDOR=""
GPU_INFO=""
SYSTEM_TYPE=""

# Initialize encoder capabilities array
declare -A ENCODER_CAPS
ENCODER_CAPS[NVENC_HEVC_10BIT]="false"
ENCODER_CAPS[NVENC_AV1]="false"
ENCODER_CAPS[QSV_HEVC_10BIT]="false"
ENCODER_CAPS[QSV_AV1]="false"
ENCODER_CAPS[VAAPI_HEVC_10BIT]="false"
ENCODER_CAPS[VAAPI_AV1]="false"

# Initialize hardware devices array
declare -A HW_DEVICES
HW_DEVICES[VAAPI]="/dev/dri/renderD128"
HW_DEVICES[NVENC]=""
HW_DEVICES[QSV]=""

# Initialize hardware support array
declare -A HW_SUPPORT
HW_SUPPORT[AMD_DISCRETE]="false"
HW_SUPPORT[AMD_INTEGRATED]="false"
HW_SUPPORT[INTEL_DISCRETE]="false"
HW_SUPPORT[INTEL_INTEGRATED]="false"
HW_SUPPORT[NVIDIA_DISCRETE]="false"

# Hardware capability scoring (higher = better)
NVENC_SCORE=100
VAAPI_SCORE=80
QSV_SCORE=90
CPU_SCORE=50

# Selected encoder storage
SELECTED_ENCODER=""

detect_cpu_info() {
    log_debug "Detecting CPU information"

    local cpu_model=""
    if [[ -f "/proc/cpuinfo" ]]; then
        cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^[ \t]*//')
    fi

    if command -v nproc >/dev/null 2>&1; then
        CPU_CORES=$(nproc)
    elif [[ -f "/proc/cpuinfo" ]]; then
        CPU_CORES=$(grep -c "^processor" /proc/cpuinfo)
    else
        CPU_CORES=1
    fi

    if [[ "$cpu_model" == *"Intel"* ]]; then
        CPU_VENDOR="Intel"
    elif [[ "$cpu_model" == *"AMD"* ]]; then
        CPU_VENDOR="AMD"
    else
        CPU_VENDOR="Unknown"
    fi

    # Detect AMD APU
    if [[ "$cpu_model" == *"AMD"* && "$cpu_model" == *"Radeon"* ]]; then
        log_debug "AMD APU detected: $cpu_model"
        SYSTEM_TYPE="AMD_APU"
        HW_SUPPORT[AMD_INTEGRATED]="true"
    fi

    log_debug "CPU: $cpu_model ($CPU_CORES cores)"
    return 0
}

detect_gpu_hardware() {
    log_debug "Detecting GPU hardware"

    if command -v lspci >/dev/null 2>&1; then
        local gpu_info
        gpu_info=$(lspci | grep -i "vga\|3d\|display")

        if [[ -n "$gpu_info" ]]; then
            GPU_INFO="$gpu_info"
            log_debug "GPU found: $gpu_info"

            if echo "$gpu_info" | grep -qi "nvidia"; then
                log_debug "NVIDIA GPU detected"
                SYSTEM_TYPE="NVIDIA"
                HW_SUPPORT[NVIDIA_DISCRETE]="true"
            elif echo "$gpu_info" | grep -qi "amd\|ati"; then
                log_debug "AMD GPU detected"
                [[ -z "$SYSTEM_TYPE" ]] && SYSTEM_TYPE="AMD_GPU"
                if echo "$gpu_info" | grep -qi "radeon"; then
                    HW_SUPPORT[AMD_INTEGRATED]="true"
                else
                    HW_SUPPORT[AMD_DISCRETE]="true"
                fi
            elif echo "$gpu_info" | grep -qi "intel"; then
                log_debug "Intel GPU detected"
                SYSTEM_TYPE="INTEL"
                if echo "$gpu_info" | grep -qi "arc\|xe"; then
                    HW_SUPPORT[INTEL_DISCRETE]="true"
                else
                    HW_SUPPORT[INTEL_INTEGRATED]="true"
                fi
            fi
        else
            log_debug "No discrete GPU found"
        fi
    else
        log_warn "lspci not available, skipping GPU detection"
    fi

    return 0
}

test_vaapi_support() {
    log_debug "Testing VAAPI support"

    local vaapi_devices=()
    if [[ -d "/dev/dri" ]]; then
        while IFS= read -r -d '' device; do
            vaapi_devices+=("$device")
        done < <(find /dev/dri -name "renderD*" -print0 2>/dev/null)
    fi

    if [[ ${#vaapi_devices[@]} -eq 0 ]]; then
        log_debug "No VAAPI render devices found"
        return 1
    fi

    for device in "${vaapi_devices[@]}"; do
        log_debug "Testing VAAPI device: $device"

        if [[ ! -r "$device" ]]; then
            log_debug "No read access to $device"
            continue
        fi

        if command -v vainfo >/dev/null 2>&1; then
            if vainfo --display drm --device "$device" >/dev/null 2>&1; then
                log_debug "VAAPI working on $device"
                VAAPI_AVAILABLE=true
                HW_DEVICES[VAAPI]="$device"
                detect_vaapi_capabilities "$device"
                return 0
            else
                log_debug "VAAPI test failed on $device"
            fi
        else
            # If vainfo is not available, assume it works if device exists
            log_debug "vainfo not available, assuming VAAPI works"
            VAAPI_AVAILABLE=true
            HW_DEVICES[VAAPI]="$device"
            detect_vaapi_capabilities "$device"
            return 0
        fi
    done

    log_debug "No working VAAPI devices found"
    return 1
}

# Detect NVENC encoder capabilities
detect_nvenc_capabilities() {
    log_debug "Detecting NVENC capabilities"

    # Check for HEVC 10-bit support (assume available on modern cards)
    ENCODER_CAPS[NVENC_HEVC_10BIT]="true"

    # Check for AV1 support (RTX 40 series and newer)
    if command -v nvidia-smi >/dev/null 2>&1; then
        local gpu_name
        gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | head -1)
        if [[ "$gpu_name" == *"RTX 40"* || "$gpu_name" == *"RTX 50"* ]]; then
            ENCODER_CAPS[NVENC_AV1]="true"
        fi
    fi
}

# Detect QSV encoder capabilities
detect_qsv_capabilities() {
    log_debug "Detecting QSV capabilities"

    # Most modern Intel GPUs support HEVC 10-bit
    ENCODER_CAPS[QSV_HEVC_10BIT]="true"

    # AV1 support on Intel Arc and newer
    if [[ "$GPU_INFO" == *"Arc"* || "$GPU_INFO" == *"Xe"* ]]; then
        ENCODER_CAPS[QSV_AV1]="true"
    fi
}

# Detect VAAPI encoder capabilities
detect_vaapi_capabilities() {
    local device="$1"
    log_debug "Detecting VAAPI capabilities for $device"

    # Test for HEVC 10-bit support
    if command -v vainfo >/dev/null 2>&1; then
        if vainfo --display drm --device "$device" 2>/dev/null | grep -q "VAProfileHEVCMain10"; then
            ENCODER_CAPS[VAAPI_HEVC_10BIT]="true"
        fi

        # Test for AV1 support
        if vainfo --display drm --device "$device" 2>/dev/null | grep -q "VAProfileAV1"; then
            ENCODER_CAPS[VAAPI_AV1]="true"
        fi
    else
        # Conservative defaults when vainfo is not available
        ENCODER_CAPS[VAAPI_HEVC_10BIT]="false"
        ENCODER_CAPS[VAAPI_AV1]="false"
    fi
}

test_nvenc_support() {
    log_debug "Testing NVENC support"

    # Check for NVIDIA GPU first
    if [[ "$SYSTEM_TYPE" != "NVIDIA" ]]; then
        log_debug "No NVIDIA GPU detected"
        return 1
    fi

    # Check for nvidia-smi
    if command -v nvidia-smi >/dev/null 2>&1; then
        if nvidia-smi >/dev/null 2>&1; then
            log_debug "NVIDIA driver working"
            NVENC_AVAILABLE=true
            detect_nvenc_capabilities
            return 0
        else
            log_debug "NVIDIA driver not responding"
        fi
    else
        log_debug "nvidia-smi not found"
    fi

    # Check for NVIDIA device files
    if [[ -c "/dev/nvidia0" ]]; then
        log_debug "NVIDIA device found, assuming NVENC available"
        NVENC_AVAILABLE=true
        detect_nvenc_capabilities
        return 0
    fi

    log_debug "NVENC not available"
    return 1
}

test_qsv_support() {
    log_debug "Testing QSV support"

    # Check for Intel GPU
    if [[ "$SYSTEM_TYPE" != "INTEL" ]]; then
        log_debug "No Intel GPU detected"
        return 1
    fi

    # Check for Intel media driver
    if [[ -d "/dev/dri" ]]; then
        local intel_devices
        intel_devices=$(find /dev/dri -name "renderD*" 2>/dev/null)

        if [[ -n "$intel_devices" ]]; then
            log_debug "Intel render devices found"
            QSV_AVAILABLE=true
            detect_qsv_capabilities
            return 0
        fi
    fi

    log_debug "QSV not available"
    return 1
}

detect_all_hardware() {
    log_debug "Starting comprehensive hardware detection"

    # Initialize all variables
    NVENC_AVAILABLE=false
    VAAPI_AVAILABLE=false
    QSV_AVAILABLE=false
    CPU_CORES=0
    CPU_VENDOR=""
    GPU_INFO=""
    SYSTEM_TYPE=""

    # Reset encoder capabilities
    ENCODER_CAPS[NVENC_HEVC_10BIT]="false"
    ENCODER_CAPS[NVENC_AV1]="false"
    ENCODER_CAPS[QSV_HEVC_10BIT]="false"
    ENCODER_CAPS[QSV_AV1]="false"
    ENCODER_CAPS[VAAPI_HEVC_10BIT]="false"
    ENCODER_CAPS[VAAPI_AV1]="false"

    # Reset hardware devices
    HW_DEVICES[VAAPI]="/dev/dri/renderD128"
    HW_DEVICES[NVENC]=""
    HW_DEVICES[QSV]=""

    # Reset hardware support
    HW_SUPPORT[AMD_DISCRETE]="false"
    HW_SUPPORT[AMD_INTEGRATED]="false"
    HW_SUPPORT[INTEL_DISCRETE]="false"
    HW_SUPPORT[INTEL_INTEGRATED]="false"
    HW_SUPPORT[NVIDIA_DISCRETE]="false"

    # Detect hardware components
    detect_cpu_info
    detect_gpu_hardware

    # Test encoder availability
    test_nvenc_support
    test_vaapi_support
    test_qsv_support

    log_debug "Hardware detection completed"
    return 0
}

# Check if a specific encoder is available
# Args: encoder_name
is_encoder_available() {
    local encoder="$1"

    case "$encoder" in
        "NVENC")
            [[ "$NVENC_AVAILABLE" == true ]]
            ;;
        "VAAPI")
            [[ "$VAAPI_AVAILABLE" == true ]]
            ;;
        "QSV")
            [[ "$QSV_AVAILABLE" == true ]]
            ;;
        "SOFTWARE"|"CPU")
            return 0  # Software encoding is always available
            ;;
        *)
            return 1
            ;;
    esac
}

get_encoder_score() {
    local encoder="$1"

    case "$encoder" in
        "NVENC")
            echo "$NVENC_SCORE"
            ;;
        "VAAPI")
            echo "$VAAPI_SCORE"
            ;;
        "QSV")
            echo "$QSV_SCORE"
            ;;
        "CPU"|"SOFTWARE")
            echo "$CPU_SCORE"
            ;;
        *)
            echo "0"
            ;;
    esac
}



get_selected_encoder() {
    echo "$SELECTED_ENCODER"
}

display_hardware_summary() {
    local gpu_desc="None"

    if [[ -n "$GPU_INFO" ]]; then
        case "$SYSTEM_TYPE" in
            "NVIDIA") gpu_desc="NVIDIA GPU" ;;
            "AMD_APU") gpu_desc="AMD APU" ;;
            "AMD_GPU") gpu_desc="AMD dGPU" ;;
            "INTEL") gpu_desc="Intel GPU" ;;
            *) gpu_desc="Unknown GPU" ;;
        esac
    fi

    printf "[HARDWARE] %d-core CPU | GPU: %s\n" "$CPU_CORES" "$gpu_desc"

    # Show available encoders
    local encoders=()
    [[ "$NVENC_AVAILABLE" == true ]] && encoders+=("NVENC")
    [[ "$VAAPI_AVAILABLE" == true ]] && encoders+=("VAAPI")
    [[ "$QSV_AVAILABLE" == true ]] && encoders+=("QSV")
    encoders+=("CPU")

    printf "[ENCODERS] Available: %s\n" "$(IFS=,; echo "${encoders[*]}")"

    if [[ -n "$SELECTED_ENCODER" ]]; then
        printf "[SELECTED] Using: %s\n" "$SELECTED_ENCODER"
    fi
}

# Check if running as main script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Hardware detection test"
    detect_all_hardware
    display_hardware_summary
fi
