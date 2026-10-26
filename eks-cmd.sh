#!/usr/bin/env bash
# ==============================================================================
# AWS EKS Cluster Provisioning & Voting App Deployment Script
# Tested & Validated for Kubernetes 1.30+ and Amazon Linux 2023 / Ubuntu 22.04+
# ==============================================================================

set -eo pipefail

# ------------------------------------------------------------------------------
# STEP 0: CONFIGURATION VARIABLES (Customize these before running)
# ------------------------------------------------------------------------------
export AWS_REGION="ap-south-1"
export CLUSTER_NAME="Voting-app-k8-cluster"
export K8S_VERSION="1.30"
export NODEGROUP_NAME="Voting-app-k8-cluster-ng-1"
export NODE_TYPE="t3.medium"
export NODE_COUNT=2
export NODE_MIN=2
export NODE_MAX=4
# Docker Hub configuration: Set your personal Docker Hub ID & email
# SECURITY NOTE: DO NOT write your password or Access Token (PAT) in this file!
# The script will securely prompt you for your token/password in your terminal with hidden input.
export DOCKER_USERNAME="chandudocker4321"
export DOCKER_EMAIL="chanduv4321@gmail.com"

# (Optional) If you need SSH access to EC2 worker nodes, specify your key pair:
# export SSH_KEY_NAME="my-key-pair"

echo "============================================================"
echo " Starting EKS Environment Setup & Validation"
echo " Region:       ${AWS_REGION}"
echo " Cluster:      ${CLUSTER_NAME}"
echo " K8s Version:  ${K8S_VERSION}"
echo "============================================================"

# ------------------------------------------------------------------------------
# STEP 1: INSTALL PREREQUISITES ON MANAGEMENT EC2 INSTANCE
# ------------------------------------------------------------------------------

install_prerequisites() {
  echo ">>> [1/5] Updating packages and installing basic tools..."
  if command -v apt-get &>/dev/null; then
    sudo apt-get update -y
    sudo apt-get install -y curl unzip tar jq git
  elif command -v dnf &>/dev/null; then
    sudo dnf update -y
    sudo dnf install -y curl unzip tar jq git
  elif command -v yum &>/dev/null; then
    sudo yum update -y
    sudo yum install -y curl unzip tar jq git
  fi

  # 1. AWS CLI v2 Installation
  if ! command -v aws &>/dev/null; then
    echo ">>> Installing AWS CLI v2..."
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
    unzip -q -o /tmp/awscliv2.zip -d /tmp
    sudo /tmp/aws/install --update
    rm -rf /tmp/awscliv2.zip /tmp/aws
  fi
  echo "AWS CLI Version: $(aws --version)"

  # 2. kubectl Installation (Matching EKS version)
  echo ">>> Installing kubectl v${K8S_VERSION}..."
  KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
  # Or use exact version: "v${K8S_VERSION}.5"
  curl -sLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
  echo "kubectl Version: $(kubectl version --client --output=yaml | grep gitVersion || true)"

  # 3. eksctl Installation (From official eksctl-io repository)
  echo ">>> Installing eksctl..."
  ARCH=amd64
  PLATFORM=$(uname -s)_$ARCH
  curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz"
  tar -xzf "eksctl_${PLATFORM}.tar.gz" -C /tmp
  sudo install -o root -g root -m 0755 /tmp/eksctl /usr/local/bin/eksctl
  rm -f "eksctl_${PLATFORM}.tar.gz" /tmp/eksctl
  echo "eksctl Version: $(eksctl version)"

  # 4. Docker Installation (Needed to pull, tag, and push personal images)
  if ! command -v docker &>/dev/null; then
    echo ">>> Installing Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sudo sh /tmp/get-docker.sh
    sudo usermod -aG docker "$USER" || true
    sudo systemctl enable --now docker
    rm -f /tmp/get-docker.sh
  fi
  echo "Docker Version: $(docker --version)"
}

# ------------------------------------------------------------------------------
# STEP 2: VERIFY AWS CREDENTIALS / IAM PERMISSIONS
# ------------------------------------------------------------------------------
verify_aws_identity() {
  echo ">>> Verifying AWS IAM identity and permissions..."
  aws configure set default.region "${AWS_REGION}"
  aws sts get-caller-identity
}

