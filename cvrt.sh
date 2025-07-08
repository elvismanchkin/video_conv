#!/bin/bash

# ==============================================================================
# GPU-Accelerated Video Converter (v4)
#
# This script iterates through all .mkv files in a target directory, re-encodes
# the video using VA-API, and handles audio tracks.
#
# BUGFIX in v4:
# - Correctly added the 'ffmpeg' command to the execution array, fixing the
#   "-vaapi_device: command not found" error.
#
# USAGE: ./cvrt_v4.sh [--replace] [/path/to/directory]
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

# Simple argument parsing for the --replace flag and optional directory
if [[ "$1" == "-r" || "$1" == "--replace" ]]; then
    REPLACE_SOURCE=true
    echo "⚠️ Replace mode enabled. Source files will be overwritten on success."
    shift # Remove the flag from arguments
fi

# Use the next argument as the working directory, if it exists
if [ -n "$1" ]; then
    WORKDIR="$1"
fi

# Check if the provided path is a valid directory
if [ ! -d "$WORKDIR" ]; then
    echo "Error: Directory '$WORKDIR' not found."
    exit 1
fi

# Change to the target directory. Exit if the directory change fails.
cd "$WORKDIR" || { echo "Error: Could not change to directory '$WORKDIR'."; exit 1; }

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
    # Check if the file exists to avoid errors with empty directories
    [ -f "$file" ] || continue

    echo "--- Processing file: $file ---"

    # If replacing, use a temp name; otherwise, use the "-converted" suffix.
    if [ "$REPLACE_SOURCE" = true ]; then
        output_file="${file%.*}-TEMP-$$.mkv"
    else
        output_file="${file%.*}-converted.mkv"
    fi

    # Count how many audio tracks are NOT 6-channel (5.1)
    valid_audio_count=$(ffprobe -v quiet -print_format json -show_streams "$file" | \
                        jq -r '[.streams[] | select(.codec_type=="audio" and .channels!=6)] | length')

    # Default ffmpeg command arguments
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

        TEMP_DIR=$(mktemp -d)
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
            trap - EXIT
            rm -rf -- "$TEMP_DIR"
            continue
        fi
        
        echo "Combining video, subtitles, and new stereo audio..."
        # FIXED: Added 'ffmpeg' to the start of the command array
        ffmpeg_cmd=(ffmpeg -vaapi_device "$VAAPI_DEVICE" "${ffmpeg_inputs[@]}" "${map_args[@]}" -map_metadata 0 -vf 'format=nv12,hwupload' -c:v hevc_vaapi -qp "$QUALITY_PARAM" -c:a copy -c:s copy -y "$output_file")
        
        # Run ffmpeg
        "${ffmpeg_cmd[@]}"
        conversion_status=$?
        
        # Clean up temp audio files
        trap - EXIT
        rm -rf -- "$TEMP_DIR"

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
        # FIXED: Added 'ffmpeg' to the start of the command array
        ffmpeg_cmd=(ffmpeg -vaapi_device "$VAAPI_DEVICE" -i "$file" "${map_args[@]}" -vf 'format=nv12,hwupload' -c:v hevc_vaapi -qp "$QUALITY_PARAM" -c:a copy -c:s copy -y "$output_file")
        
        # Run ffmpeg
        "${ffmpeg_cmd[@]}"
        conversion_status=$?
    fi

    # ==========================================================================
    # Finalization and Cleanup
    # ==========================================================================
    if [ $conversion_status -eq 0 ]; then
        if [ "$REPLACE_SOURCE" = true ]; then
            # Move the temporary file to replace the original
            mv -f "$output_file" "$file"
            if [ $? -eq 0 ]; then
                echo "✅ Success. Source file replaced."
                ((success_count++))
            else
                echo "❌ Error: Failed to replace source with '$output_file'."
                ((failed_count++))
            fi
        else
            echo "✅ Successfully created: $output_file"
            ((success_count++))
        fi
    else
        echo "❌ Error: FFmpeg command failed for '$file'."
        rm -f "$output_file" # Clean up failed temp/output file
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
