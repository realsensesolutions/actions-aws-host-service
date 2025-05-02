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
    mainSteps:
      - name: "PrepareDirectory"
        action: "aws:runShellScript"
        inputs:
          runCommand:
            - |
              # Create working directory if it doesn't exist
              mkdir -p {{WorkingDirectory}}
              chmod 755 {{WorkingDirectory}}
      - name: "InstallAwscli"
        action: "aws:runShellScript"
        inputs:
          runCommand:
            - |
              # Check if AWS CLI is already available
              if command -v aws >/dev/null 2>&1 || command -v /usr/local/aws-cli/v2/current/bin/aws >/dev/null 2>&1; then
                echo "AWS CLI is already installed, proceeding."
              else
                echo "AWS CLI not found. Installing it now."
                # Create lock file directory if it doesn't exist
                sudo mkdir -p /var/lock
                # Use flock to ensure only one installation runs at a time
                (
                  flock -w 300 9 || { echo "Could not acquire lock for AWS CLI installation after 5 minutes. Another process may be installing it."; exit 1; }
                  # Check again after acquiring the lock in case another process installed it
                  if command -v aws >/dev/null 2>&1 || command -v /usr/local/aws-cli/v2/current/bin/aws >/dev/null 2>&1; then
                    echo "AWS CLI was installed by another process while waiting for lock."
                  else
                    echo "Lock acquired, proceeding with AWS CLI installation."
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
                ) 9>/var/lock/aws_cli_install.lock
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
              # Create a temporary directory for extraction
              TEMP_DIR="{{WorkingDirectory}}/.temp_extract"
              mkdir -p "$TEMP_DIR"
              
              # Extract artifacts to temp directory
              tar -xzf {{WorkingDirectory}}/artifacts.tar.gz -C "$TEMP_DIR"
              
              # Compare and copy only changed files
              if [ -d "{{WorkingDirectory}}" ]; then
                # Find all files in the temp directory
                find "$TEMP_DIR" -type f | while read -r SOURCE_FILE; do
                  # Calculate relative path
                  REL_PATH="${SOURCE_FILE#$TEMP_DIR/}"
                  TARGET_FILE="{{WorkingDirectory}}/$REL_PATH"
                  TARGET_DIR=$(dirname "$TARGET_FILE")
                  
                  # Create target directory if it doesn't exist
                  mkdir -p "$TARGET_DIR"
                  
                  # Compare and copy only if different or doesn't exist
                  if [ ! -f "$TARGET_FILE" ] || ! cmp -s "$SOURCE_FILE" "$TARGET_FILE"; then
                    echo "Updating file: $REL_PATH"
                    cp -f "$SOURCE_FILE" "$TARGET_FILE"
                  fi
                done
              else
                # If working directory doesn't exist yet, just move everything
                cp -R "$TEMP_DIR/"* "{{WorkingDirectory}}/"
              fi
              
              # Clean up
              rm {{WorkingDirectory}}/artifacts.tar.gz
              rm -rf "$TEMP_DIR"
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