#!/bin/bash

# ==============================================================================
# GPU-Accelerated Video Converter (with 5.1 to Stereo Fallback)
#
# This script iterates through all .mkv files in the specified directory
# (or the current directory if none is provided).
#
# It attempts to keep all non-5.1 audio tracks. If a file ONLY has 5.1
# audio, the script will convert each 5.1 track to a 2.0 stereo AAC track
# and use those in the final output file.
#
# Original video, all subtitles, and the appropriate audio tracks (either
# the original non-5.1 or the converted stereo) are kept. The video is
# re-encoded using GPU acceleration.
#
# USAGE: ./cvrt_v2.sh [path/to/directory]
#
# REQUIREMENTS: ffmpeg, ffprobe, jq, and VA-API drivers must be installed.
# ==============================================================================

# --- Configuration ---
# Set the video quality. Lower is better quality, higher is smaller file.
# 20-28 is a reasonable range.
QUALITY_PARAM=24

# Set the audio quality for 5.1 -> stereo conversion.
STEREO_BITRATE="192k"

# Set the VA-API render device.
# /dev/dri/renderD128 is usually the discrete GPU.
# Check `ls /dev/dri` if you are unsure.
VAAPI_DEVICE="/dev/dri/renderD128"

# --- Script Logic ---
# Set the working directory to the first argument, or the current directory if not provided.
WORKDIR="${1:-.}"

# Check if the provided path is a valid directory
if [ ! -d "$WORKDIR" ]; then
    echo "Error: Directory '$WORKDIR' not found."
    exit 1
fi

# Change to the target directory. Exit if the directory change fails.
cd "$WORKDIR" || { echo "Error: Could not change to directory '$WORKDIR'."; exit 1; }

echo "--- Starting batch conversion in: $(pwd) ---"

# Loop through every .mkv file in the current directory
for file in *.mkv; do
    # Check if the file exists to avoid errors with empty directories
    [ -f "$file" ] || continue

    echo "--- Processing file: $file ---"

    # Define the output filename
    output_file="${file%.*}-converted.mkv"

    # Count how many audio tracks are NOT 6-channel (5.1)
    valid_audio_count=$(ffprobe -v quiet -print_format json -show_streams "$file" | \
                        jq -r '[.streams[] | select(.codec_type=="audio" and .channels!=6)] | length')

    # ==========================================================================
    # MODIFIED LOGIC BLOCK: Check if we need to convert or copy audio
    # ==========================================================================

    if [ "$valid_audio_count" -eq 0 ]; then
        # --- NEW: 5.1 to 2.0 Conversion Logic ---
        # This block runs if NO non-5.1 audio tracks were found.
        echo "No non-5.1 audio found. Converting 5.1 tracks to stereo."

        # Get the indices of all 6-channel (5.1) audio tracks
        mapfile -t five_one_indices < <(ffprobe -v quiet -print_format json -show_streams "$file" | \
                                          jq -r '.streams[] | select(.codec_type=="audio" and .channels==6) | .index')

        # If there are no 5.1 tracks either, then there's no audio at all. Skip.
        if [ ${#five_one_indices[@]} -eq 0 ]; then
            echo "Could not find any audio streams to process. Skipping."
            continue
        fi

        # Create a temporary directory for the converted audio files
        TEMP_DIR=$(mktemp -d)
        # Set a trap to automatically clean up the temp directory on script exit or error
        trap 'rm -rf -- "$TEMP_DIR"' EXIT

        ffmpeg_inputs=("-i" "$file")
        map_args=("-map" "0:v" "-map" "0:s?") # Map all video and all subtitle streams from the original file
        audio_input_counter=1

        # Loop through each 5.1 track, convert it, and add it to our argument lists
        for index in "${five_one_indices[@]}"; do
            echo "Converting 5.1 audio track #$index to stereo..."
            output_audio="$TEMP_DIR/audio_$index.m4a"
            
            # Convert one audio track to stereo AAC
            ffmpeg -y -i "$file" -map "0:$index" -c:a aac -ac 2 -b:a "$STEREO_BITRATE" "$output_audio" &> /dev/null

            # If conversion was successful, add it to our inputs and map arguments
            if [ $? -eq 0 ]; then
                ffmpeg_inputs+=("-i" "$output_audio")
                map_args+=("-map" "$audio_input_counter:a") # Map the audio from the new input file
                ((audio_input_counter++))
            else
                echo "Warning: Failed to convert audio stream #$index from '$file'."
            fi
        done
        
        # If all audio conversions failed, we can't proceed.
        if [ $audio_input_counter -eq 1 ]; then
            echo "Error: All audio conversions failed for '$file'. Skipping."
            # Clean up and continue to the next file
            trap - EXIT
            rm -rf -- "$TEMP_DIR"
            continue
        fi

        echo "Combining video, subtitles, and new stereo audio..."
        # Run the final GPU-accelerated command with multiple inputs
        ffmpeg -vaapi_device "$VAAPI_DEVICE" \
               "${ffmpeg_inputs[@]}" \
               "${map_args[@]}" \
               -map_metadata 0 \
               -vf 'format=nv12,hwupload' \
               -c:v hevc_vaapi \
               -qp "$QUALITY_PARAM" \
               -c:a copy \
               -c:s copy \
               "$output_file"

        # Conversion is done, disable and manually run the cleanup trap
        trap - EXIT
        rm -rf -- "$TEMP_DIR"

    else
        # --- ORIGINAL: Keep Existing Non-5.1 Tracks ---
        # This block runs if at least one non-5.1 audio track was found.
        echo "Found $valid_audio_count non-5.1 audio track(s) to keep."

        map_args=()
        # Get indices for all video, subtitle, and non-5.1 audio streams
        mapfile -t stream_indices < <(ffprobe -v quiet -print_format json -show_streams "$file" | \
                                      jq -r '.streams[] | select(.codec_type=="video" or .codec_type=="subtitle" or (.codec_type=="audio" and .channels!=6)) | .index')

        # Build the map arguments from the found indices
        for index in "${stream_indices[@]}"; do
            map_args+=("-map" "0:$index")
        done

        echo "Starting conversion (keeping original audio)..."
        # Run the original GPU-accelerated FFmpeg command
        ffmpeg -vaapi_device "$VAAPI_DEVICE" \
               -i "$file" \
               "${map_args[@]}" \
               -vf 'format=nv12,hwupload' \
               -c:v hevc_vaapi \
               -qp "$QUALITY_PARAM" \
               -c:a copy \
               -c:s copy \
               "$output_file"
    fi

    echo "Successfully created: $output_file"
    echo "-------------------------------------"
done

echo "All files processed."
