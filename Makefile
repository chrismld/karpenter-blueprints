# Karpenter Blueprints - Makefile
# 
# Usage:
#   make test                    # Run all blueprint tests
#   make test-node-overlay       # Run node-overlay blueprint tests
#   make test BLUEPRINT=node-overlay  # Alternative way to test specific blueprint
#   make list-blueprints         # List all blueprints with test.sh
#   make env                     # Show cluster environment variables

.PHONY: help test test-all list-blueprints env clean

# Default values (from cluster/terraform template)
# These match the Terraform template defaults for maintainers
DEFAULT_CLUSTER_NAME := karpenter-blueprints
DEFAULT_NODE_ROLE_NAME := karpenter-blueprints

# Use environment variables if set, otherwise use defaults
CLUSTER_NAME ?= $(DEFAULT_CLUSTER_NAME)
KARPENTER_NODE_IAM_ROLE_NAME ?= $(DEFAULT_NODE_ROLE_NAME)

# Export for child processes
export CLUSTER_NAME
export KARPENTER_NODE_IAM_ROLE_NAME

# Default target
help:
	@echo "Karpenter Blueprints - Available Commands"
	@echo ""
	@echo "  make test                         Run all blueprint tests"
	@echo "  make test BLUEPRINT=<name>        Run tests for a specific blueprint"
	@echo "  make test-<blueprint-name>        Run tests for a specific blueprint"
	@echo "  make list-blueprints              List all blueprints with test.sh"
	@echo "  make env                          Show environment variables"
	@echo "  make clean                        Clean up any test artifacts"
	@echo ""
	@echo "Examples:"
	@echo "  make test-node-overlay            Test the node-overlay blueprint"
	@echo "  make test BLUEPRINT=node-overlay  Same as above"
	@echo ""
	@echo "Default cluster: $(DEFAULT_CLUSTER_NAME)"
	@echo "Override with: CLUSTER_NAME=my-cluster make test"

# List all blueprints that have test.sh
list-blueprints:
	@echo "Blueprints with test.sh:"
	@find blueprints -name "test.sh" -type f | sed 's|blueprints/||;s|/test.sh||' | sort

# Show environment variable status
env:
	@echo "Environment Variables:"
	@echo ""
	@echo "  CLUSTER_NAME: $(CLUSTER_NAME)"
	@echo "  KARPENTER_NODE_IAM_ROLE_NAME: $(KARPENTER_NODE_IAM_ROLE_NAME)"
	@echo ""
	@echo "Defaults: $(DEFAULT_CLUSTER_NAME) / $(DEFAULT_NODE_ROLE_NAME)"
	@echo ""
	@echo "To override: export CLUSTER_NAME=my-cluster KARPENTER_NODE_IAM_ROLE_NAME=my-role"

# Run all blueprint tests
test-all test:
ifdef BLUEPRINT
	@if [ -f "blueprints/$(BLUEPRINT)/test.sh" ]; then \
		echo "Running tests for blueprint: $(BLUEPRINT)"; \
		./blueprints/$(BLUEPRINT)/test.sh; \
	else \
		echo "Error: No test.sh found for blueprint '$(BLUEPRINT)'"; \
		echo "Available blueprints with tests:"; \
		find blueprints -name "test.sh" -type f | sed 's|blueprints/||;s|/test.sh||' | sort; \
		exit 1; \
	fi
else
	@echo "Running all blueprint tests..."
	@failed=0; \
	for test_script in $$(find blueprints -name "test.sh" -type f | sort); do \
		blueprint=$$(echo $$test_script | sed 's|blueprints/||;s|/test.sh||'); \
		echo ""; \
		echo "========================================"; \
		echo "Testing blueprint: $$blueprint"; \
		echo "========================================"; \
		if $$test_script; then \
			echo "✅ $$blueprint: PASSED"; \
		else \
			echo "❌ $$blueprint: FAILED"; \
			failed=1; \
		fi; \
	done; \
	echo ""; \
	if [ $$failed -eq 0 ]; then \
		echo "========================================"; \
		echo "✅ ALL BLUEPRINT TESTS PASSED"; \
		echo "========================================"; \
	else \
		echo "========================================"; \
		echo "❌ SOME BLUEPRINT TESTS FAILED"; \
		echo "========================================"; \
		exit 1; \
	fi
endif

# Dynamic targets for each blueprint (test-<blueprint-name>)
test-%:
	@if [ -f "blueprints/$*/test.sh" ]; then \
		echo "Running tests for blueprint: $*"; \
		./blueprints/$*/test.sh; \
	else \
		echo "Error: No test.sh found for blueprint '$*'"; \
		echo "Available blueprints with tests:"; \
		find blueprints -name "test.sh" -type f | sed 's|blueprints/||;s|/test.sh||' | sort; \
		exit 1; \
	fi

# Clean up test artifacts
clean:
	@echo "Cleaning up test artifacts..."
	@rm -f /tmp/gpu-nodeclass-test.yaml
	@echo "Done"
