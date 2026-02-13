# Karpenter Blueprint: Using NodeOverlays

## Purpose

[NodeOverlays](https://karpenter.sh/docs/concepts/nodeoverlays/) are a Karpenter feature (currently in alpha) that allows you to inject alternative instance type information into Karpenter's scheduling simulation. This enables fine-tuning of instance pricing and adding extended resources to instance types that Karpenter considers during its decision-making process.

NodeOverlays work by modifying the instance type information that Karpenter uses during its scheduling simulation. When Karpenter evaluates which instance types can satisfy pending pod requirements, it applies any matching NodeOverlays to adjust pricing information or add extended resources before making provisioning decisions.

There are two primary use cases for NodeOverlays:

1. **Price adjustments**: Influence Karpenter's instance type selection by adjusting the perceived price of certain instance types. This is useful for prioritizing newer generation instances, accounting for savings plans, or reflecting licensing costs.

2. **Extended resources**: Add custom resources to instance types that Karpenter should consider during scheduling. This is particularly useful for GPU slicing scenarios where you want Karpenter to understand that a single GPU can serve multiple workloads.

This blueprint demonstrates both use cases with practical examples.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A `default` Karpenter `EC2NodeClass` and `NodePool` as that's the one we'll reference in this blueprint. You did this already in the ["Deploy a Karpenter Default EC2NodeClass and NodePool"](../../README.md) section from this repository.

**NOTE:** NodeOverlays are currently in alpha (`v1alpha1`) and the API may change in future versions.

## Enable NodeOverlay Feature Gate

NodeOverlays require enabling the `NodeOverlay` feature gate in Karpenter. Update your Karpenter deployment to include the feature gate:

```sh
helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace karpenter \
  --set "settings.featureGates.nodeOverlay=true" \
  --reuse-values
```

Alternatively, if you're using the Terraform template from this repository, you can add the feature gate to the Karpenter Helm values.

Verify the feature gate is enabled by checking the Karpenter controller logs:

```sh
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --all-containers=true | grep -i "feature"
```

---

## Scenario 1: Prioritizing Latest Generation Instances

### Overview

When you have multiple instance generations available (e.g., Graviton 3 and Graviton 4), you might want Karpenter to prefer the latest generation for better price-performance. By default, Karpenter selects instances based on price, but newer generations often provide better value even at similar or slightly higher prices.

Using NodeOverlays, you can adjust the perceived price of older generation instances to make newer generations more attractive to Karpenter's scheduling algorithm.

### How It Works

When you apply a `priceAdjustment` to instance types via NodeOverlay, Karpenter adjusts its internal price calculations before making provisioning decisions:

- **For On-Demand instances**: Karpenter uses the `lowest-price` allocation strategy by default. With NodeOverlay price adjustments, the perceived prices change, effectively creating a `prioritized` behavior where instances with lower adjusted prices are preferred.
- **For Spot instances**: Karpenter uses the `price-capacity-optimized` (PCO) allocation strategy. While price adjustments do influence the selection, capacity availability takes precedence—EC2 will prioritize pools with the highest capacity to reduce interruption risk, which may override your price preferences.

For this reason, we'll use On-Demand instances in this example to demonstrate deterministic behavior based on price adjustments.

### Deploy

**NOTE:** This scenario assumes your `default` NodePool allows both `c7g` and `c8g` instance families. If your NodePool restricts instance families, make sure both are included in the requirements.

First, let's create a NodeOverlay that makes `c7g` (Graviton 3) instances appear 50% more expensive, effectively giving preference to `c8g` (Graviton 4) instances:

```sh
kubectl apply -f node-overlay-generation.yaml
```

Now deploy a sample workload that will trigger Karpenter to provision a node:

```sh
kubectl apply -f workload-generation.yaml
```

### Results

Wait about one minute for Karpenter to provision the node:

```sh
kubectl get nodeclaims
```

You should see a `c8g` instance being launched instead of `c7g`:

```console
NAME            TYPE          ZONE         NODE                                        READY   AGE
default-xxxxx   c8g.xlarge    eu-west-1b   ip-10-0-xx-xx.eu-west-1.compute.internal    True    45s
```

You can verify the NodeOverlay is applied by checking its status:

```sh
kubectl get nodeoverlay prefer-graviton4 -o yaml
```

Look for the `Ready=True` condition indicating the overlay is successfully applied.

### Cleanup Scenario 1

```sh
kubectl delete -f workload-generation.yaml
kubectl delete -f node-overlay-generation.yaml
```

---

## Scenario 2: GPU Slicing with Extended Resources

### Overview

GPU instances are expensive, and many inference workloads don't need an entire GPU. Techniques like [NVIDIA Time-Slicing](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html), [MIG (Multi-Instance GPU)](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/), or [MPS (Multi-Process Service)](https://docs.nvidia.com/deploy/mps/index.html) allow multiple workloads to share a single GPU.

However, Karpenter doesn't natively understand these GPU sharing configurations. By default, it sees `nvidia.com/gpu: 1` as a whole GPU. NodeOverlays solve this by allowing you to add extended resources (like `nvidia.com/gpu-slice`) that represent fractional GPU capacity.

**Important Clarification**: NodeOverlay only affects Karpenter's scheduling simulation and consolidation decisions. It does NOT:
- Configure actual GPU slicing on the node
- Set up time-slicing, MIG, or any GPU sharing mechanism
- Modify the physical GPU resources

You are responsible for:
1. Configuring GPU sharing on your nodes (via NVIDIA device plugin configuration, MIG setup, etc.)
2. Ensuring your applications are aware they're sharing GPU resources
3. Setting appropriate resource limits in your workloads

NodeOverlay simply helps Karpenter make better scheduling and consolidation decisions by understanding that a single GPU can serve multiple workloads.

### How It Works

In this example, we'll tell Karpenter that GPU instances have 4 "GPU slices" per physical GPU. This means:
- A `g5.xlarge` (1 GPU) will be seen as having 4 `nvidia.com/gpu-slice` resources
- A `g5.2xlarge` (1 GPU) will also have 4 slices
- A `g5.12xlarge` (4 GPUs) will have 16 slices

When workloads request `nvidia.com/gpu-slice: 1`, Karpenter understands that 4 such workloads can fit on a single GPU instance.

### Deploy

First, create the NodePool for GPU instances (we'll use the existing `default` EC2NodeClass):

```sh
kubectl apply -f gpu-nodepool.yaml
```

Now apply the NodeOverlay that adds GPU slice resources. This overlay uses the `karpenter.k8s.aws/instance-gpu-count` label to dynamically calculate slices (4 slices per GPU):

```sh
kubectl apply -f node-overlay-gpu-slices.yaml
```

### Test 1: Deploy 4 Replicas

Deploy 4 replicas, each requesting 1 GPU slice (1/4 of a GPU):

```sh
kubectl apply -f workload-gpu-slices.yaml
```

Wait for Karpenter to provision the node:

```sh
kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-slices
```

You should see a single GPU instance launched:

```console
NAME              TYPE          ZONE         NODE                                        READY   AGE
gpu-slices-xxx    g5.xlarge     eu-west-1a   ip-10-0-xx-xx.eu-west-1.compute.internal    True    60s
```

All 4 pods should be running on this single node because Karpenter understands that 4 GPU slices fit on 1 GPU.

### Test 2: Scale to 8 Replicas

```sh
kubectl scale deployment workload-gpu-slices --replicas=8
```

Check the nodes:

```sh
kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-slices
```

Karpenter should either:
- Launch a second single-GPU instance, or
- Replace with a 2-GPU instance (like `g5.2xlarge` if available and cost-effective)

```console
NAME              TYPE           ZONE         NODE                                        READY   AGE
gpu-slices-xxx    g5.xlarge      eu-west-1a   ip-10-0-xx-xx.eu-west-1.compute.internal    True    2m
gpu-slices-yyy    g5.xlarge      eu-west-1b   ip-10-0-yy-yy.eu-west-1.compute.internal    True    30s
```

### Test 3: Scale to 17 Replicas

```sh
kubectl scale deployment workload-gpu-slices --replicas=17
```

With 17 replicas each needing 1 slice, and 4 slices per GPU, Karpenter needs at least 5 GPUs worth of capacity (17/4 = 4.25, rounded up to 5).

Check the nodes:

```sh
kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-slices
```

You might see a combination like:
- Multiple single-GPU instances, or
- A mix of instance sizes depending on availability and cost optimization

```console
NAME              TYPE           ZONE         NODE                                        READY   AGE
gpu-slices-xxx    g5.xlarge      eu-west-1a   ip-10-0-xx-xx.eu-west-1.compute.internal    True    5m
gpu-slices-yyy    g5.xlarge      eu-west-1b   ip-10-0-yy-yy.eu-west-1.compute.internal    True    3m
gpu-slices-zzz    g5.2xlarge     eu-west-1c   ip-10-0-zz-zz.eu-west-1.compute.internal    True    45s
...
```

### Cleanup Scenario 2

```sh
kubectl delete -f workload-gpu-slices.yaml
kubectl delete -f node-overlay-gpu-slices.yaml
kubectl delete -f gpu-nodepool.yaml
```

---

## Key Takeaways

1. **NodeOverlays modify Karpenter's view, not reality**: They affect scheduling simulation only. Actual node configuration (GPU sharing, etc.) must be done separately.

2. **Price adjustments work best with On-Demand**: For Spot instances, EC2's capacity-optimized strategy may override your price preferences.

3. **Extended resources enable smarter bin-packing**: By telling Karpenter about fractional resources, it can make better decisions about how many workloads fit on a node.

4. **GPU sharing requires additional setup**: If you're using GPU slices, you must configure the actual GPU sharing mechanism (time-slicing, MIG, etc.) on your nodes and ensure your applications are compatible.

5. **NodeOverlays integrate with consolidation**: Price and capacity changes affect consolidation decisions, potentially triggering node replacements when configurations change.

## Full Cleanup

```sh
kubectl delete -f .
```
