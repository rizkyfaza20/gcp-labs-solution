#!/usr/bin/env bash
set -euo pipefail
# GSP751 - Terraform Modules: Use Registry modules & build a custom module
# Follows the official lab instructions exactly.

confirm() {
  local prompt="$1" reply
  while true; do
    read -r -p "$prompt [y/n]: " reply
    case "$reply" in [yY]) return 0 ;; [nN]) echo "Skipped."; return 1 ;;
    *) echo "Enter y or n." ;;
    esac
  done
}

detect_project() {
  local detected
  detected=$(gcloud config get-value project 2>/dev/null || true)
  if [[ -z "$detected" || "$detected" == "(unset)" ]]; then
    echo "No project detected via gcloud."
    read -r -p "Enter your GCP project ID: " detected
  else
    echo "Detected project: $detected"
    read -r -p "Use this project? [Y/n]: " reply
    if [[ "$reply" =~ ^[nN] ]]; then
      read -r -p "Enter your GCP project ID: " detected
    fi
  fi
  PROJECT_ID="$detected"
}

pick_region() {
  local default="${1:-us-central1}"
  read -r -p "GCP region [$default]: " input
  REGION="${input:-$default}"
}

# ── Prerequisite: Install Terraform (lab's exact approach) ─────────────────
install_terraform() {
  if command -v terraform &>/dev/null; then
    echo "[skip] terraform already installed ($(terraform --version | head -1))"
    return
  fi
  confirm "Terraform not found. Install it via customize_environment?" || return 0

  cat <<'EOF' > ~/.customize_environment
# Set up HashiCorp repository and install Terraform
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
EOF
  bash ~/.customize_environment

  if ! command -v terraform &>/dev/null; then
    echo "[ERROR] Terraform install failed. Trying direct binary download as fallback..."
    local ver="1.9.8"
    local url="https://releases.hashicorp.com/terraform/${ver}/terraform_${ver}_linux_amd64.zip"
    mkdir -p "$HOME/bin"
    curl -sLo /tmp/terraform.zip "$url"
    unzip -qo /tmp/terraform.zip -d "$HOME/bin" 2>/dev/null
    rm -f /tmp/terraform.zip
    chmod +x "$HOME/bin/terraform"
    export PATH="$HOME/bin:$PATH"
    if ! command -v terraform &>/dev/null; then
      echo "[ERROR] terraform still not found. Exiting."
      exit 1
    fi
  fi
  echo "[ok] terraform $(terraform --version | head -1)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Task 1: Use modules from the Registry
# ═══════════════════════════════════════════════════════════════════════════════
task1_use_registry_module() {
  echo
  echo "═══ Task 1: Use module from Registry ═══"
  confirm "Run Task 1?" || return

  local dir="$HOME/terraform-google-network"
  rm -rf "$dir"

  echo "Cloning terraform-google-network..."
  git clone https://github.com/terraform-google-modules/terraform-google-network "$dir"
  cd "$dir"
  git checkout tags/v6.0.1 -b v6.0.1

  cd "$dir/examples/simple_project"

  # ── Update variables.tf ──────────────────────────────────────────────────
  cat > variables.tf <<EOF
variable "project_id" {
  description = "The project ID to host the network in"
  default     = "$PROJECT_ID"
}

variable "network_name" {
  description = "The name of the network to be created"
  default     = "example-vpc"
}
EOF

  # ── Update main.tf ───────────────────────────────────────────────────────
  cat > main.tf <<EOF
module "test-vpc-module" {
  source       = "terraform-google-modules/network/google"
  version      = "~> 6.0"
  project_id   = var.project_id
  network_name = var.network_name
  mtu          = 1460

  subnets = [
    {
      subnet_name   = "subnet-01"
      subnet_ip     = "10.10.10.0/24"
      subnet_region = "$REGION"
    },
    {
      subnet_name           = "subnet-02"
      subnet_ip             = "10.10.20.0/24"
      subnet_region         = "$REGION"
      subnet_private_access = "true"
      subnet_flow_logs      = "true"
    },
    {
      subnet_name               = "subnet-03"
      subnet_ip                 = "10.10.30.0/24"
      subnet_region             = "$REGION"
      subnet_flow_logs          = "true"
      subnet_flow_logs_interval = "INTERVAL_10_MIN"
      subnet_flow_logs_sampling = 0.7
      subnet_flow_logs_metadata = "INCLUDE_ALL_METADATA"
      subnet_flow_logs_filter   = "false"
    }
  ]
}
EOF

  terraform init
  echo
  confirm "Run terraform apply?" && terraform apply -auto-approve
  echo
  confirm "Run terraform destroy?" && terraform destroy -auto-approve

  cd "$HOME"
  rm -rf "$dir"
  echo "[done] Task 1 complete"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Task 2: Build a module
# ═══════════════════════════════════════════════════════════════════════════════
task2_build_module() {
  echo
  echo "═══ Task 2: Build a module ═══"
  confirm "Run Task 2?" || return

  # Save any existing files to restore later
  local backup_dir
  backup_dir="$(mktemp -d)"
  for f in main.tf variables.tf outputs.tf; do
    [[ -f "$HOME/$f" ]] && cp "$HOME/$f" "$backup_dir/"
  done
  [[ -d "$HOME/modules" ]] && cp -r "$HOME/modules" "$backup_dir/" 2>/dev/null || true

  cd "$HOME"

  # ── Create root main.tf and module directory ─────────────────────────────
  touch main.tf
  mkdir -p modules/gcs-static-website-bucket
  cd modules/gcs-static-website-bucket
  touch website.tf variables.tf outputs.tf

  # ── README.md ────────────────────────────────────────────────────────────
  tee -a README.md <<EOF
# GCS static website bucket

This module provisions Cloud Storage buckets configured for static website hosting.
EOF

  # ── LICENSE ──────────────────────────────────────────────────────────────
  tee -a LICENSE <<EOF
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
EOF

  # ── website.tf ───────────────────────────────────────────────────────────
  cat > website.tf <<'TFEOF'
resource "google_storage_bucket" "bucket" {
  name               = var.name
  project            = var.project_id
  location           = var.location
  storage_class      = var.storage_class
  labels             = var.labels
  force_destroy      = var.force_destroy
  uniform_bucket_level_access = true

  versioning {
    enabled = var.versioning
  }

  dynamic "retention_policy" {
    for_each = var.retention_policy == null ? [] : [var.retention_policy]
    content {
      is_locked        = var.retention_policy.is_locked
      retention_period = var.retention_policy.retention_period
    }
  }

  dynamic "encryption" {
    for_each = var.encryption == null ? [] : [var.encryption]
    content {
      default_kms_key_name = var.encryption.default_kms_key_name
    }
  }

  dynamic "lifecycle_rule" {
    for_each = var.lifecycle_rules
    content {
      action {
        type          = lifecycle_rule.value.action.type
        storage_class = lookup(lifecycle_rule.value.action, "storage_class", null)
      }
      condition {
        age                   = lookup(lifecycle_rule.value.condition, "age", null)
        created_before        = lookup(lifecycle_rule.value.condition, "created_before", null)
        with_state            = lookup(lifecycle_rule.value.condition, "with_state", null)
        matches_storage_class = lookup(lifecycle_rule.value.condition, "matches_storage_class", null)
        num_newer_versions    = lookup(lifecycle_rule.value.condition, "num_newer_versions", null)
      }
    }
  }
}
TFEOF

  # ── variables.tf (module) ────────────────────────────────────────────────
  cat > variables.tf <<'TFEOF'
variable "name" {
  description = "The name of the bucket."
  type        = string
}

variable "project_id" {
  description = "The ID of the project to create the bucket in."
  type        = string
}

variable "location" {
  description = "The location of the bucket."
  type        = string
}

variable "storage_class" {
  description = "The Storage Class of the new bucket."
  type        = string
  default     = null
}

variable "labels" {
  description = "A set of key/value label pairs to assign to the bucket."
  type        = map(string)
  default     = null
}


variable "bucket_policy_only" {
  description = "Enables Bucket Policy Only access to a bucket."
  type        = bool
  default     = true
}

variable "versioning" {
  description = "While set to true, versioning is fully enabled for this bucket."
  type        = bool
  default     = true
}

variable "force_destroy" {
  description = "When deleting a bucket, this boolean option will delete all contained objects. If false, Terraform will fail to delete buckets which contain objects."
  type        = bool
  default     = true
}

variable "iam_members" {
  description = "The list of IAM members to grant permissions on the bucket."
  type = list(object({
    role   = string
    member = string
  }))
  default = []
}

variable "retention_policy" {
  description = "Configuration of the bucket's data retention policy for how long objects in the bucket should be retained."
  type = object({
    is_locked        = bool
    retention_period = number
  })
  default = null
}

variable "encryption" {
  description = "A Cloud KMS key that will be used to encrypt objects inserted into this bucket"
  type = object({
    default_kms_key_name = string
  })
  default = null
}

variable "lifecycle_rules" {
  description = "The bucket's Lifecycle Rules configuration."
  type = list(object({
    # Object with keys:
    # - type - The type of the action of this Lifecycle Rule. Supported values: Delete and SetStorageClass.
    # - storage_class - (Required if action type is SetStorageClass) The target Storage Class of objects affected by this Lifecycle Rule.
    action = any

    # Object with keys:
    # - age - (Optional) Minimum age of an object in days to satisfy this condition.
    # - created_before - (Optional) Creation date of an object in RFC 3339 (e.g. 2017-06-13) to satisfy this condition.
    # - with_state - (Optional) Match to live and/or archived objects. Supported values include: "LIVE", "ARCHIVED", "ANY".
    # - matches_storage_class - (Optional) Storage Class of objects to satisfy this condition. Supported values include: MULTI_REGIONAL, REGIONAL, NEARLINE, COLDLINE, STANDARD, DURABLE_REDUCED_AVAILABILITY.
    # - num_newer_versions - (Optional) Relevant only for versioned objects. The number of newer versions of an object to satisfy this condition.
    condition = any
  }))
  default = []
}
TFEOF

  # ── outputs.tf (module) ──────────────────────────────────────────────────
  cat > outputs.tf <<'TFEOF'
output "bucket" {
  description = "The created storage bucket"
  value       = google_storage_bucket.bucket
}
TFEOF

  # ── Root main.tf ─────────────────────────────────────────────────────────
  cd "$HOME"
  cat > main.tf <<EOF
module "gcs-static-website-bucket" {
  source = "./modules/gcs-static-website-bucket"

  name       = var.name
  project_id = var.project_id
  location   = "$REGION"

  lifecycle_rules = [{
    action = {
      type = "Delete"
    }
    condition = {
      age        = 365
      with_state = "ANY"
    }
  }]
}
EOF

  # ── Root outputs.tf ──────────────────────────────────────────────────────
  cat > outputs.tf <<'EOF'
output "bucket-name" {
  description = "Bucket names."
  value       = "module.gcs-static-website-bucket.bucket"
}
EOF

  # ── Root variables.tf ────────────────────────────────────────────────────
  cat > variables.tf <<EOF
variable "project_id" {
  description = "The ID of the project in which to provision resources."
  type        = string
  default     = "$PROJECT_ID"
}

variable "name" {
  description = "Name of the buckets to create."
  type        = string
  default     = "$PROJECT_ID"
}
EOF

  # ── Provision ────────────────────────────────────────────────────────────
  terraform init
  echo
  confirm "Run terraform apply?" && terraform apply -auto-approve

  # ── Upload sample files ──────────────────────────────────────────────────
  if confirm "Upload sample index.html and error.html to the bucket?"; then
    cd "$HOME"
    curl -s https://raw.githubusercontent.com/hashicorp/learn-terraform-modules/master/modules/aws-s3-static-website-bucket/www/index.html > index.html
    curl -s https://raw.githubusercontent.com/hashicorp/learn-terraform-modules/blob/master/modules/aws-s3-static-website-bucket/www/error.html > error.html
    gsutil cp *.html "gs://$PROJECT_ID"
    echo "Website: https://storage.cloud.google.com/$PROJECT_ID/index.html"
  fi

  # ── Destroy ──────────────────────────────────────────────────────────────
  echo
  confirm "Run terraform destroy?" && terraform destroy -auto-approve

  # ── Clean up created files ───────────────────────────────────────────────
  cd "$HOME"
  rm -f main.tf variables.tf outputs.tf index.html error.html
  rm -rf modules
  # Restore any pre-existing files
  for f in main.tf variables.tf outputs.tf; do
    [[ -f "$backup_dir/$f" ]] && cp "$backup_dir/$f" "$HOME/"
  done
  [[ -d "$backup_dir/modules" ]] && cp -r "$backup_dir/modules" "$HOME/" 2>/dev/null || true
  rm -rf "$backup_dir"

  echo "[done] Task 2 complete"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════
echo "=== GSP751: Terraform Modules ==="
detect_project
pick_region
echo "Project: $PROJECT_ID  |  Region: $REGION"
echo

install_terraform
task1_use_registry_module
task2_build_module

echo
echo "=== GSP751 completed ==="
