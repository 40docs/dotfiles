#!/usr/bin/env bash
#
# Dotfiles Installation Script
# This script installs and configures various development tools and dotfiles
# Supports both manual execution and cloud-init automation
#
# Usage:
#   Manual: ./install.sh [--user username]
#   Cloud-init: ./install.sh --cloud-init [--user username]
#
# Environment variables:
#   DOTFILES_USER - Target user for installation (overrides --user)
#   DOTFILES_HOME - Target home directory (auto-detected if not set)
#   DEBUG - Enable debug mode (set to 1)
#   CI - Indicates running in CI/automation environment
#
# Exit codes:
#   0 - Success
#   1 - General error
#   2 - Network error
#   3 - File system error
#   4 - Permission error

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Enable debug mode if DEBUG environment variable is set
if [[ "${DEBUG:-}" == "1" ]]; then
    set -x
fi

# Global variables for execution context
CLOUD_INIT_MODE=false
TARGET_USER=""
TARGET_HOME=""
SCRIPT_USER=""

## --- EXECUTION CONTEXT DETECTION ---

# Detect execution context and set variables
detect_execution_context() {
    SCRIPT_USER="$(whoami)"

    # Don't automatically set CLOUD_INIT_MODE when running as root
    # Let the command line arguments or environment variables determine this
    if [[ "$EUID" -eq 0 ]]; then
        log "INFO" "Running as root user"
    fi

    # Check for CI/automation indicators
    if [[ "${CI:-}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -n "${GITLAB_CI:-}" ]]; then
        log "INFO" "CI/automation environment detected"
        CLOUD_INIT_MODE=true
    fi
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cloud-init)
                CLOUD_INIT_MODE=true
                shift
                ;;
            --user)
                TARGET_USER="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Show help message
show_help() {
    cat << EOF
Dotfiles Installation Script

Usage:
    $0 [options]

Options:
    --cloud-init        Run in cloud-init mode (for automation)
    --user USERNAME     Target user for installation
    --help, -h          Show this help message

Environment Variables:
    DOTFILES_USER       Target user (overrides --user)
    DOTFILES_HOME       Target home directory
    DEBUG=1             Enable debug mode
    CI=true             Indicates CI/automation environment

Examples:
    # Manual installation for current user
    ./install.sh

    # Cloud-init installation for specific user
    ./install.sh --cloud-init --user ubuntu

    # Installation via sudo for another user
    sudo DOTFILES_USER=myuser ./install.sh
EOF
}

# Determine target user and home directory
setup_target_user() {
    # Priority: DOTFILES_USER env var > --user argument > current context
    if [[ -n "${DOTFILES_USER:-}" ]]; then
        TARGET_USER="$DOTFILES_USER"
    elif [[ -z "$TARGET_USER" ]]; then
        # When running as root without cloud-init mode or explicit user specification,
        # install for root itself rather than trying to find another user
        if [[ "$EUID" -eq 0 && "$CLOUD_INIT_MODE" == "false" ]]; then
            TARGET_USER="root"
            log "INFO" "Running as root without --user or --cloud-init, installing for root user"
        elif [[ "$CLOUD_INIT_MODE" == "true" && "$EUID" -eq 0 ]]; then
            # In cloud-init as root, try to detect the main user
            if [[ -n "${SUDO_USER:-}" ]]; then
                TARGET_USER="$SUDO_USER"
            else
                # Try to find the first non-system user (UID >= 1000 on Linux, >= 500 on macOS)
                local min_uid
                if [[ "$(uname)" == "Darwin" ]]; then
                    min_uid=500
                else
                    min_uid=1000
                fi

                TARGET_USER="$(get_user_by_uid "$min_uid")"
                if [[ -z "$TARGET_USER" ]]; then
                    log "ERROR" "Cannot determine target user. Use --user or set DOTFILES_USER"
                    exit 1
                fi
            fi
        else
            TARGET_USER="$SCRIPT_USER"
        fi
    fi

    # Validate target user exists
    if ! user_exists "$TARGET_USER"; then
        log "ERROR" "User '$TARGET_USER' does not exist"
        exit 1
    fi

    # Set target home directory
    if [[ -n "${DOTFILES_HOME:-}" ]]; then
        TARGET_HOME="$DOTFILES_HOME"
    else
        # Special handling for root user
        if [[ "$TARGET_USER" == "root" ]]; then
            # For root user, explicitly use /root instead of relying on get_user_home
            # which might return incorrect values in some environments
            TARGET_HOME="/root"
        else
            TARGET_HOME="$(get_user_home "$TARGET_USER")"
        fi
    fi

    # Validate home directory exists or try to create it
    if [[ ! -d "$TARGET_HOME" ]]; then
        log "WARN" "Home directory '$TARGET_HOME' does not exist, attempting to create it"
        # Try to create the home directory if running as root
        if [[ "$EUID" -eq 0 ]]; then
            mkdir -p "$TARGET_HOME" || {
                log "ERROR" "Failed to create home directory '$TARGET_HOME'"
                exit 1
            }
            # Set proper ownership for the home directory
            chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$TARGET_HOME"
            chmod 755 "$TARGET_HOME"
            log "INFO" "Created home directory: $TARGET_HOME"
        else
            log "ERROR" "Home directory '$TARGET_HOME' does not exist and cannot create it without root privileges"
            exit 1
        fi
    fi

    log "INFO" "Target user: $TARGET_USER"
    log "INFO" "Target home: $TARGET_HOME"
    log "INFO" "Script user: $SCRIPT_USER"
    log "INFO" "Cloud-init mode: $CLOUD_INIT_MODE"
}

## --- ENVIRONMENT FIX FOR CLOUD-INIT ---

# Logging function with timestamp
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] [dotfiles install.sh] $*" >&2
}

# Debug logging for troubleshooting
debug_log() {
    if [[ "${DEBUG:-}" == "1" ]]; then
        log "DEBUG" "$*"
    fi
}

# Log environment state for troubleshooting
log_environment_state() {
    local context="$1"
    debug_log "=== Environment State ($context) ==="
    debug_log "TARGET_USER: $TARGET_USER"
    debug_log "TARGET_HOME: $TARGET_HOME"
    debug_log "SCRIPT_USER: $SCRIPT_USER"
    debug_log "CLOUD_INIT_MODE: $CLOUD_INIT_MODE"
    debug_log "PWD: $(pwd)"
    debug_log "HOME: $HOME"
    debug_log "Git available: $(command_exists git && echo 'yes' || echo 'no')"
    if command_exists git; then
        debug_log "Git version: $(git --version 2>/dev/null || echo 'unknown')"
    fi
    debug_log "Network tools: curl=$(command_exists curl && echo 'yes' || echo 'no'), wget=$(command_exists wget && echo 'yes' || echo 'no')"
    debug_log "Target home exists: $([[ -d "$TARGET_HOME" ]] && echo 'yes' || echo 'no')"
    debug_log "============================="
}

# Error handling function
handle_error() {
    local exit_code=$?
    local line_number=$1
    log "ERROR" "Script failed at line $line_number with exit code $exit_code"
    exit $exit_code
}

# Set proper ownership helper function
set_ownership() {
    local path="$1"
    local recursive="${2:-false}"
    
    if [[ "$EUID" -eq 0 ]] && [[ "$SCRIPT_USER" != "$TARGET_USER" ]]; then
        if [[ "$recursive" == "true" ]]; then
            chown -R "$TARGET_USER:$(id -gn "$TARGET_USER")" "$path"
        else
            chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$path"
        fi
    fi
}

# Add or update line in shell configuration file
add_to_shell_config() {
    local config_file="$1"
    local line_to_add="$2"
    local search_pattern="$3"
    local description="$4"
    
    if [[ -f "$config_file" ]]; then
        if ! grep -q "$search_pattern" "$config_file"; then
            log "INFO" "Adding $description to $(basename "$config_file")"
            echo "$line_to_add" >> "$config_file"
            set_ownership "$config_file"
        else
            log "INFO" "$description already exists in $(basename "$config_file")"
        fi
    else
        log "WARN" "$(basename "$config_file") not found, skipping $description setup"
    fi
}

# Download file with retry and proper ownership
download_file() {
    local url="$1"
    local output="$2"
    local description="${3:-file}"
    
    log "INFO" "Downloading $description from $url"
    retry_network_operation curl -fsSL "$url" -o "$output"
    set_ownership "$output"
}

# Validate environment before plugin installation
validate_plugin_environment() {
    local component_name="$1"
    local requirements=("${@:2}")
    
    log "INFO" "Validating environment for $component_name installation..."
    
    # Check basic requirements
    if [[ ! -d "$TARGET_HOME" ]]; then
        log "ERROR" "Target home directory does not exist: $TARGET_HOME"
        return 1
    fi
    
    # Check if git is available
    if ! command_exists git; then
        log "ERROR" "Git is required for $component_name but is not available"
        log "INFO" "Please install git and re-run the script"
        return 1
    fi
    
    # Check network connectivity for remote repositories
    if ! check_github_connectivity; then
        log "ERROR" "Network connectivity is required for $component_name but GitHub is not accessible"
        if [[ "$CLOUD_INIT_MODE" == "true" ]]; then
            log "INFO" "In cloud-init mode: Waiting 10 seconds for network to stabilize..."
            sleep 10
            if ! check_github_connectivity; then
                log "ERROR" "Network connectivity still unavailable after wait"
                return 1
            fi
            log "INFO" "Network connectivity restored"
        else
            return 1
        fi
    fi
    
    # Check specific requirements
    for requirement in "${requirements[@]}"; do
        case "$requirement" in
            "bash4+")
                if (( BASH_VERSINFO[0] < 4 )); then
                    log "ERROR" "$component_name requires Bash 4+ but found version ${BASH_VERSION}"
                    log "INFO" "Please upgrade Bash (e.g., 'brew install bash' on macOS)"
                    return 1
                fi
                ;;
            "oh-my-zsh")
                if [[ ! -d "$TARGET_HOME/.oh-my-zsh" ]]; then
                    log "ERROR" "$component_name requires Oh My Zsh but it's not installed"
                    return 1
                fi
                ;;
            *)
                if ! command_exists "$requirement"; then
                    log "ERROR" "$component_name requires '$requirement' but it's not available"
                    return 1
                fi
                ;;
        esac
    done
    
    log "INFO" "Environment validation passed for $component_name"
    return 0
}

# Verify plugin installation by checking for expected content
verify_plugin_installation() {
    local plugin_dir="$1"
    local plugin_name="$2"
    
    # Basic checks that should apply to all git repositories
    if [[ ! -d "$plugin_dir" ]]; then
        log "ERROR" "Plugin directory does not exist: $plugin_dir"
        return 1
    fi
    
    if [[ ! -d "$plugin_dir/.git" ]]; then
        log "ERROR" "Plugin directory is not a git repository: $plugin_dir"
        return 1
    fi
    
    # Check that the directory is not empty (except for .git)
    local content_count
    content_count=$(find "$plugin_dir" -mindepth 1 -maxdepth 1 ! -name '.git' | wc -l)
    if [[ $content_count -eq 0 ]]; then
        log "ERROR" "Plugin directory contains no content (except .git): $plugin_dir"
        return 1
    fi
    
    # Plugin-specific verification
    case "$plugin_name" in
        "tpm")
            if [[ ! -f "$plugin_dir/tpm" ]]; then
                log "ERROR" "TPM script not found in: $plugin_dir"
                return 1
            fi
            ;;
        "vim-airline")
            if [[ ! -d "$plugin_dir/autoload" ]]; then
                log "ERROR" "vim-airline autoload directory not found in: $plugin_dir"
                return 1
            fi
            ;;
        "nerdtree")
            if [[ ! -f "$plugin_dir/plugin/NERD_tree.vim" ]]; then
                log "ERROR" "NERDTree plugin file not found in: $plugin_dir"
                return 1
            fi
            ;;
        "zsh-autosuggestions")
            if [[ ! -f "$plugin_dir/zsh-autosuggestions.zsh" ]]; then
                log "ERROR" "zsh-autosuggestions main file not found in: $plugin_dir"
                return 1
            fi
            ;;
        "zsh-syntax-highlighting")
            if [[ ! -f "$plugin_dir/zsh-syntax-highlighting.zsh" ]]; then
                log "ERROR" "zsh-syntax-highlighting main file not found in: $plugin_dir"
                return 1
            fi
            ;;
        *)
            # For unknown plugins, just check for common indicators
            # Look for typical plugin files
            if [[ ! -f "$plugin_dir/README.md" ]] && [[ ! -f "$plugin_dir/README" ]] && \
               [[ ! -d "$plugin_dir/plugin" ]] && [[ ! -d "$plugin_dir/autoload" ]] && \
               [[ ! -f "$plugin_dir/"*.vim ]] && [[ ! -f "$plugin_dir/"*.zsh ]] && \
               [[ ! -f "$plugin_dir/"*.sh ]]; then
                log "WARN" "Plugin may be incomplete - no common plugin files found in: $plugin_dir"
                # Don't fail for unknown plugins, just warn
            fi
            ;;
    esac
    
    log "DEBUG" "Plugin verification passed for: $plugin_name at $plugin_dir"
    return 0
}

