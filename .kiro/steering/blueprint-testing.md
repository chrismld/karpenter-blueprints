---
inclusion: manual
---

# Blueprint Testing Guidelines

When creating or modifying Karpenter blueprints, include a `test.sh` script that validates the blueprint works as documented.

## Test Script Structure

Each blueprint's `test.sh` should:

1. **Check prerequisites** - Verify kubectl access, required feature gates, environment variables
2. **Deploy resources** - Apply the blueprint's YAML files
3. **Validate behavior** - Confirm the expected outcomes from the README
4. **Cleanup** - Remove all created resources

## Template

```bash
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test() { echo -e "${GREEN}[TEST]${NC} $1"; }

check_prerequisites() {
    # Verify kubectl, cluster access, feature gates, env vars
}

cleanup() {
    # Delete all resources created by the test
}

test_scenario() {
    cleanup
    # Deploy resources
    # Wait for expected state
    # Validate results
    # Return 0 on success, 1 on failure
}

main() {
    check_prerequisites
    test_scenario || exit 1
    cleanup
    log_test "=== ALL TESTS PASSED ==="
}

main "$@"
```

## Key Patterns

### Waiting for Resources

```bash
wait_for_nodeclaim() {
    local label_selector=$1
    local expected_count=$2
    local timeout=300
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        ready_count=$(kubectl get nodeclaims -l "$label_selector" --no-headers 2>/dev/null | grep -c "True" || echo "0")
        if [ "$ready_count" -ge "$expected_count" ]; then
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    return 1
}
```

### Handling Placeholders

If the blueprint uses placeholders like `<<CLUSTER_NAME>>`, replace them before applying:

```bash
sed "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g; s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" nodeclass.yaml > /tmp/nodeclass-test.yaml
kubectl apply -f /tmp/nodeclass-test.yaml
```

### Test Assertions

Validate specific outcomes documented in the README:

```bash
# Check instance generation
node_generation=$(kubectl get nodeclaims -l karpenter.sh/nodepool=default -o jsonpath='{.items[0].metadata.labels.karpenter\.k8s\.aws/instance-generation}')
if [ "$node_generation" == "8" ]; then
    log_test "✅ PASSED: Node is generation 8"
else
    log_error "❌ FAILED: Expected generation 8, got $node_generation"
    return 1
fi
```

## Running Tests

```bash
# Run all tests for a blueprint
./blueprints/<blueprint-name>/test.sh

# Run specific scenario (if supported)
./blueprints/<blueprint-name>/test.sh scenario1
```

## Reference Implementation

See `blueprints/node-overlay/test.sh` for a complete example with multiple scenarios.
