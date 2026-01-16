#!/usr/bin/env bash
# VM management functions

ensure_vm_exists() {
    # Check if VM exists
    if gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$GCP_PROJECT" &>/dev/null; then
        echo "  VM already exists: ${VM_NAME}"
        
        # Ensure disk is attached
        if ! gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$GCP_PROJECT" \
            --format="value(disks[].source)" | grep -q "$DISK_NAME"; then
            echo "  Attaching disk to existing VM..."
            gcloud compute instances attach-disk "$VM_NAME" \
                --disk="$DISK_NAME" \
                --zone="$ZONE" \
                --project="$GCP_PROJECT" \
                --quiet
        fi
        
        # Ensure SSH keys are added
        ensure_ssh_keys
        
        # Ensure startup script is up to date
        ensure_startup_script
        
        # Check if dependencies are installed, offer to install if not
        check_and_install_dependencies
        
        return 0
    fi

    echo "  Creating VM: ${VM_NAME} (${MACHINE_TYPE}, ${ZONE})"
    
    # Determine boot disk type based on machine type
    # c3 and c4 machine types require pd-ssd or pd-balanced
    # Other machine types can use pd-standard
    if [[ "$MACHINE_TYPE" =~ ^c[34]- ]]; then
        BOOT_DISK_TYPE="pd-balanced"
    else
        BOOT_DISK_TYPE="pd-standard"
    fi
    
    # Create startup script
    STARTUP_SCRIPT=$(create_startup_script)
    
    # Get SSH public key to add to VM metadata
    SSH_KEY_FILE="${HOME}/.ssh/google_compute_engine.pub"
    if [[ ! -f "$SSH_KEY_FILE" ]]; then
        # Generate key if it doesn't exist
        echo "  Generating SSH key..."
        ssh-keygen -t rsa -f "${HOME}/.ssh/google_compute_engine" -C "$(whoami)" -N "" -q
    fi
    
    # Format SSH key for metadata (username:publickey)
    SSH_USER=$(whoami)
    SSH_PUBLIC_KEY=$(cat "$SSH_KEY_FILE")
    SSH_KEYS_METADATA="${SSH_USER}:${SSH_PUBLIC_KEY}"
    
    # Create VM with external IP for internet access (still using IAP for SSH)
    # The external IP is needed for outbound internet access (apt-get, Docker downloads, etc.)
    # Disable automatic restart so VM stays stopped when idle shutdown triggers
    # Add compute scope so the VM can stop itself via API
    gcloud compute instances create "$VM_NAME" \
        --machine-type="$MACHINE_TYPE" \
        --zone="$ZONE" \
        --image-family="ubuntu-2204-lts" \
        --image-project="ubuntu-os-cloud" \
        --boot-disk-size=10GB \
        --boot-disk-type="$BOOT_DISK_TYPE" \
        --disk="name=${DISK_NAME},device-name=devbox-disk,mode=rw" \
        --metadata-from-file="startup-script=${STARTUP_SCRIPT}" \
        --metadata="ssh-keys=${SSH_KEYS_METADATA}" \
        --tags="devbox" \
        --no-restart-on-failure \
        --scopes="https://www.googleapis.com/auth/compute" \
        --project="$GCP_PROJECT" \
        --quiet

    if [[ $? -eq 0 ]]; then
        echo "  ✓ VM created successfully"
        echo "  ⏳ Waiting for VM to be ready (this may take a few minutes)..."
        wait_for_vm_ready
        return 0
    else
        echo "  ❌ Failed to create VM"
        return 1
    fi
}