# Install plugin collection from associative array with comprehensive error handling
install_plugin_collection() {
    local array_name="$1"
    local base_dir="$2"
    local description="$3"
    
    log "INFO" "Installing $description..."
    
    # Ensure base directory exists before starting
    if ! safe_mkdir_user "$base_dir"; then
        log "ERROR" "Failed to create base directory for $description: $base_dir"
        return 1
    fi
    
    local success_count=0
    local failure_count=0
    local total_plugins=0
    
    # Check if we can use nameref (bash 4.3+)
    if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
        # Use nameref for bash 4.3+
        local -n plugin_array=$array_name
        total_plugins=${#plugin_array[@]}
        
        if [[ $total_plugins -eq 0 ]]; then
            log "WARN" "No plugins found in $array_name array"
            return 0
        fi
        
        log "INFO" "Found $total_plugins plugins to install for $description"
        
        for plugin in "${!plugin_array[@]}"; do
            local plugin_dir="$base_dir/$plugin"
            local plugin_url="${plugin_array[$plugin]}"
            local clone_args=""
            
            # Special handling for plugins that need shallow clone
            if [[ "$plugin" == "vim-polyglot" ]]; then
                clone_args="--depth 1"
            fi
            
            log "INFO" "Installing plugin: $plugin from $plugin_url"
            
            if git_clone_or_update_user "$plugin_url" "$plugin_dir" "$clone_args"; then
                # Verify the installation by checking for content
                if verify_plugin_installation "$plugin_dir" "$plugin"; then
                    log "INFO" "Successfully installed and verified plugin: $plugin"
                    ((success_count++))
                else
                    log "ERROR" "Plugin installation verification failed: $plugin"
                    ((failure_count++))
                fi
            else
                log "ERROR" "Failed to clone plugin: $plugin from $plugin_url"
                ((failure_count++))
            fi
        done
    else
        # Enhanced fallback for older bash versions
        log "WARN" "Bash version ${BASH_VERSION} detected. Using enhanced eval fallback for associative arrays."
        
        # Safer eval approach with validation
        local plugin_keys
        if ! plugin_keys=$(eval "echo \"\${!${array_name}[@]}\"" 2>/dev/null); then
            log "ERROR" "Failed to extract keys from associative array $array_name"
            return 1
        fi
        
        if [[ -z "$plugin_keys" ]]; then
            log "WARN" "No plugin keys found in $array_name array"
            return 0
        fi
        
        # Count plugins for logging
        total_plugins=$(echo "$plugin_keys" | wc -w)
        log "INFO" "Found $total_plugins plugins to install for $description (using eval fallback)"
        
        for plugin in $plugin_keys; do
            local plugin_dir="$base_dir/$plugin"
            local plugin_url
            
            # Safer eval with validation
            if ! plugin_url=$(eval "echo \"\${${array_name}[$plugin]}\"" 2>/dev/null); then
                log "ERROR" "Failed to get URL for plugin: $plugin"
                ((failure_count++))
                continue
            fi
            
            if [[ -z "$plugin_url" ]]; then
                log "ERROR" "Empty URL for plugin: $plugin"
                ((failure_count++))
                continue
            fi
            
            local clone_args=""
            # Special handling for plugins that need shallow clone
            if [[ "$plugin" == "vim-polyglot" ]]; then
                clone_args="--depth 1"
            fi
            
            log "INFO" "Installing plugin: $plugin from $plugin_url"
            
            if git_clone_or_update_user "$plugin_url" "$plugin_dir" "$clone_args"; then
                # Verify the installation by checking for content
                if verify_plugin_installation "$plugin_dir" "$plugin"; then
                    log "INFO" "Successfully installed and verified plugin: $plugin"
                    ((success_count++))
                else
                    log "ERROR" "Plugin installation verification failed: $plugin"
                    ((failure_count++))
                fi
            else
                log "ERROR" "Failed to clone plugin: $plugin from $plugin_url"
                ((failure_count++))
            fi
        done
    fi
    
    # Report installation results
    log "INFO" "$description installation completed: $success_count successful, $failure_count failed out of $total_plugins total"
    
    if [[ $failure_count -gt 0 ]]; then
        log "WARN" "Some $description failed to install. Check the logs above for details."
        if [[ $success_count -eq 0 ]]; then
            log "ERROR" "All $description failed to install"
            return 1
        fi
    fi
    
    return 0
}

# Find Claude binary across different installation methods
find_claude_binary() {
    local claude_path=""
    
    # Common locations to check for Claude binary
    local possible_paths=(
        "/opt/homebrew/bin/claude"          # Homebrew on Apple Silicon Mac
        "/usr/local/bin/claude"             # Homebrew on Intel Mac or manual install
        "$HOME/.local/bin/claude"           # Local user installation
        "$TARGET_HOME/.local/bin/claude"    # Target user local installation
        "/usr/bin/claude"                   # System-wide installation
        "/bin/claude"                       # System binary directory
    )
    
    # Check versioned installation directories
    local version_dirs=(
        "$HOME/.local/share/claude/versions"
        "$TARGET_HOME/.local/share/claude/versions"
        "$HOME/.claude/versions"
        "$TARGET_HOME/.claude/versions"
    )
    
    # First check common direct paths
    for path in "${possible_paths[@]}"; do
        if [[ -L "$path" ]]; then
            # Handle symlinks - check if target exists
            if [[ -f "$path" && -x "$path" ]]; then
                claude_path="$path"
                log "INFO" "Found Claude binary at: $claude_path (symlink)"
                echo "$claude_path"
                return 0
            else
                log "WARN" "Found broken Claude symlink at: $path - removing"
                rm -f "$path" 2>/dev/null || true
            fi
        elif [[ -f "$path" && -x "$path" ]]; then
            claude_path="$path"
            log "INFO" "Found Claude binary at: $claude_path"
            echo "$claude_path"
            return 0
        fi
    done
    
    # Check versioned installations
    for version_dir in "${version_dirs[@]}"; do
        if [[ -d "$version_dir" ]]; then
            # Find the most recent version directory
            local latest_version
            latest_version=$(find "$version_dir" -mindepth 1 -maxdepth 1 -type d -name "v*" | sort -V | tail -1)
            if [[ -n "$latest_version" && -f "$latest_version/claude" && -x "$latest_version/claude" ]]; then
                claude_path="$latest_version/claude"
                log "INFO" "Found Claude binary at: $claude_path"
                echo "$claude_path"
                return 0
            fi
            
            # Also check for binaries directly in version subdirectories
            local claude_in_version
            claude_in_version=$(find "$version_dir" -name "claude" -type f -executable | head -1)
            if [[ -n "$claude_in_version" ]]; then
                claude_path="$claude_in_version"
                log "INFO" "Found Claude binary at: $claude_path"
                echo "$claude_path"
                return 0
            fi
        fi
    done
    
    # Check if claude is in PATH
    if command_exists claude; then
        claude_path=$(command -v claude)
        log "INFO" "Found Claude binary in PATH: $claude_path"
        echo "$claude_path"
        return 0
    fi
    
    log "WARN" "Claude binary not found in any expected locations"
    return 1
}

# Find GitHub CLI binary across different installation methods
find_gh_binary() {
    local gh_path=""
    
    # Common locations to check for gh binary
    local possible_paths=(
        "/opt/homebrew/bin/gh"          # Homebrew on Apple Silicon Mac
        "/usr/local/bin/gh"             # Homebrew on Intel Mac or manual install
        "/usr/bin/gh"                   # System package manager install (Linux)
        "/bin/gh"                       # System binary directory
        "$HOME/.local/bin/gh"           # Local user installation
        "$TARGET_HOME/.local/bin/gh"    # Target user local installation
    )
    
    # Check common direct paths first
    for path in "${possible_paths[@]}"; do
        if [[ -f "$path" && -x "$path" ]]; then
            gh_path="$path"
            log "INFO" "Found GitHub CLI binary at: $gh_path"
            echo "$gh_path"
            return 0
        fi
    done
    
    # Check if gh is in PATH
    if command_exists gh; then
        gh_path=$(command -v gh)
        log "INFO" "Found GitHub CLI binary in PATH: $gh_path"
        echo "$gh_path"
        return 0
    fi
    
    log "WARN" "GitHub CLI binary not found in any expected locations"
    return 1
}

# Update .gitconfig with dynamic gh path before copying
setup_gitconfig_with_gh_path() {
    local source_gitconfig=".gitconfig"
    local target_gitconfig="$TARGET_HOME/.gitconfig"
    local temp_gitconfig
    temp_gitconfig=$(mktemp) || {
        log "ERROR" "Failed to create temporary file for .gitconfig processing"
        return 3
    }
    
    # Ensure cleanup of temporary file
    trap 'rm -f "$temp_gitconfig"' RETURN
    
    if [[ ! -f "$source_gitconfig" ]]; then
        log "WARN" ".gitconfig not found in dotfiles, skipping GitHub CLI configuration"
        return 0
    fi
    
    # Find GitHub CLI binary
    local gh_binary_path
    gh_binary_path=$(find_gh_binary)
    
    if [[ -z "$gh_binary_path" ]]; then
        log "WARN" "GitHub CLI not found. Copying .gitconfig without updating gh paths."
        log "INFO" "If you install GitHub CLI later, update the paths manually in .gitconfig"
        # Copy original file without modification
        safe_copy_user "$source_gitconfig" "$target_gitconfig"
        return 0
    fi
    
    log "INFO" "Updating .gitconfig with GitHub CLI path: $gh_binary_path"
    
    # Update the gh paths in .gitconfig - replace existing gh path with detected path
    sed "s|helper = !/[^[:space:]]*/gh|helper = !$gh_binary_path|g" "$source_gitconfig" > "$temp_gitconfig" || {
        log "ERROR" "Failed to update .gitconfig with gh path"
        return 3
    }
    
    # Copy the updated .gitconfig
    if [[ -f "$target_gitconfig" ]]; then
        local backup_ext
        backup_ext=".backup.$(date +%Y%m%d_%H%M%S)"
        log "INFO" "Backing up existing .gitconfig: $target_gitconfig -> $target_gitconfig$backup_ext"
        cp "$target_gitconfig" "$target_gitconfig$backup_ext"
        set_ownership "$target_gitconfig$backup_ext"
    fi
    
    log "INFO" "Copying updated .gitconfig -> $target_gitconfig"
    cp "$temp_gitconfig" "$target_gitconfig" || {
        log "ERROR" "Failed to copy updated .gitconfig"
        return 3
    }
    
    # Set proper ownership
    set_ownership "$target_gitconfig"
    
    # Verify the update worked
    if grep -q "$gh_binary_path" "$target_gitconfig"; then
        log "INFO" ".gitconfig updated successfully with gh path: $gh_binary_path"
    else
        log "WARN" ".gitconfig may not have been updated correctly"
    fi
}

## --- MCP SERVER SETUP FUNCTIONS ---

# Detect environment conditions for MCP server installation
detect_environment_condition() {
    local condition="$1"
    
    case "$condition" in
        "always")
            return 0
            ;;
        "azure_environment")
            # Check for Azure CLI, environment variables, or Azure config
            if [[ -n "${AZUREPS_HOST_ENVIRONMENT:-}" ]] || command_exists az || [[ -d "$TARGET_HOME/.azure" ]]; then
                return 0
            fi
            return 1
            ;;
        "development_environment")
            # Check for common development indicators
            if [[ -f "package.json" ]] || [[ -f ".git/config" ]] || [[ -f "Dockerfile" ]] || [[ -f "pyproject.toml" ]]; then
                return 0
            fi
            return 1
            ;;
        "git_repository")
            if [[ -d ".git" ]] || git rev-parse --git-dir >/dev/null 2>&1; then
                return 0
            fi
            return 1
            ;;
        "api_keys_available")
            if [[ -n "${PERPLEXITY_API_KEY:-}" ]] || [[ -n "${BRAVE_API_KEY:-}" ]]; then
                return 0
            fi
            return 1
            ;;
        *)
            log "WARN" "Unknown condition: $condition"
            return 1
            ;;
    esac
}

# Check if MCP server dependencies are available
check_mcp_dependencies() {
    local dependencies_str="$1"
    
    if [[ -z "$dependencies_str" ]] || [[ "$dependencies_str" == "[]" ]]; then
        return 0
    fi
    
    # Remove brackets and split by comma
    local deps_clean="${dependencies_str//[\[\]\"]/}"
    IFS=',' read -ra deps <<< "$deps_clean"
    
    for dep in "${deps[@]}"; do
        local dep_clean="${dep// /}"  # Remove spaces
        if ! command_exists "$dep_clean"; then
            log "WARN" "Missing dependency for MCP server: $dep_clean"
            return 1
        fi
    done
    return 0
}

