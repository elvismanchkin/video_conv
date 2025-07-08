#!/bin/bash

# ==============================================================================
# GPU-Accelerated Video Converter (v8)
#
# NEW in v8:
# - Reverts to the faster CPU-decode/GPU-encode pipeline (like v6).
# - Adds an explicit GOP size (`-g 240`) as a final attempt to stabilize the
#   hardware encoder's initialization and fix artifacts at the start of video.
#
# USAGE: ./cvrt_v8.sh [--replace] [/path/to/directory]
# ==============================================================================

# --- Configuration ---
QUALITY_PARAM=24
GOP_SIZE=240 # Keyframe interval, ~10 seconds for 24fps video.
STEREO_BITRATE="192k"
VAAPI_DEVICE="/dev/dri/renderD128"

# --- Argument Parsing & Initialization ---
REPLACE_SOURCE=false
WORKDIR="."

if [[ "$1" == "-r" || "$1" == "--replace" ]]; then
    REPLACE_SOURCE=true
    echo "⚠️ Replace mode enabled. Source files will be overwritten on success."
    shift
fi

if [ -n "$1" ]; then
    WORKDIR="$1"
fi

if [ ! -d "$WORKDIR" ]; then
    echo "Error: Directory '$WORKDIR' not found."
    exit 1
fi

cd "$WORKDIR" || { echo "Error: Could not change to directory '$WORKDIR'."; exit 1; }

# --- Check for RAM Disk (/dev/shm) ---
SHM_PATH="/dev/shm"
CAN_USE_SHM=false
if [ -d "$SHM_PATH" ]; then
    CAN_USE_SHM=true
    echo "ℹ️ RAM Disk ($SHM_PATH) is available for use."
else
    echo "ℹ️ RAM Disk ($SHM_PATH) not found, will use standard disk for temp files."
fi

# --- Summary Counters ---
success_count=0
skipped_count=0
failed_count=0
file_list=$(ls *.mkv 2> /dev/null)
total_files=$(echo "$file_list" | wc -w)

echo "--- 🎬 Starting batch conversion in: $(pwd) ---"
echo "Found $total_files .mkv file(s) to process."

