# Using AWS Batch and AssemblyAI to Label Podcast Episodes at Scale

A scalable AWS Batch pipeline that automatically labels podcast speakers using AssemblyAI transcription and LeMUR APIs.

## Overview

This project processes a podcast catalogue stored in S3 to:
1. Transcribe audio using AssemblyAI's API
2. Identify and label speakers using the LeMUR API based on this [Cookbook](https://github.com/AssemblyAI/cookbook/blob/master/lemur/speaker-identification.ipynb)
3. Store the speaker-labeled transcript back in S3

## Prerequisites

- AWS Account with appropriate IAM permissions for:
  - AWS Batch operations
  - ECR repository management
  - S3 operations
- AWS CLI installed and configured (`pip install awscli`)
- Docker installed (for local testing)
- AssemblyAI [API key](https://www.assemblyai.com/dashboard/signup)

## Setup

1. Clone this repository and configure your environment:
   ```bash
   # Configure AWS CLI with your credentials
   aws configure
   ```

2. Create required IAM roles:
   - Create a job role with permissions for S3 and CloudWatch Logs
   - Create an execution role for AWS Batch
   - Note the ARNs for both roles

3. Update configuration files:

   In `deploy.sh`:
   ```bash
   AWS_ACCOUNT_ID="your-account-id"
   AWS_REGION="your-region"  # default is us-west-2
   ```

   In `batch-job-definition.json`:
   ```json
   {
     "jobRoleArn": "arn:aws:iam::YOUR_ACCOUNT:role/YOUR_JOB_ROLE",
     "executionRoleArn": "arn:aws:iam::YOUR_ACCOUNT:role/YOUR_EXECUTION_ROLE",
     "environment": [
       {
         "name": "S3_BUCKET_LOCATION",
         "value": "your-bucket-name"
       },
       {
         "name": "ASSEMBLYAI_API_KEY",
         "value": "your-api-key"
       },
       {
         "name": "S3_BUCKET_PREFIX",
         "value": ""
       },
       {
         "name": "MAX_CONCURRENT_JOBS",
         "value": "200"
       }
     ]
   }
   ```
   Only the `S3_BUCKET_LOCATION` and `ASSEMBLYAI_API_KEY` are required.
   `S3_BUCKET_PREFIX` format is `folder/subfolder/`
   `MAX_CONCURRENT_JOBS` is the maximum number of jobs to run concurrently and defaults to AssemblyAI's account concurrency limit of 200.

4. Run the deployment script:
   ```bash
   chmod +x deploy.sh
   ./deploy.sh
   ```

   The script will:
   - Build the Docker image
   - Create an ECR repository
   - Push the image to ECR
   - Set up AWS Batch resources (job queue, compute environment, job definition). You can also choose to set these up in the AWS Batch console if you prefer.

## Usage

1. Submit a batch job:
   ```bash
   aws batch submit-job \
       --job-name podcast-labeling-job \
       --job-queue podcast-labeling-job-queue \
       --job-definition podcast-labeling-job
   ```

2. Monitor progress:
   ```bash
   # Get job status
   aws batch describe-jobs --jobs <job-id>
   
   # View logs in CloudWatch
   aws logs get-log-events \
       --log-group-name /aws/batch/podcast-labeling \
       --log-stream-name podcast-labeling/<job-id>
   ```

## Project Structure

```
.
├── README.md                    # Documentation
├── deploy.sh                    # Deployment automation script
├── Dockerfile                   # Container definition
├── batch_transcribe.py         # Main processing script
└── batch-job-definition.json   # AWS Batch job configuration
```

## Costs

AWS Batch costs are based on underlying resources:

1. **Compute (EC2/Spot)**:
   - Use Spot Instances for up to 90% savings
   - Default configuration: 2 vCPUs, 4GB memory
   - Concurrent jobs limited to 200 by default

2. **API Costs**:
   - AssemblyAI Transcription: Pay per second of audio processed
   - LeMUR: Pay per input and output tokens generated

3. **Storage & Transfer**:
   - S3 storage for podcasts and metadata
   - CloudWatch Logs storage
   - Data transfer between services

## Troubleshooting

Common issues and solutions:

1. **Job Fails Immediately**
   - Check IAM roles and permissions
   - Verify S3 bucket exists and is accessible
   - Ensure AssemblyAI API key is valid

2. **Container Errors**
   - Check CloudWatch logs for detailed error messages
   - Verify memory/CPU settings are sufficient
   - Test Docker image locally

3. **Network Issues**
   - Confirm public IP assignment is enabled
   - Check VPC/subnet configurations
   - Verify internet access is available

## Clean Up

Remove all created resources:
```bash
# Delete job queue
aws batch update-job-queue --job-queue podcast-labeling-job-queue --state DISABLED
aws batch delete-job-queue --job-queue podcast-labeling-job-queue

# Delete compute environment
aws batch update-compute-environment --compute-environment podcast-labeling-compute-env --state DISABLED
aws batch delete-compute-environment --compute-environment podcast-labeling-compute-env

# Delete ECR repository
aws ecr delete-repository --repository-name podcast-labeling --force
```

## Additional Resources

- [AWS Batch Documentation](https://docs.aws.amazon.com/batch/)
- [AssemblyAI API Documentation](https://www.assemblyai.com/docs)
- [AWS Batch Pricing](https://aws.amazon.com/batch/pricing/)
- [AssemblyAI Pricing](https://www.assemblyai.com/pricing)