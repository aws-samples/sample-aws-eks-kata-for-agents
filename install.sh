#!/bin/bash

set -e

REGION="us-west-2"
CLUSTER_NAME="hermes-kata-eks"
KATA_MODE="nested-kvm"
KATA_INSTANCE_TYPES=""

show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --region REGION             AWS region (default: us-west-2)
  --cluster-name NAME         EKS cluster name (default: hermes-kata-eks)
  --kata-mode MODE            Kata node mode: nested-kvm or bare-metal (default: nested-kvm)
                                nested-kvm: Uses c8i/m8i/r8i instances with NestedVirtualization=enabled
                                bare-metal: Uses *.metal instances with native /dev/kvm
  --kata-instance-types TYPES Comma-separated instance types (default depends on mode)
                                nested-kvm default: m8i.2xlarge,m8i.4xlarge
                                bare-metal default: m5.metal,m5n.metal
  --help                      Show this help message

Examples:
  $0 --kata-mode nested-kvm
  $0 --kata-mode nested-kvm --kata-instance-types c8i.4xlarge,c8i.8xlarge
  $0 --kata-mode bare-metal --kata-instance-types m5.metal
EOF
  exit 0
}

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
    --kata-mode)
      KATA_MODE="$2"
      if [[ "$KATA_MODE" != "nested-kvm" && "$KATA_MODE" != "bare-metal" ]]; then
        echo "ERROR: --kata-mode must be 'nested-kvm' or 'bare-metal'"
        exit 1
      fi
      shift 2
      ;;
    --kata-instance-types)
      KATA_INSTANCE_TYPES="$2"
      shift 2
      ;;
    --help|-h)
      show_usage
      ;;
    *)
      echo "Unknown option: $1"
      show_usage
      ;;
  esac
done

# Set default instance types based on mode if not explicitly provided
if [[ -z "$KATA_INSTANCE_TYPES" ]]; then
  if [[ "$KATA_MODE" == "nested-kvm" ]]; then
    KATA_INSTANCE_TYPES="m8i.2xlarge,m8i.4xlarge"
  else
    KATA_INSTANCE_TYPES="m5.metal,m5n.metal"
  fi
fi

echo "============================================"
echo "  Hermes Agent on EKS - Deployment Script"
echo "============================================"
echo "Region:         $REGION"
echo "Cluster Name:   $CLUSTER_NAME"
echo "Kata Mode:      $KATA_MODE"
echo "Instance Types: $KATA_INSTANCE_TYPES"
echo "============================================"

# Auto-install prerequisites if missing
install_aws_cli() {
  echo ">>> Installing AWS CLI v2..."
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
  unzip -qo /tmp/awscliv2.zip -d /tmp
  sudo /tmp/aws/install --update
  rm -rf /tmp/aws /tmp/awscliv2.zip
}

install_kubectl() {
  echo ">>> Installing kubectl..."
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
  esac
  curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${arch}/kubectl"
  chmod +x kubectl
  sudo mv kubectl /usr/local/bin/
}

install_terraform() {
  echo ">>> Installing Terraform..."
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
  esac
  local version="1.12.1"
  curl -fsSL "https://releases.hashicorp.com/terraform/${version}/terraform_${version}_linux_${arch}.zip" -o /tmp/terraform.zip
  unzip -qo /tmp/terraform.zip -d /tmp
  sudo mv /tmp/terraform /usr/local/bin/
  rm -f /tmp/terraform.zip
}