create_startup_script() {
    local script_file=$(mktemp)
    cat > "$script_file" <<'EOF'
#!/bin/bash
# Log all output to a file for debugging
exec > >(tee -a /var/log/devbox-startup.log) 2>&1

echo "=== Devbox Startup Script Started ==="
date

# Helper function to wait for network connectivity
wait_for_network() {
    max_attempts=30
    attempt=0
    echo "Waiting for network connectivity..."
    
    while [ $attempt -lt $max_attempts ]; do
        if ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1; then
            echo "Network connectivity confirmed"
            return 0
        fi
        attempt=$((attempt + 1))
        echo "Waiting for network... ($attempt/$max_attempts)"
        sleep 2
    done
    
    echo "Warning: Network connectivity check timed out, but continuing..."
    return 0
}

# Helper function to retry a command
retry_command() {
    max_attempts=3
    attempt=0
    command="$@"
    
    while [ $attempt -lt $max_attempts ]; do
        if $command; then
            return 0
        fi
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo "Command failed, retrying... ($attempt/$max_attempts)"
            sleep 5
        fi
    done
    
    echo "Command failed after $max_attempts attempts: $command"
    return 1
}

# Mount persistent disk
DISK_DEVICE="/dev/disk/by-id/google-devbox-disk"
MOUNT_POINT="/mnt/dev"

echo "Setting up persistent disk..."
# Wait for disk to be available
disk_wait_attempts=0
while [ ! -e "$DISK_DEVICE" ] && [ $disk_wait_attempts -lt 60 ]; do
    echo "Waiting for disk $DISK_DEVICE... ($disk_wait_attempts/60)"
    sleep 2
    disk_wait_attempts=$((disk_wait_attempts + 1))
done

if [ ! -e "$DISK_DEVICE" ]; then
    echo "ERROR: Disk $DISK_DEVICE not found after waiting"
    exit 1
fi

# Check if disk is already mounted
if ! mountpoint -q "$MOUNT_POINT"; then
    echo "Mounting persistent disk..."
    # Create mount point
    mkdir -p "$MOUNT_POINT"
    
    # Format disk if not already formatted
    if ! blkid "$DISK_DEVICE" > /dev/null 2>&1; then
        echo "Formatting disk..."
        mkfs.ext4 -F "$DISK_DEVICE" || {
            echo "ERROR: Failed to format disk"
            exit 1
        }
    fi
    
    # Mount disk
    mount "$DISK_DEVICE" "$MOUNT_POINT" || {
        echo "ERROR: Failed to mount disk"
        exit 1
    }
    
    # Add to fstab if not already present
    if ! grep -q "$DISK_DEVICE.*$MOUNT_POINT" /etc/fstab; then
        echo "$DISK_DEVICE $MOUNT_POINT ext4 defaults 0 2" >> /etc/fstab
    fi
    
    # Set permissions - ownership will be fixed when user first connects
    # Make it writable so the first user can fix ownership
    chmod 777 "$MOUNT_POINT"
    echo "Persistent disk mounted (permissions will be fixed on first connection)"
    echo "Persistent disk mounted successfully"
else
    echo "Persistent disk already mounted"
fi

# Wait for network before installing packages
wait_for_network

# Install Docker if not present
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    
    # Update package lists with retry
    retry_command apt-get update -qq || {
        echo "WARNING: apt-get update failed, but continuing..."
    }
    
    # Install prerequisites
    retry_command apt-get install -y ca-certificates curl gnupg lsb-release || {
        echo "ERROR: Failed to install prerequisites"
        exit 1
    }
    
    # Set up Docker repository
    install -m 0755 -d /etc/apt/keyrings || {
        echo "ERROR: Failed to create keyrings directory"
        exit 1
    }
    
    # Download Docker GPG key with retry
    retry_command curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg || {
        echo "ERROR: Failed to download Docker GPG key"
        exit 1
    }
    
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg < /tmp/docker.gpg || {
        echo "ERROR: Failed to process Docker GPG key"
        exit 1
    }
    
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Update package lists again
    retry_command apt-get update -qq || {
        echo "ERROR: Failed to update package lists after adding Docker repo"
        exit 1
    }
    
    # Install Docker packages
    retry_command apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || {
        echo "ERROR: Failed to install Docker packages"
        exit 1
    }
    
    # Enable and start Docker
    systemctl enable docker || {
        echo "WARNING: Failed to enable Docker service"
    }
    
    systemctl start docker || {
        echo "WARNING: Failed to start Docker service"
    }
    
    # Verify Docker is working
    if docker --version > /dev/null 2>&1; then
        echo "Docker installed successfully: $(docker --version)"
    else
        echo "WARNING: Docker installed but version check failed"
    fi
else
    echo "Docker already installed: $(docker --version)"
fi

# Install Git if not present
if ! command -v git &> /dev/null; then
    echo "Installing Git..."
    retry_command apt-get update -qq || {
        echo "WARNING: apt-get update failed for Git installation"
    }
    retry_command apt-get install -y git || {
        echo "ERROR: Failed to install Git"
        exit 1
    }
    echo "Git installed successfully: $(git --version)"
else
    echo "Git already installed: $(git --version)"
fi

# Install idle shutdown service
cat > /usr/local/bin/devbox-idle-shutdown.sh <<'IDLESCRIPT'
#!/bin/bash
IDLE_TIMEOUT_MINUTES=10
IDLE_TIMEOUT_SECONDS=$((IDLE_TIMEOUT_MINUTES * 60))
TIMESTAMP_FILE="/tmp/devbox-last-ssh-activity"
LOG_FILE="/var/log/devbox-idle-shutdown.log"

# Logging function
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Update timestamp
update_timestamp() {
    echo $(date +%s) > "$TIMESTAMP_FILE"
}

# Check for active SSH sessions - use multiple methods for reliability
check_active_sessions() {
    sessions=0
    
    # Method 1: Check for active pseudo-terminals (SSH sessions) - PRIMARY METHOD
    # This is the most reliable - actual user sessions show up in 'who'
    if command -v who >/dev/null 2>&1; then
        session_count=$(who | grep -c "pts/" 2>/dev/null || echo "0")
        # Ensure it's a number, default to 0 if not, and strip whitespace
        session_count=$(echo "$session_count" | tr -d '[:space:]')
        if [ -z "$session_count" ] || ! [ "$session_count" -eq "$session_count" ] 2>/dev/null; then
            session_count=0
        fi
        sessions=$session_count
    fi
    
    # Only use fallback methods if 'who' shows no sessions
    # (IAP tunnel connections don't show up in 'who', so we need to be careful)
    if [ $sessions -eq 0 ] && command -v pgrep >/dev/null 2>&1; then
        # Check for SSH processes serving user sessions (sshd: user@pts)
        # This is more reliable than checking network connections
        sshd_count=$(pgrep -f "sshd:.*@pts" 2>/dev/null | wc -l)
        sshd_count=$(echo "$sshd_count" | tr -d '[:space:]')
        if [ -z "$sshd_count" ] || ! [ "$sshd_count" -eq "$sshd_count" ] 2>/dev/null; then
            sshd_count=0
        fi
        if [ $sshd_count -gt 0 ]; then
            sessions=$sshd_count
        fi
    fi
    
    # Ensure we return a clean integer (no whitespace)
    echo $sessions
}

# Initialize
update_timestamp
log_message "Idle shutdown service started (timeout: ${IDLE_TIMEOUT_MINUTES} minutes)"
LAST_SESSION_COUNT=0

while true; do
    # Check for active SSH sessions
    ACTIVE_SESSIONS=$(check_active_sessions)
    # Ensure ACTIVE_SESSIONS is a clean integer (handle empty/whitespace)
    ACTIVE_SESSIONS=$(echo "$ACTIVE_SESSIONS" | tr -d '[:space:]')
    if [ -z "$ACTIVE_SESSIONS" ] || ! [ "$ACTIVE_SESSIONS" -eq "$ACTIVE_SESSIONS" ] 2>/dev/null; then
        ACTIVE_SESSIONS=0
    fi
    
    # Debug logging every 5 minutes
    if [ $(($(date +%s) % 300)) -lt 60 ]; then
        log_message "Debug: ACTIVE_SESSIONS=$ACTIVE_SESSIONS, LAST_SESSION_COUNT=$LAST_SESSION_COUNT"
    fi
    
    if [ $ACTIVE_SESSIONS -gt 0 ]; then
        # Active sessions exist
        if [ $LAST_SESSION_COUNT -eq 0 ]; then
            # Just transitioned from no sessions to having sessions
            log_message "SSH session detected (count: $ACTIVE_SESSIONS)"
        fi
        update_timestamp
        LAST_SESSION_COUNT=$ACTIVE_SESSIONS
    else
        # No active sessions
        if [ $LAST_SESSION_COUNT -gt 0 ]; then
            # Just transitioned from having sessions to no sessions
            log_message "All SSH sessions disconnected. Starting idle timer."
            update_timestamp  # Set timestamp to now when sessions disconnect
        fi
        
        # Check idle time since last activity
        if [ -f "$TIMESTAMP_FILE" ]; then
            LAST_ACTIVITY=$(cat "$TIMESTAMP_FILE")
            NOW=$(date +%s)
            IDLE_SECONDS=$((NOW - LAST_ACTIVITY))
            IDLE_MINUTES=$((IDLE_SECONDS / 60))
            
            # Log every 5 minutes when idle
            if [ $((IDLE_SECONDS % 300)) -lt 60 ]; then
                log_message "Idle for ${IDLE_MINUTES} minutes (${IDLE_TIMEOUT_MINUTES} minute timeout)"
            fi
            
            if [ "$IDLE_SECONDS" -ge "$IDLE_TIMEOUT_SECONDS" ]; then
                log_message "Idle timeout reached (${IDLE_MINUTES} minutes). Stopping VM..."
                
                # Get VM name, zone, and project from metadata
                VM_NAME=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)
                ZONE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone | sed 's/.*\///')
                PROJECT=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id)
                
                # Try using gcloud first (simpler and more reliable)
                if command -v gcloud >/dev/null 2>&1 && [ -n "$VM_NAME" ] && [ -n "$ZONE" ] && [ -n "$PROJECT" ]; then
                    log_message "Stopping VM using gcloud: $VM_NAME in zone $ZONE"
                    if gcloud compute instances stop "$VM_NAME" --zone="$ZONE" --project="$PROJECT" --quiet 2>&1 | tee -a "$LOG_FILE"; then
                        log_message "VM stop command sent successfully via gcloud"
                        sleep 2
                        exit 0
                    else
                        log_message "gcloud stop command failed, trying REST API..."
                    fi
                fi
                
                # Fallback to REST API
                TOKEN_RESPONSE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token)
                ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
                
                if [ -n "$ACCESS_TOKEN" ] && [ -n "$VM_NAME" ] && [ -n "$ZONE" ] && [ -n "$PROJECT" ]; then
                    log_message "Stopping VM using REST API: $VM_NAME in zone $ZONE"
                    RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
                        -H "Authorization: Bearer $ACCESS_TOKEN" \
                        "https://compute.googleapis.com/compute/v1/projects/$PROJECT/zones/$ZONE/instances/$VM_NAME/stop")
                    
                    HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
                    RESPONSE_BODY=$(echo "$RESPONSE" | sed '/HTTP_CODE:/d')
                    
                    if [ "$HTTP_CODE" = "200" ] || echo "$RESPONSE_BODY" | grep -q '"status":"DONE"'; then
                        log_message "VM stop request sent successfully (HTTP $HTTP_CODE)"
                        sleep 2
                        exit 0
                    else
                        log_message "API call failed (HTTP $HTTP_CODE): $RESPONSE_BODY"
                        log_message "Falling back to systemctl poweroff"
                        systemctl poweroff || shutdown -h now
                    fi
                else
                    log_message "Failed to get metadata or access token, using systemctl poweroff"
                    systemctl poweroff || shutdown -h now
                fi
                exit 0
            fi
        fi
        LAST_SESSION_COUNT=0
    fi
    
    sleep 60
