#!/usr/bin/env bash
# Unit tests for shell scripts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

errors=0

echo "==> Testing bootstrap script syntax"

test_script_syntax() {
    local script="$1"
    
    if bash -n "$script" 2>/dev/null; then
        echo "PASS: $script has valid bash syntax"
    else
        echo "FAIL: $script has syntax errors"
        ((errors++))
    fi
}

for script in "$PROJECT_ROOT"/bootstrap/scripts/*.sh; do
    test_script_syntax "$script"
done

echo ""
echo "==> Testing bootstrap script functions"

test_function_exists() {
    local script="$1"
    local function="$2"
    
    if grep -q "^${function}()" "$script"; then
        echo "PASS: Function '$function' exists in $(basename $script)"
    else
        echo "FAIL: Function '$function' not found in $(basename $script)"
        ((errors++))
    fi
}

test_function_exists "$PROJECT_ROOT/bootstrap/scripts/bootstrap.sh" "check_prerequisites"
test_function_exists "$PROJECT_ROOT/bootstrap/scripts/bootstrap.sh" "bootstrap_server"

echo ""
if [ $errors -gt 0 ]; then
    echo "FAILED: $errors tests failed"
    exit 1
else
    echo "SUCCESS: All tests passed"
fi
