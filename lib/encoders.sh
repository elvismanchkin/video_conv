#!/bin/bash
# Encoder selection and configuration management

SELECTED_ENCODER=""
FALLBACK_ENCODER=""

select_best_encoder() {
    local forced="${1:-}"

    if [[ -n "$forced" ]]; then
        select_forced_encoder "$forced"
    else
        select_automatic_encoder
    fi

    if [[ "$SELECTED_ENCODER" != "SOFTWARE" ]]; then
        FALLBACK_ENCODER="SOFTWARE"
    fi

    log_info "Selected encoder: $SELECTED_ENCODER"
    if [[ -n "$FALLBACK_ENCODER" ]]; then
        log_debug "Fallback encoder: $FALLBACK_ENCODER"
    fi
}

select_forced_encoder() {
    local encoder="$1"

    case "$encoder" in
        GPU)
            if is_encoder_available "NVENC"; then
                SELECTED_ENCODER="NVENC"
            elif is_encoder_available "QSV"; then
                SELECTED_ENCODER="QSV"
            elif is_encoder_available "VAAPI"; then
                SELECTED_ENCODER="VAAPI"
            else
                log_warn "No GPU encoder available, using SOFTWARE"
                SELECTED_ENCODER="SOFTWARE"
            fi
            ;;
        CPU)
            SELECTED_ENCODER="SOFTWARE"
            ;;
        NVENC|QSV|VAAPI)
            if is_encoder_available "$encoder"; then
                SELECTED_ENCODER="$encoder"
            else
                log_warn "$encoder not available, using SOFTWARE"
                SELECTED_ENCODER="SOFTWARE"
            fi
            ;;
        *)
            log_error "Unknown encoder: $encoder"
            SELECTED_ENCODER="SOFTWARE"
            ;;
    esac
}

select_automatic_encoder() {
    local best_encoder="SOFTWARE"
    local best_score=0
    local encoder score

    # Score available encoders
    for encoder in NVENC QSV VAAPI SOFTWARE; do
        if is_encoder_available "$encoder"; then
            score=${ENCODER_SCORES[$encoder]}

            # Bonus scoring for advanced features
            case "$encoder" in
                NVENC)
                    [[ "${ENCODER_CAPS[NVENC_HEVC_10BIT]:-}" == "true" ]] && score=$((score + 20))
                    [[ "${ENCODER_CAPS[NVENC_AV1]:-}" == "true" ]] && score=$((score + 30))
                    ;;
                QSV)
                    [[ "${ENCODER_CAPS[QSV_HEVC_10BIT]:-}" == "true" ]] && score=$((score + 15))
                    [[ "${ENCODER_CAPS[QSV_AV1]:-}" == "true" ]] && score=$((score + 25))
                    ;;
                VAAPI)
                    [[ "${ENCODER_CAPS[VAAPI_HEVC_10BIT]:-}" == "true" ]] && score=$((score + 10))
                    [[ "${ENCODER_CAPS[VAAPI_AV1]:-}" == "true" ]] && score=$((score + 20))
                    ;;
            esac

            log_debug "Encoder $encoder score: $score"

            if [[ $score -gt $best_score ]]; then
                best_encoder="$encoder"
                best_score="$score"
            fi
        fi
    done

    SELECTED_ENCODER="$best_encoder"
}

# Get encoder arguments for specific encoder and content
# Args: encoder_name is_10bit complexity_level output_array_name
get_encoder_arguments() {
    local encoder="$1"
    local is_10bit="$2"
    local complexity="$3"
    local -n args_array=$4

    args_array=()

    case "$encoder" in
        NVENC)
            get_nvenc_arguments "$is_10bit" "$complexity" args_array
            ;;
        QSV)
            get_qsv_arguments "$is_10bit" "$complexity" args_array
            ;;
        VAAPI)
            get_vaapi_arguments "$is_10bit" "$complexity" args_array
            ;;
        SOFTWARE)
            get_software_arguments "$is_10bit" "$complexity" args_array
            ;;
        *)
            log_error "Unknown encoder: $encoder"
            return 1
            ;;
    esac

    log_debug "Encoder arguments for $encoder: ${args_array[*]}"
}

# NVENC encoder arguments
# Args: is_10bit complexity_level output_array_name
get_nvenc_arguments() {
    local is_10bit="$1"
    local complexity="$2"
    local -n nvenc_args=$3

    nvenc_args+=("-c:v" "hevc_nvenc")

    # Profile and pixel format
    if [[ "$is_10bit" == "true" && "${ENCODER_CAPS[NVENC_HEVC_10BIT]:-}" == "true" ]]; then
        nvenc_args+=("-profile:v" "main10" "-pix_fmt" "p010le")
    else
        nvenc_args+=("-profile:v" "main" "-pix_fmt" "yuv420p")
    fi

    # Complexity-based settings
    case "$complexity" in
        high)
            nvenc_args+=("-cq" "$QUALITY_PARAM" "-preset" "p4" "-rc" "vbr" "-multipass" "2")
            ;;
        medium)
            nvenc_args+=("-cq" "$QUALITY_PARAM" "-preset" "p3" "-rc" "vbr")
            ;;
        *)
            nvenc_args+=("-cq" "$QUALITY_PARAM" "-preset" "p2" "-rc" "vbr")
            ;;
    esac

    nvenc_args+=(
        "-b:v" "0"
        "-maxrate" "$MAX_BITRATE"
        "-bufsize" "$BUFFER_SIZE"
        "-spatial_aq" "1"
        "-temporal_aq" "1"
    )
}