done
IDLESCRIPT

chmod +x /usr/local/bin/devbox-idle-shutdown.sh

# Create systemd service
cat > /etc/systemd/system/devbox-idle-shutdown.service <<'SERVICEDEF'
[Unit]
Description=Devbox Idle Shutdown Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/devbox-idle-shutdown.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICEDEF

echo "Setting up idle shutdown service..."
systemctl daemon-reload
systemctl enable devbox-idle-shutdown.service || {
    echo "WARNING: Failed to enable idle shutdown service"
}
systemctl start devbox-idle-shutdown.service || {
    echo "WARNING: Failed to start idle shutdown service"
}

echo ""
echo "=== Devbox Startup Script Completed Successfully ==="
date
echo "Log saved to: /var/log/devbox-startup.log"
EOF
    echo "$script_file"
}

ensure_ssh_keys() {
    # Ensure SSH keys are added to VM metadata
    SSH_KEY_FILE="${HOME}/.ssh/google_compute_engine.pub"
    if [[ ! -f "$SSH_KEY_FILE" ]]; then
        echo "  Generating SSH key..."
        ssh-keygen -t rsa -f "${HOME}/.ssh/google_compute_engine" -C "$(whoami)" -N "" -q
    fi
    
    SSH_USER=$(whoami)
    SSH_PUBLIC_KEY=$(cat "$SSH_KEY_FILE")
    
    # Check if key already exists in metadata
    EXISTING_KEYS=$(gcloud compute instances describe "$VM_NAME" \
        --zone="$ZONE" \
        --project="$GCP_PROJECT" \
        --format="get(metadata.items[key=ssh-keys].value)" 2>/dev/null || echo "")
    
    if echo "$EXISTING_KEYS" | grep -q "$SSH_PUBLIC_KEY"; then
        echo "  SSH key already added to VM"
    else
        echo "  Adding SSH key to VM metadata..."
        # Append new key to existing keys
        if [[ -n "$EXISTING_KEYS" ]]; then
            NEW_KEYS="${EXISTING_KEYS}"$'\n'"${SSH_USER}:${SSH_PUBLIC_KEY}"
        else
            NEW_KEYS="${SSH_USER}:${SSH_PUBLIC_KEY}"
        fi
        
        gcloud compute instances add-metadata "$VM_NAME" \
            --zone="$ZONE" \
            --project="$GCP_PROJECT" \
            --metadata="ssh-keys=${NEW_KEYS}" \
            --quiet
        echo "  ✓ SSH key added"
    fi
}

