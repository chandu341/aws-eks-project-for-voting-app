

# End-to-End AWS EKS Voting App Deployment Guide

A complete, production-ready guide to provision an **Amazon EKS (Kubernetes 1.30+)** cluster using an **EC2 Management Instance**, set up personal Docker Hub credentials, and deploy the **Microservices Voting Application** exposed via **AWS Network Load Balancers (NLB)**.

---

## 📑 Table of Contents
1. [Architecture Overview](#-architecture-overview)
2. [What Was Fixed & Upgraded (Audit Summary)](#-what-was-fixed--upgraded-audit-summary)
3. [Required Information From You](#-required-information-from-you)
4. [Step 1: Launch & Configure EC2 Management Instance](#step-1-launch--configure-ec2-management-instance)
5. [Step 2: Connect to EC2 & Clone Repository](#step-2-connect-to-ec2--clone-repository)
6. [Step 3: Install Up-to-Date Tools (`eks-cmd.sh`)](#step-3-install-up-to-date-tools-eks-cmdsh)
7. [Step 4: Prepare & Push Docker Images Under Your Own Account](#step-4-prepare--push-docker-images-under-your-own-account)
8. [Step 5: Create AWS EKS Cluster & Worker Node Group](#step-5-create-aws-eks-cluster--worker-node-group)
9. [Step 6: Deploy Voting App to EKS](#step-6-deploy-voting-app-to-eks)
10. [Step 7: Verify & Access the Voting App Online](#step-7-verify--access-the-voting-app-online)
11. [Step 8: Clean Up / Teardown Resources](#step-8-clean-up--teardown-resources)

---

## 🏛 Architecture Overview

The Voting App consists of 5 microservices communicating inside Kubernetes:

```
                      +-------------------+
                      |   End User (Web)  |
                      +---------+---------+
                                |
             +------------------+------------------+
             |                                     |
   (Vote UI: Port 80)                    (Result UI: Port 80)
   AWS Network Load Balancer             AWS Network Load Balancer
             |                                     |
             v                                     v
     +---------------+                     +----------------+
     |   vote (app)  |                     |  result (app)  |
     | Python/Flask  |                     |   Node.js UI   |
     +-------+-------+                     +-------+--------+
             |                                     ^
       (Sends votes)                               |
             v                                     | (Reads results)
     +---------------+                     +-------+--------+
     |  redis queue  |                     |   db (Postgres)|
     |  (In-Memory)  |                     |    Persistent  |
     +-------+-------+                     +-------+--------+
             ^                                     ^
             |             +------------+          |
             +-------------+ worker app +----------+
             (Consumes)    |   (.NET)   | (Persists votes)
                           +------------+
```

---

## 🔍 What Was Fixed & Upgraded (Audit Summary)

All repository files have been analyzed and updated:

| Component / Issue | Original File (`eks-cmd.sh`, `eks_deploy.yaml`, `votingapp.yaml`) | Updated & Working Solution |
| :--- | :--- | :--- |
| **kubectl Download URL** | Legacy `storage.googleapis.com/kubernetes-release/...` (deprecated) | Modern official `dl.k8s.io/release/stable.txt` binary source |
| **kubectl Placement** | Executed `chmod 700 /usr/local/bin/kubectl` without moving the binary (failed with `No such file`) | `sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl` |
| **eksctl Repository** | Outdated `weaveworks/eksctl` GitHub URL | Official canonical repository: `eksctl-io/eksctl` |
| **eksctl Placement** | Extracted to `/tmp/eksctl` but never moved to `/usr/local/bin` (command not found) | Extracted and moved with `sudo install -o root -g root -m 0755 /tmp/eksctl /usr/local/bin/eksctl` |
| **AWS CLI** | Had `run aws configure` (invalid bash syntax, no installation commands) | Added automated AWS CLI v2 installation package |
| **Docker Engine** | Missing on EC2 (cannot build/tag/push personal images) | Automated Docker CE installation and user permissions |
| **Hardcoded Third-party Images** | Hardcoded to `kiran2361993/testing:...` | Parameterized with `<YOUR_DOCKER_USERNAME>` and instructions to push to your Docker Hub |
| **Docker Pull Secret** | `votingapp.yaml` referenced missing `docker-pwd` secret | Added automated `kubectl create secret docker-registry docker-pwd` generation |
| **PostgreSQL Database** | `postgres:9.4` (EOL since 2019, security vulnerabilities) | Upgraded to stable, lightweight `postgres:15-alpine` |
| **LoadBalancer Annotations** | Used unsupported `nlb-target-type: ip` without AWS Load Balancer Controller | Updated to standard AWS NLB (`service.beta.kubernetes.io/aws-load-balancer-type: "nlb"`) for instant public provisioning |
| **Corrupted Shell Script** | Raw YAML manifests and deprecated `extensions/v1beta1` Ingress were pasted directly into `eks-cmd.sh` | Cleaned into an idempotent, modular Bash script with dedicated functions and argument parsing |

---

## 📋 Required Information From You

Before running the commands, collect your details:

1. **Docker Hub Username**: (e.g., `yourusername`)
2. **Docker Hub Password or Personal Access Token (PAT)**: (Generate at [hub.docker.com](https://hub.docker.com) -> Account Settings -> Security -> Access Tokens)
3. **Docker Hub Email**: (e.g., `yourname@example.com`)
4. **AWS Region**: (e.g., `us-east-1` or `ap-south-1`)
5. **EC2 Key Pair Name (Optional)**: Needed only if you want SSH access to worker nodes; otherwise not required.

---

## Step 1: Launch & Configure EC2 Management Instance

You will use an EC2 instance as the bastion/management machine to run `eksctl`, `kubectl`, `docker`, and `aws-cli`.

### 1.1 Launch EC2 Instance via AWS Console
- **AMI**: Ubuntu 22.04 LTS (x86_64) or Amazon Linux 2023
- **Instance Type**: `t3.medium` (2 vCPU, 4 GiB RAM) recommended for smooth builds
- **Storage**: 20 GiB gp3
- **Security Group**:
  - Inbound: SSH (Port 22) from your IP (`My IP`)
  - Outbound: All traffic (`0.0.0.0/0`)

### 1.2 Attach IAM Role to EC2 (Crucial!)
To avoid storing permanent AWS credentials on the EC2 machine:
1. Go to **AWS IAM Console** -> **Roles** -> **Create Role**.
2. Select **AWS Service** -> **EC2**.
3. Attach policies:
   - `AdministratorAccess` (for practice/learning environments) **OR** granular policies:
     - `AmazonEKSClusterPolicy`
     - `AmazonEC2FullAccess`
     - `IAMFullAccess`
     - `AWSCloudFormationFullAccess`
     - `AmazonVPCFullAccess`
4. Name the role: `EKS-Management-Role`.
5. Attach the role to your EC2 instance:
   - **EC2 Console** -> Select Instance -> **Actions** -> **Security** -> **Modify IAM Role** -> Select `EKS-Management-Role` -> **Update**.

---

## Step 2: Connect to EC2 & Clone Repository

SSH into your management EC2 instance:

```bash
ssh -i /path/to/your-key.pem ubuntu@<EC2_PUBLIC_IP>
```

Navigate to your workspace directory or copy these project files (`eks-cmd.sh`, `eks_deploy.yaml`, `votingapp.yaml`) to the EC2 instance.

Make `eks-cmd.sh` executable:
```bash
chmod +x eks-cmd.sh
```

---

## Step 3: Install Up-to-Date Tools (`eks-cmd.sh`)

You can run the prerequisites installation function from `eks-cmd.sh`:

```bash
./eks-cmd.sh prereqs
```

This installs:
- **AWS CLI v2**
- **kubectl** (Matching current stable Kubernetes version)
- **eksctl** (Official release from `eksctl-io`)
- **Docker CE**

Verify AWS credentials provided by your IAM Role:
```bash
./eks-cmd.sh verify
```
*Expected output: Your AWS Account ID and the `EKS-Management-Role` ARN.*

---

## Step 4: Prepare & Push Docker Images Under Your Own Account

To use your own credentials and Docker Hub repository:

### 4.1 Export your Docker Hub credentials
```bash
export DOCKER_USERNAME="chandudocker4321"
export DOCKER_EMAIL="chanduv4321@gmail.com"
```

### 4.2 Log in to Docker Hub
```bash
# Securely log into Docker Hub (prompts for your token/password)
docker login -u "$DOCKER_USERNAME"
```

### 4.3 Build & Push Your Custom Application Images
Run the automated build and push command:
```bash
./eks-cmd.sh docker
```
*Behind the scenes, this executes:*
```bash
# 1. Build Vote Frontend (Python / Flask)
docker build -t "${DOCKER_USERNAME}/voting-app-vote:latest" ./vote

# 2. Build Result Dashboard (Node.js / Express)
docker build -t "${DOCKER_USERNAME}/voting-app-result:latest" ./result

# 3. Build Background Worker (Python / PostgreSQL / Redis)
docker build -t "${DOCKER_USERNAME}/voting-app-worker:latest" ./worker

# 4. Push all your custom images to your Docker Hub repository
docker push "${DOCKER_USERNAME}/voting-app-vote:latest"
docker push "${DOCKER_USERNAME}/voting-app-result:latest"
docker push "${DOCKER_USERNAME}/voting-app-worker:latest"
```

---

## Step 5: Create AWS EKS Cluster & Worker Node Group

### 5.1 Create EKS Control Plane
```bash
./eks-cmd.sh cluster
```
*Behind the scenes, this executes:*
```bash
eksctl create cluster \
  --name "Voting-app-k8-cluster" \
  --region "ap-south-1" \
  --version "1.30" \
  --zones=ap-south-1a,ap-south-1b,ap-south-1c \
  --without-nodegroup

eksctl utils associate-iam-oidc-provider \
  --region "ap-south-1" \
  --cluster "Voting-app-k8-cluster" \
  --approve
```
*(Takes approximately 10–12 minutes).*

### 5.2 Create Managed Node Group
```bash
./eks-cmd.sh nodegroup
```
*Behind the scenes, this executes:*
```bash
eksctl create nodegroup \
  --cluster="Voting-app-k8-cluster" \
  --region="ap-south-1" \
  --name="Voting-app-k8-cluster-ng-1" \
  --node-type="t3.medium" \
  --nodes=2 \
  --nodes-min=2 \
  --nodes-max=4 \
  --node-volume-size=20 \
  --managed \
  --asg-access \
  --external-dns-access \
  --full-ecr-access \
  --alb-ingress-access
```

### 5.3 Verify Nodes
```bash
kubectl get nodes -o wide
```
Ensure both nodes report status `Ready`.

---

## Step 6: Deploy Voting App to EKS

### 6.1 Create Docker Registry Secret
If your Docker Hub repositories are private, create the Kubernetes secret:
```bash
kubectl create secret docker-registry docker-pwd \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username="${DOCKER_USERNAME}" \
  --docker-password="${DOCKER_PASSWORD}" \
  --docker-email="${DOCKER_EMAIL}"
```

### 6.2 Update Manifests with your Docker Hub Username
Replace `<YOUR_DOCKER_USERNAME>` in `eks_deploy.yaml`:
```bash
sed -i "s|<YOUR_DOCKER_USERNAME>|${DOCKER_USERNAME}|g" eks_deploy.yaml
sed -i "s|<YOUR_DOCKER_USERNAME>|${DOCKER_USERNAME}|g" votingapp.yaml
```

### 6.3 Apply Kubernetes Manifests
```bash
kubectl apply -f eks_deploy.yaml
```
*(Or use `kubectl apply -f votingapp.yaml` if using `imagePullSecrets: docker-pwd`)*

### 6.4 Monitor Deployment Rollout
```bash
kubectl rollout status deployment/redis
kubectl rollout status deployment/db
kubectl rollout status deployment/vote
kubectl rollout status deployment/result
kubectl rollout status deployment/worker
```

---

## Step 7: Verify & Access the Voting App Online

### 7.1 Inspect Running Pods
```bash
kubectl get pods -o wide
```
*Sample output:*
```
NAME                      READY   STATUS    RESTARTS   AGE
db-6869b5585-x5h9k        1/1     Running   0          2m
redis-5b6c9779df-2tfl7    1/1     Running   0          2m
result-79b8849b7d-6m8rq   1/1     Running   0          2m
vote-74d755ffbc-8jkd8     1/1     Running   0          2m
vote-74d755ffbc-w9r4k     1/1     Running   0          2m
worker-7c4b5749f-z7d6p    1/1     Running   0          2m
```

### 7.2 Get Public Load Balancer URLs
```bash
kubectl get svc vote result
```
*Sample output:*
```
NAME     TYPE           CLUSTER-IP       EXTERNAL-IP                                                              PORT(S)
result   LoadBalancer   10.100.124.58    k8s-default-result-xxxxxx-xxxxxx.elb.us-east-1.amazonaws.com              80:31234/TCP
vote     LoadBalancer   10.100.210.102   k8s-default-vote-xxxxxx-xxxxxx.elb.us-east-1.amazonaws.com                80:30456/TCP
```

### 7.3 Open in Your Web Browser
1. **Vote Interface**: Open `http://<VOTE_EXTERNAL_IP>` (Cast your vote between "Cats" and "Dogs").
2. **Results Interface**: Open `http://<RESULT_EXTERNAL_IP>` (Watch votes update in real-time!).

---

## Step 8: Clean Up / Teardown Resources

To prevent ongoing AWS EC2 and NAT Gateway charges when you finish testing:

```bash
./eks-cmd.sh cleanup
```

*Or manually:*
```bash
# 1. Delete Kubernetes resources (releases Load Balancers)
kubectl delete -f eks_deploy.yaml

# 2. Delete Node Group
eksctl delete nodegroup \
  --cluster="Voting-app-k8-cluster" \
  --region="ap-south-1" \
  --name="Voting-app-k8-cluster-ng-1"

# 3. Delete EKS Cluster (VPC, CloudFormation stacks, Control Plane)
eksctl delete cluster \
  --name="Voting-app-k8-cluster" \
  --region="ap-south-1"

# 4. Terminate the EC2 Management Instance via AWS Console.
```
