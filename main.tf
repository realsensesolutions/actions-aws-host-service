resource "aws_s3_bucket" "artifacts" {
  bucket = "actions-aws-host-service-${var.name}-${random_id.bucket.hex}"
  
  tags = {
    provisioned-by = "actions-aws-host-service"
  }
}

# SSM document
resource "aws_ssm_document" "service" {
  name          = "actions-aws-host-service-${var.name}-${data.archive_file.artifacts.output_md5}"
  document_type = "Command"
  document_format = "YAML"
  
  content = <<-DOC
    schemaVersion: '2.2'
    description: Deploy and manage systemd services
    parameters:
      ServiceName:
        type: String
        description: Name of the service
      ServiceStatus:
        type: String
        description: Service status (enabled/disabled)
      WorkingDirectory:
        type: String
        description: Where to extract artifacts
      ArtifactPath:
        type: String
        description: Path to artifacts in S3
      DefinitionFile:
        type: String
        description: Service definition file path
      SetupFile:
        type: String
        description: Setup script file path
        default: ""
      Service:
        type: String
        description: Whether to check for infrastructure service
        default: "false"
      DependentService:
        type: String
        description: Infrastructure service name to check
        default: ""
    mainSteps:
      - name: "CheckDependentService"
        action: "aws:runShellScript"
        precondition:
          StringEquals: ["{{Service}}", "true"]
        inputs:
          runCommand:
            - |
              #!/bin/bash
              if [ "{{DependentService}}" != "" ]; then
                echo "Checking if {{DependentService}} service is active..."
                max_retries=20
                retry_count=0
                
                while [ $retry_count -lt $max_retries ]; do
                  if systemctl is-active {{DependentService}} >/dev/null 2>&1; then
                    echo "Service {{DependentService}} is active, proceeding with deployment."
                    exit 0
                  else
                    echo "Service {{DependentService}} is not active, retrying in 30 seconds (attempt $((retry_count+1))/$max_retries)"
                    sleep 30
                    retry_count=$((retry_count+1))
                  fi
                done
                
                echo "Service {{DependentService}} did not become active after $max_retries attempts. Deployment will continue but may fail."
              else
                echo "No infrastructure service specified to check. Proceeding without checks."
              fi
      - name: "PrepareDirectory"
        action: "aws:runShellScript"
        inputs:
          runCommand:
            - |
              # Create working directory if it doesn't exist
              mkdir -p {{WorkingDirectory}}
              chmod 755 {{WorkingDirectory}}
      - name: "DownloadArtifacts"
        action: "aws:runShellScript"
        inputs:
          runCommand:
            - |
              # Check if AWS CLI is already available
              if command -v aws >/dev/null 2>&1 || command -v /usr/local/aws-cli/v2/current/bin/aws >/dev/null 2>&1; then
                echo "AWS CLI is already installed, proceeding."
              else
                echo "AWS CLI not found. Installing it now."
                if curl -s https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip -o {{WorkingDirectory}}/awscliv2.zip && \
                   unzip -q {{WorkingDirectory}}/awscliv2.zip -d {{WorkingDirectory}} && \
                   sudo {{WorkingDirectory}}/aws/install --update; then
                  echo "AWS CLI installed successfully!"
                  sudo rm -rf {{WorkingDirectory}}/awscliv2.zip {{WorkingDirectory}}/aws
                else
                  echo "AWS CLI installation failed."
                  exit 1
                fi
              fi
      - name: "DownloadS3Artifacts"
        action: "aws:runShellScript"
        inputs:
          runCommand:
            - |
              # Download artifacts with AWS CLI
              if command -v /usr/local/aws-cli/v2/current/bin/aws >/dev/null 2>&1; then
                echo "Using AWS CLI from specific path to download artifacts"
                /usr/local/aws-cli/v2/current/bin/aws s3 cp s3://${aws_s3_bucket.artifacts.bucket}/{{ArtifactPath}}/artifacts.tar.gz {{WorkingDirectory}}/artifacts.tar.gz
              elif command -v aws >/dev/null 2>&1; then
                echo "Using AWS CLI from PATH to download artifacts"
                aws s3 cp s3://${aws_s3_bucket.artifacts.bucket}/{{ArtifactPath}}/artifacts.tar.gz {{WorkingDirectory}}/artifacts.tar.gz
              else
                echo "AWS CLI not available after installation attempts."
                exit 1
              fi
      - name: "ExtractArtifacts"
        action: "aws:runShellScript"
        inputs:
          runCommand:
            - |
              # Extract to working directory
              tar -xzf {{WorkingDirectory}}/artifacts.tar.gz -C {{WorkingDirectory}}
              # Clean up
              rm {{WorkingDirectory}}/artifacts.tar.gz
      - name: "RunSetup"
        action: "aws:runShellScript"
        inputs:
          runCommand:
            - |
              # Run setup script if provided
              if [ ! -z "{{SetupFile}}" ] && [ -f "{{WorkingDirectory}}/{{SetupFile}}" ]; then
                chmod +x "{{WorkingDirectory}}/{{SetupFile}}"
                cd "{{WorkingDirectory}}"
                ./{{SetupFile}}
              fi
      - name: "UpdateService"
        action: "aws:runShellScript"
        inputs:
          runCommand:
            - |
              # Compare service definition
              if [ ! -f "/etc/systemd/system/{{ServiceName}}.service" ] || ! diff -q "{{WorkingDirectory}}/{{DefinitionFile}}" "/etc/systemd/system/{{ServiceName}}.service"; then
                # Copy new definition
                mv "{{WorkingDirectory}}/{{DefinitionFile}}" "/etc/systemd/system/{{ServiceName}}.service"
                systemctl daemon-reload
              fi
              
              # Set service status
              if [ "{{ServiceStatus}}" = "enabled" ]; then
                systemctl enable {{ServiceName}}
                systemctl restart {{ServiceName}}
              else
                systemctl stop {{ServiceName}}
                systemctl disable {{ServiceName}}
              fi
  DOC

  depends_on = [aws_s3_object.artifacts]
}

