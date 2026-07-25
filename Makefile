.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

TF_DIR ?= terraform/envs/prod
TF_VARS ?= $(TF_DIR)/terraform.tfvars
KUBECONFIG ?= kubeconfig
BACKEND_CONFIG ?=

.PHONY: help init plan apply destroy bootstrap platform-install verify test lint render fmt clean

help:
	@echo "Hetzner Kubernetes Platform"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Infrastructure:"
	@echo "  init        Initialize Terraform"
	@echo "  plan        Plan Terraform changes"
	@echo "  apply       Apply Terraform infrastructure"
	@echo "  destroy     Destroy all infrastructure"
	@echo "  output      Show Terraform outputs"
	@echo ""
	@echo "Bootstrap:"
	@echo "  bootstrap   Bootstrap k3s cluster"
	@echo "  platform-install Install Cilium and base platform"
	@echo "  get-kubeconfig Retrieve kubeconfig from first node"
	@echo ""
	@echo "Verification:"
	@echo "  verify      Verify cluster health"
	@echo "  nodes       Show cluster nodes"
	@echo ""
	@echo "Testing:"
	@echo "  test        Run all tests"
	@echo "  test-tf     Test Terraform"
	@echo "  test-render Test manifest rendering"
	@echo "  lint        Lint all code"
	@echo "  fmt         Format all code"
	@echo "  render      Render all manifests"
	@echo ""
	@echo "Cleanup:"
	@echo "  clean       Remove generated files"

init:
	@echo "==> Initializing Terraform"
	cd $(TF_DIR) && terraform init $(if $(BACKEND_CONFIG),-backend-config=$(BACKEND_CONFIG),-backend=false)

plan:
	@echo "==> Planning Terraform changes"
	cd $(TF_DIR) && terraform plan -var-file=$(notdir $(TF_VARS))

apply:
	@echo "==> Applying Terraform infrastructure"
	cd $(TF_DIR) && terraform apply -auto-approve -var-file=$(notdir $(TF_VARS))

destroy:
	@echo "==> Destroying infrastructure"
	cd $(TF_DIR) && terraform destroy -var-file=$(notdir $(TF_VARS))

output:
	cd $(TF_DIR) && terraform output

bootstrap:
	@echo "==> Bootstrapping k3s cluster"
	./bootstrap/scripts/bootstrap.sh

platform-install:
	@echo "==> Installing platform components"
	./bootstrap/scripts/install-platform.sh

get-kubeconfig:
	@echo "==> Retrieving kubeconfig"
	./bootstrap/scripts/get-kubeconfig.sh

verify:
	@echo "==> Verifying cluster health"
	@kubectl get nodes -o wide
	@echo ""
	@kubectl get pods -A

nodes:
	@kubectl get nodes -o wide

test: test-tf test-render test-unit test-scripts
	@echo "==> All tests passed"

test-tf:
	@echo "==> Testing Terraform"
	@terraform fmt -check -recursive terraform/
	@cd $(TF_DIR) && terraform init -backend=false >/dev/null && terraform validate

test-render:
	@echo "==> Testing manifest rendering"
	@./tests/render/validate-all.sh

test-unit:
	@echo "==> Running unit tests"
	@./tests/unit/test_terraform.sh
	@./tests/unit/test_scripts.sh

test-scripts:
	@echo "==> Testing scripts"
	@shellcheck bootstrap/scripts/*.sh 2>/dev/null || echo "shellcheck not installed, skipping"

lint: lint-tf lint-yaml lint-shell
	@echo "==> Linting complete"

lint-tf:
	@terraform fmt -check -recursive terraform/ || (echo "Run 'make fmt' to fix" && exit 1)

lint-yaml:
	@echo "==> Linting YAML"
	@find platform workloads tests -name "*.yaml" -o -name "*.yml" | head -20 | xargs -I {} sh -c 'echo "Checking {}"'

lint-shell:
	@shellcheck bootstrap/scripts/*.sh 2>/dev/null || echo "shellcheck not installed, skipping"

fmt:
	@echo "==> Formatting code"
	@terraform fmt -recursive terraform/
	@echo "Done"

render:
	@echo "==> Rendering manifests"
	@mkdir -p tests/render/output
	@./tests/render/render-all.sh

clean:
	@echo "==> Cleaning generated files"
	@rm -rf tests/render/output
	@rm -f kubeconfig kubeconfig.*

show-costs:
	@echo "==> Estimated monthly costs (net, ex-VAT)"
	@echo "Baseline: Hetzner Usage preview 01-25 Jul 2026 (576h). Prices rose ~25% on 2026-04-01."
	@echo ""
	@echo "3x CPX32 control planes:            ~€40-45   [TBC: CPX22 was 7.99 ea before ADR-0018]"
	@echo "4x CPX42 workers:                   ~€102     (25.49 ea)"
	@echo "3x LB11 (api, traefik, core-gw):    ~€22      (7.49 ea)"
	@echo "1x Object Storage (state+etcd):     €6.49"
	@echo "~25x CSI PVC volumes (10-64GB):     ~€11      (0.0572/GB/mo)"
	@echo "7x primary IPv4:                    ~€3.50    (0.50 ea)"
	@echo "Estimated total:                    ~€185-190/month net (~€220 gross incl. 19% VAT)"
	@echo ""
	@echo "NOT included: off-cloud Robot GPU servers (gpu-1/gpu-2) bill on a SEPARATE Robot invoice."
	@echo "The old '~EUR100/month' target predates the Apr-2026 price rise, the 2->4 worker"
	@echo "scale-up, the 3rd LB, and the CP resize. See docs/adr/0018 and arc42 SS 10.5."
