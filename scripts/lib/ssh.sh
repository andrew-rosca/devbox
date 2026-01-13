#!/usr/bin/env bash
# SSH configuration functions

configure_ssh() {
    # Derive SSH hostname from VM name
    SSH_HOSTNAME="${VM_NAME}"
    SSH_CONFIG_FILE="${HOME}/.ssh/config"
    SSH_CONFIG_ENTRY="${VM_NAME}"
    
    # Create SSH config entry
    mkdir -p "${HOME}/.ssh"
    
    # Check if entry already exists
    if grep -q "Host ${SSH_CONFIG_ENTRY}" "$SSH_CONFIG_FILE" 2>/dev/null; then
        echo "  SSH config entry already exists: ${SSH_CONFIG_ENTRY}"
    else
        echo "  Adding SSH config entry: ${SSH_CONFIG_ENTRY}"
        
        # Find available port (starting from 2222)
        SSH_PORT=2222
        while grep -q "Port ${SSH_PORT}" "$SSH_CONFIG_FILE" 2>/dev/null; do
            SSH_PORT=$((SSH_PORT + 1))
        done
        
        cat >> "$SSH_CONFIG_FILE" <<EOF

# Devbox SSH entry (auto-generated)
Host ${SSH_CONFIG_ENTRY}
    HostName localhost
    Port ${SSH_PORT}
    User $(whoami)
    ProxyCommand ${DEVBOX_DIR}/bin/devbox-connect %h %p
    IdentityFile ~/.ssh/google_compute_engine
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
        echo "  ✓ SSH config entry added"
    fi
    
    # Ensure devbox-connect is executable
    chmod +x "${DEVBOX_DIR}/bin/devbox-connect"
    
    echo "  SSH Host: ${SSH_CONFIG_ENTRY}"
    echo "  Connect with: ssh ${SSH_CONFIG_ENTRY}"
}
