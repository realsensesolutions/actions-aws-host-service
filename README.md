# Actions AWS Host Service

This GitHub Action deploys and manages systemd services on External Hosts or EC2 using AWS Systems Manager (SSM). It creates an SSM document and association to handle service deployment and management.

## Architecture

```mermaid
graph TD
    subgraph GitHub Actions
        GA[GitHub Actions Workflow]
    end

    subgraph AWS
        S3[S3 Bucket]
        SSM[SSM Service]
        IAM[IAM Role]
    end

    subgraph Host
        SSMAgent[SSM Agent]
        SystemD[SystemD Service]
    end

    GA -->|1. Upload Artifacts| S3
    GA -->|2. Create SSM Document| SSM
    GA -->|3. Assume Role| IAM
    SSM -->|4. Execute Commands| SSMAgent
    SSMAgent -->|5. Manage Service| SystemD
    S3 -->|6. Download Artifacts| SSMAgent
```

## Deployment Flow

```mermaid
sequenceDiagram
    participant GA as GitHub Actions
    participant S3 as S3 Bucket
    participant SSM as SSM Service
    participant Host as Target Host

    GA->>S3: 1. Create Bucket
    GA->>S3: 2. Upload Artifacts
    GA->>SSM: 3. Create Document
    GA->>SSM: 4. Create Association
    SSM->>Host: 5. Download Artifacts
    SSM->>Host: 6. Extract Files
    SSM->>Host: 7. Update Service
    SSM->>Host: 8. Manage State
```

## Features

- Deploy systemd services to EC2 instances
- Manage service state (enable/disable)
- Automatically handle service definition updates
- Target instances using AWS tags
- Secure artifact storage in S3

## Prerequisites

- AWS credentials with appropriate permissions
- EC2 instances with SSM agent installed
- Instances must be tagged appropriately for targeting

## Inputs

### Required Inputs

| Name | Description | Example |
|------|-------------|---------|
| `name` | Service name | `my-service` |
| `definition` | Service definition file path (relative to artifacts) | `my-service.service` |
| `targets` | Target selection criteria in format KEY:VALUE (one per line) | `Environment:DEV` |
| `artifacts` | Folder containing deployment artifacts | `resource/my-service` |

### Optional Inputs

| Name | Description | Default | Example |
|------|-------------|---------|---------|
| `status` | Service status (enabled/disabled) | `enabled` | `disabled` |
| `working-directory` | Where to extract artifacts on target instances | `/home/ssm-user` | `/opt/my-service` |
| `action` | Desired outcome: apply, plan or destroy | `apply` | `plan` |

## Outputs

| Name | Description |
|------|-------------|
| `bucket` | S3 bucket name for artifacts |
| `document` | SSM document ARN |

## Usage

```yaml
name: Deploy Service

on:
  push:
    branches: [ main ]

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    
    steps:
    - uses: actions/checkout@v4

    - name: Configure AWS Credentials
      uses: aws-actions/configure-aws-credentials@v4
      with:
        role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
        aws-region: us-east-1

    - name: Deploy Service
      uses: realsensesolutions/actions-aws-host-service@main
      with:
        name: my-service
        status: enabled
        working-directory: /opt/my-service
        definition: my-service.service
        artifacts: resource/my-service
        targets: |
          Environment:DEV
```

## How It Works

1. Creates an S3 bucket for storing service artifacts
2. Creates an SSM document with the service management commands
3. Sets up IAM roles and policies for SSM
4. Creates an SSM association targeting instances based on tags
5. Uploads and deploys the service artifacts
6. Manages the service state (enable/disable)

## Security

- Uses AWS IAM roles for secure access
- Artifacts are stored in a dedicated S3 bucket
- SSM provides secure command execution
- All resources are tagged with `provisioned-by: actions-aws-host-service`

## Development

### Local Testing

1. Set up AWS credentials
2. Run Terraform locally:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

### Requirements

- Terraform 1.0+
- AWS CLI configured
- Appropriate AWS permissions

## License

[Add your license here]
