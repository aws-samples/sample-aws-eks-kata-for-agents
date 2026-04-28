#!/bin/bash

set -e

REGION="us-west-2"
CLUSTER_NAME="hermes-kata-eks"

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)
      REGION="$2"
      shift 2
      ;;
    --cluster-name)
      CLUSTER_NAME="$2"
      shift 2
      ;;
    -y|--yes)
      AUTO_APPROVE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--region REGION] [--cluster-name CLUSTER_NAME] [-y|--yes]"
      exit 1
      ;;
  esac
done

echo "============================================"
echo "  Hermes Agent on EKS - Cleanup Script"
echo "============================================"
echo "Region:       $REGION"
echo "Cluster Name: $CLUSTER_NAME"
echo "============================================"

if [[ "$AUTO_APPROVE" != "true" ]]; then
  read -p "This will DESTROY all resources. Continue? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
  fi
fi

# Step 1: Delete manually deployed workloads (not managed by Terraform)
echo ""
echo ">>> Step 1: Deleting manually deployed workloads..."
kubectl delete pods -n hermes -l app=hermes-sandbox --ignore-not-found=true 2>/dev/null || true
kubectl delete svc -n hermes -l app=hermes-sandbox --ignore-not-found=true 2>/dev/null || true
kubectl delete configmap -n hermes -l tenant --ignore-not-found=true 2>/dev/null || true
kubectl delete secret -n hermes -l tenant --ignore-not-found=true 2>/dev/null || true
kubectl delete pvc -n hermes --all --ignore-not-found=true 2>/dev/null || true
kubectl apply -f examples/ --dry-run=client > /dev/null 2>&1 && \
  kubectl delete -f examples/ --ignore-not-found=true 2>/dev/null || true
echo "  Workloads deleted."

# Step 2: Wait for pods to terminate
echo ""
echo ">>> Step 2: Waiting for pods to terminate..."
kubectl wait --for=delete pods -n hermes -l app=hermes-sandbox --timeout=60s 2>/dev/null || true

# Step 3: Remove Karpenter nodeclaims (so nodes drain before VPC teardown)
echo ""
echo ">>> Step 3: Draining Karpenter nodes..."
kubectl delete nodeclaims --all 2>/dev/null || true
sleep 10

# Step 4: Terraform destroy (with retries for dependency ordering)
echo ""
echo ">>> Step 4: Destroying Terraform-managed infrastructure..."
echo "  This takes ~10-15 minutes."

# First pass: destroy Helm releases and K8s resources
terraform destroy \
  -var="region=$REGION" \
  -var="name=$CLUSTER_NAME" \
  -auto-approve 2>&1 || {
    echo ""
    echo ">>> First destroy pass had errors. Cleaning up orphaned state..."

    # Remove K8s resources from state if cluster is already gone
    for res in $(terraform state list 2>/dev/null | grep -E 'kubernetes_|helm_release|kubectl_manifest'); do
      echo "  Removing from state: $res"
      terraform state rm "$res" 2>/dev/null || true
    done

    echo ""
    echo ">>> Retrying destroy..."
    terraform destroy \
      -var="region=$REGION" \
      -var="name=$CLUSTER_NAME" \
      -auto-approve
  }

# Step 5: Clean up local files
echo ""
echo ">>> Step 5: Cleaning up local files..."
rm -f tfplan
rm -f terraform.tfstate.*.backup

echo ""
echo "============================================"
echo "  Cleanup Complete!"
echo "============================================"
echo ""
echo "Remaining local files (kept intentionally):"
echo "  - terraform.tfstate      (tracks that resources are destroyed)"
echo "  - .terraform/            (provider cache, re-used on next deploy)"
echo ""
echo "To fully reset: rm -rf .terraform terraform.tfstate*"
