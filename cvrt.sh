#!/bin/bash

# ==============================================================================
# GPU-Accelerated Video Converter (Skips 5.1 Audio)
#
# This script iterates through all .mkv files in the current directory.
# For each file, it automatically keeps the video, all subtitles, and ALL
# audio tracks that are NOT 5.1 surround sound. It then re-encodes the
# video using GPU acceleration.
#
# DETECTION METHOD: A 5.1 audio track has 6 channels. The script looks for
# any audio stream where the channel count is not equal to 6.
#
# REQUIREMENTS: ffmpeg, ffprobe, jq, and VA-API drivers must be installed.
# ==============================================================================

# --- Configuration ---
# Set the video quality. Lower is better quality, higher is smaller file.
# 20-28 is a reasonable range.
QUALITY_PARAM=24

# Set the VA-API render device.
# /dev/dri/renderD128 is usually the discrete GPU (e.g., your RX 580).
# Check `ls /dev/dri` if you are unsure.
VAAPI_DEVICE="/dev/dri/renderD128"

# --- Script Logic ---
# Loop through every .mkv file in the current directory
for file in *.mkv; do
    # Check if the file exists to avoid errors with empty directories
    [ -f "$file" ] || continue

    echo "--- Processing file: $file ---"

    # Create an empty array to hold our '-map' arguments
    map_args=()

    # Use ffprobe and jq to find the index of all desired streams.
    # We want streams that are: video OR subtitle OR (audio AND NOT 6-channel).
    # The `mapfile` command reads the output lines into a bash array.
    mapfile -t stream_indices < <(ffprobe -v quiet -print_format json -show_streams "$file" | \
                                  jq -r '.streams[] | select(.codec_type=="video" or .codec_type=="subtitle" or (.codec_type=="audio" and .channels!=6)) | .index')


    # Check if we found any streams at all.
    if [ ${#stream_indices[@]} -eq 0 ]; then
        echo "Could not find any suitable video/audio streams to process. Skipping."
        continue
    fi
    
    # Check if we found at least one valid audio track.
    # The `jq` expression here is slightly different to only count valid audio tracks.
    valid_audio_count=$(ffprobe -v quiet -print_format json -show_streams "$file" | \
                        jq -r '[.streams[] | select(.codec_type=="audio" and .channels!=6)] | length')

    if [ "$valid_audio_count" -eq 0 ]; then
        echo "No audio tracks other than 5.1 found. Skipping file."
        continue
    fi

    echo "Found $valid_audio_count audio track(s) to keep."

    # Dynamically build the array of '-map' arguments from the indices we found
    for index in "${stream_indices[@]}"; do
        map_args+=("-map" "0:$index")
    done

    # Define the output filename
    output_file="${file%.*}-no5.1.mkv"

    echo "Starting conversion..."

    # Run the GPU-accelerated FFmpeg command using the dynamically built map arguments
    ffmpeg -vaapi_device "$VAAPI_DEVICE" \
           -i "$file" \
           "${map_args[@]}" \
           -vf 'format=nv12,hwupload' \
           -c:v hevc_vaapi \
           -qp "$QUALITY_PARAM" \
           -c:a copy \
           -c:s copy \
           "$output_file"

    echo "Successfully created: $output_file"
    echo "-------------------------------------"
done

echo "All files processed."
