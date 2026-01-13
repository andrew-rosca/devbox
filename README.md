# Devbox

**Simple Elastic GCP Development Machine** - Work locally on your MacBook while all heavy computation runs on a powerful GCP VM.

## What is Devbox?

Devbox is a tool that creates an on-demand development environment in Google Cloud Platform. It gives you the best of both worlds:

- **Work locally** - Use VS Code or Cursor on your MacBook with a familiar, responsive UI
- **Compute in the cloud** - All heavy operations (builds, tests, Docker containers, language servers) run on a powerful GCP VM
- **Automatic management** - The VM starts when you connect and stops when you're done (saves money!)
- **Persistent storage** - All your work, caches, and Docker images survive VM restarts

### Key Features

✅ **Automatic VM lifecycle** - Starts on SSH connect, stops after idle timeout  
✅ **Persistent disk** - All data survives VM restarts  
✅ **Pre-configured** - Docker, Git, and essential tools installed automatically  
✅ **Cost-effective** - Only pay for compute when actively working  
✅ **Multi-project** - Share one VM across all your projects  
✅ **Secure** - Uses IAP (Identity-Aware Proxy) for SSH access

## Prerequisites

1. **Google Cloud Platform account** with billing enabled
2. **gcloud CLI** installed and configured
   ```bash
   # Install gcloud CLI
   # https://cloud.google.com/sdk/docs/install
   
   # Authenticate
   gcloud auth login
   
   # Set your project
   gcloud config set project YOUR_PROJECT_ID
   ```
3. **jq** (optional, but recommended for JSON parsing)
   ```bash
   brew install jq  # macOS
   ```

## Installation

1. Clone or download this repository
2. Add the `bin` directory to your PATH:
   ```bash
   # Add to ~/.zshrc or ~/.bashrc
   export PATH="$PATH:/path/to/devbox/bin"
   ```

## Quick Start

### Step 1: Install and Configure

1. **Clone this repository:**
   ```bash
   git clone <repository-url>
   cd devbox
   ```

2. **Add devbox to your PATH:**
   ```bash
   # Add to ~/.zshrc (or ~/.bashrc)
   export PATH="$PATH:$(pwd)/bin"
   
   # Reload your shell
   source ~/.zshrc
   ```