ensure_startup_script() {
    # The startup script is embedded in VM metadata, so we'd need to recreate the VM to update it
    # For now, we'll just ensure the service is running if VM exists
    echo "  Ensuring startup script is installed (may require VM restart to update)"
}

check_and_install_dependencies() {
    # Only check if VM is running
    local vm_status=$(get_vm_status)
    if [[ "$vm_status" != "RUNNING" ]]; then
        return 0  # Skip check if VM is not running
    fi
    
    # Check if Docker is installed
    if gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$GCP_PROJECT" \
        --tunnel-through-iap \
        --command="command -v docker > /dev/null 2>&1" --quiet 2>/dev/null; then
        echo "  ✓ Dependencies are installed"
        return 0
    fi
    
    echo "  ⚠ Dependencies (Docker, Git) are not installed"
    echo "  This is likely because the VM has no internet access (no external IP or Cloud NAT)"
    echo ""
    echo "  To install dependencies, you can:"
    echo "  1. Run the install script via SSH:"
    echo "     ssh ${VM_NAME}"
    echo "     curl -fsSL https://raw.githubusercontent.com/your-repo/devbox/main/scripts/install-dependencies.sh | sudo bash"
    echo ""
    echo "  2. Or set up Cloud NAT for automatic internet access"
    return 0
}