# IAM role for SSM
resource "aws_iam_role" "ssm" {
  name = "actions-aws-host-service-${var.name}"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ssm.amazonaws.com"
        }
      }
    ]
  })
  
  tags = {
    provisioned-by = "actions-aws-host-service"
  }
}

resource "aws_iam_role_policy" "s3_access" {
  name = "s3-access"
  role = aws_iam_role.ssm.id
    
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Effect = "Allow"
        Resource = [
          "arn:aws:s3:::actions-aws-host-service-*",
          "arn:aws:s3:::actions-aws-host-service-*/*"
        ]
      }
    ]
  })
}

# Random ID for bucket name
resource "random_id" "bucket" {
  byte_length = 8
}

# SSM document association
resource "aws_ssm_association" "service" {
  name = aws_ssm_document.service.name
  depends_on = [aws_ssm_document.service, aws_s3_object.artifacts]
  
  dynamic "targets" {
    for_each = [for target in split("\n", var.targets) : {
      key   = "tag:${trimspace(split(":", target)[0])}"
      value = trimspace(split(":", target)[1])
    } if length(split(":", target)) == 2]
    
    content {
      key    = targets.value.key
      values = [targets.value.value]
    }
  }
  
  parameters = {
    ServiceName     = var.name
    ServiceStatus   = var.status
    WorkingDirectory = var.working_directory
    ArtifactPath    = var.artifact_path
    DefinitionFile  = var.definition_file
    SetupFile       = var.setup_file
    Service         = tostring(var.service)
    DependentService = var.service_name
  }
}

# Create tar.gz archive of artifacts
data "archive_file" "artifacts" {
  type        = "tar.gz"
  source_dir  = var.artifacts_path
  output_path = "${path.module}/artifacts.tar.gz"
}

# Upload tar.gz file to S3 
resource "aws_s3_object" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "${var.artifact_path}/artifacts.tar.gz"
  source = data.archive_file.artifacts.output_path
  etag   = data.archive_file.artifacts.output_md5
  force_destroy = false
}

# Outputs
output "bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "document" {
  value = aws_ssm_document.service.arn
}

output "role_name" {
  value = aws_iam_role.ssm.name
}

# Attach AmazonSSMManagedInstanceCore policy to IAM role
resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
} 