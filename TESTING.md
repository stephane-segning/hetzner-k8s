# Testing Strategy

This document describes the test coverage and approach for this project.

## What Is Tested

### Terraform

| Test | Description | Tool |
|------|-------------|------|
| Format check | Validates HCL formatting | `terraform fmt -check` |
| Validate | Validates configuration | `terraform validate` |
| Variable defaults | Unit tests for default values | bash script |
| Output existence | Verifies required outputs | bash script |

### Kubernetes Manifests

| Test | Description | Tool |
|------|-------------|------|
| YAML syntax | Validates YAML structure | Python YAML parser |
| Schema validation | Validates against K8s schemas | kubeconform (optional) |
| Render dry-run | Renders all manifests without applying | helm template |

### Shell Scripts

| Test | Description | Tool |
|------|-------------|------|
| ShellCheck | Static analysis for bash | shellcheck |

### Structural

| Test | Description | Tool |
|------|-------------|------|
| File existence | Verifies required files exist | bash script |
| README commands | Validates referenced commands work | manual |

## What Is NOT Tested (Yet)

- **Live infrastructure**: No integration tests with real Hetzner resources
- **k3s bootstrap**: Manual verification required
- **Argo CD sync**: Requires home-cluster setup
- **End-to-end workflows**: Requires live cluster

## Running Tests

### All Tests

```bash
make test
```

### Individual Test Suites

```bash
# Terraform tests
make test-tf

# Manifest rendering
make render

# Shell script linting
make lint-shell

# Unit tests
./tests/unit/test_terraform.sh
```

### Validation Only

```bash
./tests/render/validate-all.sh
```

## Test Coverage

### Terraform Modules

Each module has tests for:

1. **Variables**: Required variables are defined
2. **Outputs**: Required outputs are defined
3. **Resources**: Resources are correctly configured

### Platform Manifests

Each manifest is validated for:

1. **Syntax**: Valid YAML structure
2. **Schema**: Valid Kubernetes API objects (with kubeconform)
3. **Helm**: Charts render without errors

## CI Integration

For CI pipelines, use:

```yaml
test:
  script:
    - terraform fmt -check -recursive terraform/
    - cd terraform/envs/prod && terraform init -backend=false && terraform validate
    - ./tests/render/validate-all.sh
    - shellcheck bootstrap/scripts/*.sh
```

## Test Assumptions

1. **No live API**: Tests do not call Hetzner API
2. **No cluster**: Tests do not require running Kubernetes
3. **No secrets**: Tests use placeholder values
4. **Optional tools**: kubeconform, shellcheck, helm are optional

## Improving Tests

To add more comprehensive tests:

1. **Add Terratest**: For Terraform integration tests (requires Hetzner account)
2. **Add conftest**: For policy-based validation of manifests
3. **Add kuttl**: For Kubernetes end-to-end testing (requires cluster)
4. **Add pre-commit**: For automated pre-commit checks

## Known Limitations

- k3s bootstrap requires manual verification
- NetworkPolicy effectiveness requires running cluster
- Load balancer integration requires live infrastructure
- Argo CD applications require home-cluster setup