3. **Ensure prerequisites are installed:**
   - `gcloud` CLI ([install guide](https://cloud.google.com/sdk/docs/install))
   - `jq` (optional but recommended): `brew install jq`
   - Authenticated with GCP: `gcloud auth login`
   - Billing enabled on your GCP project

### Step 2: Bootstrap Your First Project

Navigate to your project directory and run:

```bash
devbox bootstrap
```

**First time setup:**
- You'll be prompted for global configuration:
  - GCP Project ID
  - VM name (default: `devbox-<username>`)
  - Machine type (default: `n1-standard-8`)
  - Region and zone (default: `us-central1-a`)
  - Disk size (default: 300GB)
  - Idle timeout (default: 10 minutes)
- Configuration is saved to `~/.devbox/config.json`
- You'll be prompted for a project directory name (saved to `.devbox/config.json`)

**What happens during bootstrap:**
1. Creates a persistent disk in GCP (if it doesn't exist)
2. Creates a VM with Ubuntu 22.04 LTS
3. Installs Docker, Git, and essential tools automatically
4. Sets up SSH configuration for seamless connection
5. Creates your project directory on the persistent disk
6. Configures idle shutdown service

**Subsequent projects:**
- Just run `devbox bootstrap` in each project directory
- The same VM and disk will be reused
- Each project gets its own directory on the shared persistent disk

### Step 3: Connect with VS Code / Cursor

1. **Open VS Code or Cursor**

2. **Install the Remote - SSH extension** (if not already installed)
   - VS Code: Search for "Remote - SSH" in Extensions
   - Cursor: Usually pre-installed

3. **Connect to your devbox:**
   - Press `Cmd+Shift+P` (Mac) or `Ctrl+Shift+P` (Windows/Linux)
   - Type "Remote-SSH: Connect to Host"
   - Select your devbox host (e.g., `devbox-1` or your configured VM name)

4. **Open your project folder:**
   - After connecting, open the folder: `/mnt/dev/<project-dir>`
   - The path is shown at the end of the bootstrap output

**The VM will automatically start when you connect!** The first connection may take 30-60 seconds while the VM boots.

### Step 4: Work Normally

Once connected, everything works as if you're working locally:
- Edit files with full IntelliSense and language support
- Run builds, tests, and Docker containers
- Use terminal commands normally
- All heavy computation happens on the GCP VM
- Your laptop stays cool and responsive

### Step 5: Disconnect

Simply close VS Code / Cursor. The VM will:
- Automatically shut down after 10 minutes of no SSH activity (configurable)
- Stop billing immediately when it shuts down
- Preserve all your work on the persistent disk

## Configuration

### Global Configuration (`~/.devbox/config.json`)

Configured once per developer, applies to all projects:

```json
{
  "vmName": "devbox-username",
  "diskName": "devbox-username-disk",
  "machineType": "n1-standard-8",
  "region": "us-central1",
  "zone": "us-central1-a",
  "diskSizeGB": 300,
  "idleTimeoutMinutes": 10
}
```

### Project Configuration (`.devbox/config.json`)

Configured per project:

```json
{
  "projectDir": "my-project"
}
```

## Commands

```bash
devbox bootstrap    # Set up devbox for current project
devbox status       # Show VM and disk status
devbox start        # Manually start the VM
devbox stop         # Manually stop the VM
devbox ssh          # Connect to VM via SSH
devbox teardown     # Delete VM and persistent disk (destructive!)
devbox help         # Show help
```

## What's Included

The VM comes pre-configured with:

- **Ubuntu 22.04 LTS** - Latest LTS release
- **Docker** - Full Docker Engine with Docker Compose
- **Git** - Version control
- **Internet access** - VM has external IP for package downloads and Docker pulls
- **Idle shutdown service** - Automatically stops the VM when not in use

All tools are installed automatically during VM creation via the startup script.

## How It Works

### Architecture

- **One VM per developer** - Shared across all your projects
- **One persistent disk per developer** - Contains all project directories
- **Automatic start/stop** - VM starts on SSH connect, stops after idle timeout
- **Persistent storage** - All work, caches, Docker images survive VM restarts
- **Internet access** - VM has external IP for outbound connections (apt, Docker Hub, etc.)

### Storage Structure

```
/mnt/dev/
  ├── project1/
  │   ├── .git/
  │   ├── src/
  │   └── ...
  ├── project2/
  │   ├── .git/
  │   ├── src/
  │   └── ...
  └── ...
```

### SSH Flow

1. VS Code/Cursor connects to your devbox hostname (e.g., `devbox-1`)
2. The `devbox-connect` wrapper intercepts the connection
3. Checks if the VM is running
4. If stopped, automatically starts the VM
5. Waits for the VM to be ready (network, SSH service)
6. Proxies the connection through IAP (Identity-Aware Proxy) to the VM
7. VS Code connects normally - you're now working on the GCP VM!

### Idle Shutdown

- A systemd service runs on the VM
- Checks every minute for active SSH sessions
- If no sessions for 10 minutes (configurable), shuts down the VM
- Billing stops automatically

## Cost Model

**Always pay:**
- Persistent disk: ~$10–$20/month (300GB)

**Pay for compute:**
- Only while VM is running
- Billed by the minute
- Example: n1-standard-8 costs ~$0.38/hour
- If you work 8 hours/day, 20 days/month: ~$60/month compute + $15 disk = ~$75/month

**Cost optimization:**
- VM automatically stops when idle
- Only pay for compute when actively working
- Persistent disk is always available

## Troubleshooting

### VM won't start

```bash
# Check status
devbox status

# Manually start
devbox start

# Check GCP console for errors
gcloud compute instances describe devbox-username --zone=us-central1-a
```

### SSH connection fails

```bash
# Test SSH directly
devbox ssh

# Check SSH config
cat ~/.ssh/config | grep devbox

# Verify VM is running
devbox status
```

### Disk full

```bash
# SSH into VM
devbox ssh

# Check disk usage
df -h /mnt/dev
du -sh /mnt/dev/*

# Clean up if needed
docker system prune -a
```

### VM not shutting down

```bash
# Check idle shutdown service
devbox ssh
sudo systemctl status devbox-idle-shutdown.service
sudo journalctl -u devbox-idle-shutdown.service

# Manually stop the VM
devbox stop
```

### Docker not installed

If Docker wasn't installed during bootstrap, check the startup log:

```bash
devbox ssh
sudo cat /var/log/devbox-startup.log
```

The startup script automatically installs Docker, but if there were network issues, you may need to recreate the VM:

```bash
devbox teardown  # Delete VM (keeps disk)
devbox bootstrap # Recreate with Docker installation
```

### Check startup script execution

```bash
devbox ssh
sudo cat /var/log/devbox-startup.log
```

This log shows what happened during VM startup, including Docker installation.

## Advanced Usage

### Multiple Projects

Each project just needs its own `.devbox/config.json` with a unique `projectDir`. The same VM is shared across all projects.

### Custom Software Installation

Edit the VM startup script in `scripts/lib/vm.sh` (the `create_startup_script` function) to install additional software.

### Change Machine Type

Edit `~/.devbox/config.json` and recreate the VM:

```bash
# Use the teardown command to delete VM (disk is preserved)
devbox teardown
# Or manually:
# gcloud compute instances delete devbox-username --zone=us-central1-a --delete-disks=boot

# Run bootstrap again (will recreate VM with new machine type)
devbox bootstrap
```

### Complete Teardown (Delete Everything)

To delete both the VM and persistent disk:

```bash
devbox teardown
# Follow the prompts to confirm deletion
```

**Warning:** This permanently deletes all data on the persistent disk!

## Project Structure

```
devbox/
├── bin/
│   ├── devbox              # Main CLI entry point
│   └── devbox-connect      # SSH ProxyCommand wrapper
├── scripts/
│   └── lib/
│       ├── config.sh       # Configuration handling
│       ├── gcp.sh          # GCP operations
│       ├── vm.sh           # VM management
│       └── ssh.sh          # SSH configuration
├── docs/
│   └── devbox-v1-design.md
└── README.md
```

## License

MIT

## Contributing

Contributions welcome! Please open an issue or pull request.
