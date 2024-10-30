#!/bin/bash

# Exit on error
set -e

# Configuration variables - replace these with your values
AWS_REGION="us-west-2"
AWS_ACCOUNT_ID=""
REPOSITORY_NAME="podcast-labeling"
IMAGE_TAG="latest"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting deployment process...${NC}"

# Function to check command existence
check_command() {
    if ! command -v $1 &> /dev/null; then
        echo -e "${RED}$1 is not installed. Please install it first.${NC}"
        exit 1
    fi
}

# Verify AWS CLI and Docker are installed
check_command aws
check_command docker

# Build and push Docker image to ECR
echo -e "${GREEN}Building Docker image...${NC}"
docker build --platform linux/amd64 -t ${REPOSITORY_NAME}:${IMAGE_TAG} .

echo -e "${GREEN}Ensuring ECR repository exists...${NC}"
aws ecr describe-repositories --repository-names ${REPOSITORY_NAME} &>/dev/null || \
    aws ecr create-repository --repository-name ${REPOSITORY_NAME}

echo -e "${GREEN}Logging into ECR and pushing image...${NC}"
aws ecr get-login-password --region ${AWS_REGION} | \
    docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

docker tag ${REPOSITORY_NAME}:${IMAGE_TAG} ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPOSITORY_NAME}:${IMAGE_TAG}
docker push ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPOSITORY_NAME}:${IMAGE_TAG}

# Register Batch job definition
echo -e "${GREEN}Registering AWS Batch job definition...${NC}"
sed -e "s/\${AWS_ACCOUNT_ID}/$AWS_ACCOUNT_ID/g" -e "s/\${AWS_REGION}/$AWS_REGION/g" \
    batch-job-definition.json > batch-job-definition.tmp.json
aws batch register-job-definition --cli-input-json file://batch-job-definition.tmp.json
rm batch-job-definition.tmp.json

# Function to check and create if needed (ECS roles, compute env, job queue)
ensure_resource() {
    local name=$1
    local check_cmd=$2
    local create_cmd=$3
    echo -e "${GREEN}Ensuring $name exists...${NC}"
    
    # Run check command and capture output
    local check_output
    if ! check_output=$(eval $check_cmd 2>/dev/null); then
        echo "Resource $name not found, creating..."
        eval $create_cmd
    elif [[ "$check_output" == "None" ]]; then
        echo "Resource $name not found (None), creating..."
        eval $create_cmd
    else
        echo "Resource $name already exists"
    fi
}

# Ensure roles
ensure_resource "AWSBatchServiceRole" \
    "aws iam get-role --role-name AWSBatchServiceRole" \
    "aws iam create-role --role-name AWSBatchServiceRole --assume-role-policy-document '{\"Version\": \"2012-10-17\", \"Statement\": [{\"Effect\": \"Allow\", \"Principal\": {\"Service\": \"batch.amazonaws.com\"}, \"Action\": \"sts:AssumeRole\"}]}' && \
    aws iam attach-role-policy --role-name AWSBatchServiceRole --policy-arn arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"

ensure_resource "ecsInstanceRole" \
    "aws iam get-role --role-name ecsInstanceRole" \
    "aws iam create-role --role-name ecsInstanceRole --assume-role-policy-document '{\"Version\": \"2012-10-17\", \"Statement\": [{\"Effect\": \"Allow\", \"Principal\": {\"Service\": \"ec2.amazonaws.com\"}, \"Action\": \"sts:AssumeRole\"}]}' && \
    aws iam attach-role-policy --role-name ecsInstanceRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role && \
    aws iam create-instance-profile --instance-profile-name ecsInstanceRole && \
    aws iam add-role-to-instance-profile --instance-profile-name ecsInstanceRole --role-name ecsInstanceRole"

# Create Compute Environment if it doesn't exist
echo -e "${GREEN}Getting VPC configuration...${NC}"
# Get subnet IDs as a JSON array string
SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$(aws ec2 describe-vpcs --filters 'Name=isDefault,Values=true' --query 'Vpcs[0].VpcId' --output text)" \
    --query 'Subnets[*].SubnetId' \
    --output json)

# Get security group ID
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$(aws ec2 describe-vpcs --filters 'Name=isDefault,Values=true' --query 'Vpcs[0].VpcId' --output text)" \
    "Name=group-name,Values=default" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