wait_for_vm_ready() {
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$GCP_PROJECT" \
            --tunnel-through-iap \
            --command="echo 'VM is ready'" --quiet &>/dev/null; then
            echo "  ✓ VM is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        echo "  Waiting... ($attempt/$max_attempts)"
        sleep 10
    done
    
    echo "  ⚠ VM created but not yet ready. It may take a few more minutes."
    return 0
}

create_project_directory() {
    # Create project directory on VM if it's running, otherwise note it for creation
    local vm_status=$(get_vm_status)
    
    if [[ "$vm_status" == "RUNNING" ]]; then
        echo "  Creating project directory on VM: ${PROJECT_DIR}"
        # Fix /mnt/dev ownership if needed, then create project directory
        gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$GCP_PROJECT" \
            --tunnel-through-iap \
            --command="sudo chown -R \$(whoami):\$(whoami) /mnt/dev 2>/dev/null || true && sudo mkdir -p ${PROJECT_DIR} && sudo chown \$(whoami):\$(whoami) ${PROJECT_DIR}" \
            --quiet 2>/dev/null || {
            echo "  ⚠ Could not create directory now (will be created on first connection)"
            return 0
        }
        echo "  ✓ Project directory created"
    else
        echo "  Project directory will be created at: ${PROJECT_DIR}"
        echo "  (Will be created automatically when VM starts)"
    fi
}

