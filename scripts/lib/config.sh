#!/usr/bin/env bash
# Configuration handling for devbox

# Load global configuration
load_global_config() {
    if [[ -f "$GLOBAL_CONFIG_FILE" ]]; then
        echo "  Reading global config from: $GLOBAL_CONFIG_FILE"
        # Use jq if available, otherwise use grep/sed fallback
        if command -v jq &> /dev/null; then
            GCP_PROJECT=$(jq -r '.gcpProject // empty' "$GLOBAL_CONFIG_FILE")
            VM_NAME=$(jq -r '.vmName // empty' "$GLOBAL_CONFIG_FILE")
            DISK_NAME=$(jq -r '.diskName // empty' "$GLOBAL_CONFIG_FILE")
            MACHINE_TYPE=$(jq -r '.machineType // "n1-standard-8"' "$GLOBAL_CONFIG_FILE")
            REGION=$(jq -r '.region // "us-central1"' "$GLOBAL_CONFIG_FILE")
            ZONE=$(jq -r '.zone // "us-central1-a"' "$GLOBAL_CONFIG_FILE")
            DISK_SIZE_GB=$(jq -r '.diskSizeGB // 300' "$GLOBAL_CONFIG_FILE")
            IDLE_TIMEOUT_MINUTES=$(jq -r '.idleTimeoutMinutes // 10' "$GLOBAL_CONFIG_FILE")
        else
            # Fallback parsing without jq
            GCP_PROJECT=$(grep -o '"gcpProject": *"[^"]*"' "$GLOBAL_CONFIG_FILE" | cut -d'"' -f4 || echo "")
            VM_NAME=$(grep -o '"vmName": *"[^"]*"' "$GLOBAL_CONFIG_FILE" | cut -d'"' -f4 || echo "")
            DISK_NAME=$(grep -o '"diskName": *"[^"]*"' "$GLOBAL_CONFIG_FILE" | cut -d'"' -f4 || echo "")
            MACHINE_TYPE=$(grep -o '"machineType": *"[^"]*"' "$GLOBAL_CONFIG_FILE" | cut -d'"' -f4 || echo "n1-standard-8")
            REGION=$(grep -o '"region": *"[^"]*"' "$GLOBAL_CONFIG_FILE" | cut -d'"' -f4 || echo "us-central1")
            ZONE=$(grep -o '"zone": *"[^"]*"' "$GLOBAL_CONFIG_FILE" | cut -d'"' -f4 || echo "us-central1-a")
            DISK_SIZE_GB=$(grep -o '"diskSizeGB": *[0-9]*' "$GLOBAL_CONFIG_FILE" | grep -o '[0-9]*' || echo "300")
            IDLE_TIMEOUT_MINUTES=$(grep -o '"idleTimeoutMinutes": *[0-9]*' "$GLOBAL_CONFIG_FILE" | grep -o '[0-9]*' || echo "10")
        fi
    else
        echo "  Global config not found. Creating it..."
        prompt_global_config
    fi

    # Set defaults if not provided
    # GCP_PROJECT should be set from config or prompt, no default
    VM_NAME="${VM_NAME:-devbox-${USERNAME}}"
    DISK_NAME="${DISK_NAME:-devbox-${USERNAME}-disk}"
    MACHINE_TYPE="${MACHINE_TYPE:-n1-standard-8}"
    REGION="${REGION:-us-central1}"
    ZONE="${ZONE:-us-central1-a}"
    DISK_SIZE_GB="${DISK_SIZE_GB:-300}"
    IDLE_TIMEOUT_MINUTES="${IDLE_TIMEOUT_MINUTES:-10}"

    # Save global config
    mkdir -p "$GLOBAL_CONFIG_DIR"
    cat > "$GLOBAL_CONFIG_FILE" <<EOF
{
  "gcpProject": "${GCP_PROJECT}",
  "vmName": "${VM_NAME}",
  "diskName": "${DISK_NAME}",
  "machineType": "${MACHINE_TYPE}",
  "region": "${REGION}",
  "zone": "${ZONE}",
  "diskSizeGB": ${DISK_SIZE_GB},
  "idleTimeoutMinutes": ${IDLE_TIMEOUT_MINUTES}
}
EOF
    echo "  Global config saved to: $GLOBAL_CONFIG_FILE"
}