install_helm() {
  echo ">>> Installing Helm v3..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

declare -A INSTALLERS=(
  [aws]=install_aws_cli
  [kubectl]=install_kubectl
  [terraform]=install_terraform
  [helm]=install_helm
)

MISSING=()
for cmd in aws kubectl terraform helm; do
  if ! command -v "$cmd" &> /dev/null; then
    MISSING+=("$cmd")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Missing tools: ${MISSING[*]}"
  read -p "Auto-install them? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Please install manually: ${MISSING[*]}"
    exit 1
  fi
  for cmd in "${MISSING[@]}"; do
    ${INSTALLERS[$cmd]}
    if ! command -v "$cmd" &> /dev/null; then
      echo "ERROR: Failed to install $cmd"
      exit 1
    fi
    echo "  $cmd installed: $(command -v $cmd)"
  done
fi

echo "All prerequisites satisfied."
for cmd in aws kubectl terraform helm; do
  echo "  $cmd: $($cmd version --client 2>/dev/null || $cmd --version 2>/dev/null | head -1)"
done

# Convert comma-separated instance types to Terraform list format
IFS=',' read -ra INSTANCE_TYPE_ARRAY <<< "$KATA_INSTANCE_TYPES"
TF_INSTANCE_TYPES=$(printf '"%s",' "${INSTANCE_TYPE_ARRAY[@]}")
TF_INSTANCE_TYPES="[${TF_INSTANCE_TYPES%,}]"

# Pre-create launch template for nested-kvm mode via AWS CLI.
# Terraform AWS provider 5.x and CloudFormation do not support
# CpuOptions.NestedVirtualization — only the EC2 API does directly.
LT_NAME="${CLUSTER_NAME}-kata-nested-kvm"

if [[ "$KATA_MODE" == "nested-kvm" ]]; then
  echo ""
  echo ">>> Creating launch template with NestedVirtualization=enabled..."
  if aws ec2 describe-launch-templates --region "$REGION" \
    --launch-template-names "$LT_NAME" &>/dev/null; then
    echo "  Launch template '$LT_NAME' already exists, skipping creation."
  else
    aws ec2 create-launch-template \
      --region "$REGION" \
      --launch-template-name "$LT_NAME" \
      --launch-template-data '{
        "BlockDeviceMappings": [{
          "DeviceName": "/dev/xvda",
          "Ebs": {
            "VolumeSize": 100,
            "VolumeType": "gp3",
            "Encrypted": true,
            "DeleteOnTermination": true
          }
        }],
        "CpuOptions": {
          "NestedVirtualization": "enabled"
        },
        "MetadataOptions": {
          "HttpEndpoint": "enabled",
          "HttpTokens": "required",
          "HttpPutResponseHopLimit": 2
        }
      }' \
      --tag-specifications "ResourceType=launch-template,Tags=[{Key=Blueprint,Value=${CLUSTER_NAME}},{Key=Workload,Value=hermes-kata}]"
    echo "  Launch template '$LT_NAME' created successfully."
  fi
fi

# Terraform init
echo ""
echo ">>> Initializing Terraform..."
terraform init

# Terraform plan
echo ""
echo ">>> Planning infrastructure..."
terraform plan \
  -var="region=$REGION" \
  -var="name=$CLUSTER_NAME" \
  -var="kata_node_mode=$KATA_MODE" \
  -var="kata_instance_types=$TF_INSTANCE_TYPES" \
  -out=tfplan

# Confirm
echo ""
read -p "Proceed with deployment? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Deployment cancelled."
  exit 0
fi

# Terraform apply
echo ""
echo ">>> Deploying infrastructure (this takes ~15-20 minutes)..."
terraform apply tfplan

# Configure kubectl
echo ""
echo ">>> Configuring kubectl..."
aws eks --region "$REGION" update-kubeconfig --name "$CLUSTER_NAME"

echo ""
echo "============================================"
echo "  Deployment Complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo ""
echo "1. Generate LiteLLM API Key:"
echo "   MASTER_KEY=\$(kubectl get secret litellm-masterkey -n litellm \\"
echo "     -o jsonpath='{.data.masterkey}' | base64 -d)"
echo ""
echo "   LITELLM_API_KEY=\$(kubectl run -n litellm gen-key --rm -i \\"
echo "     --restart=Never --image=curlimages/curl -- \\"
echo "     curl -s -X POST http://litellm:4000/key/generate \\"
echo "     -H \"Authorization: Bearer \$MASTER_KEY\" \\"
echo "     -H \"Content-Type: application/json\" \\"
echo "     -d '{\"models\": [\"claude-opus-4-6\"], \"duration\": \"30d\"}' \\"
echo "     | grep -o '\"key\":\"[^\"]*\"' | cut -d'\"' -f4)"
echo ""
echo "2. Deploy a Hermes Agent sandbox:"
echo "   cd examples"
echo "   # Edit hermes-feishu-sandbox.yaml with your credentials"
echo "   sed -i.bak \\"
echo "     -e \"s/YOUR_LITELLM_API_KEY/\${LITELLM_API_KEY}/g\" \\"
echo "     -e \"s/YOUR_FEISHU_APP_ID/\${FEISHU_APP_ID}/g\" \\"
echo "     -e \"s/YOUR_FEISHU_APP_SECRET/\${FEISHU_APP_SECRET}/g\" \\"
echo "     hermes-feishu-sandbox.yaml"
echo "   kubectl apply -f hermes-feishu-sandbox.yaml"
echo ""
echo "3. Verify:"
echo "   kubectl get pods -n hermes"
echo "   kubectl logs -f hermes-feishu-sandbox -n hermes"
echo ""
echo "4. Grafana dashboard:"
echo "   terraform output -raw grafana_admin_password"
echo "   kubectl port-forward -n monitoring svc/grafana 3000:80"
echo ""
