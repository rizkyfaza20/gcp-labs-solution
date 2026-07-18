#!/usr/bin/env bash
set -euo pipefail
# GSP752 - Terraform State: Backends, Import, and State Management

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
  local default="${1:-us-east1}"
  read -r -p "GCP region [$default]: " input
  REGION="${input:-$default}"
}

# ── Install Terraform (lab's approach with binary fallback) ──────────────
install_terraform() {
  if command -v terraform &>/dev/null; then
    echo "[skip] terraform already installed ($(terraform --version | head -1))"
    return
  fi
  confirm "Terraform not found. Install it?" || return 0

  cat <<'EOF' > ~/.customize_environment
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
EOF
  bash ~/.customize_environment 2>/dev/null || true

  if ! command -v terraform &>/dev/null; then
    echo "[fallback] downloading terraform binary..."
    local ver="1.9.8"
    curl -sLo /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${ver}/terraform_${ver}_linux_amd64.zip"
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

# ═══════════════════════════════════════════════════════════════════════════
# Task 1: Work with backends
# ═══════════════════════════════════════════════════════════════════════════
task1_backends() {
  echo
  echo "═══ Task 1: Work with backends ═══"
  confirm "Run Task 1?" || return

  local dir="$HOME/gsp752-task1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cd "$dir"

  # ── 1. Create initial main.tf ──────────────────────────────────────────
  cat > main.tf <<EOF
provider "google" {
  project     = "$PROJECT_ID"
  region      = "$REGION"
}

resource "google_storage_bucket" "test-bucket-for-state" {
  name        = "$PROJECT_ID"
  location    = "US"
  uniform_bucket_level_access = true
}
EOF

  # ── 2. Add local backend ───────────────────────────────────────────────
  cat > backend.tf <<EOF
terraform {
  backend "local" {
    path = "terraform/state/terraform.tfstate"
  }
}
EOF

  terraform init
  echo
  confirm "Run terraform apply to create the bucket?" && terraform apply -auto-approve

  echo
  echo "[state] current state file:"
  terraform show

  # ── 3. Switch to gcs backend ───────────────────────────────────────────
  echo
  confirm "Migrate state to Cloud Storage backend?" || return

  cat > backend.tf <<EOF
terraform {
  backend "gcs" {
    bucket  = "$PROJECT_ID"
    prefix  = "terraform/state"
  }
}
EOF

  terraform init -migrate-state -auto-approve

  echo "[ok] state migrated to gs://$PROJECT_ID/terraform/state/default.tfstate"

  # ── 4. Add label via gcloud & refresh ──────────────────────────────────
  echo
  if confirm "Add label (key=value) to bucket and refresh state?"; then
    gcloud storage buckets update "gs://$PROJECT_ID" --update-labels=key=value
    terraform refresh
    echo "[state] after refresh:"
    terraform show
  fi

  # ── 5. Clean up ────────────────────────────────────────────────────────
  echo
  confirm "Clean up: revert to local backend and destroy?" || return

  cat > backend.tf <<EOF
terraform {
  backend "local" {
    path = "terraform/state/terraform.tfstate"
  }
}
EOF

  terraform init -migrate-state -auto-approve

  # Add force_destroy so bucket can be deleted
  cat > main.tf <<EOF
provider "google" {
  project     = "$PROJECT_ID"
  region      = "$REGION"
}

resource "google_storage_bucket" "test-bucket-for-state" {
  name        = "$PROJECT_ID"
  location    = "US"
  uniform_bucket_level_access = true
  force_destroy = true
}
EOF

  terraform apply -auto-approve
  terraform destroy -auto-approve

  cd "$HOME"
  rm -rf "$dir"
  echo "[done] Task 1 complete"
}

# ═══════════════════════════════════════════════════════════════════════════
# Task 2: Import a Terraform configuration
# ═══════════════════════════════════════════════════════════════════════════
task2_import() {
  echo
  echo "═══ Task 2: Import a Terraform configuration ═══"
  confirm "Run Task 2 (requires Docker)?" || return

  if ! command -v docker &>/dev/null; then
    echo "[ERROR] Docker not found. Install Docker and re-run."
    return
  fi

  # ── 1. Create Docker container ─────────────────────────────────────────
  echo "[docker] creating hashicorp-learn container..."
  docker rm -f hashicorp-learn 2>/dev/null || true
  docker run --name hashicorp-learn --detach --publish 8080:80 nginx:latest
  docker ps

  # ── 2. Clone repo ──────────────────────────────────────────────────────
  local dir="$HOME/learn-terraform-import"
  rm -rf "$dir"
  git clone https://github.com/hashicorp/learn-terraform-import.git "$dir"
  cd "$dir"

  # ── 3. Update provider version ─────────────────────────────────────────
  sed -i 's/version = "~> 3.0.2"/version = ">= 3.5"/' terraform.tf

  # ── 4. Init ────────────────────────────────────────────────────────────
  terraform init -upgrade

  # ── 5. Fix provider host (comment out Windows npipe) ───────────────────
  sed -i 's/host    = "npipe:\/\/\/\/.\/\/\/pipe\/\/docker_engine"/# host    = "npipe:\/\/\/\/.\/\/\/pipe\/\/docker_engine"/' main.tf

  # ── 6. Add empty docker_container resource ─────────────────────────────
  # First backup original docker.tf
  cp docker.tf docker.tf.bak
  cat > docker.tf <<'EOF'
resource "docker_container" "web" {}
EOF

  # ── 7. Import the container ────────────────────────────────────────────
  local container_id
  container_id=$(docker inspect -f {{.ID}} hashicorp-learn)
  echo "[import] container ID: $container_id"
  terraform import docker_container.web "$container_id"

  echo
  echo "[state] after import:"
  terraform show

  echo
  confirm "Continue with configuration generation?" || return

  # ── 8. Generate config from state ──────────────────────────────────────
  terraform show -no-color > docker.tf

  echo
  echo "[plan] before cleanup (expect warnings):"
  terraform plan 2>&1 || true

  echo
  confirm "Clean up docker.tf to keep only required attributes?" || return

  # ── 9. Clean up docker.tf ──────────────────────────────────────────────
  cat > docker.tf <<'EOF'
resource "docker_container" "web" {
    image = "nginx:latest"
    name  = "hashicorp-learn"
    ports {
        external = 8080
        internal = 80
        ip       = "0.0.0.0"
        protocol = "tcp"
    }
}
EOF

  terraform plan
  echo
  confirm "Run terraform apply to sync?" && terraform apply -auto-approve

  # ── 10. Create image resource ──────────────────────────────────────────
  echo
  confirm "Add docker_image.nginx resource?" || return

  cat >> docker.tf <<'EOF'

resource "docker_image" "nginx" {
  name         = "nginx:latest"
}
EOF

  terraform apply -auto-approve

  # ── 11. Reference image in container ───────────────────────────────────
  cat > docker.tf <<'EOF'
resource "docker_container" "web" {
    image             = docker_image.nginx.image_id
    name              = "hashicorp-learn"
    ports {
        external = 8080
        internal = 80
        ip       = "0.0.0.0"
        protocol = "tcp"
    }
}

resource "docker_image" "nginx" {
  name         = "nginx:latest"
}
EOF

  echo
  confirm "Run terraform apply to update image reference?" && terraform apply -auto-approve

  # ── 12. Change external port ───────────────────────────────────────────
  echo
  confirm "Change external port from 8080 to 8081?" || return

  sed -i 's/external = 8080/external = 8081/' docker.tf

  terraform apply -auto-approve

  docker ps

  # ── 13. Destroy ────────────────────────────────────────────────────────
  echo
  confirm "Destroy all infrastructure?" && terraform destroy -auto-approve

  docker ps --filter "name=hashicorp-learn"

  cd "$HOME"
  rm -rf "$dir"
  echo "[done] Task 2 complete"
}

# ═══════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════
echo "=== GSP752: Terraform State Management ==="
detect_project
pick_region
echo "Project: $PROJECT_ID  |  Region: $REGION"
echo

install_terraform
task1_backends
task2_import

echo
echo "=== GSP752 completed ==="