# Create the compute resources JSON with proper formatting
COMPUTE_RESOURCES=$(cat <<EOF
{
    "type": "EC2",
    "minvCpus": 0,
    "maxvCpus": 256,
    "desiredvCpus": 0,
    "instanceTypes": ["optimal"],
    "subnets": ${SUBNET_IDS},
    "securityGroupIds": ["${SECURITY_GROUP_ID}"],
    "instanceRole": "ecsInstanceRole"
}
EOF
)

ensure_resource "Compute Environment" \
    "aws batch describe-compute-environments --compute-environments podcast-labeling-compute-env --query 'computeEnvironments[0]' --output text" \
    "aws batch create-compute-environment \
        --compute-environment-name podcast-labeling-compute-env \
        --type MANAGED \
        --state ENABLED \
        --service-role arn:aws:iam::${AWS_ACCOUNT_ID}:role/AWSBatchServiceRole \
        --compute-resources '${COMPUTE_RESOURCES}' \
        --region ${AWS_REGION}"

# wait_for_status function
wait_for_status() {
    local resource_type=$1
    local resource_name=$2
    local query_path="${resource_type}[0].status"

    # Correct the query path based on resource type
    if [ "$resource_type" == "compute-environments" ]; then
        query_path="computeEnvironments[0].status"
    elif [ "$resource_type" == "job-queues" ]; then
        query_path="jobQueues[0].status"
    fi

    echo -e "${GREEN}Waiting for $resource_type to be ready...${NC}"
    while : ; do
        STATUS=$(aws batch describe-$resource_type --$resource_type $resource_name --query "$query_path" --output text)
        [[ "$STATUS" == "VALID" ]] && break
        [[ "$STATUS" == "INVALID" ]] && { echo -e "${RED}$resource_type creation failed${NC}"; exit 1; }
        echo "Waiting... Current status: $STATUS"
        sleep 10
    done
}

wait_for_status "compute-environments" "podcast-labeling-compute-env"

# Create Job Queue if it doesn't exist
ensure_resource "Job Queue" \
    "aws batch describe-job-queues --job-queues podcast-labeling-job-queue --query 'jobQueues[0]' --output text" \
    "aws batch create-job-queue --job-queue-name podcast-labeling-job-queue --state ENABLED --priority 1 --compute-environment-order order=1,computeEnvironment=podcast-labeling-compute-env"

wait_for_status "job-queues" "podcast-labeling-job-queue"

# Ensure BatchJobRole exists
ensure_resource "BatchJobRole" \
    "aws iam get-role --role-name BatchJobRole" \
    "aws iam create-role --role-name BatchJobRole --assume-role-policy-document '{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ecs-tasks.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}' && \
    aws iam attach-role-policy --role-name BatchJobRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy && \
    aws iam attach-role-policy --role-name BatchJobRole --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess"

# Create CloudWatch log group
echo -e "${GREEN}Creating CloudWatch log group...${NC}"
aws logs create-log-group --log-group-name "/aws/batch/podcast-labeling" || true

# Ensure BatchExecutionRole exists
ensure_resource "BatchExecutionRole" \
    "aws iam get-role --role-name BatchExecutionRole" \
    "aws iam create-role --role-name BatchExecutionRole --assume-role-policy-document '{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ecs-tasks.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}' && \
    aws iam attach-role-policy --role-name BatchExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy && \
    aws iam put-role-policy --role-name BatchExecutionRole --policy-name BatchExecutionRolePolicy --policy-document '{
        \"Version\": \"2012-10-17\",
        \"Statement\": [
            {
                \"Effect\": \"Allow\",
                \"Action\": [
                    \"logs:CreateLogStream\",
                    \"logs:PutLogEvents\",
                    \"logs:CreateLogGroup\",
                    \"logs:DescribeLogGroups\",
                    \"logs:DescribeLogStreams\"
                ],
                \"Resource\": \"arn:aws:logs:*:*:*\"
            }
        ]
    }'"

echo -e "${GREEN}Deployment complete!${NC}"
echo -e "${GREEN}You can now submit jobs using:${NC}"
echo "aws batch submit-job --job-name podcast-labeling-job --job-queue podcast-labeling-job-queue --job-definition podcast-labeling-job"