# Check if NPM package is installed globally
is_npm_package_installed_globally() {
    local package_name="$1"
    
    # Check if package is installed globally using npm list -g
    if [[ "$EUID" -eq 0 ]]; then
        # Running as root - check system-wide global packages
        npm list -g --depth=0 "$package_name" >/dev/null 2>&1
    else
        # Running as non-root user - check user's global packages
        run_as_user_with_home "npm list -g --depth=0 '$package_name'" >/dev/null 2>&1
    fi
}

# Install NPM packages for MCP servers with proper root/non-root handling
install_mcp_server_package() {
    local server_name="$1"
    local package_name="$2"
    
    if ! command_exists npm; then
        log "WARN" "npm not found, skipping MCP server installation: $server_name"
        return 1
    fi
    
    if [[ "$EUID" -eq 0 ]]; then
        # Running as root - check if already installed globally, then install globally
        if is_npm_package_installed_globally "$package_name"; then
            log "INFO" "MCP server package already installed globally: $server_name ($package_name)"
            return 0
        fi
        
        log "INFO" "Installing MCP server package globally as root: $server_name ($package_name)"
        if npm install -g "$package_name" >/dev/null 2>&1; then
            log "INFO" "Successfully installed MCP server globally: $server_name"
            return 0
        else
            log "WARN" "Failed to install MCP server package globally: $server_name"
            return 1
        fi
    else
        # Running as non-root - first check if already installed globally (system-wide)
        if npm list -g --depth=0 "$package_name" >/dev/null 2>&1; then
            log "INFO" "MCP server package already installed globally (system-wide): $server_name ($package_name)"
            return 0
        fi
        
        # Non-root users cannot install global packages, so skip installation
        log "INFO" "Running as non-root user - cannot install global npm packages"
        log "INFO" "MCP server '$server_name' ($package_name) is not installed globally"
        log "INFO" "To install this MCP server, run as root: sudo npm install -g $package_name"
        return 1
    fi
}

# Generate MCP server configuration for Claude Code
generate_mcp_config() {
    local claude_config="$TARGET_HOME/.claude/claude_desktop_config.json"
    local existing_mcp_config="./.claude/mcp.json"
    local servers_config="./.claude/mcp/servers.json"
    
    log "INFO" "Setting up MCP server configuration..."
    
    # Check if we have the existing comprehensive MCP configuration
    if [[ -f "$existing_mcp_config" ]]; then
        log "INFO" "Using existing comprehensive MCP configuration from mcp.json"
        safe_mkdir_user "$(dirname "$claude_config")"
        safe_copy_user "$existing_mcp_config" "$claude_config"
        log "INFO" "MCP configuration deployed to: $claude_config"
        return 0
    fi
    
    # Fallback to generating from servers.json
    if [[ ! -f "$servers_config" ]]; then
        log "WARN" "No MCP configuration found, creating minimal setup"
        generate_minimal_mcp_config "$claude_config"
        return 1
    fi
    
    log "INFO" "Generating MCP server configuration from servers.json..."
    
    # Create a simple MCP configuration
    local mcp_config='{'
    mcp_config+='"mcpServers": {'
    
    local first_server=true
    local temp_file
    temp_file=$(mktemp)
    
    # Parse the servers.json to extract enabled servers
    if command_exists jq && [[ -f "$servers_config" ]]; then
        # Use jq to parse and generate config
        run_as_user_with_home "jq -r '.mcpServers | to_entries[] | select(.value.install_condition) | \"\\(.key),\\(.value.command),\\(.value.args | join(\" \"))\"' '$servers_config'" > "$temp_file"
    else
        # Fallback: extract basic server info manually
        log "WARN" "jq not available, using basic MCP server configuration"
        echo "memory,npx,-y @modelcontextprotocol/server-memory" > "$temp_file"
        echo "git,npx,-y @modelcontextprotocol/server-git" >> "$temp_file"
    fi
    
    while IFS=',' read -r server_name command args; do
        if [[ -n "$server_name" ]]; then
            if [[ "$first_server" == "false" ]]; then
                mcp_config+=','
            fi
            mcp_config+="\"$server_name\": {"
            mcp_config+="\"command\": \"$command\","
            mcp_config+="\"args\": [\"$args\"]"
            mcp_config+='}'
            first_server=false
        fi
    done < "$temp_file"
    
    mcp_config+='}'
    mcp_config+='}'
    
    # Write the configuration
    safe_mkdir_user "$(dirname "$claude_config")"
    echo "$mcp_config" | run_as_user "tee '$claude_config'" >/dev/null
    set_ownership "$claude_config"
    
    rm -f "$temp_file"
    log "INFO" "MCP configuration written to: $claude_config"
}

# Generate minimal MCP configuration as fallback
generate_minimal_mcp_config() {
    local claude_config="$1"
    
    log "INFO" "Creating minimal MCP configuration..."
    
    local minimal_config='{
  "mcpServers": {
    "memory": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-memory"],
      "tools": ["*"]
    }
  }
}'
    
    safe_mkdir_user "$(dirname "$claude_config")"
    echo "$minimal_config" | run_as_user "tee '$claude_config'" >/dev/null
    set_ownership "$claude_config"
    
    log "INFO" "Minimal MCP configuration written to: $claude_config"
}

# Main MCP server setup function
setup_mcp_servers() {
    log "INFO" "Configuring MCP servers based on environment..."
    
    # Install core MCP servers that are always useful
    install_core_mcp_servers
    
    # Install environment-specific servers
    install_environment_specific_mcp_servers
    
    # Generate/deploy Claude Code configuration
    generate_mcp_config
    
    log "INFO" "MCP server setup completed"
}

# Install core MCP servers that should always be available
install_core_mcp_servers() {
    log "INFO" "Installing core MCP servers..."
    
    # Memory server - always useful for context retention
    install_mcp_server_package "memory" "@modelcontextprotocol/server-memory" || true
    
    # Sequential thinking server - for complex analysis
    install_mcp_server_package "sequential-thinking" "@modelcontextprotocol/server-sequential-thinking" || true
    
    # Git server - if we're in a git repository
    if command_exists git && (git rev-parse --git-dir >/dev/null 2>&1 || [[ -d ".git" ]]); then
        log "INFO" "Git repository detected, installing Git MCP server"
        # Using the server from your existing config - no official git server yet
        # install_mcp_server_package "git" "@modelcontextprotocol/server-git" || true
    fi
}

# Install environment-specific MCP servers
install_environment_specific_mcp_servers() {
    # Development environment servers
    if detect_environment_condition "development_environment"; then
        log "INFO" "Development environment detected, installing additional MCP servers..."
        install_mcp_server_package "context7" "@upstash/context7-mcp" || true
        install_mcp_server_package "magic" "@21st-dev/magic" || true
    fi
    
    # Azure environment servers
    if detect_environment_condition "azure_environment"; then
        log "INFO" "Azure environment detected, installing Azure MCP servers..."
        # Use the generic Azure MCP package which includes all platform-specific versions
        install_mcp_server_package "azure" "@azure/mcp" || true
        log "INFO" "Microsoft Learn MCP server is available as HTTP endpoint (configured via MCP config files)"
    fi
    
    # Terraform server if terraform is available
    if command_exists terraform || command_exists docker; then
        log "INFO" "Terraform/Docker detected, terraform MCP server available via Docker"
        # Note: Terraform server uses Docker, so just log it's available
    fi
    
    # Perplexity server if API key is available
    if [[ -n "${PERPLEXITY_API_KEY:-}" ]]; then
        log "INFO" "Perplexity API key detected, installing Perplexity MCP server..."
        # Using uvx as per your config, but fallback to npx if unavailable
        if command_exists uvx; then
            log "INFO" "Using uvx for Perplexity MCP server (as configured)"
        else
            log "INFO" "uvx not found, Perplexity server will use uvx when available"
        fi
    fi
    
    # MCP installer server - helpful for managing other servers
    install_mcp_server_package "mcp-installer" "@anaisbetts/mcp-installer" || true
}

# Setup Claude binary symlink in ~/.local/bin
setup_claude_symlink() {
    local claude_binary_path
    local symlink_path="$TARGET_HOME/.local/bin/claude"
    
    # Ensure TARGET_HOME exists before creating subdirectories
    if [[ ! -d "$TARGET_HOME" ]]; then
        log "ERROR" "Target home directory does not exist: $TARGET_HOME"
        log "INFO" "Skipping Claude symlink setup"
        return 1
    fi
    
    # Ensure ~/.local/bin exists
    safe_mkdir_user "$TARGET_HOME/.local/bin"
    
    # Find the Claude binary
    claude_binary_path=$(find_claude_binary)
    if [[ -z "$claude_binary_path" ]]; then
        log "WARN" "Claude binary not found. Installing Claude CLI..."
        
        # Install Claude using the official installer
        log "INFO" "Downloading and installing Claude CLI..."
        if run_as_user_with_home "curl -fsSL https://claude.ai/install.sh | bash -s latest" >/dev/null 2>&1; then
            log "INFO" "Claude CLI installed successfully"
            
            # Try to find the binary again after installation
            claude_binary_path=$(find_claude_binary)
            if [[ -z "$claude_binary_path" ]]; then
                log "WARN" "Claude binary still not found after installation. It may be installed in a location not in PATH."
                log "INFO" "You may need to restart your shell or add Claude to your PATH manually."
                return 0
            fi
        else
            log "ERROR" "Failed to install Claude CLI automatically"
            log "INFO" "Please install Claude manually using: curl -fsSL https://claude.ai/install.sh | bash -s latest"
            return 0
        fi
    fi
    
    # If the symlink target is already ~/.local/bin/claude, don't create a recursive symlink
    if [[ "$claude_binary_path" == "$symlink_path" ]]; then
        log "INFO" "Claude binary is already at $symlink_path, no symlink needed"
        return 0
    fi
    
    # Remove existing symlink or file if it exists
    if [[ -e "$symlink_path" || -L "$symlink_path" ]]; then
        if [[ -L "$symlink_path" ]]; then
            local current_target
            current_target=$(readlink "$symlink_path")
            if [[ "$current_target" == "$claude_binary_path" ]]; then
                log "INFO" "Claude symlink already points to correct location: $claude_binary_path"
                return 0
            fi
            log "INFO" "Removing existing Claude symlink (pointed to: $current_target)"
        else
            log "INFO" "Removing existing Claude file at $symlink_path"
        fi
        rm -f "$symlink_path"
    fi
    
    # Create the symlink
    log "INFO" "Creating Claude symlink: $symlink_path -> $claude_binary_path"
    ln -sf "$claude_binary_path" "$symlink_path"
    
    # Set proper ownership if running as root
    set_ownership "$symlink_path"
    
    # Verify the symlink works
    if [[ -L "$symlink_path" && -x "$symlink_path" ]]; then
        log "INFO" "Claude symlink created successfully"
        # Test that the symlink works
        if run_as_user_with_home "'$symlink_path' --version" >/dev/null 2>&1; then
            log "INFO" "Claude symlink is functional"
        else
            log "WARN" "Claude symlink created but may not be functional"
        fi
    else
        log "ERROR" "Failed to create functional Claude symlink"
        return 1
    fi
}

# Set up error trap
trap 'handle_error $LINENO' ERR

