#!/usr/bin/env bash
# GCP utility functions

validate_environment() {
    # Check if gcloud is installed
    if ! command -v gcloud &> /dev/null; then
        echo "❌ Error: gcloud CLI is not installed"
        echo "   Install it from: https://cloud.google.com/sdk/docs/install"
        return 1
    fi

    # Check if user is authenticated
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
        echo "❌ Error: No active gcloud authentication"
        echo "   Run: gcloud auth login"
        return 1
    fi

    # GCP_PROJECT should be set from config (load_global_config)
    # If not set, try to get from gcloud config as fallback
    if [[ -z "${GCP_PROJECT:-}" ]]; then
        export GCP_PROJECT=$(gcloud config get-value project 2>/dev/null)
        if [[ -z "$GCP_PROJECT" ]]; then
            echo "❌ Error: No GCP project configured"
            echo "   Run 'devbox bootstrap' to configure the project"
            return 1
        fi
    else
        export GCP_PROJECT
    fi

    # Verify project access
    if ! gcloud projects describe "$GCP_PROJECT" &>/dev/null; then
        echo "❌ Error: Cannot access project '${GCP_PROJECT}'"
        echo "   Make sure you have access to this project"
        echo "   Or update the project in ~/.devbox/config.json"
        return 1
    fi

    echo "  GCP Project: ${GCP_PROJECT}"
    
    # Check if Compute Engine API is enabled
    echo "  Checking if Compute Engine API is enabled..."
    if ! gcloud services list --enabled --project="$GCP_PROJECT" --filter="name:compute.googleapis.com" --format="value(name)" | grep -q "compute.googleapis.com"; then
        echo "  ⚠ Compute Engine API is not enabled"
        echo "  Enabling Compute Engine API (this may take a few minutes)..."
        if gcloud services enable compute.googleapis.com --project="$GCP_PROJECT"; then
            echo "  ✓ Compute Engine API enabled"
        else
            echo "  ❌ Failed to enable Compute Engine API"
            echo "  You may need to enable it manually:"
            echo "  gcloud services enable compute.googleapis.com --project=${GCP_PROJECT}"
            return 1
        fi
    else
        echo "  ✓ Compute Engine API is enabled"
    fi
    
    # Check if Identity-Aware Proxy API is enabled (required for IAP SSH)
    echo "  Checking if Identity-Aware Proxy API is enabled..."
    if ! gcloud services list --enabled --project="$GCP_PROJECT" --filter="name:iap.googleapis.com" --format="value(name)" | grep -q "iap.googleapis.com"; then
        echo "  ⚠ Identity-Aware Proxy API is not enabled"
        echo "  Enabling Identity-Aware Proxy API (this may take a few minutes)..."
        if gcloud services enable iap.googleapis.com --project="$GCP_PROJECT"; then
            echo "  ✓ Identity-Aware Proxy API enabled"
        else
            echo "  ❌ Failed to enable Identity-Aware Proxy API"
            echo "  You may need to enable it manually:"
            echo "  gcloud services enable iap.googleapis.com --project=${GCP_PROJECT}"
            return 1
        fi
    else
        echo "  ✓ Identity-Aware Proxy API is enabled"
    fi
    
    return 0
}

ensure_disk_exists() {
    # Ensure GCP_PROJECT is set
    if [[ -z "${GCP_PROJECT:-}" ]]; then
        export GCP_PROJECT=$(gcloud config get-value project 2>/dev/null)
        if [[ -z "$GCP_PROJECT" ]]; then
            echo "  ❌ Error: No GCP project selected"
            return 1
        fi
    fi
    
    # Check if disk exists
    if gcloud compute disks describe "$DISK_NAME" --zone="$ZONE" --project="$GCP_PROJECT" --format="value(name)" &>/dev/null; then
        echo "  Disk already exists: ${DISK_NAME}"
        return 0
    fi

    echo "  Creating disk: ${DISK_NAME} (${DISK_SIZE_GB}GB, ${ZONE})"
    echo "  Project: ${GCP_PROJECT}"
    echo "  This may take a minute..."
    
    # Create disk with explicit format to avoid interactive prompts
    # Don't redirect to file initially - let user see progress
    echo "  Executing: gcloud compute disks create..."
    
    if gcloud compute disks create "$DISK_NAME" \
        --size="${DISK_SIZE_GB}GB" \
        --type="$DEFAULT_DISK_TYPE" \
        --zone="$ZONE" \
        --project="$GCP_PROJECT" \
        --format="value(name)" \
        --quiet; then
        echo "  ✓ Disk created successfully"
        return 0
    else
        local exit_code=$?
        echo "  ❌ Failed to create disk (exit code: $exit_code)"
        echo "  Try running the command manually to see the error:"
        echo "  gcloud compute disks create ${DISK_NAME} --size=${DISK_SIZE_GB}GB --type=${DEFAULT_DISK_TYPE} --zone=${ZONE} --project=${GCP_PROJECT}"
        return 1
    fi
}