# ------------------------------------------------------------------------------
# STEP 3: CREATE EKS CLUSTER CONTROL PLANE
# ------------------------------------------------------------------------------
create_cluster() {
  echo ">>> Creating EKS Cluster: ${CLUSTER_NAME} (Control Plane)..."
  eksctl create cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --version "${K8S_VERSION}" \
    --zones="${AWS_REGION}a,${AWS_REGION}b,${AWS_REGION}c" \
    --without-nodegroup

  echo ">>> Associating IAM OIDC Provider for Service Accounts..."
  eksctl utils associate-iam-oidc-provider \
    --region "${AWS_REGION}" \
    --cluster "${CLUSTER_NAME}" \
    --approve

  # Update kubeconfig
  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"
  kubectl get nodes
}

# ------------------------------------------------------------------------------
# STEP 4: CREATE MANAGED NODE GROUP
# ------------------------------------------------------------------------------
create_public_nodegroup() {
  echo ">>> Creating Public Managed Node Group: ${NODEGROUP_NAME}..."
  
  # Base command
  CMD=(eksctl create nodegroup \
    --cluster="${CLUSTER_NAME}" \
    --region="${AWS_REGION}" \
    --name="${NODEGROUP_NAME}" \
    --node-type="${NODE_TYPE}" \
    --nodes="${NODE_COUNT}" \
    --nodes-min="${NODE_MIN}" \
    --nodes-max="${NODE_MAX}" \
    --node-volume-size="${NODE_VOLUME_SIZE}" \
    --managed \
    --asg-access \
    --external-dns-access \
    --full-ecr-access \
    --alb-ingress-access)

  # Attach SSH key only if variable SSH_KEY_NAME is defined
  if [ -n "${SSH_KEY_NAME:-}" ]; then
    CMD+=(--ssh-access --ssh-public-key="${SSH_KEY_NAME}")
  fi

  "${CMD[@]}"

  echo ">>> Verifying Ready Nodes:"
  kubectl get nodes -o wide
}

# ------------------------------------------------------------------------------
# STEP 5: BUILD & PUSH YOUR OWN DOCKER IMAGES TO DOCKER HUB
# ------------------------------------------------------------------------------
prepare_docker_images() {
  echo ">>> Building your own custom container images under account: ${DOCKER_USERNAME}..."

  if [ -z "${DOCKER_USERNAME}" ]; then
    echo "ERROR: Please set DOCKER_USERNAME in STEP 0!"
    exit 1
  fi

  # Securely prompt for password/token if not already in environment
  if [ -z "${DOCKER_PASSWORD:-}" ]; then
    echo -n "Enter Docker Hub Password or Personal Access Token (PAT) [input hidden]: "
    read -rs DOCKER_PASSWORD
    echo
    export DOCKER_PASSWORD
  fi

  # Log in to Docker Hub
  echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin

  # 1. Build Vote frontend
  echo ">>> [1/3] Building Vote frontend image (${DOCKER_USERNAME}/voting-app-vote:latest)..."
  docker build -t "${DOCKER_USERNAME}/voting-app-vote:latest" ./vote

  # 2. Build Result dashboard
  echo ">>> [2/3] Building Result dashboard image (${DOCKER_USERNAME}/voting-app-result:latest)..."
  docker build -t "${DOCKER_USERNAME}/voting-app-result:latest" ./result

  # 3. Build Worker background service
  echo ">>> [3/3] Building Worker background processor (${DOCKER_USERNAME}/voting-app-worker:latest)..."
  docker build -t "${DOCKER_USERNAME}/voting-app-worker:latest" ./worker

  # 4. Push your images to your personal Docker Hub repository
  echo ">>> Pushing your custom images to your Docker Hub repository..."
  docker push "${DOCKER_USERNAME}/voting-app-vote:latest"
  docker push "${DOCKER_USERNAME}/voting-app-result:latest"
  docker push "${DOCKER_USERNAME}/voting-app-worker:latest"

  echo ">>> All your custom images were built and published successfully!"
}

