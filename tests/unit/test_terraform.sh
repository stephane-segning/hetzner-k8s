#!/usr/bin/env bash
# Unit tests for Terraform configurations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

errors=0

echo "==> Testing Terraform variable defaults"

test_variable_default() {
    local var_name="$1"
    local expected_default="$2"
    local var_file="$3"
    
    actual=$(grep -A5 "variable \"$var_name\"" "$var_file" | grep "default" | sed 's/.*default[[:space:]]*=[[:space:]]*//; s/"//g' | tr -d ' ')
    
    if [ "$actual" = "$expected_default" ]; then
        echo "PASS: $var_name = $expected_default"
    else
        echo "FAIL: $var_name expected '$expected_default', got '$actual'"
        ((errors++))
    fi
}

test_variable_default "cluster_name" "hetzner-k8s" "$PROJECT_ROOT/terraform/envs/prod/main.tf"
test_variable_default "server_type" "cpx42" "$PROJECT_ROOT/terraform/envs/prod/main.tf"
test_variable_default "server_count" "3" "$PROJECT_ROOT/terraform/envs/prod/main.tf"
test_variable_default "location" "fsn1" "$PROJECT_ROOT/terraform/envs/prod/main.tf"

echo ""
echo "==> Testing module outputs exist"

test_output_exists() {
    local output_name="$1"
    local output_file="$2"
    
    if grep -q "output \"$output_name\"" "$output_file"; then
        echo "PASS: Output '$output_name' exists"
    else
        echo "FAIL: Output '$output_name' not found"
        ((errors++))
    fi
}

test_output_exists "ipv4_addresses" "$PROJECT_ROOT/terraform/modules/server/outputs.tf"
test_output_exists "first_node_public_ip" "$PROJECT_ROOT/terraform/modules/server/outputs.tf"
test_output_exists "ipv4_address" "$PROJECT_ROOT/terraform/modules/loadbalancer/outputs.tf"
test_output_exists "network_id" "$PROJECT_ROOT/terraform/modules/network/outputs.tf"

echo ""
echo "==> Testing required files exist"

test_file_exists() {
    local file="$1"
    
    if [ -f "$file" ]; then
        echo "PASS: $file exists"
    else
        echo "FAIL: $file not found"
        ((errors++))
    fi
}

test_file_exists "$PROJECT_ROOT/README.md"
test_file_exists "$PROJECT_ROOT/DECISIONS.md"
test_file_exists "$PROJECT_ROOT/Makefile"
test_file_exists "$PROJECT_ROOT/terraform/envs/prod/main.tf"
test_file_exists "$PROJECT_ROOT/terraform/envs/prod/outputs.tf"
test_file_exists "$PROJECT_ROOT/terraform/envs/prod/terraform.tfvars.example"

echo ""
echo "==> Testing YAML structure"

test_yaml_valid() {
    local yaml_file="$1"
    
    if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
        if python3 -c "import yaml; yaml.safe_load_all(open('$yaml_file'))" 2>/dev/null; then
            echo "PASS: $yaml_file is valid YAML"
        else
            echo "FAIL: $yaml_file has invalid YAML"
            ((errors++))
        fi
    else
        # Fallback: check basic YAML structure
        if head -1 "$yaml_file" | grep -qE "^(apiVersion|kind|---|#)"; then
            echo "PASS: $yaml_file appears to be valid YAML (basic check)"
        else
            echo "FAIL: $yaml_file does not appear to be valid YAML"
            ((errors++))
        fi
    fi
}

for yaml in "$PROJECT_ROOT"/platform/base/*.yaml; do
    test_yaml_valid "$yaml"
done

echo ""
if [ $errors -gt 0 ]; then
    echo "FAILED: $errors tests failed"
    exit 1
else
    echo "SUCCESS: All tests passed"
fi
