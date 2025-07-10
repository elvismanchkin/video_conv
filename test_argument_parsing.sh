#!/bin/bash

# Test script for argument parsing validation
# This script tests the enhanced validation in cvrt.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CVRT_SCRIPT="${SCRIPT_DIR}/cvrt.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

# Test function
run_test() {
    local test_name="$1"
    local expected_exit_code="$2"
    shift 2
    local args=("$@")

    echo -n "Testing: $test_name ... "

    # Run the command and capture exit code
    local actual_exit_code=0
    if ! "${CVRT_SCRIPT}" "${args[@]}" >/dev/null 2>&1; then
        actual_exit_code=$?
    fi

    if [[ $actual_exit_code -eq $expected_exit_code ]]; then
        echo -e "${GREEN}PASS${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAIL${NC} (expected: $expected_exit_code, got: $actual_exit_code)"
        ((TESTS_FAILED++))
    fi
}

echo "Testing argument parsing validation in cvrt.sh"
echo "=============================================="

# Test 1: Valid arguments should work
run_test "Valid format, codec, and audio-codec" 0 --format mp4 --codec hevc --audio-codec aac --help

# Test 2: Invalid video codec should fail
run_test "Invalid video codec (h265)" 1 --codec h265 --help

# Test 3: Invalid output format should fail
run_test "Invalid output format (avi)" 1 --format avi --help

# Test 4: Invalid audio codec should fail
run_test "Invalid audio codec (wma)" 1 --audio-codec wma --help

# Test 5: Multiple invalid arguments should fail
run_test "Multiple invalid arguments" 1 --format avi --codec h265 --audio-codec wma --help

# Test 6: Valid arguments with different values
run_test "Valid mkv format" 0 --format mkv --help
run_test "Valid h264 codec" 0 --codec h264 --help
run_test "Valid opus audio codec" 0 --audio-codec opus --help

# Test 7: List commands should still work
run_test "List formats command" 0 --list-formats
run_test "List codecs command" 0 --list-codecs

# Test 8: Help command should work
run_test "Help command" 0 --help

echo
echo "Test Results:"
echo "============="
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
