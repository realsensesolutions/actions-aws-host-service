resource "aws_s3_bucket" "artifacts" {
  bucket = "actions-aws-host-service-${var.name}-${random_id.bucket.hex}"
  
  tags = {
    provisioned-by = "actions-aws-host-service"
  }
}

# SSM document
resource "aws_ssm_document" "service" {
  name          = "actions-aws-host-service-${var.name}"
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
    mainSteps:
      - name: "DownloadArtifacts"
        action: "aws:downloadContent"
        inputs:
          sourceType: "S3"
          sourceInfo: "{\"path\": \"https://s3.amazonaws.com/${aws_s3_bucket.artifacts.bucket}/{{ArtifactPath}}/artifacts.zip\"}"
          destinationPath: "{{WorkingDirectory}}"
      - name: "ExtractArtifacts"
        action: "aws:runShellScript"
        inputs:
          runCommand:
            - |
              # Extract zip file
              unzip -o "{{WorkingDirectory}}/artifacts.zip" -d "{{WorkingDirectory}}"
      - name: "UpdateService"
        action: "aws:runShellScript"
        inputs:
          runCommand:
            - |
              # Compare service definition
              if [ ! -f "/etc/systemd/system/{{ServiceName}}.service" ] || ! diff -q "{{WorkingDirectory}}/{{DefinitionFile}}" "/etc/systemd/system/{{ServiceName}}.service"; then
                # Copy new definition
                cp "{{WorkingDirectory}}/{{DefinitionFile}}" "/etc/systemd/system/{{ServiceName}}.service"
                systemctl daemon-reload
              fi
              
              # Set service status
              if [ "{{ServiceStatus}}" = "enabled" ]; then
                systemctl enable {{ServiceName}}
                systemctl start {{ServiceName}}
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
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*"
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
  }
}

# Create zip archive of artifacts
data "archive_file" "artifacts" {
  type        = "zip"
  source_dir  = var.artifacts_path
  output_path = "${path.module}/artifacts.zip"
}

# Upload zip file to S3
resource "aws_s3_object" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "${var.artifact_path}/artifacts.zip"
  source = data.archive_file.artifacts.output_path
  etag   = data.archive_file.artifacts.output_md5
}

# Outputs
output "bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "document" {
  value = aws_ssm_document.service.arn
} 