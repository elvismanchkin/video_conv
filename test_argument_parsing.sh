#!/bin/bash

# Test script to demonstrate robust argument parsing
# This script tests the cvrt.sh argument parsing with different option orders

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

# Function to run a test
run_test() {
    local test_name="$1"
    local expected_output="$2"
    shift 2
    local args=("$@")

    echo -e "${YELLOW}Testing: $test_name${NC}"
    echo "Command: ./cvrt.sh ${args[*]}"

    # Capture output and exit code
    local output
    local exit_code
    output=$(./cvrt.sh "${args[@]}" 2>&1) || exit_code=$?

    # Check if the output contains expected content
    if echo "$output" | grep -q "$expected_output"; then
        echo -e "${GREEN}✓ PASS${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ FAIL${NC}"
        echo "Expected: $expected_output"
        echo "Got: $output"
        ((TESTS_FAILED++))
    fi
    echo
}

# Function to test error cases
run_error_test() {
    local test_name="$1"
    local expected_error="$2"
    shift 2
    local args=("$@")

    echo -e "${YELLOW}Testing Error: $test_name${NC}"
    echo "Command: ./cvrt.sh ${args[*]}"

    # Capture output and exit code
    local output
    local exit_code
    output=$(./cvrt.sh "${args[@]}" 2>&1) || exit_code=$?

    # Check if the output contains expected error
    if echo "$output" | grep -q "$expected_error"; then
        echo -e "${GREEN}✓ PASS (Error correctly caught)${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ FAIL (Error not caught properly)${NC}"
        echo "Expected error: $expected_error"
        echo "Got: $output"
        ((TESTS_FAILED++))
    fi
    echo
}

echo "Testing cvrt.sh argument parsing robustness..."
echo "=============================================="
echo

# Test 1: Normal order
run_test "Normal order" "Output format: mp4" --format mp4 --codec h264

# Test 2: Reversed order (this was the problematic case)
run_test "Reversed order" "Output format: mp4" --codec h264 --format mp4

# Test 3: Mixed order
run_test "Mixed order" "Video codec: h264" --format mp4 --debug --codec h264 --replace

# Test 4: Multiple options with values
run_test "Multiple value options" "Thread count: 4" --format mkv --codec hevc --threads 4 --audio-codec aac

# Test 5: Error case - missing argument
run_error_test "Missing format argument" "Missing format argument" --format

# Test 6: Error case - invalid format
run_error_test "Invalid format" "Invalid output format" --format invalid_format

# Test 7: Error case - invalid codec
run_error_test "Invalid codec" "Invalid video codec" --codec invalid_codec

# Test 8: Error case - invalid thread count
run_error_test "Invalid thread count" "Invalid thread count" --threads -1

# Test 9: Error case - invalid quality
run_error_test "Invalid quality" "Invalid quality parameter" --quality 9999

# Test 10: Help and list commands
run_test "Help command" "GPU Video Converter" --help

run_test "List formats" "Supported Output Formats" --list-formats

run_test "List codecs" "Supported Video Codecs" --list-codecs

echo "=============================================="
echo "Test Results:"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo "Total: $((TESTS_PASSED + TESTS_FAILED))"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed! Argument parsing is robust.${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. Please review the argument parsing implementation.${NC}"
    exit 1
fi
