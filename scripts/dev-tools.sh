#!/bin/bash

# Development tools for video converter project
# Usage: ./dev-tools.sh [command]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

check_shellcheck() {
    log_info "Checking if ShellCheck is installed..."
    if command -v shellcheck >/dev/null 2>&1; then
        log_success "ShellCheck found: $(shellcheck --version | head -1)"
        return 0
    else
        log_warn "ShellCheck not installed. Install with:"
        echo "  Ubuntu/Debian: sudo apt install shellcheck"
        echo "  Fedora: sudo dnf install ShellCheck"
        echo "  macOS: brew install shellcheck"
        return 1
    fi
}

run_shellcheck() {
    if ! check_shellcheck; then
        return 1
    fi

    log_info "Running ShellCheck on all shell scripts..."
    local exit_code=0

    while IFS= read -r -d '' file; do
        echo "Checking: $file"
        if ! shellcheck "$file"; then
            exit_code=1
        fi
    done < <(find "$SCRIPT_DIR" -name "*.sh" -print0)

    if [[ $exit_code -eq 0 ]]; then
        log_success "All shell scripts passed ShellCheck"
    else
        log_error "Some shell scripts failed ShellCheck"
    fi

    return $exit_code
}

check_syntax() {
    log_info "Checking bash syntax on all shell scripts..."
    local exit_code=0

    while IFS= read -r -d '' file; do
        echo "Checking syntax: $file"
        if ! bash -n "$file"; then
            exit_code=1
        fi
    done < <(find "$SCRIPT_DIR" -name "*.sh" -print0)

    if [[ $exit_code -eq 0 ]]; then
        log_success "All shell scripts have valid syntax"
    else
        log_error "Some shell scripts have syntax errors"
    fi

    return $exit_code
}

check_trailing_whitespace() {
    log_info "Checking for trailing whitespace..."
    local found=false

    while IFS= read -r -d '' file; do
        if grep -q " $" "$file"; then
            echo "Trailing whitespace found in: $file"
            found=true
        fi
    done < <(find "$SCRIPT_DIR" -name "*.sh" -print0)

    if [[ "$found" == false ]]; then
        log_success "No trailing whitespace found"
    else
        log_warn "Trailing whitespace found in some files"
    fi
}

check_missing_newlines() {
    log_info "Checking for missing final newlines..."
    local found=false

    while IFS= read -r -d '' file; do
        if [[ -s "$file" ]] && [[ $(tail -c1 "$file" | wc -l) -eq 0 ]]; then
            echo "Missing final newline in: $file"
            found=true
        fi
    done < <(find "$SCRIPT_DIR" -name "*.sh" -print0)

    if [[ "$found" == false ]]; then
        log_success "All files have final newlines"
    else
        log_warn "Some files are missing final newlines"
    fi
}

format_code() {
    log_info "Formatting shell scripts..."

    # Remove trailing whitespace
    find "$SCRIPT_DIR" -name "*.sh" -exec sed -i 's/[[:space:]]*$//' {} \;

    # Ensure final newlines
    find "$SCRIPT_DIR" -name "*.sh" -exec sh -c 'tail -c1 "$1" | read -r _ || echo >> "$1"' _ {} \;

    log_success "Code formatting completed"
}

run_tests() {
    log_info "Running basic functionality tests..."

    # Test help output
    if [[ -f "$SCRIPT_DIR/cvrt.sh" ]]; then
        if "$SCRIPT_DIR/cvrt.sh" --help >/dev/null 2>&1; then
            log_success "Help command works"
        else
            log_error "Help command failed"
            return 1
        fi
    fi

    log_success "Basic tests completed"
}

show_help() {
    cat << EOF
Development tools for video converter project

USAGE: $0 [COMMAND]

COMMANDS:
    shellcheck    Run ShellCheck on all shell scripts
    syntax        Check bash syntax on all shell scripts
    whitespace    Check for trailing whitespace
    newlines      Check for missing final newlines
    format        Format code (remove trailing whitespace, add newlines)
    test          Run basic functionality tests
    all           Run all checks
    help          Show this help

EXAMPLES:
    $0 shellcheck
    $0 all
    $0 format
EOF
}

main() {
    case "${1:-help}" in
        shellcheck)
            run_shellcheck
            ;;
        syntax)
            check_syntax
            ;;
        whitespace)
            check_trailing_whitespace
            ;;
        newlines)
            check_missing_newlines
            ;;
        format)
            format_code
            ;;
        test)
            run_tests
            ;;
        all)
            log_info "Running all checks..."
            run_shellcheck || true
            check_syntax || true
            check_trailing_whitespace
            check_missing_newlines
            run_tests || true
            log_info "All checks completed"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