# --- Main Processing Loop ---
for file in $file_list; do
    [ -f "$file" ] || continue
    echo "--- Processing file: $file ---"

    # --- Path Determination ---
    final_destination_path=""
    if [ "$REPLACE_SOURCE" = true ]; then
        final_destination_path="$file"
    else
        final_destination_path="${file%.*}-converted.mkv"
    fi

    ffmpeg_output_path=""
    USE_SHM_FOR_FILE=false
    if [ "$CAN_USE_SHM" = true ]; then
        available_kb=$(df -k "$SHM_PATH" | awk 'NR==2 {print $4}')
        required_kb=$(du -k "$file" | cut -f1)
        if (( available_kb > required_kb )); then
            USE_SHM_FOR_FILE=true
            ffmpeg_output_path="$SHM_PATH/conv-temp-$$_$(basename "$file")"
            echo "👍 Using RAM disk for temporary output."
        else
            echo "⚠️ Not enough space on RAM disk for '$file'. Using standard disk."
        fi
    fi

    if [ ! "$USE_SHM_FOR_FILE" = true ]; then
        if [ "$REPLACE_SOURCE" = true ]; then
            ffmpeg_output_path="${file%.*}-TEMP-$$.mkv"
        else
            ffmpeg_output_path="$final_destination_path"
        fi
    fi

    # --- Pixel Format Detection & Encoder Argument Setup ---
    PIX_FMT=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$file")
    encoder_args=()
    if [[ "$PIX_FMT" == "yuv420p10le" ]]; then
        echo "ℹ️ Detected 10-bit video ($PIX_FMT). Using 10-bit encoding profile."
        encoder_args=("-vf" "format=p010le,hwupload" "-profile:v" "main10")
    else
        echo "ℹ️ Detected 8-bit video ($PIX_FMT). Using 8-bit encoding profile."
        encoder_args=("-vf" "format=nv12,hwupload")
    fi

    # --- Audio Stream Analysis ---
    valid_audio_count=$(ffprobe -v quiet -print_format json -show_streams "$file" | \
                        jq -r '[.streams[] | select(.codec_type=="audio" and .channels!=6)] | length')
    
    conversion_status=1 # 1 for fail, 0 for success

    if [ "$valid_audio_count" -eq 0 ]; then
        # --- 5.1 to 2.0 Conversion Logic ---
        mapfile -t five_one_indices < <(ffprobe -v quiet -print_format json -show_streams "$file" | \
                                          jq -r '.streams[] | select(.codec_type=="audio" and .channels==6) | .index')

        if [ ${#five_one_indices[@]} -eq 0 ]; then
            echo "Skipping: No audio streams found."
            ((skipped_count++)); continue
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
            else
                echo "Warning: Failed to convert audio stream #$index from '$file'."
            fi
        done

        if [ $audio_input_counter -eq 1 ]; then
            echo "Error: All audio conversions failed. Skipping."
            ((failed_count++)); trap - EXIT; rm -rf -- "$TEMP_DIR"; continue
        fi
        
        echo "Combining video, subtitles, and new stereo audio..."
        ffmpeg -vaapi_device "$VAAPI_DEVICE" "${ffmpeg_inputs[@]}" "${map_args[@]}" -map_metadata 0 \
               "${encoder_args[@]}" -c:v hevc_vaapi -qp "$QUALITY_PARAM" -g "$GOP_SIZE" \
               -c:a copy -c:s copy -y "$ffmpeg_output_path"
        conversion_status=$?
        
        trap - EXIT; rm -rf -- "$TEMP_DIR"

    else
        # --- Keep Existing Non-5.1 Tracks ---
        mapfile -t stream_indices < <(ffprobe -v quiet -print_format json -show_streams "$file" | \
                                      jq -r '.streams[] | select(.codec_type=="video" or .codec_type=="subtitle" or (.codec_type=="audio" and .channels!=6)) | .index')
        map_args=()
        for index in "${stream_indices[@]}"; do
            map_args+=("-map" "0:$index")
        done

        echo "Starting conversion (keeping original audio)..."
        ffmpeg -vaapi_device "$VAAPI_DEVICE" -i "$file" "${map_args[@]}" \
               "${encoder_args[@]}" -c:v hevc_vaapi -qp "$QUALITY_PARAM" -g "$GOP_SIZE" \
               -c:a copy -c:s copy -y "$ffmpeg_output_path"
        conversion_status=$?
    fi

    # --- Finalization and Cleanup ---
    if [ $conversion_status -eq 0 ]; then
        if [ "$ffmpeg_output_path" != "$final_destination_path" ]; then
            mv -f "$ffmpeg_output_path" "$final_destination_path"
            if [ $? -eq 0 ]; then
                 [ "$REPLACE_SOURCE" = true ] && echo "✅ Success. Source file replaced." || echo "✅ Successfully created: $final_destination_path"
                ((success_count++))
            else
                echo "❌ Error: Failed to move temporary file to '$final_destination_path'."
                ((failed_count++))
            fi
        else
            echo "✅ Successfully created: $final_destination_path"
            ((success_count++))
        fi
    else
        echo "❌ Error: FFmpeg command failed for '$file'."
        rm -f "$ffmpeg_output_path"
        ((failed_count++))
    fi
    echo "-------------------------------------"
done

# --- Final Summary ---
echo "--- ✨ All files processed. ---"
echo "Summary:"
echo "  - ✅ Successful: $success_count / $total_files"
echo "  - ❌ Failed:      $failed_count / $total_files"
echo "  - ⏭️ Skipped:     $skipped_count / $total_files"
echo "-------------------------------------"