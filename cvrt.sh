#!/bin/bash

# Entry point for GPU Video Converter
# This script calls the main implementation in src/cvrt.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="${SCRIPT_DIR}/src/cvrt.sh"

if [[ ! -f "$MAIN_SCRIPT" ]]; then
    echo "Error: Main script not found at $MAIN_SCRIPT" >&2
    exit 1
fi

# Execute the main script with all arguments
exec "$MAIN_SCRIPT" "$@"
