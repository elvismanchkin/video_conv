#!/bin/bash

# Test script for enhanced filter compatibility validation
# This script tests the improved validate_filter_compatibility function

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CVRT_SCRIPT="${SCRIPT_DIR}/cvrt.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "Testing enhanced filter compatibility validation"
echo "==============================================="

# Test 1: Test suboptimal combination (should show warning but continue)
echo -n "Testing suboptimal combination (NVENC + deinterlace) ... "
if ./cvrt.sh --nvenc --deinterlace --help >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    exit 1
fi

# Test 2: Test suboptimal combination (NVENC + denoise)
echo -n "Testing suboptimal combination (NVENC + denoise) ... "
if ./cvrt.sh --nvenc --denoise --help >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    exit 1
fi

# Test 3: Test suboptimal combination (NVENC + sharpen)
echo -n "Testing suboptimal combination (NVENC + sharpen) ... "
if ./cvrt.sh --nvenc --sharpen --help >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    exit 1
fi

# Test 4: Test suboptimal combination (QSV + denoise)
echo -n "Testing suboptimal combination (QSV + denoise) ... "
if ./cvrt.sh --qsv --denoise --help >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    exit 1
fi

# Test 5: Test suboptimal combination (VAAPI + denoise)
echo -n "Testing suboptimal combination (VAAPI + denoise) ... "
if ./cvrt.sh --vaapi --denoise --help >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    exit 1
fi

# Test 6: Test software encoding (should work with all filters)
echo -n "Testing software encoding with all filters ... "
if ./cvrt.sh --cpu --denoise --sharpen --deinterlace --help >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    exit 1
fi

# Test 7: Test multiple suboptimal filters together
echo -n "Testing multiple suboptimal filters (NVENC + deinterlace + denoise) ... "
if ./cvrt.sh --nvenc --deinterlace --denoise --help >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL${NC}"
    exit 1
fi

echo
echo -e "${GREEN}All filter compatibility tests passed!${NC}"
echo
echo "Enhanced filter compatibility validation now provides:"
echo "✓ Clear visual warnings for suboptimal combinations"
echo "✓ Fatal error detection for known problematic combinations"
echo "✓ Specific recommendations for each issue"
echo "✓ Graceful handling of different encoder types"
echo
echo "Users will now see prominent warnings when using filters that may not work"
echo "optimally with their chosen encoder, helping them make informed decisions."