# QSV encoder arguments
# Args: is_10bit complexity_level output_array_name
get_qsv_arguments() {
    local is_10bit="$1"
    local complexity="$2"
    local -n qsv_args=$3

    qsv_args+=("-c:v" "hevc_qsv")

    # Profile setup
    if [[ "$is_10bit" == "true" && "${ENCODER_CAPS[QSV_HEVC_10BIT]:-}" == "true" ]]; then
        qsv_args+=("-profile:v" "main10" "-pix_fmt" "p010le")
    else
        qsv_args+=("-profile:v" "main" "-pix_fmt" "nv12")
    fi

    # Quality settings
    case "$complexity" in
        high)
            qsv_args+=("-global_quality" "$QUALITY_PARAM" "-preset" "veryslow" "-look_ahead" "1")
            ;;
        medium)
            qsv_args+=("-global_quality" "$QUALITY_PARAM" "-preset" "medium" "-look_ahead" "1")
            ;;
        *)
            qsv_args+=("-global_quality" "$QUALITY_PARAM" "-preset" "fast")
            ;;
    esac

    qsv_args+=("-load_plugin" "hevc_hw")
}

# VAAPI encoder arguments
# Args: is_10bit complexity_level output_array_name
get_vaapi_arguments() {
    local is_10bit="$1"
    local complexity="$2"
    local -n vaapi_args=$3

    local vaapi_device="${HW_DEVICES[VAAPI]:-/dev/dri/renderD128}"

    vaapi_args+=(
        "-init_hw_device" "vaapi=hw:$vaapi_device"
        "-filter_hw_device" "hw"
        "-c:v" "hevc_vaapi"
    )

    # Pixel format and profile
    if [[ "$is_10bit" == "true" && "${ENCODER_CAPS[VAAPI_HEVC_10BIT]:-}" == "true" ]]; then
        vaapi_args+=("-vf" "format=p010le,hwupload" "-profile:v" "main10")
    else
        vaapi_args+=("-vf" "format=nv12,hwupload" "-profile:v" "main")
    fi

    # Quality and keyframe settings
    vaapi_args+=("-qp" "$QUALITY_PARAM" "-g" "250" "-keyint_min" "25")

    # Hardware-specific optimizations
    apply_vaapi_optimizations "$complexity" vaapi_args
}

# Apply VAAPI optimizations based on hardware vendor
# Args: complexity_level output_array_name
apply_vaapi_optimizations() {
    local complexity="$1"
    local -n vaapi_opt_args=$2

    if [[ "${HW_SUPPORT[AMD_DISCRETE]:-}" == "true" || "${HW_SUPPORT[AMD_INTEGRATED]:-}" == "true" ]]; then
        # AMD VAAPI optimizations
        vaapi_opt_args+=("-quality" "1" "-compression_level" "1")
        case "$complexity" in
            high)
                vaapi_opt_args+=("-bf" "3" "-refs" "3")
                ;;
            medium)
                vaapi_opt_args+=("-bf" "2" "-refs" "2")
                ;;
            *)
                vaapi_opt_args+=("-bf" "0" "-refs" "1")
                ;;
        esac
    elif [[ "${HW_SUPPORT[INTEL_INTEGRATED]:-}" == "true" || "${HW_SUPPORT[INTEL_DISCRETE]:-}" == "true" ]]; then
        # Intel VAAPI optimizations
        vaapi_opt_args+=("-quality" "4")
        case "$complexity" in
            high)
                vaapi_opt_args+=("-bf" "4" "-refs" "4")
                ;;
            *)
                vaapi_opt_args+=("-bf" "2" "-refs" "2")
                ;;
        esac
    fi
}

# Software encoder arguments
# Args: is_10bit complexity_level output_array_name
get_software_arguments() {
    local is_10bit="$1"
    local complexity="$2"
    local -n sw_args=$3

    sw_args+=("-c:v" "libx265")

    # Pixel format and profile
    if [[ "$is_10bit" == "true" ]]; then
        sw_args+=("-profile:v" "main10" "-pix_fmt" "yuv420p10le")
    else
        sw_args+=("-profile:v" "main" "-pix_fmt" "yuv420p")
    fi

    sw_args+=("-crf" "$QUALITY_PARAM")

    # CPU-optimized presets
    configure_software_preset "$complexity" sw_args
}

# Configure software encoding preset based on CPU and complexity
# Args: complexity_level output_array_name
configure_software_preset() {
    local complexity="$1"
    local -n preset_args=$2

    case "$complexity" in
        high)
            if [[ $CPU_CORES -gt 12 ]]; then
                preset_args+=("-preset" "slow" "-x265-params" "pools=$CPU_CORES:frame-threads=4")
            elif [[ $CPU_CORES -gt 8 ]]; then
                preset_args+=("-preset" "medium" "-x265-params" "pools=$CPU_CORES:frame-threads=3")
            else
                preset_args+=("-preset" "medium" "-x265-params" "pools=$CPU_CORES:frame-threads=2")
            fi
            ;;
        medium)
            preset_args+=("-preset" "medium" "-x265-params" "pools=$CPU_CORES")
            ;;
        *)
            preset_args+=("-preset" "fast" "-x265-params" "pools=$CPU_CORES")
            ;;
    esac

    # CPU vendor optimizations
    if [[ "$CPU_VENDOR" == "AMD" ]]; then
        local numa_pools=$(((CPU_CORES + 7) / 8))
        preset_args+=("-x265-params" "pools=+:numa-pools=$numa_pools")
    fi
}

# Get the currently selected encoder name
get_selected_encoder() {
    echo "$SELECTED_ENCODER"
}

# Get the fallback encoder name
get_fallback_encoder() {
    echo "$FALLBACK_ENCODER"
}
