#!/bin/bash

# ==============================================================================
# GPU-Accelerated Video Converter (v5)
#
# This script iterates through all .mkv files in a target directory, re-encodes
# the video using VA-API, and handles audio tracks.
#
# NEW in v5:
# - Automatically uses a RAM disk (/dev/shm) for temporary files and the
#   primary conversion artifact to reduce disk I/O and speed up the process.
#   This is only done if /dev/shm exists and has sufficient space for the file.
#
# USAGE: ./cvrt_v5.sh [--replace] [/path/to/directory]
#
# REQUIREMENTS: ffmpeg, ffprobe, jq, and VA-API drivers must be installed.
# ==============================================================================

# --- Configuration ---
QUALITY_PARAM=24
STEREO_BITRATE="192k"
VAAPI_DEVICE="/dev/dri/renderD128"

# --- Argument Parsing & Initialization ---
REPLACE_SOURCE=false
WORKDIR="."

if [[ "$1" == "-r" || "$1" == "--replace" ]]; then
    REPLACE_SOURCE=true
    echo "⚠️ Replace mode enabled. Source files will be overwritten on success."
    shift # Remove the flag from arguments
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

    # --- Determine Paths ---
    final_destination_path=""
    if [ "$REPLACE_SOURCE" = true ]; then
        final_destination_path="$file"
    else
        final_destination_path="${file%.*}-converted.mkv"
    fi

    # Determine the temporary path for FFmpeg's output
    ffmpeg_output_path=""
    USE_SHM_FOR_FILE=false
    if [ "$CAN_USE_SHM" = true ]; then
        available_kb=$(df -k "$SHM_PATH" | awk 'NR==2 {print $4}')
        required_kb=$(du -k "$file" | cut -f1) # Estimate output size <= input size
        if (( available_kb > required_kb )); then
            USE_SHM_FOR_FILE=true
            ffmpeg_output_path="$SHM_PATH/conv-temp-$$_$(basename "$file")"
            echo "👍 Using RAM disk for temporary output to speed up conversion."
        else
            echo "⚠️ Not enough space on RAM disk for '$file'. Using standard disk."
        fi
    fi

    if [ "$USE_SHM_FOR_FILE" = false ]; then
        if [ "$REPLACE_SOURCE" = true ]; then
            ffmpeg_output_path="${file%.*}-TEMP-$$.mkv"
        else
            ffmpeg_output_path="$final_destination_path"
        fi
    fi

    # --- Audio Stream Analysis ---
    valid_audio_count=$(ffprobe -v quiet -print_format json -show_streams "$file" | \
                        jq -r '[.streams[] | select(.codec_type=="audio" and .channels!=6)] | length')
    
    ffmpeg_cmd=()
    conversion_status=1 # 1 for fail, 0 for success

    # ==========================================================================
    # Audio Processing Logic
    # ==========================================================================
    if [ "$valid_audio_count" -eq 0 ]; then
        # --- 5.1 to 2.0 Conversion Logic ---
        echo "No non-5.1 audio found. Converting 5.1 tracks to stereo."
        mapfile -t five_one_indices < <(ffprobe -v quiet -print_format json -show_streams "$file" | \
                                          jq -r '.streams[] | select(.codec_type=="audio" and .channels==6) | .index')

        if [ ${#five_one_indices[@]} -eq 0 ]; then
            echo "Skipping: Could not find any audio streams to process."
            ((skipped_count++))
            continue
        fi

        # Use /dev/shm for audio temp files if available
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
            echo "Error: All audio conversions failed for '$file'. Skipping."
            ((failed_count++))
            trap - EXIT; rm -rf -- "$TEMP_DIR"
            continue
        fi
        
        echo "Combining video, subtitles, and new stereo audio..."
        ffmpeg_cmd=(ffmpeg -vaapi_device "$VAAPI_DEVICE" "${ffmpeg_inputs[@]}" "${map_args[@]}" -map_metadata 0 -vf 'format=nv12,hwupload' -c:v hevc_vaapi -qp "$QUALITY_PARAM" -c:a copy -c:s copy -y "$ffmpeg_output_path")
        
        "${ffmpeg_cmd[@]}"
        conversion_status=$?
        
        trap - EXIT; rm -rf -- "$TEMP_DIR"

    else
        # --- Keep Existing Non-5.1 Tracks ---
        echo "Found $valid_audio_count non-5.1 audio track(s) to keep."
        mapfile -t stream_indices < <(ffprobe -v quiet -print_format json -show_streams "$file" | \
                                      jq -r '.streams[] | select(.codec_type=="video" or .codec_type=="subtitle" or (.codec_type=="audio" and .channels!=6)) | .index')
        map_args=()
        for index in "${stream_indices[@]}"; do
            map_args+=("-map" "0:$index")
        done

        echo "Starting conversion (keeping original audio)..."
        ffmpeg_cmd=(ffmpeg -vaapi_device "$VAAPI_DEVICE" -i "$file" "${map_args[@]}" -vf 'format=nv12,hwupload' -c:v hevc_vaapi -qp "$QUALITY_PARAM" -c:a copy -c:s copy -y "$ffmpeg_output_path")
        
        "${ffmpeg_cmd[@]}"
        conversion_status=$?
    fi

    # ==========================================================================
    # Finalization and Cleanup
    # ==========================================================================
    if [ $conversion_status -eq 0 ]; then
        # If output was written to a temporary location, move it to the final destination
        if [ "$ffmpeg_output_path" != "$final_destination_path" ]; then
            mv -f "$ffmpeg_output_path" "$final_destination_path"
            if [ $? -eq 0 ]; then
                if [ "$REPLACE_SOURCE" = true ]; then
                    echo "✅ Success. Source file replaced."
                else
                    echo "✅ Successfully created: $final_destination_path"
                fi
                ((success_count++))
            else
                echo "❌ Error: Failed to move temporary file to '$final_destination_path'."
                ((failed_count++))
            fi
        else
            # File was written directly to its final destination
            echo "✅ Successfully created: $final_destination_path"
            ((success_count++))
        fi
    else
        echo "❌ Error: FFmpeg command failed for '$file'."
        rm -f "$ffmpeg_output_path" # Clean up failed temp/output file
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