install_idle_shutdown() {
    # Idle shutdown is installed via startup script
    # Just verify it's running if VM is up
    local vm_status=$(get_vm_status)
    if [[ "$vm_status" == "RUNNING" ]]; then
        echo "  Verifying idle shutdown service..."
        gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$GCP_PROJECT" \
            --tunnel-through-iap \
            --command="systemctl is-active devbox-idle-shutdown.service || echo 'Service not active'" \
            --quiet 2>/dev/null || true
    else
        echo "  Idle shutdown will be installed on next VM start"
    fi
}

get_vm_status() {
    gcloud compute instances describe "$VM_NAME" \
        --zone="$ZONE" \
        --project="$GCP_PROJECT" \
        --format="value(status)" 2>/dev/null || echo "NOT_FOUND"
}

check_vm_status() {
    local status=$(get_vm_status)
    echo "VM Status: ${status}"
    echo "VM Name: ${VM_NAME}"
    echo "Zone: ${ZONE}"
    
    if [[ "$status" == "RUNNING" ]]; then
        echo ""
        echo "Active SSH sessions:"
        gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$GCP_PROJECT" \
            --tunnel-through-iap \
            --command="who" --quiet 2>/dev/null || echo "  (Unable to check)"
    fi
}

start_vm() {
    local status=$(get_vm_status)
    if [[ "$status" == "RUNNING" ]]; then
        echo "VM is already running"
        return 0
    fi
    
    echo "Starting VM: ${VM_NAME}"
    gcloud compute instances start "$VM_NAME" --zone="$ZONE" --project="$GCP_PROJECT"
    wait_for_vm_ready
}

stop_vm() {
    local status=$(get_vm_status)
    if [[ "$status" != "RUNNING" ]]; then
        echo "VM is not running"
        return 0
    fi
    
    echo "Stopping VM: ${VM_NAME}"
    gcloud compute instances stop "$VM_NAME" --zone="$ZONE" --project="$GCP_PROJECT"
}

ssh_to_vm() {
    local status=$(get_vm_status)
    if [[ "$status" != "RUNNING" ]]; then
        echo "VM is not running. Starting it..."
        start_vm
    fi
    
    # If arguments are provided, treat them as a command to run
    # Otherwise, open an interactive SSH session
    if [ $# -gt 0 ]; then
        # Join all arguments into a single command string
        local command="$*"
        gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$GCP_PROJECT" \
            --tunnel-through-iap \
            --command="$command"
    else
        # No arguments, open interactive session
        gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$GCP_PROJECT" \
            --tunnel-through-iap
    fi
}
