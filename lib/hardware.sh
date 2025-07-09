#!/bin/bash

# Hardware Detection and Capabilities
# Compatible with bash 3.2+ and common Linux tools

# Initialize all hardware capability variables
NVENC_AVAILABLE=false
VAAPI_AVAILABLE=false
QSV_AVAILABLE=false
CPU_CORES=0
GPU_INFO=""
SYSTEM_TYPE=""

# Hardware capability scoring (higher = better)
NVENC_SCORE=100
VAAPI_SCORE=80
QSV_SCORE=90
CPU_SCORE=50

# Selected encoder storage
SELECTED_ENCODER=""

detect_cpu_info() {
    log_debug "Detecting CPU information"

    # Get CPU model name
    local cpu_model=""
    if [[ -f "/proc/cpuinfo" ]]; then
        cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^[ \t]*//')
    fi

    # Get CPU core count
    if command -v nproc >/dev/null 2>&1; then
        CPU_CORES=$(nproc)
    elif [[ -f "/proc/cpuinfo" ]]; then
        CPU_CORES=$(grep -c "^processor" /proc/cpuinfo)
    else
        CPU_CORES=1
    fi

    # Detect AMD APU
    if [[ "$cpu_model" == *"AMD"* && "$cpu_model" == *"Radeon"* ]]; then
        log_debug "AMD APU detected: $cpu_model"
        SYSTEM_TYPE="AMD_APU"
    fi

    log_debug "CPU: $cpu_model ($CPU_CORES cores)"
    return 0
}

detect_gpu_hardware() {
    log_debug "Detecting GPU hardware"

    # Use lspci to detect GPU hardware
    if command -v lspci >/dev/null 2>&1; then
        local gpu_info
        gpu_info=$(lspci | grep -i "vga\|3d\|display")

        if [[ -n "$gpu_info" ]]; then
            GPU_INFO="$gpu_info"
            log_debug "GPU found: $gpu_info"

            # Detect specific GPU vendors
            if echo "$gpu_info" | grep -qi "nvidia"; then
                log_debug "NVIDIA GPU detected"
                SYSTEM_TYPE="NVIDIA"
            elif echo "$gpu_info" | grep -qi "amd\|ati"; then
                log_debug "AMD GPU detected"
                [[ -z "$SYSTEM_TYPE" ]] && SYSTEM_TYPE="AMD_GPU"
            elif echo "$gpu_info" | grep -qi "intel"; then
                log_debug "Intel GPU detected"
                SYSTEM_TYPE="INTEL"
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

    # Check for VAAPI devices
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

    # Test each VAAPI device
    for device in "${vaapi_devices[@]}"; do
        log_debug "Testing VAAPI device: $device"

        # Check device permissions
        if [[ ! -r "$device" ]]; then
            log_debug "No read access to $device"
            continue
        fi

        # Test with vainfo if available
        if command -v vainfo >/dev/null 2>&1; then
            if vainfo --display drm --device "$device" >/dev/null 2>&1; then
                log_debug "VAAPI working on $device"
                VAAPI_AVAILABLE=true
                return 0
            else
                log_debug "VAAPI test failed on $device"
            fi
        else
            # If vainfo is not available, assume it works if device exists
            log_debug "vainfo not available, assuming VAAPI works"
            VAAPI_AVAILABLE=true
            return 0
        fi
    done

    log_debug "No working VAAPI devices found"
    return 1
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
    GPU_INFO=""
    SYSTEM_TYPE=""

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
        "CPU")
            echo "$CPU_SCORE"
            ;;
        *)
            echo "0"
            ;;
    esac
}

select_best_encoder() {
    local force_encoder="$1"

    log_debug "Selecting encoder (forced: ${force_encoder:-none})"

    # Handle forced encoder selection
    if [[ -n "$force_encoder" ]]; then
        case "$force_encoder" in
            "NVENC")
                if [[ "$NVENC_AVAILABLE" == true ]]; then
                    SELECTED_ENCODER="NVENC"
                    log_info "Forced encoder selected: NVENC"
                    return 0
                else
                    log_error "NVENC forced but not available"
                    return 1
                fi
                ;;
            "VAAPI")
                if [[ "$VAAPI_AVAILABLE" == true ]]; then
                    SELECTED_ENCODER="VAAPI"
                    log_info "Forced encoder selected: VAAPI"
                    return 0
                else
                    log_error "VAAPI forced but not available"
                    return 1
                fi
                ;;
            "QSV")
                if [[ "$QSV_AVAILABLE" == true ]]; then
                    SELECTED_ENCODER="QSV"
                    log_info "Forced encoder selected: QSV"
                    return 0
                else
                    log_error "QSV forced but not available"
                    return 1
                fi
                ;;
            "CPU")
                SELECTED_ENCODER="CPU"
                log_info "Forced encoder selected: CPU"
                return 0
                ;;
            "GPU")
                # Auto-select best GPU encoder
                force_encoder=""
                ;;
            *)
                log_error "Unknown forced encoder: $force_encoder"
                return 1
                ;;
        esac
    fi

    # Auto-select best available encoder
    local best_encoder=""
    local best_score=0

    # Check available encoders and their scores
    if [[ "$NVENC_AVAILABLE" == true ]]; then
        local score
        score=$(get_encoder_score "NVENC")
        if [[ $score -gt $best_score ]]; then
            best_score=$score
            best_encoder="NVENC"
        fi
    fi

    if [[ "$VAAPI_AVAILABLE" == true ]]; then
        local score
        score=$(get_encoder_score "VAAPI")
        if [[ $score -gt $best_score ]]; then
            best_score=$score
            best_encoder="VAAPI"
        fi
    fi

    if [[ "$QSV_AVAILABLE" == true ]]; then
        local score
        score=$(get_encoder_score "QSV")
        if [[ $score -gt $best_score ]]; then
            best_score=$score
            best_encoder="QSV"
        fi
    fi

    # CPU is always available as fallback
    if [[ -z "$best_encoder" ]]; then
        best_encoder="CPU"
        best_score=$(get_encoder_score "CPU")
    fi

    SELECTED_ENCODER="$best_encoder"
    log_info "Selected encoder: $SELECTED_ENCODER (score: $best_score)"
    return 0
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

    printf "[ENCODERS] Available: %s\n" "$(IFS=', '; echo "${encoders[*]}")"

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