# ------------------------------------------------------------------------------
# STEP 6: CREATE KUBERNETES DOCKER SECRET (docker-pwd) & DEPLOY APP
# ------------------------------------------------------------------------------
deploy_voting_app() {
  if [ -z "${DOCKER_USERNAME}" ]; then
    echo "ERROR: Please set DOCKER_USERNAME in STEP 0!"
    exit 1
  fi

  # Securely prompt for password/token if not already in environment
  if [ -z "${DOCKER_PASSWORD:-}" ]; then
    echo -n "Enter Docker Hub Password or Personal Access Token (PAT) [input hidden]: "
    read -rs DOCKER_PASSWORD
    echo
    export DOCKER_PASSWORD
  fi

  echo ">>> Creating Kubernetes Image Pull Secret (docker-pwd)..."
  kubectl create secret docker-registry docker-pwd \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username="${DOCKER_USERNAME}" \
    --docker-password="${DOCKER_PASSWORD}" \
    --docker-email="${DOCKER_EMAIL}" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo ">>> Updating manifests with your Docker Hub username..."
  # Replace <YOUR_DOCKER_USERNAME> placeholder on the fly or in file
  sed -i "s|<YOUR_DOCKER_USERNAME>|${DOCKER_USERNAME}|g" eks_deploy.yaml
  sed -i "s|<YOUR_DOCKER_USERNAME>|${DOCKER_USERNAME}|g" votingapp.yaml

  echo ">>> Deploying Voting App to EKS..."
  kubectl apply -f eks_deploy.yaml

  echo ">>> Waiting for Pods to be Ready..."
  kubectl rollout status deployment/redis --timeout=120s
  kubectl rollout status deployment/db --timeout=120s
  kubectl rollout status deployment/vote --timeout=120s
  kubectl rollout status deployment/result --timeout=120s
  kubectl rollout status deployment/worker --timeout=120s

  echo ">>> Pods Status:"
  kubectl get pods -o wide

  echo ">>> Fetching Load Balancer Endpoints:"
  kubectl get svc vote result
}

# ------------------------------------------------------------------------------
# STEP 7: CLEANUP / TEARDOWN INSTRUCTIONS
# ------------------------------------------------------------------------------
cleanup_resources() {
  echo ">>> WARNING: This will delete your Voting App & EKS Cluster to avoid AWS charges."
  read -p "Are you sure you want to delete the cluster ${CLUSTER_NAME}? (y/n) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ">>> Deleting Kubernetes manifests..."
    kubectl delete -f eks_deploy.yaml --ignore-not-found=true

    echo ">>> Deleting Node Group..."
    eksctl delete nodegroup \
      --cluster="${CLUSTER_NAME}" \
      --region="${AWS_REGION}" \
      --name="${NODEGROUP_NAME}"

    echo ">>> Deleting EKS Cluster..."
    eksctl delete cluster \
      --name="${CLUSTER_NAME}" \
      --region="${AWS_REGION}"
    echo ">>> Teardown Complete!"
  fi
}

# ------------------------------------------------------------------------------
# ENTRY POINT MENU
# ------------------------------------------------------------------------------
case "${1:-all}" in
  prereqs)
    install_prerequisites
    ;;
  verify)
    verify_aws_identity
    ;;
  cluster)
    create_cluster
    ;;
  nodegroup)
    create_public_nodegroup
    ;;
  docker)
    prepare_docker_images
    ;;
  deploy)
    deploy_voting_app
    ;;
  cleanup)
    cleanup_resources
    ;;
  all)
    echo "Running Full Automated Workflow..."
    install_prerequisites
    verify_aws_identity
    create_cluster
    create_public_nodegroup
    prepare_docker_images
    deploy_voting_app
    echo "============================================================"
    echo " Deployment Succeeded! Check your LoadBalancer URLs above."
    echo "============================================================"
    ;;
  *)
    echo "Usage: $0 {prereqs|verify|cluster|nodegroup|docker|deploy|cleanup|all}"
    exit 1
    ;;
esac