# Enhanced network operation with retry and better error handling
retry_network_operation() {
    local max_attempts=3
    local delay=2
    local attempt=1
    local command=("$@")
    
    # Validate that we have a command to run
    if [[ ${#command[@]} -eq 0 ]]; then
        log "ERROR" "retry_network_operation called with no command"
        return 1
    fi
    
    # In cloud-init environments, increase retry attempts and delays
    if [[ "$CLOUD_INIT_MODE" == "true" ]]; then
        max_attempts=5
        delay=5
        log "INFO" "Cloud-init mode: Using extended retry parameters (max_attempts=$max_attempts, initial_delay=${delay}s)"
    fi
    
    # For git operations, check connectivity first
    if [[ "${command[0]}" =~ git|curl|wget ]] && [[ "${command[*]}" =~ github\.com|githubusercontent\.com ]]; then
        if ! check_github_connectivity; then
            log "ERROR" "Network connectivity check failed before attempting operation"
            return 2
        fi
    fi

    while [[ $attempt -le $max_attempts ]]; do
        log "INFO" "Attempting network operation (attempt $attempt/$max_attempts): ${command[*]}"
        
        # Execute command and capture both exit code and output
        local temp_output
        temp_output=$(mktemp)
        local exit_code=0
        
        if "${command[@]}" >"$temp_output" 2>&1; then
            log "INFO" "Network operation succeeded on attempt $attempt"
            rm -f "$temp_output"
            return 0
        else
            exit_code=$?
            local error_output
            error_output=$(cat "$temp_output" 2>/dev/null || echo "No error output available")
            rm -f "$temp_output"
            
            log "WARN" "Network operation failed (attempt $attempt/$max_attempts) with exit code $exit_code"
            debug_log "Error output: $error_output"
            
            # Don't retry on certain types of errors (like permission denied)
            if [[ $exit_code -eq 128 ]] || [[ "$error_output" =~ "Permission denied"|"authentication failed"|"Access denied" ]]; then
                log "ERROR" "Non-retryable error detected, aborting retries"
                return $exit_code
            fi
            
            if [[ $attempt -lt $max_attempts ]]; then
                log "INFO" "Waiting ${delay}s before retry..."
                sleep $delay
                ((delay *= 2))  # Exponential backoff with maximum cap
                if [[ $delay -gt 30 ]]; then
                    delay=30
                fi
            fi
            ((attempt++))
        fi
    done

    log "ERROR" "Network operation failed after $max_attempts attempts: ${command[*]}"
    return 2
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check network connectivity to GitHub
check_github_connectivity() {
    local test_url="https://github.com"
    log "INFO" "Checking connectivity to GitHub..."
    
    # Try multiple methods to check connectivity
    if command_exists curl; then
        if curl -fsSL --connect-timeout 10 --max-time 30 "$test_url" >/dev/null 2>&1; then
            log "INFO" "GitHub connectivity verified via curl"
            return 0
        fi
    fi
    
    if command_exists wget; then
        if wget -q --timeout=30 --tries=1 "$test_url" -O /dev/null 2>/dev/null; then
            log "INFO" "GitHub connectivity verified via wget"
            return 0
        fi
    fi
    
    # Basic ping test (may not work in all environments)
    if command_exists ping; then
        if ping -c 1 -W 5 github.com >/dev/null 2>&1; then
            log "INFO" "GitHub connectivity verified via ping"
            return 0
        fi
    fi
    
    log "WARN" "Cannot verify connectivity to GitHub. Network operations may fail."
    return 1
}

# Cross-platform user validation
user_exists() {
    local user="$1"
    if command_exists getent; then
        # Linux with getent
        getent passwd "$user" >/dev/null 2>&1
    elif [[ "$(uname)" == "Darwin" ]]; then
        # macOS
        dscl . -read "/Users/$user" >/dev/null 2>&1
    else
        # Fallback - check if user has a home directory
        id "$user" >/dev/null 2>&1
    fi
}

# Cross-platform get user home directory
get_user_home() {
    local user="$1"
    
    # Special handling for root user
    if [[ "$user" == "root" ]]; then
        echo "/root"
        return 0
    fi
    
    if command_exists getent; then
        # Linux with getent
        local home_dir
        home_dir=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
        if [[ -n "$home_dir" ]]; then
            echo "$home_dir"
        else
            # Fallback for root or if getent fails
            eval echo "~$user" 2>/dev/null || echo "/home/$user"
        fi
    elif [[ "$(uname)" == "Darwin" ]]; then
        # macOS
        local home_dir
        home_dir=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        if [[ -n "$home_dir" ]]; then
            echo "$home_dir"
        else
            # Fallback
            eval echo "~$user" 2>/dev/null || echo "/Users/$user"
        fi
    else
        # Fallback
        eval echo "~$user" 2>/dev/null || echo "/home/$user"
    fi
}

# Cross-platform get user by minimum UID
get_user_by_uid() {
    local min_uid="$1"
    if command_exists getent; then
        # Linux with getent - find first user with UID >= min_uid
        getent passwd | awk -F: -v min_uid="$min_uid" '$3 >= min_uid { print $1; exit }'
    elif [[ "$(uname)" == "Darwin" ]]; then
        # macOS - find first user with UID >= min_uid
        dscl . -list /Users UniqueID | awk -v min_uid="$min_uid" '$2 >= min_uid { print $1; exit }'
    else
        # Fallback - try to find a user with UID >= min_uid
        # This is a best-effort approach when getent is not available
        local users_found=""
        for user in $(cut -d: -f1 /etc/passwd); do
            local user_uid
            user_uid=$(id -u "$user" 2>/dev/null || echo "0")
            if [[ "$user_uid" -ge "$min_uid" ]]; then
                echo "$user"
                return 0
            fi
        done
    fi
}

# Verify file exists and is readable
verify_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        log "ERROR" "Required file not found: $file"
        return 3
    fi
    if [[ ! -r "$file" ]]; then
        log "ERROR" "Required file not readable: $file"
        return 3
    fi
}

# Safe directory creation
safe_mkdir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        log "INFO" "Creating directory: $dir"
        mkdir -p "$dir" || {
            log "ERROR" "Failed to create directory: $dir"
            return 3
        }
    fi
}

# Safe file copy with backup
safe_copy() {
    local src="$1"
    local dest="$2"
    local backup_ext
    backup_ext=".backup.$(date +%Y%m%d_%H%M%S)"

    verify_file "$src"

    if [[ -f "$dest" ]]; then
        log "INFO" "Backing up existing file: $dest -> $dest$backup_ext"
        cp "$dest" "$dest$backup_ext"
    fi

    log "INFO" "Copying $src -> $dest"
    cp "$src" "$dest" || {
        log "ERROR" "Failed to copy $src to $dest"
        return 3
    }
}

# Git clone or update function
git_clone_or_update() {
    local repo_url="$1"
    local target_dir="$2"
    local clone_args="${3:-}"

    if [[ ! -d "$target_dir" ]]; then
        log "INFO" "Cloning $repo_url to $target_dir"
        retry_network_operation git clone $clone_args "$repo_url" "$target_dir"
    else
        log "INFO" "Updating repository in $target_dir"
        (
            cd "$target_dir" || {
                log "ERROR" "Failed to change to directory: $target_dir"
                return 1
            }
            retry_network_operation git pull --quiet
        )
    fi
}

# Safe download function
safe_download() {
    local url="$1"
    local output="$2"
    local description="${3:-file}"

    log "INFO" "Downloading $description from $url"
    retry_network_operation curl -fsSL "$url" -o "$output"
}

# Execute command as target user
run_as_user() {
    local cmd="$*"

    if [[ "$SCRIPT_USER" == "$TARGET_USER" ]]; then
        # Same user, execute directly
        eval "$cmd"
    elif [[ "$EUID" -eq 0 ]]; then
        # Running as root, switch to target user
        sudo -u "$TARGET_USER" bash -c "$cmd"
    else
        log "ERROR" "Cannot switch to user '$TARGET_USER' without root privileges"
        return 4
    fi
}

# Execute command as target user with proper HOME environment and enhanced error handling
run_as_user_with_home() {
    local cmd="$*"
    local exit_code=0

    # Validate inputs
    if [[ -z "$cmd" ]]; then
        log "ERROR" "Command cannot be empty"
        return 1
    fi
    
    # Ensure target home directory exists and is accessible
    if [[ ! -d "$TARGET_HOME" ]]; then
        log "ERROR" "Target home directory does not exist: $TARGET_HOME"
        return 1
    fi
    
    # Check directory is accessible
    if [[ "$SCRIPT_USER" != "$TARGET_USER" ]] && [[ "$EUID" -ne 0 ]]; then
        if [[ ! -r "$TARGET_HOME" ]]; then
            log "ERROR" "Target home directory not accessible: $TARGET_HOME"
            return 1
        fi
    fi

    debug_log "Executing as user '$TARGET_USER': $cmd"

    if [[ "$SCRIPT_USER" == "$TARGET_USER" ]]; then
        # Same user, execute directly with proper environment
        (
            cd "$TARGET_HOME" || {
                log "ERROR" "Failed to change to home directory: $TARGET_HOME"
                exit 1
            }
            eval "$cmd"
        )
        exit_code=$?
    elif [[ "$EUID" -eq 0 ]]; then
        # Running as root, switch to target user with comprehensive environment setup
        sudo -u "$TARGET_USER" -H bash -c "
            set -euo pipefail
            cd '$TARGET_HOME' || {
                echo '[ERROR] Failed to change to home directory: $TARGET_HOME' >&2
                exit 1
            }
            
            # Set up proper environment
            export HOME='$TARGET_HOME'
            export USER='$TARGET_USER'
            export LOGNAME='$TARGET_USER'
            
            # Execute the command
            $cmd
        "
        exit_code=$?
    else
        log "ERROR" "Cannot switch to user '$TARGET_USER' without root privileges"
        return 4
    fi
    
    if [[ $exit_code -ne 0 ]]; then
        debug_log "Command failed with exit code $exit_code: $cmd"
    else
        debug_log "Command completed successfully: $cmd"
    fi
    
    return $exit_code
}

# Create directory with proper ownership
safe_mkdir_user() {
    local dir="$1"

    if [[ ! -d "$dir" ]]; then
        log "INFO" "Creating directory: $dir"
        
        # Ensure parent directory exists first
        local parent_dir="$(dirname "$dir")"
        if [[ ! -d "$parent_dir" && "$parent_dir" != "/" && "$parent_dir" != "." ]]; then
            safe_mkdir_user "$parent_dir"
        fi
        
        # Enhanced cloud-init compatibility: wait for filesystem to be ready
        if [[ "$CLOUD_INIT_MODE" == "true" ]]; then
            local fs_attempts=10  # Increased from 3 to 10 for better cloud-init compatibility
            local fs_attempt=1
            while [[ $fs_attempt -le $fs_attempts ]]; do
                if [[ -w "$parent_dir" ]] || [[ "$EUID" -eq 0 ]]; then
                    break
                fi
                log "INFO" "Waiting for filesystem to be ready for directory creation (attempt $fs_attempt/$fs_attempts)"
                sleep 2  # Increased from 1 to 2 seconds
                ((fs_attempt++))
            done
            
            # Final check after waiting
            if [[ $fs_attempt -gt $fs_attempts ]]; then
                log "WARN" "Filesystem may not be fully ready after $fs_attempts attempts, proceeding anyway"
            fi
        fi
        
        # Create the directory - use sudo if running as root for a different user
        if [[ "$EUID" -eq 0 ]] && [[ "$SCRIPT_USER" != "$TARGET_USER" ]]; then
            # Running as root for another user - create as that user
            if ! sudo -u "$TARGET_USER" mkdir -p "$dir" 2>&1; then
                log "WARN" "Failed to create directory as $TARGET_USER, attempting as root: $dir"
                # If that fails, create as root and then set ownership
                if ! mkdir -p "$dir"; then
                    log "ERROR" "Failed to create directory even as root: $dir"
                    return 3
                fi
                log "INFO" "Created directory as root, will set ownership: $dir"
            fi
        else
            # Regular creation
            if ! mkdir -p "$dir"; then
                log "ERROR" "Failed to create directory: $dir"
                return 3
            fi
        fi

        # Set proper ownership if running as root
        set_ownership "$dir" true
    fi
}


# Set proper permissions and ownership for Claude directories
set_claude_permissions() {
    local claude_dir="$1"
    
    if [[ -d "$claude_dir" ]]; then
        # Set directory permissions to 755 (readable by all, writable by owner)
        find "$claude_dir" -type d -exec chmod 755 {} \;
        
        # Set file permissions to 644 (readable by all, writable by owner)
        find "$claude_dir" -type f -exec chmod 644 {} \;
        
        # Set ownership recursively if running as root
        set_ownership "$claude_dir" true
        
        log "INFO" "Set proper permissions and ownership for $claude_dir"
    fi
}

# Copy file with proper ownership
safe_copy_user() {
    local src="$1"
    local dest="$2"
    local backup_ext
    backup_ext=".backup.$(date +%Y%m%d_%H%M%S)"

    verify_file "$src"

    # Special handling for sensitive configuration files - preserve if they contain authentication data
    if [[ "$dest" == *"/settings.json" ]] || [[ "$dest" == *"/.credentials.json" ]] || [[ "$dest" == *"/claude_desktop_config.json" ]] || [[ "$dest" == *"/.gitconfig" ]] || [[ "$dest" == *"/.vscode/settings.json" ]]; then
        if [[ -f "$dest" ]]; then
            # Check if existing file contains authentication tokens or sensitive data
            # Include VSCode-specific sensitive patterns and git helper patterns
            if grep -q '"token"' "$dest" 2>/dev/null || grep -q '"sessionToken"' "$dest" 2>/dev/null || grep -q '"authToken"' "$dest" 2>/dev/null || grep -q '"apiKey"' "$dest" 2>/dev/null || grep -q '"credentials"' "$dest" 2>/dev/null || grep -q 'helper = !' "$dest" 2>/dev/null || grep -q '"github.copilot"' "$dest" 2>/dev/null || grep -q '"accessToken"' "$dest" 2>/dev/null || grep -q '"personal-access-token"' "$dest" 2>/dev/null; then
                log "INFO" "Preserving existing file with authentication data: $(basename "$dest")"
                return 0  # Skip copying this file to preserve sensitive data
            fi
        fi
    fi

    if [[ -f "$dest" ]]; then
        log "INFO" "Backing up existing file: $dest -> $dest$backup_ext"
        cp "$dest" "$dest$backup_ext"

        # Set proper ownership for backup if running as root
        set_ownership "$dest$backup_ext"
    fi

    log "INFO" "Copying $src -> $dest"
    cp "$src" "$dest" || {
        log "ERROR" "Failed to copy $src to $dest"
        return 3
    }

    # Set proper ownership if running as root
    set_ownership "$dest"
}

# Safely merge directory contents without overwriting existing directories
safe_merge_directory() {
    local src_dir="$1"
    local dest_dir="$2"
    local description="$3"
    local backup_existing="${4:-false}"
    
    if [[ ! -d "$src_dir" ]]; then
        log "WARN" "Source directory $src_dir not found, skipping $description"
        return 0
    fi
    
    log "INFO" "Merging $description from $src_dir to $dest_dir"
    
    # Create destination directory if it doesn't exist
    safe_mkdir_user "$dest_dir"
    
    # Use find to copy all files while preserving directory structure
    # Exclude runtime/temporary files that shouldn't be copied
    find "$src_dir" -type f \( \
        ! -path "*/logs/*" \
        ! -path "*/shell-snapshots/*" \
        ! -path "*/backups/*" \
        ! -path "*/statsig/*" \
        ! -path "*/todos/*" \
        ! -path "*/projects/*" \
        ! -name "*.backup.*" \
    \) -print0 | while IFS= read -r -d '' src_file; do
        # Calculate relative path from source directory
        rel_path="${src_file#$src_dir/}"
        dest_file="$dest_dir/$rel_path"
        dest_subdir="$(dirname "$dest_file")"
        
        # Create subdirectory if needed
        if [[ ! -d "$dest_subdir" ]]; then
            safe_mkdir_user "$dest_subdir"
        fi
        
        # Check if file already exists and backup if requested
        if [[ -f "$dest_file" ]] && [[ "$backup_existing" == "true" ]]; then
            local backup_ext=".backup.$(date +%Y%m%d_%H%M%S)"
            log "INFO" "Backing up existing file: $dest_file -> $dest_file$backup_ext"
            cp "$dest_file" "$dest_file$backup_ext"
            set_ownership "$dest_file$backup_ext"
        fi
        
        # Special handling for sensitive files - preserve if they contain authentication data
        if [[ "$dest_file" == *"/settings.json" ]] || [[ "$dest_file" == *"/.credentials.json" ]] || [[ "$dest_file" == *"/claude_desktop_config.json" ]] || [[ "$dest_file" == *"/.vscode/settings.json" ]]; then
            if [[ -f "$dest_file" ]]; then
                # Check if existing file contains authentication tokens or sensitive data
                # Include VSCode-specific sensitive patterns
                if grep -q '"token"' "$dest_file" 2>/dev/null || grep -q '"sessionToken"' "$dest_file" 2>/dev/null || grep -q '"authToken"' "$dest_file" 2>/dev/null || grep -q '"apiKey"' "$dest_file" 2>/dev/null || grep -q '"credentials"' "$dest_file" 2>/dev/null || grep -q '"github.copilot"' "$dest_file" 2>/dev/null || grep -q '"accessToken"' "$dest_file" 2>/dev/null || grep -q '"personal-access-token"' "$dest_file" 2>/dev/null; then
                    log "INFO" "Preserving existing file with authentication data: $rel_path"
                    continue  # Skip copying this file to preserve sensitive data
                fi
            fi
        fi
        
        # Copy file and overwrite if it exists
        if [[ -f "$dest_file" ]]; then
            log "INFO" "Overwriting existing file: $rel_path"
        else
            log "INFO" "Copying file: $rel_path"
        fi
        cp "$src_file" "$dest_file" || {
            log "ERROR" "Failed to copy $src_file to $dest_file"
            continue
        }
        set_ownership "$dest_file"
    done
}

# Enhanced git clone or update with comprehensive error handling
git_clone_or_update_user() {
    local repo_url="$1"
    local target_dir="$2"
    local clone_args="${3:-}"
    local max_retries=3
    local retry_count=0

    # Validate inputs
    if [[ -z "$repo_url" ]]; then
        log "ERROR" "Repository URL cannot be empty"
        return 1
    fi
    
    if [[ -z "$target_dir" ]]; then
        log "ERROR" "Target directory cannot be empty"
        return 1
    fi

    # Check if git is available
    if ! command_exists git; then
        log "ERROR" "Git is not available. Cannot clone repository: $repo_url"
        return 1
    fi
    
    # Verify network connectivity if this is a remote repository
    if [[ "$repo_url" =~ ^https?:// ]]; then
        if ! check_github_connectivity; then
            log "ERROR" "Network connectivity issues detected. Cannot clone: $repo_url"
            return 1
        fi
    fi

    if [[ ! -d "$target_dir" ]]; then
        log "INFO" "Cloning $repo_url to $target_dir"
        
        # Ensure parent directory exists with proper ownership
        local parent_dir="$(dirname "$target_dir")"
        if ! safe_mkdir_user "$parent_dir"; then
            log "ERROR" "Failed to create parent directory: $parent_dir"
            return 1
        fi
        
        # Clean up any partial clones from previous failed attempts
        if [[ -d "$target_dir" ]]; then
            log "WARN" "Removing incomplete clone directory: $target_dir"
            rm -rf "$target_dir"
        fi

        # Attempt clone with retry logic
        while [[ $retry_count -lt $max_retries ]]; do
            ((retry_count++))
            log "INFO" "Clone attempt $retry_count/$max_retries for $repo_url"
            
            if run_as_user_with_home "git clone $clone_args '$repo_url' '$target_dir'"; then
                log "INFO" "Successfully cloned $repo_url on attempt $retry_count"
                
                # Verify the clone was successful
                if [[ -d "$target_dir/.git" ]]; then
                    # Set ownership if running as root
                    set_ownership "$target_dir" true
                    
                    # Final verification
                    local content_count
                    content_count=$(find "$target_dir" -mindepth 1 -maxdepth 1 ! -name '.git' | wc -l)
                    if [[ $content_count -gt 0 ]]; then
                        log "INFO" "Clone verification successful: $target_dir contains $content_count items"
                        return 0
                    else
                        log "ERROR" "Clone appears empty (no content besides .git): $target_dir"
                        rm -rf "$target_dir"
                    fi
                else
                    log "ERROR" "Clone completed but .git directory missing: $target_dir"
                    rm -rf "$target_dir"
                fi
            else
                log "WARN" "Git clone attempt $retry_count failed for $repo_url"
                # Clean up failed clone attempt
                if [[ -d "$target_dir" ]]; then
                    rm -rf "$target_dir"
                fi
            fi
            
            # Wait before retry (exponential backoff)
            if [[ $retry_count -lt $max_retries ]]; then
                local wait_time=$((retry_count * 2))
                log "INFO" "Waiting ${wait_time}s before retry..."
                sleep $wait_time
            fi
        done
        
        log "ERROR" "Failed to clone repository $repo_url after $max_retries attempts"
        return 1
    else
        log "INFO" "Updating existing repository in $target_dir"
        
        # Verify this is actually a git repository
        if [[ ! -d "$target_dir/.git" ]]; then
            log "ERROR" "Target directory exists but is not a git repository: $target_dir"
            return 1
        fi
        
        # Enhanced git update with proper error handling
        local update_cmd="cd '$target_dir' && {
            # Verify we can fetch from remote
            if git fetch origin --quiet 2>/dev/null; then
                # Get the default branch from remote
                default_branch=\$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || {
                    # Fallback: try to determine default branch
                    git remote show origin 2>/dev/null | grep 'HEAD branch' | cut -d' ' -f5 || echo 'main'
                })
                
                log "INFO" "Updating to default branch: \$default_branch"
                
                # Ensure we're on the right branch
                if git show-ref --verify --quiet refs/heads/\$default_branch; then
                    git checkout \$default_branch --quiet 2>/dev/null || true
                else
                    # Create and checkout the default branch if it doesn't exist locally
                    git checkout -b \$default_branch origin/\$default_branch --quiet 2>/dev/null || {
                        # If that fails, try to checkout the remote default branch directly
                        git checkout origin/\$default_branch --quiet 2>/dev/null || true
                    }
                fi
                
                # Now pull the latest changes
                if git pull --quiet 2>/dev/null; then
                    log "INFO" "Successfully updated repository"
                else
                    log "WARN" "Pull failed, attempting reset"
                    git reset --hard origin/\$default_branch --quiet 2>/dev/null || {
                        log "ERROR" "Failed to reset repository to origin/\$default_branch"
                        exit 1
                    }
                fi
            else
                log "ERROR" "Failed to fetch from remote repository"
                exit 1
            fi
        }"

        if run_as_user_with_home "$update_cmd"; then
            log "INFO" "Repository update completed successfully: $target_dir"
            return 0
        else
            log "ERROR" "Repository update failed for $target_dir"
            return 1
        fi
    fi
}

# Set readonly variables for script execution (must be before function calls)
declare -r DOTFILEDIR="$(pwd)"
declare -r SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Validate we're in the correct directory
if [[ ! -f "$SCRIPT_DIR/install.sh" ]]; then
    log "ERROR" "Script must be run from the dotfiles directory"
    exit 1
fi

## --- MAIN SCRIPT EXECUTION ---

# If $HOME is unset or set to 'None', set it to the current user's home directory
if [[ -z "${HOME:-}" ]] || [[ "${HOME:-}" == "None" ]]; then
    current_user="$(whoami)"
    home_dir="$(get_user_home "$current_user")"
    export HOME="$home_dir"
fi

# Parse command line arguments first
parse_arguments "$@"

# Detect execution context
detect_execution_context

# Setup target user and home directory
setup_target_user

# Create essential directories early to ensure they exist before any operations
# This is particularly important for cloud-init contexts where operations may fail silently
ensure_essential_directories() {
    log "INFO" "Creating essential directories for user $TARGET_USER..."
    
    # Core directories that should always exist
    safe_mkdir_user "$TARGET_HOME/.local"
    safe_mkdir_user "$TARGET_HOME/.local/bin"
    safe_mkdir_user "$TARGET_HOME/.cache"
    safe_mkdir_user "$TARGET_HOME/.config"
    
    # Tool-specific directories
    safe_mkdir_user "$TARGET_HOME/.azure"
    safe_mkdir_user "$TARGET_HOME/.oh-my-posh"
    safe_mkdir_user "$TARGET_HOME/.oh-my-posh/themes"
    safe_mkdir_user "$TARGET_HOME/.oh-my-zsh"
    safe_mkdir_user "$TARGET_HOME/.oh-my-zsh/custom"
    safe_mkdir_user "$TARGET_HOME/.oh-my-zsh/custom/plugins"
    safe_mkdir_user "$TARGET_HOME/.tfenv"
    safe_mkdir_user "$TARGET_HOME/.tfenv/bin"
    safe_mkdir_user "$TARGET_HOME/.tmux"
    safe_mkdir_user "$TARGET_HOME/.tmux/plugins"
    safe_mkdir_user "$TARGET_HOME/.vim"
    safe_mkdir_user "$TARGET_HOME/.vim/pack"
    safe_mkdir_user "$TARGET_HOME/.vim/pack/plugin"
    safe_mkdir_user "$TARGET_HOME/.vim/pack/plugin/start"
    safe_mkdir_user "$TARGET_HOME/.vim/pack/themes"
    safe_mkdir_user "$TARGET_HOME/.vim/pack/themes/start"
    safe_mkdir_user "$TARGET_HOME/.vscode"
    safe_mkdir_user "$TARGET_HOME/.vscode-insiders"
    safe_mkdir_user "$TARGET_HOME/.vscode-server"
    safe_mkdir_user "$TARGET_HOME/.vscode-server-insiders"
    safe_mkdir_user "$TARGET_HOME/.claude"
    
    # Create .z file for z jump tool
    if [[ ! -f "$TARGET_HOME/.z" ]]; then
        touch "$TARGET_HOME/.z"
        set_ownership "$TARGET_HOME/.z"
        log "INFO" "Created .z file for z jump tool"
    fi
    
    log "INFO" "Essential directories created successfully"
}

# Ensure all essential directories exist early in the process
ensure_essential_directories

# Override HOME with target home if different user
if [[ "$TARGET_USER" != "$SCRIPT_USER" ]]; then
    export HOME="$TARGET_HOME"
fi

# Log the value of HOME for debugging
log "INFO" "HOME is set to: $HOME"

# If XDG_CACHE_HOME is unset, set it to $HOME/.cache
if [[ -z "${XDG_CACHE_HOME:-}" ]]; then
    export XDG_CACHE_HOME="$HOME/.cache"
fi

# Log the value of XDG_CACHE_HOME for debugging
log "INFO" "XDG_CACHE_HOME is set to: $XDG_CACHE_HOME"

# Setup shell configuration function
setup_shell_config() {
    local shellrc="$1"
    
    if [[ ! -f "$shellrc" ]]; then
        return 0
    fi
    
    # Add $HOME/.local/bin to PATH
    local home_localbin_export='export PATH=$PATH:$HOME/.local/bin'
    if ! grep -q "export PATH=.*\.local/bin" "$shellrc"; then
        add_to_shell_config "$shellrc" "$home_localbin_export" "export PATH=.*\.local/bin" "\$HOME/.local/bin to PATH"
    else
        # Check if it's using hardcoded path and replace it
        if grep -q "export PATH=.*${TARGET_USER}.*\.local/bin" "$shellrc" && ! grep -q "export PATH=.*\$HOME.*\.local/bin" "$shellrc"; then
            log "INFO" "Replacing hardcoded path with \$HOME variable in $shellrc"
            # Create a backup
            cp "$shellrc" "$shellrc.backup.$(date +%Y%m%d_%H%M%S)"
            # Replace hardcoded path with $HOME version
            if [[ "$(uname)" == "Darwin" ]]; then
                sed -i '' "s|export PATH=\$PATH:[^:]*${TARGET_USER}[^:]*\.local/bin|${home_localbin_export}|g" "$shellrc"
            else
                sed -i "s|export PATH=\$PATH:[^:]*${TARGET_USER}[^:]*\.local/bin|${home_localbin_export}|g" "$shellrc"
            fi
            set_ownership "$shellrc"
        fi
    fi
    
    # Add GitHub CLI pager configuration
    add_to_shell_config "$shellrc" 'export GH_PAGER=' "export GH_PAGER=" "GitHub CLI pager configuration"
}

# Apply shell configuration to both zsh and bash
for shellrc in "$TARGET_HOME/.zshrc" "$TARGET_HOME/.bashrc"; do
    setup_shell_config "$shellrc"
done

# Setup VSCode shell integration
log "INFO" "Setting up VSCode shell integration..."

setup_vscode_integration() {
    local shell_type="$1"
    local shell_file="$TARGET_HOME/.${shell_type}rc"
    local integration_line="[[ \"\$TERM_PROGRAM\" == \"vscode\" ]] && . \"\$(code --locate-shell-integration-path $shell_type)\""
    
    if [[ -f "$shell_file" ]]; then
        if ! grep -qF "TERM_PROGRAM.*vscode.*locate-shell-integration-path.*$shell_type" "$shell_file"; then
            log "INFO" "Adding VSCode shell integration to .$shell_type" "rc"
            {
                echo ""
                echo "# VSCode shell integration" 
                echo "$integration_line"
            } >> "$shell_file"
            set_ownership "$shell_file"
        else
            log "INFO" "VSCode shell integration already configured in .$shell_type" "rc"
        fi
    else
        log "WARN" ".$shell_type" "rc not found, skipping VSCode shell integration setup"
    fi
}

setup_vscode_integration "bash"
setup_vscode_integration "zsh"

log "INFO" "Starting dotfiles installation..."
log "INFO" "Working directory: ${DOTFILEDIR}"

# Update ZSH theme if .zshrc exists
if [[ -f "$TARGET_HOME/.zshrc" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' 's/^ZSH_THEME="[^"]*"/ZSH_THEME="agnoster"/' "$TARGET_HOME/.zshrc"
    else
        sed -i 's/^ZSH_THEME="[^"]*"/ZSH_THEME="agnoster"/' "$TARGET_HOME/.zshrc"
    fi
fi

# List of configuration files to copy
declare -a config_files=(
    ".act"
    ".claude.json"
    ".digrc"
    ".opencommit"
    ".p10k.zsh"
    ".tmux.conf"
    ".gitconfig"
    ".vimrc"
)

# Copy configuration files safely
for config_file in "${config_files[@]}"; do
    if [[ -f "$config_file" ]]; then
        # Special handling for .gitconfig to update gh paths dynamically
        if [[ "$config_file" == ".gitconfig" ]]; then
            setup_gitconfig_with_gh_path
        else
            safe_copy_user "$config_file" "$TARGET_HOME/$config_file"
        fi
    else
        log "WARN" "Configuration file not found: $config_file"
    fi
done

log "INFO" "Configuration files copied successfully"

# --- Claude config setup ---
log "INFO" "Setting up Claude Code configuration..."

claude_dir="$TARGET_HOME/.claude"
claude_source_dir="./.claude"

# Safely merge Claude directory contents without overwriting existing directory
safe_merge_directory "$claude_source_dir" "$claude_dir" "Claude Code configuration" false


# Set proper permissions and ownership for the Claude directory
set_claude_permissions "$claude_dir"

# Setup MCP servers
setup_mcp_servers

# Setup Claude binary symlink
setup_claude_symlink

vscode_dir="$TARGET_HOME/.vscode"

# Safely merge VSCode directory contents without overwriting existing directory
if [[ -d .vscode ]]; then
    safe_merge_directory ".vscode" "$vscode_dir" "VSCode configuration" false
else
    log "WARN" "VSCode configuration directory not found in dotfiles"
fi

#if ! [ -d ~/.continue ]; then
#  mkdir -p ~/.continue
#fi
#cp .continue/config.json ~/.continue

log "INFO" "Setting up tmux plugins..."
log_environment_state "tmux setup"

# Validate environment before proceeding with tmux setup
if validate_plugin_environment "TMux plugins" "git"; then
    # Enhanced cloud-init compatibility with retry logic for filesystem operations
    local max_attempts=5
    local attempt=1
    local tmux_setup_success=false
    
    while [[ $attempt -le $max_attempts ]] && [[ "$tmux_setup_success" == "false" ]]; do
        if [[ $attempt -gt 1 ]]; then
            log "INFO" "Retrying tmux setup (attempt $attempt/$max_attempts)..."
            sleep 2
        fi
        
        # Verify target home is writable
        if [[ -w "$TARGET_HOME" ]] || [[ "$EUID" -eq 0 ]]; then
            if safe_mkdir_user "$TARGET_HOME/.tmux" && safe_mkdir_user "$TARGET_HOME/.tmux/plugins"; then
                log "INFO" "Attempting to clone tmux plugin manager (TPM)..."
                if git_clone_or_update_user "https://github.com/tmux-plugins/tpm" "$TARGET_HOME/.tmux/plugins/tpm"; then
                    # Enhanced verification using the new verification function
                    if verify_plugin_installation "$TARGET_HOME/.tmux/plugins/tpm" "tpm"; then
                        log "INFO" "TPM installation completed and verified successfully"
                        log "INFO" "TPM installed at: $TARGET_HOME/.tmux/plugins/tpm"
                        
                        # Additional verification - check if TPM is executable
                        if [[ -x "$TARGET_HOME/.tmux/plugins/tpm/tpm" ]]; then
                            log "INFO" "TPM script is executable and ready to use"
                        else
                            log "WARN" "TPM script exists but may not be executable"
                            # Try to fix permissions
                            chmod +x "$TARGET_HOME/.tmux/plugins/tpm/tpm" 2>/dev/null || log "WARN" "Could not fix TPM script permissions"
                        fi
                        tmux_setup_success=true
                    else
                        log "ERROR" "TPM installation verification failed (attempt $attempt/$max_attempts)"
                        log "INFO" "Tmux configuration will work, but plugins will not be available"
                    fi
                else
                    log "WARN" "Git clone failed for tmux plugins (attempt $attempt/$max_attempts)"
                fi
            else
                log "WARN" "Failed to create tmux directories (attempt $attempt/$max_attempts)"
            fi
        else
            log "WARN" "Target home directory not writable: $TARGET_HOME (attempt $attempt/$max_attempts)"
        fi
        
        ((attempt++))
    done
    
    if [[ "$tmux_setup_success" == "false" ]]; then
        log "ERROR" "Failed to set up tmux plugins after $max_attempts attempts"
        log "INFO" "This may be due to filesystem mounting timing during cloud-init"
        
        # Enhanced diagnostics for troubleshooting
        log "INFO" "=== TPM Installation Diagnostics ==="
        log "INFO" "Target directory: $TARGET_HOME/.tmux/plugins/tpm"
        log "INFO" "Directory exists: $([[ -d "$TARGET_HOME/.tmux/plugins/tpm" ]] && echo 'yes' || echo 'no')"
        log "INFO" "Parent directory exists: $([[ -d "$TARGET_HOME/.tmux/plugins" ]] && echo 'yes' || echo 'no')"
        log "INFO" "Parent directory writable: $([[ -w "$TARGET_HOME/.tmux/plugins" ]] && echo 'yes' || echo 'no')"
        log "INFO" "Target home accessible: $([[ -d "$TARGET_HOME" && -r "$TARGET_HOME" ]] && echo 'yes' || echo 'no')"
        if [[ -d "$TARGET_HOME/.tmux/plugins/tpm" ]]; then
            log "INFO" "Directory contents: $(ls -la "$TARGET_HOME/.tmux/plugins/tpm" 2>/dev/null | wc -l) items"
            if [[ -f "$TARGET_HOME/.tmux/plugins/tpm/tpm" ]]; then
                log "INFO" "TPM script exists but installation reported as failed"
            else
                log "INFO" "TPM directory exists but script is missing"
            fi
        fi
        log "INFO" "Git available: $(command_exists git && echo 'yes' || echo 'no')"
        log "INFO" "Network connectivity: $(check_github_connectivity >/dev/null 2>&1 && echo 'ok' || echo 'failed')"
        log "INFO" "Current user: $(whoami)"
        log "INFO" "Target user: $TARGET_USER"
        log "INFO" "Running as root: $([[ "$EUID" -eq 0 ]] && echo 'yes' || echo 'no')"
        log "INFO" "================================"
        
        log "INFO" "To manually install TPM later, run:"
        log "INFO" "  git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm"
    fi
else
    log "ERROR" "Environment validation failed for TMux plugins"
    log "INFO" "Skipping tmux plugin installation"
fi

log "INFO" "Setting up Vim plugins and themes..."

# Validate environment for Vim plugins
if validate_plugin_environment "Vim plugins" "git" "bash4+"; then
    safe_mkdir_user "$TARGET_HOME/.vim"
    safe_mkdir_user "$TARGET_HOME/.vim/pack"
    safe_mkdir_user "$TARGET_HOME/.vim/pack/plugin"
    safe_mkdir_user "$TARGET_HOME/.vim/pack/themes"
    safe_mkdir_user "$TARGET_HOME/.vim/pack/plugin/start"
    safe_mkdir_user "$TARGET_HOME/.vim/pack/themes/start"
    
    # Vim plugins configuration
    declare -A vim_plugins=(
            ["vim-airline"]="https://github.com/vim-airline/vim-airline"
            ["nerdtree"]="https://github.com/preservim/nerdtree.git"
            ["fzf"]="https://github.com/junegunn/fzf.vim.git"
            ["vim-gitgutter"]="https://github.com/airblade/vim-gitgutter.git"
            ["vim-fugitive"]="https://github.com/tpope/vim-fugitive.git"
            ["vim-terraform"]="https://github.com/hashivim/vim-terraform.git"
            ["vim-polyglot"]="https://github.com/sheerun/vim-polyglot"
        )

        # Vim themes configuration
        declare -A vim_themes=(
            ["vim-code-dark"]="https://github.com/tomasiser/vim-code-dark"
    )
    
    # Install/update Vim plugins and themes with error checking
        local vim_plugins_success=false
        local vim_themes_success=false
        
        if install_plugin_collection vim_plugins "$TARGET_HOME/.vim/pack/plugin/start" "Vim plugins"; then
            log "INFO" "Vim plugins installation completed successfully"
            vim_plugins_success=true
        else
            log "ERROR" "Vim plugins installation encountered errors"
        fi
        
        if install_plugin_collection vim_themes "$TARGET_HOME/.vim/pack/themes/start" "Vim themes"; then
            log "INFO" "Vim themes installation completed successfully"
            vim_themes_success=true
        else
            log "ERROR" "Vim themes installation encountered errors"
        fi
        
        if [[ "$vim_plugins_success" == "true" ]] && [[ "$vim_themes_success" == "true" ]]; then
            log "INFO" "All Vim plugins and themes set up successfully"
        elif [[ "$vim_plugins_success" == "true" ]] || [[ "$vim_themes_success" == "true" ]]; then
            log "WARN" "Vim setup completed with some errors - check logs above for details"
    else
        log "ERROR" "Vim plugins and themes installation failed"
        log "INFO" "Vim will work with basic functionality, but plugins may not be available"
    fi
else
    log "ERROR" "Environment validation failed for Vim plugins"
    log "INFO" "Skipping Vim plugin installation"
fi

log "INFO" "Setting up Zsh and Oh My Zsh..."
oh_my_zsh_dir="$TARGET_HOME/.oh-my-zsh"

if [[ ! -d "$oh_my_zsh_dir" ]]; then
    log "INFO" "Installing Oh My Zsh..."
    
    # Enhanced Oh My Zsh installation with better error handling
    local install_cmd='sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
    
    if run_as_user_with_home "$install_cmd"; then
        log "INFO" "Oh My Zsh installation completed"
    else
        log "WARN" "Initial Oh My Zsh installation failed, retrying with network retry logic..."
        if retry_network_operation run_as_user_with_home "$install_cmd"; then
            log "INFO" "Oh My Zsh installation completed on retry"
        else
            log "ERROR" "Oh My Zsh installation failed after multiple attempts"
            log "INFO" "Continuing without Oh My Zsh - some Zsh features may not be available"
            # Don't fail the entire script, just skip Zsh plugin installation
        fi
    fi
    
    # Verify Oh My Zsh installation
    if [[ -d "$oh_my_zsh_dir" ]]; then
        # Check for essential Oh My Zsh components
        if [[ -f "$oh_my_zsh_dir/oh-my-zsh.sh" ]]; then
            log "INFO" "Oh My Zsh installation verified successfully"
        else
            log "ERROR" "Oh My Zsh directory exists but core files are missing"
        fi
        
        # Ensure proper ownership
        set_ownership "$oh_my_zsh_dir" true
    else
        log "ERROR" "Oh My Zsh installation failed - directory does not exist"
    fi
else
    log "INFO" "Oh My Zsh already installed"
    
    # Verify existing installation
    if [[ -f "$oh_my_zsh_dir/oh-my-zsh.sh" ]]; then
        log "INFO" "Existing Oh My Zsh installation verified"
    else
        log "WARN" "Oh My Zsh directory exists but core files may be missing"
    fi
fi

log "INFO" "Setting up z jump tool..."
z_file="$TARGET_HOME/.z"
if [[ ! -f "$z_file" ]]; then
    run_as_user_with_home "curl -fsSL 'https://raw.githubusercontent.com/rupa/z/master/z.sh' -o '$z_file'" || {
        retry_network_operation run_as_user_with_home "curl -fsSL 'https://raw.githubusercontent.com/rupa/z/master/z.sh' -o '$z_file'"
    }
    log "INFO" "z script downloaded successfully"
else
    log "INFO" "z script already exists"
fi

log "INFO" "Setting up .zshrc configuration..."
zshrc_file="$TARGET_HOME/.zshrc"
if [[ ! -f "$zshrc_file" ]]; then
    log "INFO" "Creating .zshrc from template..."
    template_file="$oh_my_zsh_dir/templates/zshrc.zsh-template"
    if [[ -f "$template_file" ]]; then
        cp "$template_file" "$zshrc_file"

        # Set proper ownership if running as root
        set_ownership "$zshrc_file"
    else
        log "WARN" "Oh My Zsh template not found, creating basic .zshrc"
        echo "# Basic zshrc configuration" > "$zshrc_file"

        # Set proper ownership if running as root
        set_ownership "$zshrc_file"
    fi
else
    log "INFO" ".zshrc already exists"
fi

log "INFO" "Setting up Zsh plugins..."

# Validate environment for Zsh plugins
if validate_plugin_environment "Zsh plugins" "git" "oh-my-zsh"; then
    safe_mkdir_user "$oh_my_zsh_dir/custom/plugins"
    
    # Check bash version for associative array support
    if (( BASH_VERSINFO[0] >= 4 )); then
        # Zsh plugins configuration
        declare -A zsh_plugins=(
            ["zsh-autosuggestions"]="https://github.com/zsh-users/zsh-autosuggestions.git"
            ["zsh-syntax-highlighting"]="https://github.com/zsh-users/zsh-syntax-highlighting.git"
            ["conda-zsh-completion"]="https://github.com/conda-incubator/conda-zsh-completion.git"
            ["zsh-tfenv"]="https://github.com/cda0/zsh-tfenv.git"
            ["zsh-aliases-lsd"]="https://github.com/yuhonas/zsh-aliases-lsd.git"
        )

        # Install/update Zsh plugins with error checking
        if install_plugin_collection zsh_plugins "$oh_my_zsh_dir/custom/plugins" "Zsh plugins"; then
            log "INFO" "Zsh plugins installation completed successfully"
        else
            log "ERROR" "Zsh plugins installation encountered errors"
            log "INFO" "Zsh will work with basic functionality, but some plugins may not be available"
        fi
    else
        log "WARN" "Bash version ${BASH_VERSION} detected. Installing Zsh plugins individually without associative arrays."

        # Install plugins individually with error checking
        local individual_plugins=(
            "zsh-autosuggestions:https://github.com/zsh-users/zsh-autosuggestions.git"
            "zsh-syntax-highlighting:https://github.com/zsh-users/zsh-syntax-highlighting.git"
            "conda-zsh-completion:https://github.com/conda-incubator/conda-zsh-completion.git"
            "zsh-tfenv:https://github.com/cda0/zsh-tfenv.git"
            "zsh-aliases-lsd:https://github.com/yuhonas/zsh-aliases-lsd.git"
        )
        
        local success_count=0
        local total_plugins=${#individual_plugins[@]}
        
        log "INFO" "Installing $total_plugins Zsh plugins individually (bash version fallback)"
        
        for plugin_info in "${individual_plugins[@]}"; do
            IFS=':' read -r plugin_name plugin_url <<< "$plugin_info"
            local plugin_dir="$oh_my_zsh_dir/custom/plugins/$plugin_name"
            
            log "INFO" "Installing Zsh plugin: $plugin_name"
            if git_clone_or_update_user "$plugin_url" "$plugin_dir"; then
                if verify_plugin_installation "$plugin_dir" "$plugin_name"; then
                    log "INFO" "Successfully installed and verified: $plugin_name"
                    ((success_count++))
                else
                    log "ERROR" "Installation verification failed for: $plugin_name"
                fi
            else
                log "ERROR" "Failed to install Zsh plugin: $plugin_name"
            fi
        done
        
        log "INFO" "Zsh individual plugin installation completed: $success_count/$total_plugins successful"
        
        if [[ $success_count -eq 0 ]]; then
            log "ERROR" "All Zsh plugins failed to install"
        elif [[ $success_count -lt $total_plugins ]]; then
            log "WARN" "Some Zsh plugins failed to install - check logs above for details"
        fi
    fi
else
    log "ERROR" "Environment validation failed for Zsh plugins"
    log "INFO" "Skipping Zsh plugin installation"
fi

if [[ -d "$oh_my_zsh_dir/custom" ]]; then
    log "INFO" "Downloading Azure CLI completion..."
    az_completion_file="$oh_my_zsh_dir/custom/az.zsh"
    run_as_user_with_home "curl -fsSL 'https://raw.githubusercontent.com/Azure/azure-cli/dev/az.completion' -o '$az_completion_file'" || {
        retry_network_operation run_as_user_with_home "curl -fsSL 'https://raw.githubusercontent.com/Azure/azure-cli/dev/az.completion' -o '$az_completion_file'"
    }
    set_ownership "$az_completion_file"
else
    log "INFO" "Skipping Azure CLI completion - Oh My Zsh custom directory does not exist"
fi

log "INFO" "Zsh and Oh My Zsh set up successfully"

log "INFO" "Configuring Zsh plugins in .zshrc..."
cd "${DOTFILEDIR}" || {
    log "ERROR" "Failed to change to dotfiles directory"
    exit 1
}


# Only attempt to modify plugins line if $zshrc_file exists
if [[ -f "$zshrc_file" ]]; then
    tmpfile=$(mktemp) || {
        log "ERROR" "Failed to create temporary file"
        exit 3
    }
    # Ensure cleanup of temporary file
    trap 'rm -f "$tmpfile"' EXIT
    if sed 's/^plugins=.*$/plugins=(git zsh-syntax-highlighting zsh-autosuggestions ubuntu jsontools gh common-aliases conda-zsh-completion zsh-aliases-lsd zsh-tfenv z pip docker)/' "$zshrc_file" > "$tmpfile"; then
        mv "$tmpfile" "$zshrc_file" || {
            log "ERROR" "Failed to update .zshrc"
            exit 3
        }
        # Set proper ownership if running as root
        set_ownership "$zshrc_file"
    else
        log "ERROR" "Failed to modify .zshrc content"
        exit 3
    fi
else
    log "WARN" "$zshrc_file not found, skipping plugins configuration update."
fi

log "INFO" "Zsh plugins configured successfully"

log "INFO" "Setting up Oh My Posh prompt theme..."
if [[ -d "$TARGET_HOME" ]]; then
    safe_mkdir_user "$TARGET_HOME/.local/bin"
    safe_mkdir_user "$TARGET_HOME/.oh-my-posh"
    safe_mkdir_user "$TARGET_HOME/.oh-my-posh/themes"
else
    log "ERROR" "Target home directory does not exist: $TARGET_HOME"
    log "INFO" "Skipping Oh My Posh setup"
fi

if [[ -d "$TARGET_HOME" ]]; then
    log "INFO" "Installing Oh My Posh..."
    # Install Oh My Posh as the target user
    run_as_user_with_home "curl -s https://ohmyposh.dev/install.sh | bash -s -- -d '$TARGET_HOME/.local/bin' -t '$TARGET_HOME/.oh-my-posh/themes'" || {
        retry_network_operation run_as_user_with_home "curl -s https://ohmyposh.dev/install.sh | bash -s -- -d '$TARGET_HOME/.local/bin' -t '$TARGET_HOME/.oh-my-posh/themes'"
    }
else
    log "INFO" "Skipping Oh My Posh installation due to missing home directory"
fi

log "INFO" "Installing Meslo font (non-interactive)..."
oh_my_posh_bin="$TARGET_HOME/.local/bin/oh-my-posh"
if [[ -f "$oh_my_posh_bin" ]]; then
    run_as_user_with_home "'$oh_my_posh_bin' font install Meslo" || log "WARN" "Font installation failed or already installed"
else
    log "WARN" "oh-my-posh not found, skipping font installation"
fi

log "INFO" "Copying powerlevel10k theme..."
if [[ -f powerlevel10k.omp.json ]]; then
    safe_copy_user powerlevel10k.omp.json "$TARGET_HOME/.oh-my-posh/themes/powerlevel10k.omp.json"
else
    log "WARN" "powerlevel10k.omp.json not found in dotfiles"
fi

if [[ -f "$oh_my_posh_bin" ]]; then
    run_as_user_with_home "'$oh_my_posh_bin' disable notice"
fi

#log "INFO" "Configuring Oh My Posh in shell configurations..."
# Configure Oh My Posh for zsh
#oh_my_posh_zsh_line='eval "$(oh-my-posh init zsh --config ~/.oh-my-posh/themes/powerlevel10k.omp.json)"'
#if ! grep -qxF "$oh_my_posh_zsh_line" "$zshrc_file" 2>/dev/null; then
#    echo "$oh_my_posh_zsh_line" >> "$zshrc_file"
#
#    # Set proper ownership if running as root
#    if [[ "$EUID" -eq 0 ]] && [[ "$SCRIPT_USER" != "$TARGET_USER" ]]; then
#        chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$zshrc_file"
#    fi
#fi

log "INFO" "Configuring Conda (if available)..."
if command_exists conda; then
    log "INFO" "Initializing Conda for all shells..."
    conda init --all --no-user-rc-path 2>&1 || log "WARN" "Conda init failed"

    log "INFO" "Disabling Conda prompt changes..."
    conda config --set changeps1 False 2>&1 || log "WARN" "Conda config failed"

    log "INFO" "Conda configured successfully"
else
    log "INFO" "Conda not found, skipping configuration"
fi

log "INFO" "Installing lsd (modern ls replacement) on Linux..."
if [[ "$(uname)" == "Linux" ]]; then
    if ! run_as_user_with_home "command -v lsd >/dev/null 2>&1"; then
        log "INFO" "Downloading and installing lsd..."
        lsd_version="v1.0.0"
        lsd_file="lsd-${lsd_version}-x86_64-unknown-linux-gnu.tar.gz"
        lsd_url="https://github.com/lsd-rs/lsd/releases/download/${lsd_version}/${lsd_file}"

        # Download to a temporary location
        temp_dir=$(mktemp -d)
        trap 'rm -rf "$temp_dir"' EXIT

        retry_network_operation curl -fsSL "$lsd_url" -o "$temp_dir/$lsd_file"

        (
            cd "$temp_dir" || exit 3
            tar -zxf "$lsd_file" || {
                log "ERROR" "Failed to extract lsd archive"
                exit 3
            }

            # Extract directory name without extension
            lsd_dir="${lsd_file%.tar.gz}"

            # Ensure local bin directory exists
            if [[ -d "$TARGET_HOME" ]]; then
                safe_mkdir_user "$TARGET_HOME/.local/bin"
            else
                log "ERROR" "Target home directory does not exist: $TARGET_HOME"
                exit 3
            fi

            # Move binary and set ownership
            mv "$lsd_dir/lsd" "$TARGET_HOME/.local/bin/" || {
                log "ERROR" "Failed to move lsd binary"
                exit 3
            }

            # Set proper ownership and permissions
            set_ownership "$TARGET_HOME/.local/bin/lsd"
            chmod +x "$TARGET_HOME/.local/bin/lsd"
        )

        log "INFO" "lsd installed successfully"
    else
        log "INFO" "lsd already installed"
    fi
else
    log "INFO" "Not on Linux, skipping lsd installation"
fi

log "INFO" "Setting up PowerShell profile..."
if [[ -n "${AZUREPS_HOST_ENVIRONMENT:-}" ]]; then
    log "INFO" "Detected Azure PowerShell environment"
    powershell_dir="$TARGET_HOME/.config/PowerShell"
    safe_mkdir_user "$powershell_dir"

    log "INFO" "Copying PowerShell profile..."
    if [[ -f Microsoft.PowerShell_profile.ps1 ]]; then
        safe_copy_user Microsoft.PowerShell_profile.ps1 "$powershell_dir/Microsoft.PowerShell_profile.ps1"
        log "INFO" "PowerShell profile set up for Azure environment"
    else
        log "WARN" "PowerShell profile not found in dotfiles"
    fi
else
    log "INFO" "Standard environment detected"
    if command_exists az; then
        log "INFO" "Configuring Azure CLI auto-upgrade..."
        run_as_user "az config set auto-upgrade.enable=yes --only-show-errors" || log "WARN" "Failed to set Azure CLI auto-upgrade"
        run_as_user "az config set auto-upgrade.prompt=no --only-show-errors" || log "WARN" "Failed to set Azure CLI prompt setting"
    fi

    powershell_dir="$TARGET_HOME/.config/powershell"
    safe_mkdir_user "$powershell_dir"

    log "INFO" "Copying PowerShell profile..."
    if [[ -f Microsoft.PowerShell_profile.ps1 ]]; then
        safe_copy_user Microsoft.PowerShell_profile.ps1 "$powershell_dir/Microsoft.PowerShell_profile.ps1"
        log "INFO" "PowerShell profile set up successfully"
    else
        log "WARN" "PowerShell profile not found in dotfiles"
    fi
fi

log "INFO" "Setting up Terraform version manager (tfenv)..."
tfenv_dir="$TARGET_HOME/.tfenv"

# Install tfenv with enhanced error checking
if git_clone_or_update_user "https://github.com/tfutils/tfenv.git" "$tfenv_dir" "--depth=1"; then
    # Verify tfenv installation
    if [[ -f "$tfenv_dir/bin/tfenv" ]]; then
        log "INFO" "tfenv cloned successfully, verifying installation..."
        
        # Make sure tfenv binary is executable
        chmod +x "$tfenv_dir/bin/tfenv" 2>/dev/null || true
        
        # Test that tfenv is functional
        if run_as_user_with_home "'$tfenv_dir/bin/tfenv' --version" >/dev/null 2>&1; then
            log "INFO" "tfenv installation verified successfully"
            
            # Initialize tfenv
            log "INFO" "Initializing tfenv..."
            if run_as_user_with_home "'$tfenv_dir/bin/tfenv' init" 2>&1; then
                log "INFO" "tfenv initialized successfully"
            else
                log "WARN" "tfenv init failed or already initialized"
            fi
            
            # Install latest Terraform version
            log "INFO" "Installing latest Terraform version..."
            if run_as_user_with_home "'$tfenv_dir/bin/tfenv' install" 2>&1; then
                log "INFO" "Latest Terraform version installed successfully"
                
                # Set the installed version as active
                log "INFO" "Setting Terraform version..."
                if run_as_user_with_home "'$tfenv_dir/bin/tfenv' use" 2>&1; then
                    log "INFO" "Terraform version set successfully"
                    
                    # Verify final installation
                    if run_as_user_with_home "'$tfenv_dir/bin/terraform' version" >/dev/null 2>&1; then
                        log "INFO" "Terraform version manager setup completed and verified"
                    else
                        log "WARN" "tfenv installed but terraform command may not be working properly"
                    fi
                else
                    log "WARN" "tfenv use failed - terraform version may not be set"
                fi
            else
                log "WARN" "tfenv install failed - no Terraform version installed"
            fi
        else
            log "ERROR" "tfenv binary is not functional after installation"
        fi
    else
        log "ERROR" "tfenv binary not found after clone: $tfenv_dir/bin/tfenv"
        log "INFO" "tfenv directory contents: $(ls -la "$tfenv_dir" 2>/dev/null || echo 'directory not accessible')"
    fi
else
    log "ERROR" "Failed to clone tfenv repository"
    log "INFO" "Terraform version manager installation failed"
    log "INFO" "You can install tfenv manually later with:"
    log "INFO" "  git clone https://github.com/tfutils/tfenv.git ~/.tfenv"
fi

# Ensure all expected directories exist (fallback for cloud-init compatibility)
if [[ "$CLOUD_INIT_MODE" == "true" ]]; then
    log "INFO" "Ensuring all expected directories exist for cloud-init compatibility..."
    
    # Create directories that might be missing due to failed network operations or plugin installations
    safe_mkdir_user "$TARGET_HOME/.azure"
    safe_mkdir_user "$TARGET_HOME/.oh-my-posh"
    safe_mkdir_user "$TARGET_HOME/.oh-my-posh/themes"
    safe_mkdir_user "$TARGET_HOME/.oh-my-zsh"
    safe_mkdir_user "$TARGET_HOME/.oh-my-zsh/custom"
    safe_mkdir_user "$TARGET_HOME/.oh-my-zsh/custom/plugins"
    safe_mkdir_user "$TARGET_HOME/.tfenv"
    safe_mkdir_user "$TARGET_HOME/.tfenv/bin"
    safe_mkdir_user "$TARGET_HOME/.tmux"
    safe_mkdir_user "$TARGET_HOME/.tmux/plugins" 
    safe_mkdir_user "$TARGET_HOME/.vim"
    safe_mkdir_user "$TARGET_HOME/.vim/pack"
    safe_mkdir_user "$TARGET_HOME/.vim/pack/plugin"
    safe_mkdir_user "$TARGET_HOME/.vim/pack/plugin/start"
    safe_mkdir_user "$TARGET_HOME/.vim/pack/themes"
    safe_mkdir_user "$TARGET_HOME/.vim/pack/themes/start"
    safe_mkdir_user "$TARGET_HOME/.vscode"
    safe_mkdir_user "$TARGET_HOME/.vscode-insiders"
    safe_mkdir_user "$TARGET_HOME/.vscode-server"
    safe_mkdir_user "$TARGET_HOME/.vscode-server-insiders"
    
    # Create empty .z file if it doesn't exist (for z jump tool)
    if [[ ! -f "$TARGET_HOME/.z" ]]; then
        touch "$TARGET_HOME/.z"
        set_ownership "$TARGET_HOME/.z"
    fi
    
    log "INFO" "Cloud-init directory structure validation completed"
    
    # Verify all expected directories were actually created
    verify_directory_structure
fi

# Verify directory structure function
verify_directory_structure() {
    log "INFO" "Verifying directory structure..."
    
    local missing_dirs=()
    local expected_dirs=(
        ".azure"
        ".cache"
        ".claude"
        ".config"
        ".local"
        ".local/bin"
        ".oh-my-posh"
        ".oh-my-posh/themes"
        ".oh-my-zsh"
        ".oh-my-zsh/custom"
        ".oh-my-zsh/custom/plugins"
        ".tfenv"
        ".tfenv/bin"
        ".tmux"
        ".tmux/plugins"
        ".vim"
        ".vim/pack"
        ".vim/pack/plugin"
        ".vim/pack/plugin/start"
        ".vim/pack/themes"
        ".vim/pack/themes/start"
        ".vscode"
        ".vscode-insiders"
        ".vscode-server"
        ".vscode-server-insiders"
    )
    
    for dir in "${expected_dirs[@]}"; do
        if [[ ! -d "$TARGET_HOME/$dir" ]]; then
            missing_dirs+=("$dir")
            log "WARN" "Directory missing: $TARGET_HOME/$dir"
        fi
    done
    
    # Check for .z file
    if [[ ! -f "$TARGET_HOME/.z" ]]; then
        log "WARN" "File missing: $TARGET_HOME/.z"
    fi
    
    if [[ ${#missing_dirs[@]} -gt 0 ]]; then
        log "ERROR" "The following directories are missing: ${missing_dirs[*]}"
        log "INFO" "Attempting to create missing directories..."
        for dir in "${missing_dirs[@]}"; do
            safe_mkdir_user "$TARGET_HOME/$dir"
        done
        log "INFO" "Retry completed for missing directories"
    else
        log "INFO" "All expected directories verified successfully"
    fi
}

# Commented out PowerShell module installation
# This would require PowerShell to be installed and may need user interaction
#if run_as_user "command -v pwsh >/dev/null 2>&1"; then
#    log "INFO" "Installing PowerShell modules..."
#    run_as_user 'pwsh -NoProfile -NonInteractive -Command "Install-Module -Name Terminal-Icons -Repository PSGallery -AllowClobber -Force"' || log "WARN" "Failed to install Terminal-Icons module"
#    run_as_user 'pwsh -NoProfile -NonInteractive -Command "Install-Module -Name z -Repository PSGallery -AllowClobber -Force"' || log "WARN" "Failed to install z module"
#fi

# Generate comprehensive installation summary
generate_installation_summary() {
    log "INFO" "=== DOTFILES INSTALLATION SUMMARY ==="
    log "INFO" "Installation completed for user: $TARGET_USER"
    log "INFO" "Configuration installed to: $TARGET_HOME"
    
    # Check status of major components
    local summary_items=()
    
    # TMux plugins
    if [[ -f "$TARGET_HOME/.tmux/plugins/tpm/tpm" ]]; then
        summary_items+=("✓ TMux Plugin Manager (TPM): Successfully installed")
    else
        summary_items+=("✗ TMux Plugin Manager (TPM): Installation failed")
    fi
    
    # Vim plugins
    local vim_plugin_count
    vim_plugin_count=$(find "$TARGET_HOME/.vim/pack/plugin/start" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    if [[ $vim_plugin_count -gt 0 ]]; then
        summary_items+=("✓ Vim Plugins: $vim_plugin_count plugins installed")
    else
        summary_items+=("✗ Vim Plugins: No plugins found")
    fi
    
    # Zsh plugins
    if [[ -d "$TARGET_HOME/.oh-my-zsh" ]]; then
        local zsh_plugin_count
        zsh_plugin_count=$(find "$TARGET_HOME/.oh-my-zsh/custom/plugins" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        if [[ $zsh_plugin_count -gt 0 ]]; then
            summary_items+=("✓ Oh My Zsh: Installed with $zsh_plugin_count custom plugins")
        else
            summary_items+=("! Oh My Zsh: Installed but no custom plugins found")
        fi
    else
        summary_items+=("✗ Oh My Zsh: Installation failed")
    fi
    
    # tfenv
    if [[ -f "$TARGET_HOME/.tfenv/bin/tfenv" ]]; then
        summary_items+=("✓ Terraform Version Manager (tfenv): Successfully installed")
    else
        summary_items+=("✗ Terraform Version Manager (tfenv): Installation failed")
    fi
    
    # Claude configuration
    if [[ -d "$TARGET_HOME/.claude" ]]; then
        summary_items+=("✓ Claude Code Configuration: Successfully deployed")
    else
        summary_items+=("✗ Claude Code Configuration: Deployment failed")
    fi
    
    # VSCode configuration
    if [[ -d "$TARGET_HOME/.vscode" ]]; then
        summary_items+=("✓ VSCode Configuration: Successfully deployed")
    else
        summary_items+=("✗ VSCode Configuration: Deployment failed")
    fi
    
    # Print summary
    for item in "${summary_items[@]}"; do
        if [[ "$item" =~ ^✓ ]]; then
            log "INFO" "$item"
        elif [[ "$item" =~ ^! ]]; then
            log "WARN" "$item"
        else
            log "ERROR" "$item"
        fi
    done
    
    log "INFO" "======================================"
}

# Generate and display installation summary
generate_installation_summary

log "INFO" "Dotfiles installation completed!"

if [[ "$CLOUD_INIT_MODE" == "true" ]]; then
    log "INFO" "Cloud-init installation completed for user: $TARGET_USER"
    log "INFO" "The user should restart their terminal or run 'source ~/.zshrc' to apply changes."
else
    log "INFO" "Manual installation completed for user: $TARGET_USER"
    log "INFO" "Please restart your terminal or run 'source ~/.zshrc' to apply all changes."
fi

# If running as root for another user, provide additional information
if [[ "$EUID" -eq 0 ]] && [[ "$SCRIPT_USER" != "$TARGET_USER" ]]; then
    log "INFO" "Files have been installed with proper ownership for user: $TARGET_USER"
    log "INFO" "The target user should log in and restart their shell to see the changes."
fi

# Provide troubleshooting information if there were failures
log "INFO" "If any components failed to install:"
log "INFO" "1. Check your network connectivity"
log "INFO" "2. Ensure git is installed and accessible"
log "INFO" "3. Verify you have proper permissions"
log "INFO" "4. Re-run the script with DEBUG=1 for detailed diagnostics"
log "INFO" "5. Check the installation logs above for specific error messages"