# Prompt for global configuration
prompt_global_config() {
    echo ""
    echo "Global Devbox Configuration"
    echo "=========================="
    echo ""
    
    # Get current project as default
    CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null || echo "")
    
    # List available projects
    echo "Available GCP projects:"
    gcloud projects list --format="table(projectId,name)" 2>/dev/null || echo "  (Unable to list projects)"
    echo ""
    
    if [[ -n "$CURRENT_PROJECT" ]]; then
        read -p "GCP Project ID [${CURRENT_PROJECT}]: " input_gcp_project
        GCP_PROJECT="${input_gcp_project:-${CURRENT_PROJECT}}"
    else
        read -p "GCP Project ID: " input_gcp_project
        GCP_PROJECT="${input_gcp_project}"
    fi
    
    if [[ -z "$GCP_PROJECT" ]]; then
        echo "❌ Error: GCP Project ID is required"
        return 1
    fi
    
    # Verify project exists and user has access
    if ! gcloud projects describe "$GCP_PROJECT" &>/dev/null; then
        echo "⚠ Warning: Cannot verify access to project '${GCP_PROJECT}'"
        echo "  Make sure you have access to this project"
    fi
    
    echo ""
    read -p "VM name [devbox-${USERNAME}]: " input_vm_name
    VM_NAME="${input_vm_name:-devbox-${USERNAME}}"
    
    read -p "Disk name [devbox-${USERNAME}-disk]: " input_disk_name
    DISK_NAME="${input_disk_name:-devbox-${USERNAME}-disk}"
    
    echo ""
    echo "Available machine types (common):"
    echo "  - n1-standard-4  (4 vCPU, 15 GB RAM)"
    echo "  - n1-standard-8  (8 vCPU, 30 GB RAM)"
    echo "  - n1-standard-16 (16 vCPU, 60 GB RAM)"
    echo "  - n2-standard-8  (8 vCPU, 32 GB RAM)"
    read -p "Machine type [n1-standard-8]: " input_machine_type
    MACHINE_TYPE="${input_machine_type:-n1-standard-8}"
    
    read -p "Region [us-central1]: " input_region
    REGION="${input_region:-us-central1}"
    
    read -p "Zone [us-central1-a]: " input_zone
    ZONE="${input_zone:-us-central1-a}"
    
    read -p "Disk size (GB) [300]: " input_disk_size
    DISK_SIZE_GB="${input_disk_size:-300}"
    
    read -p "Idle timeout (minutes) [10]: " input_idle_timeout
    IDLE_TIMEOUT_MINUTES="${input_idle_timeout:-10}"
}

# Load project configuration
load_project_config() {
    if [[ -f "$PROJECT_CONFIG_FILE" ]]; then
        echo "  Reading project config from: $PROJECT_CONFIG_FILE"
        if command -v jq &> /dev/null; then
            PROJECT_DIR_NAME=$(jq -r '.projectDir // empty' "$PROJECT_CONFIG_FILE")
        else
            PROJECT_DIR_NAME=$(grep -o '"projectDir": *"[^"]*"' "$PROJECT_CONFIG_FILE" | cut -d'"' -f4 || echo "")
        fi
    else
        echo "  Project config not found. Creating it..."
        prompt_project_config
    fi

    if [[ -z "$PROJECT_DIR_NAME" ]]; then
        # Try to derive from git remote or directory name
        if git rev-parse --git-dir > /dev/null 2>&1; then
            REPO_NAME=$(basename -s .git "$(git config --get remote.origin.url 2>/dev/null || echo '')")
            if [[ -n "$REPO_NAME" ]]; then
                PROJECT_DIR_NAME="$REPO_NAME"
            fi
        fi
        
        if [[ -z "$PROJECT_DIR_NAME" ]]; then
            PROJECT_DIR_NAME=$(basename "$(pwd)")
        fi
    fi

    PROJECT_DIR="${DEFAULT_MOUNT_POINT}/${PROJECT_DIR_NAME}"
    
    # Save project config
    mkdir -p "$(dirname "$PROJECT_CONFIG_FILE")"
    cat > "$PROJECT_CONFIG_FILE" <<EOF
{
  "projectDir": "${PROJECT_DIR_NAME}"
}
EOF
    echo "  Project config saved to: $PROJECT_CONFIG_FILE"
    echo "  Project directory: ${PROJECT_DIR}"
}

# Prompt for project configuration
prompt_project_config() {
    echo ""
    echo "Project Configuration"
    echo "===================="
    echo ""
    
    # Try to suggest a name
    SUGGESTED_NAME=""
    if git rev-parse --git-dir > /dev/null 2>&1; then
        REPO_NAME=$(basename -s .git "$(git config --get remote.origin.url 2>/dev/null || echo '')")
        if [[ -n "$REPO_NAME" ]]; then
            SUGGESTED_NAME="$REPO_NAME"
        fi
    fi
    
    if [[ -z "$SUGGESTED_NAME" ]]; then
        SUGGESTED_NAME=$(basename "$(pwd)")
    fi
    
    read -p "Project directory name [${SUGGESTED_NAME}]: " input_project_dir
    PROJECT_DIR_NAME="${input_project_dir:-${SUGGESTED_NAME}}"
}
