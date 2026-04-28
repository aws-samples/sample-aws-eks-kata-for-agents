#!/bin/bash
#
# Build RayClaw container image and push to your private ECR.
#
# Prerequisites:
#   - Docker (or Podman)
#   - AWS CLI configured
#   - RayClaw source code (git clone https://github.com/rayclaw/rayclaw)
#
# Usage:
#   ./scripts/build-rayclaw-ecr.sh --source /path/to/rayclaw [--region us-west-2] [--repo-name rayclaw] [--tag latest]

set -euo pipefail

REGION="us-west-2"
REPO_NAME="rayclaw"
TAG="latest"
SOURCE_DIR=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --source)     SOURCE_DIR="$2"; shift 2 ;;
    --region)     REGION="$2"; shift 2 ;;
    --repo-name)  REPO_NAME="$2"; shift 2 ;;
    --tag)        TAG="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --source /path/to/rayclaw [--region REGION] [--repo-name NAME] [--tag TAG]"
      echo ""
      echo "Options:"
      echo "  --source      Path to rayclaw source directory (required)"
      echo "  --region      AWS region for ECR (default: us-west-2)"
      echo "  --repo-name   ECR repository name (default: rayclaw)"
      echo "  --tag         Image tag (default: latest)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$SOURCE_DIR" ]]; then
  echo "ERROR: --source is required (path to rayclaw source directory)"
  echo "  Example: $0 --source ~/rayclaw"
  exit 1
fi

if [[ ! -f "$SOURCE_DIR/Cargo.toml" ]]; then
  echo "ERROR: $SOURCE_DIR/Cargo.toml not found. Is this a rayclaw source directory?"
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"

echo "============================================"
echo "  RayClaw → ECR Build & Push"
echo "============================================"
echo "Source:     $SOURCE_DIR"
echo "ECR URI:    $ECR_URI:$TAG"
echo "Region:     $REGION"
echo "============================================"

# Step 1: Create ECR repository if it doesn't exist
echo ""
echo ">>> Step 1: Ensuring ECR repository exists..."
aws ecr describe-repositories --repository-names "$REPO_NAME" --region "$REGION" > /dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$REPO_NAME" --region "$REGION" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 > /dev/null
echo "  Repository: $ECR_URI"

# Step 2: Login to ECR
echo ""
echo ">>> Step 2: Logging into ECR..."
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Step 3: Generate Dockerfile (not committed to repo)
echo ""
echo ">>> Step 3: Building image..."
DOCKERFILE=$(mktemp)
trap "rm -f $DOCKERFILE" EXIT

cat > "$DOCKERFILE" << 'DOCKERFILE_CONTENT'
# ---- Stage 1: Build web frontend ----
FROM node:20-slim AS web-builder
WORKDIR /build/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --ignore-scripts
COPY web/ ./
RUN npm run build

# ---- Stage 2: Build Rust binary ----
FROM rust:1.87-bookworm AS builder
RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Cargo.toml Cargo.lock build.rs ./
COPY src/ src/
COPY --from=web-builder /build/web/dist/ web/dist/
COPY rayclaw.data/ rayclaw.data/
COPY SOUL.md ./
RUN cargo build --release --features all

# ---- Stage 3: Runtime image ----
FROM debian:bookworm-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-client && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd -g 1000 rayclaw && \
    useradd -u 1000 -g rayclaw -m -s /bin/bash rayclaw

COPY --from=builder /build/target/release/rayclaw /usr/local/bin/rayclaw
COPY --from=builder /build/rayclaw.data/skills/ /opt/rayclaw/default-skills/

RUN mkdir -p /data/runtime /data/skills && \
    cp -r /opt/rayclaw/default-skills/* /data/skills/ 2>/dev/null || true && \
    chown -R rayclaw:rayclaw /data

USER rayclaw
WORKDIR /data
ENV RAYCLAW_CONFIG=/data/rayclaw.config.yaml

EXPOSE 10962
ENTRYPOINT ["rayclaw"]
DOCKERFILE_CONTENT

docker build -t "${ECR_URI}:${TAG}" -f "$DOCKERFILE" "$SOURCE_DIR"

# Step 4: Push to ECR
echo ""
echo ">>> Step 4: Pushing to ECR..."
docker push "${ECR_URI}:${TAG}"

# Step 5: Print summary
IMAGE_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${ECR_URI}:${TAG}" 2>/dev/null || echo "${ECR_URI}:${TAG}")
echo ""
echo "============================================"
echo "  Build Complete!"
echo "============================================"
echo ""
echo "Image:  ${ECR_URI}:${TAG}"
echo ""
echo "To use in Kubernetes examples, update the image field:"
echo "  image: ${ECR_URI}:${TAG}"
echo ""
echo "Or set in terraform.tfvars:"
echo "  rayclaw_image = \"${ECR_URI}:${TAG}\""
