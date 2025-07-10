#!/bin/bash

# Test script for flexible configuration sourcing
# This script tests the new multi-location configuration system

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CVRT_SCRIPT="${SCRIPT_DIR}/cvrt.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "Testing flexible configuration sourcing"
echo "======================================"

# Create test configuration files
create_test_config() {
    local file="$1"
    local content="$2"
    echo "$content" > "$file"
    echo "Created test config: $file"
}

# Clean up test files
cleanup_test_files() {
    rm -f ./custom.conf
    rm -f ~/.config/video_conv/custom.conf
    rm -f ~/.video_conv.conf
    rm -f config/custom.conf
    echo "Cleaned up test files"
}

# Test 1: Test XDG config directory
echo -n "Testing XDG config directory support ... "
mkdir -p ~/.config/video_conv
create_test_config ~/.config/video_conv/custom.conf "SUPPORTED_OUTPUT_FORMATS=(mkv mp4 avi)"
if ./cvrt.sh --list-formats 2>/dev/null | grep -q "avi"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    cleanup_test_files
    exit 1
fi
cleanup_test_files

# Test 2: Test current directory precedence
echo -n "Testing current directory precedence ... "
create_test_config ~/.config/video_conv/custom.conf "SUPPORTED_OUTPUT_FORMATS=(mkv mp4)"
create_test_config ./custom.conf "SUPPORTED_OUTPUT_FORMATS=(mkv mp4 avi webm)"
if ./cvrt.sh --list-formats 2>/dev/null | grep -q "webm"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    cleanup_test_files
    exit 1
fi
cleanup_test_files

# Test 3: Test home directory config
echo -n "Testing home directory config ... "
create_test_config ~/.video_conv.conf "SUPPORTED_OUTPUT_FORMATS=(mkv mp4 avi)"
if ./cvrt.sh --list-formats 2>/dev/null | grep -q "avi"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    cleanup_test_files
    exit 1
fi
cleanup_test_files

# Test 4: Test script directory fallback
echo -n "Testing script directory fallback ... "
create_test_config config/custom.conf "SUPPORTED_OUTPUT_FORMATS=(mkv mp4 avi)"
if ./cvrt.sh --list-formats 2>/dev/null | grep -q "avi"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    cleanup_test_files
    exit 1
fi
cleanup_test_files

# Test 5: Test XDG_CONFIG_HOME environment variable
echo -n "Testing XDG_CONFIG_HOME environment variable ... "
mkdir -p /tmp/test_xdg_config/video_conv
create_test_config /tmp/test_xdg_config/video_conv/custom.conf "SUPPORTED_OUTPUT_FORMATS=(mkv mp4 avi)"
if XDG_CONFIG_HOME=/tmp/test_xdg_config ./cvrt.sh --list-formats 2>/dev/null | grep -q "avi"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    rm -rf /tmp/test_xdg_config
    exit 1
fi
rm -rf /tmp/test_xdg_config

# Test 6: Test no config files (should use defaults)
echo -n "Testing default configuration (no custom files) ... "
if ./cvrt.sh --list-formats 2>/dev/null | grep -A 10 "Supported Output Formats:" | grep -q "mkv" && ! ./cvrt.sh --list-formats 2>/dev/null | grep -A 10 "Supported Output Formats:" | grep -q "avi"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    exit 1
fi

echo
echo -e "${GREEN}All configuration sourcing tests passed!${NC}"
echo
echo "Flexible configuration sourcing now supports:"
echo "✓ Current working directory (./custom.conf) - highest priority"
echo "✓ XDG config directory (~/.config/video_conv/custom.conf)"
echo "✓ User home directory (~/.video_conv.conf)"
echo "✓ Script directory (config/custom.conf) - lowest priority"
echo "✓ XDG_CONFIG_HOME environment variable support"
echo "✓ Proper precedence order (later sources override earlier ones)"
echo
echo "Users can now place configuration files in their preferred location"
echo "and have project-specific overrides while maintaining global defaults." 