#!/bin/bash
# Test script for the NodeOverlay blueprint
# This script validates that the blueprint works as documented in the README
#
# Prerequisites:
# - kubectl configured with access to an EKS cluster
# - Karpenter installed with NodeOverlay feature gate enabled
# - Environment variables set: CLUSTER_NAME, KARPENTER_NODE_IAM_ROLE_NAME
#
# Usage: ./test.sh [scenario1|scenario2|all]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test configuration
TIMEOUT_NODE_READY=300  # 5 minutes for GPU nodes
TIMEOUT_POD_READY=60

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test() { echo -e "${GREEN}[TEST]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found"
        exit 1
    fi
    
    if ! kubectl get nodes &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    # Check NodeOverlay feature gate
    FEATURE_GATES=$(kubectl -n karpenter get deployment karpenter -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FEATURE_GATES")].value}' 2>/dev/null || echo "")
    if [[ ! "$FEATURE_GATES" == *"NodeOverlay=true"* ]]; then
        log_error "NodeOverlay feature gate is not enabled in Karpenter"
        log_info "Enable it with: helm upgrade karpenter ... --set 'settings.featureGates.nodeOverlay=true'"
        exit 1
    fi
    
    log_info "Prerequisites check passed"
}

# Wait for nodeclaim to be ready
wait_for_nodeclaim() {
    local label_selector=$1
    local expected_count=$2
    local timeout=$TIMEOUT_NODE_READY
    local elapsed=0
    
    log_info "Waiting for $expected_count nodeclaim(s) with selector '$label_selector' to be ready..."
    
    while [ $elapsed -lt $timeout ]; do
        ready_count=$(kubectl get nodeclaims -l "$label_selector" --no-headers 2>/dev/null | grep -c "True" || true)
        ready_count=${ready_count:-0}
        ready_count=$((ready_count + 0))  # Force integer
        if [ "$ready_count" -ge "$expected_count" ]; then
            log_info "$ready_count nodeclaim(s) ready"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo ""
    log_error "Timeout waiting for nodeclaims to be ready"
    kubectl get nodeclaims -l "$label_selector" 2>/dev/null || true
    return 1
}

# Wait for pods to be running
wait_for_pods() {
    local label_selector=$1
    local expected_count=$2
    local timeout=$TIMEOUT_POD_READY
    local elapsed=0
    
    log_info "Waiting for $expected_count pod(s) with selector '$label_selector' to be running..."
    
    while [ $elapsed -lt $timeout ]; do
        running_count=$(kubectl get pods -l "$label_selector" --no-headers 2>/dev/null | grep -c "Running" || true)
        running_count=${running_count:-0}
        running_count=$((running_count + 0))  # Force integer
        if [ "$running_count" -ge "$expected_count" ]; then
            log_info "$running_count pod(s) running"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    log_error "Timeout waiting for pods to be running"
    kubectl get pods -l "$label_selector" 2>/dev/null || true
    return 1
}

# Cleanup function
cleanup_scenario1() {
    log_info "Cleaning up Scenario 1..."
    kubectl delete -f workload-generation.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f node-overlay-generation.yaml --ignore-not-found=true 2>/dev/null || true
    sleep 10
}

cleanup_scenario2() {
    log_info "Cleaning up Scenario 2..."
    kubectl delete -f workload-gpu-slices.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f node-overlay-gpu-slices.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f gpu-nodepool.yaml --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f gpu-nodeclass.yaml --ignore-not-found=true 2>/dev/null || true
    sleep 10
}

# ============================================================================
# SCENARIO 1: Instance Generation Prioritization
# ============================================================================
test_scenario1() {
    log_test "=== SCENARIO 1: Instance Generation Prioritization ==="
    
    cleanup_scenario1
    
    # Deploy NodeOverlays
    log_info "Deploying NodeOverlays for generation prioritization..."
    kubectl apply -f node-overlay-generation.yaml
    
    # Verify NodeOverlays are ready
    sleep 5
    overlay_count=$(kubectl get nodeoverlay --no-headers 2>/dev/null | grep -E "penalize-gen[567]" | wc -l)
    if [ "$overlay_count" -lt 3 ]; then
        log_error "Expected 3 NodeOverlays, found $overlay_count"
        cleanup_scenario1
        return 1
    fi
    log_info "NodeOverlays created successfully"
    
    # Deploy workload
    log_info "Deploying test workload..."
    kubectl apply -f workload-generation.yaml
    
    # Wait for node to be provisioned
    if ! wait_for_nodeclaim "karpenter.sh/nodepool=default" 1; then
        log_error "Failed to provision node"
        cleanup_scenario1
        return 1
    fi
    
    # Verify the node is generation 8
    log_info "Verifying node generation..."
    node_generation=$(kubectl get nodeclaims -l karpenter.sh/nodepool=default -o jsonpath='{.items[0].metadata.labels.karpenter\.k8s\.aws/instance-generation}' 2>/dev/null || echo "unknown")
    instance_type=$(kubectl get nodeclaims -l karpenter.sh/nodepool=default -o jsonpath='{.items[0].spec.instanceType}' 2>/dev/null || echo "unknown")
    
    log_info "Provisioned instance: $instance_type (generation $node_generation)"
    
    if [ "$node_generation" == "8" ]; then
        log_test "✅ PASSED: Node is generation 8 as expected"
        cleanup_scenario1
        return 0
    else
        log_error "❌ FAILED: Expected generation 8, got generation $node_generation"
        cleanup_scenario1
        return 1
    fi
}

# ============================================================================
# SCENARIO 2: GPU Time-Slicing
# ============================================================================
test_scenario2() {
    log_test "=== SCENARIO 2: GPU Time-Slicing ==="
    
    # Check environment variables - use defaults if not set
    if [ -z "$CLUSTER_NAME" ]; then
        export CLUSTER_NAME="karpenter-blueprints"
        log_warn "CLUSTER_NAME not set, using default: $CLUSTER_NAME"
    fi
    if [ -z "$KARPENTER_NODE_IAM_ROLE_NAME" ]; then
        export KARPENTER_NODE_IAM_ROLE_NAME="karpenter-blueprints"
        log_warn "KARPENTER_NODE_IAM_ROLE_NAME not set, using default: $KARPENTER_NODE_IAM_ROLE_NAME"
    fi
    
    log_info "Using cluster: $CLUSTER_NAME, IAM role: $KARPENTER_NODE_IAM_ROLE_NAME"
    
    cleanup_scenario2
    
    # Prepare EC2NodeClass with cluster-specific values
    log_info "Preparing EC2NodeClass..."
    sed "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g; s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" gpu-nodeclass.yaml > /tmp/gpu-nodeclass-test.yaml
    
    # Deploy resources
    log_info "Deploying GPU EC2NodeClass and NodePool..."
    kubectl apply -f /tmp/gpu-nodeclass-test.yaml
    kubectl apply -f gpu-nodepool.yaml
    kubectl apply -f node-overlay-gpu-slices.yaml
    
    sleep 5
    
    # Verify NodeOverlays are ready
    overlay_count=$(kubectl get nodeoverlay --no-headers 2>/dev/null | grep -E "gpu-slices-[1248]gpu" | wc -l)
    if [ "$overlay_count" -lt 4 ]; then
        log_error "Expected 4 GPU NodeOverlays, found $overlay_count"
        cleanup_scenario2
        return 1
    fi
    
    # --- TEST 1: Deploy 4 replicas, expect 1 node ---
    log_test "--- Test 1: 4 replicas should fit on 1 GPU node ---"
    kubectl apply -f workload-gpu-slices.yaml
    
    if ! wait_for_nodeclaim "karpenter.sh/nodepool=gpu-slices" 1; then
        log_error "Test 1 failed: No GPU node provisioned"
        cleanup_scenario2
        return 1
    fi
    
    # Wait for pods
    sleep 30
    if ! wait_for_pods "app=workload-gpu-slices" 4; then
        log_error "Test 1 failed: Pods not running"
        cleanup_scenario2
        return 1
    fi
    
    # Verify time-slicing is working (node should advertise 4 GPUs)
    gpu_capacity=$(kubectl get nodes -l karpenter.sh/nodepool=gpu-slices -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
    if [ "$gpu_capacity" != "4" ]; then
        log_warn "Expected GPU capacity 4 (time-sliced), got $gpu_capacity"
    fi
    
    node_count=$(kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-slices --no-headers 2>/dev/null | grep -c "True" || echo "0")
    if [ "$node_count" -eq 1 ]; then
        log_test "✅ Test 1 PASSED: 4 pods running on 1 GPU node"
    else
        log_error "❌ Test 1 FAILED: Expected 1 node, got $node_count"
        cleanup_scenario2
        return 1
    fi
    
    # --- TEST 2: Scale to 8 replicas, expect 2 nodes ---
    log_test "--- Test 2: 8 replicas should need 2 GPU nodes ---"
    kubectl scale deployment workload-gpu-slices --replicas=8
    
    if ! wait_for_nodeclaim "karpenter.sh/nodepool=gpu-slices" 2; then
        log_error "Test 2 failed: Second GPU node not provisioned"
        cleanup_scenario2
        return 1
    fi
    
    sleep 30
    if ! wait_for_pods "app=workload-gpu-slices" 8; then
        log_error "Test 2 failed: Not all pods running"
        cleanup_scenario2
        return 1
    fi
    
    node_count=$(kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-slices --no-headers 2>/dev/null | grep -c "True" || echo "0")
    if [ "$node_count" -eq 2 ]; then
        log_test "✅ Test 2 PASSED: 8 pods running on 2 GPU nodes"
    else
        log_error "❌ Test 2 FAILED: Expected 2 nodes, got $node_count"
        cleanup_scenario2
        return 1
    fi
    
    # --- TEST 3: Scale to 17 replicas, expect 5 nodes ---
    log_test "--- Test 3: 17 replicas should need 5 GPU nodes ---"
    kubectl scale deployment workload-gpu-slices --replicas=17
    
    if ! wait_for_nodeclaim "karpenter.sh/nodepool=gpu-slices" 5; then
        log_error "Test 3 failed: Not enough GPU nodes provisioned"
        cleanup_scenario2
        return 1
    fi
    
    sleep 60
    if ! wait_for_pods "app=workload-gpu-slices" 17; then
        log_error "Test 3 failed: Not all pods running"
        cleanup_scenario2
        return 1
    fi
    
    node_count=$(kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-slices --no-headers 2>/dev/null | grep -c "True" || echo "0")
    if [ "$node_count" -ge 5 ]; then
        log_test "✅ Test 3 PASSED: 17 pods running on $node_count GPU nodes"
    else
        log_error "❌ Test 3 FAILED: Expected at least 5 nodes, got $node_count"
        cleanup_scenario2
        return 1
    fi
    
    cleanup_scenario2
    log_test "=== SCENARIO 2: ALL TESTS PASSED ==="
    return 0
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    local test_target="${1:-all}"
    local exit_code=0
    
    check_prerequisites
    
    case "$test_target" in
        scenario1)
            test_scenario1 || exit_code=1
            ;;
        scenario2)
            test_scenario2 || exit_code=1
            ;;
        all)
            test_scenario1 || exit_code=1
            test_scenario2 || exit_code=1
            ;;
        *)
            echo "Usage: $0 [scenario1|scenario2|all]"
            exit 1
            ;;
    esac
    
    if [ $exit_code -eq 0 ]; then
        log_test "=== ALL TESTS PASSED ==="
    else
        log_error "=== SOME TESTS FAILED ==="
    fi
    
    exit $exit_code
}

main "$@"
