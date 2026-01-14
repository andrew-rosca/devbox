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
        # Check if timeout settings are missing and add them
        if ! grep -A 15 "Host ${SSH_CONFIG_ENTRY}" "$SSH_CONFIG_FILE" 2>/dev/null | grep -q "ConnectTimeout"; then
            echo "  Adding timeout settings to existing SSH config entry..."
            # Append timeout settings after the existing Host block
            # Find the line number of the Host entry
            HOST_LINE=$(grep -n "Host ${SSH_CONFIG_ENTRY}" "$SSH_CONFIG_FILE" 2>/dev/null | head -1 | cut -d: -f1)
            if [ -n "$HOST_LINE" ]; then
                # Find the end of this Host block (next Host or end of file)
                NEXT_HOST_LINE=$(sed -n "$((HOST_LINE + 1)),$" "$SSH_CONFIG_FILE" 2>/dev/null | grep -n "^Host " | head -1 | cut -d: -f1)
                if [ -n "$NEXT_HOST_LINE" ]; then
                    INSERT_LINE=$((HOST_LINE + NEXT_HOST_LINE - 1))
                else
                    INSERT_LINE=$(wc -l < "$SSH_CONFIG_FILE" 2>/dev/null || echo "0")
                fi
                # Insert timeout settings before the next Host or at end
                {
                    head -n "$INSERT_LINE" "$SSH_CONFIG_FILE" 2>/dev/null
                    echo "    ConnectTimeout 180"
                    echo "    ServerAliveInterval 60"
                    echo "    ServerAliveCountMax 3"
                    echo "    TCPKeepAlive yes"
                    tail -n +$((INSERT_LINE + 1)) "$SSH_CONFIG_FILE" 2>/dev/null
                } > "${SSH_CONFIG_FILE}.tmp" && mv "${SSH_CONFIG_FILE}.tmp" "$SSH_CONFIG_FILE"
                echo "  ✓ Timeout settings added to SSH config"
            fi
        fi
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
    ConnectTimeout 180
    ServerAliveInterval 60
    ServerAliveCountMax 3
    TCPKeepAlive yes
EOF
        echo "  ✓ SSH config entry added"
    fi
    
    # Ensure devbox-connect is executable
    chmod +x "${DEVBOX_DIR}/bin/devbox-connect"
    
    echo "  SSH Host: ${SSH_CONFIG_ENTRY}"
    echo "  Connect with: ssh ${SSH_CONFIG_ENTRY}"
}
