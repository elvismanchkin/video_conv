#!/bin/bash
set -e

# Local CI script to mirror GitHub Actions workflow

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

fail() {
  echo -e "${RED}FAILED:${NC} $1"
  exit 1
}

warn() {
  echo -e "${YELLOW}WARNING:${NC} $1"
}

echo -e "${GREEN}==> Running ShellCheck on all .sh files${NC}"
if ! command -v shellcheck >/dev/null; then
  fail "ShellCheck not found! Please install it (e.g., sudo dnf install ShellCheck or sudo apt install shellcheck)"
fi
find . -name "*.sh" -exec shellcheck {} \;

echo -e "${GREEN}==> Checking bash syntax for all .sh files${NC}"
find . -name "*.sh" -exec bash -n {} \;

echo -e "${GREEN}==> Checking script help output${NC}"
chmod +x ./cvrt.sh
./cvrt.sh --help > /dev/null || fail "cvrt.sh --help failed"

echo -e "${GREEN}==> Checking for trailing whitespace${NC}"
trailing=$(find . -name "*.sh" -exec grep -l " $" {} \;)
if [[ -n "$trailing" ]]; then
  warn "Trailing whitespace found in:"
  echo "$trailing"
  exit 1
fi

echo -e "${GREEN}==> Checking for missing newlines at EOF${NC}"
missing_newline=$(find . -name "*.sh" -exec sh -c 'tail -c1 "$1" | read -r _ || echo "$1"' _ {} \;)
if [[ -n "$missing_newline" ]]; then
  warn "Files missing newline at EOF:"
  echo "$missing_newline"
  exit 1
fi

echo -e "${GREEN}All CI checks passed!${NC}"
