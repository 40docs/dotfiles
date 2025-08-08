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

    # Check if running as root (typical in cloud-init)
    if [[ "$EUID" -eq 0 ]]; then
        log "INFO" "Running as root - cloud-init or sudo execution detected"
        CLOUD_INIT_MODE=true
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
        if [[ "$CLOUD_INIT_MODE" == "true" && "$EUID" -eq 0 ]]; then
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
        TARGET_HOME="$(get_user_home "$TARGET_USER")"
    fi

    # Validate home directory
    if [[ ! -d "$TARGET_HOME" ]]; then
        log "ERROR" "Home directory '$TARGET_HOME' does not exist"
        exit 1
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

# Install plugin collection from associative array
install_plugin_collection() {
    local -n plugin_array=$1
    local base_dir="$2"
    local description="$3"
    
    log "INFO" "Installing $description..."
    for plugin in "${!plugin_array[@]}"; do
        local plugin_dir="$base_dir/$plugin"
        local clone_args=""
        
        # Special handling for plugins that need shallow clone
        if [[ "$plugin" == "vim-polyglot" ]]; then
            clone_args="--depth 1"
        fi
        
        git_clone_or_update_user "${plugin_array[$plugin]}" "$plugin_dir" "$clone_args"
    done
}

# Set up error trap
trap 'handle_error $LINENO' ERR

# Network operation with retry
retry_network_operation() {
    local max_attempts=3
    local delay=2
    local attempt=1
    local command=("$@")

    while [[ $attempt -le $max_attempts ]]; do
        if "${command[@]}"; then
            return 0
        else
            log "WARN" "Network operation failed (attempt $attempt/$max_attempts)"
            if [[ $attempt -lt $max_attempts ]]; then
                sleep $delay
                ((delay *= 2))  # Exponential backoff
            fi
            ((attempt++))
        fi
    done

    log "ERROR" "Network operation failed after $max_attempts attempts"
    return 2
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
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
    if command_exists getent; then
        # Linux with getent
        getent passwd "$user" | cut -d: -f6
    elif [[ "$(uname)" == "Darwin" ]]; then
        # macOS
        dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
    else
        # Fallback
        eval echo "~$user"
    fi
}

# Cross-platform get user by UID
get_user_by_uid() {
    local uid="$1"
    if command_exists getent; then
        # Linux with getent
        getent passwd "$uid" | cut -d: -f1
    elif [[ "$(uname)" == "Darwin" ]]; then
        # macOS
        dscl . -search /Users UniqueID "$uid" 2>/dev/null | head -1 | awk '{print $1}'
    else
        # Fallback
        id -un "$uid" 2>/dev/null
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

# Execute command as target user with proper HOME environment
run_as_user_with_home() {
    local cmd="$*"

    if [[ "$SCRIPT_USER" == "$TARGET_USER" ]]; then
        # Same user, execute directly
        eval "$cmd"
    elif [[ "$EUID" -eq 0 ]]; then
        # Running as root, switch to target user with proper environment
        sudo -u "$TARGET_USER" -H bash -c "cd '$TARGET_HOME' && $cmd"
    else
        log "ERROR" "Cannot switch to user '$TARGET_USER' without root privileges"
        return 4
    fi
}

# Create directory with proper ownership
safe_mkdir_user() {
    local dir="$1"

    if [[ ! -d "$dir" ]]; then
        log "INFO" "Creating directory: $dir"
        mkdir -p "$dir" || {
            log "ERROR" "Failed to create directory: $dir"
            return 3
        }

        # Set proper ownership if running as root
        set_ownership "$dir" true
    fi
}

# Copy file with proper ownership
safe_copy_user() {
    local src="$1"
    local dest="$2"
    local backup_ext
    backup_ext=".backup.$(date +%Y%m%d_%H%M%S)"

    verify_file "$src"

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

# Git clone or update with user context
git_clone_or_update_user() {
    local repo_url="$1"
    local target_dir="$2"
    local clone_args="${3:-}"

    if [[ ! -d "$target_dir" ]]; then
        log "INFO" "Cloning $repo_url to $target_dir"
        # Ensure parent directory exists with proper ownership
        safe_mkdir_user "$(dirname "$target_dir")"

        run_as_user_with_home "git clone $clone_args '$repo_url' '$target_dir'" || {
            # If git clone fails, try with retry
            retry_network_operation run_as_user_with_home "git clone $clone_args '$repo_url' '$target_dir'"
        }

        # Set ownership if running as root
        set_ownership "$target_dir" true
    else
        log "INFO" "Updating repository in $target_dir"
        # Enhanced git update with branch handling
        local update_cmd="cd '$target_dir' && git fetch origin --quiet && {
            # Get the default branch from remote
            default_branch=\$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo 'main')
            # Check if default branch exists locally
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
            git pull --quiet 2>/dev/null || git reset --hard origin/\$default_branch --quiet 2>/dev/null || true
        }"

        run_as_user_with_home "$update_cmd" || {
            log "WARN" "Git update failed for $target_dir, attempting fallback"
            # Fallback: try a simple pull, and if that fails, reset to origin
            run_as_user_with_home "cd '$target_dir' && (git pull --quiet || git fetch --quiet && git reset --hard origin/HEAD --quiet)" || {
                log "WARN" "Repository update failed for $target_dir, but continuing installation"
            }
        }
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
            sed -i "s|export PATH=\$PATH:[^:]*${TARGET_USER}[^:]*\.local/bin|${home_localbin_export}|g" "$shellrc"
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

log "INFO" "VSCode shell integration setup completed"

log "INFO" "Starting dotfiles installation..."
log "INFO" "Working directory: ${DOTFILEDIR}"

log "INFO" "Copying configuration files to home directory..."

# Update ZSH theme if .zshrc exists
if [[ -f "$TARGET_HOME/.zshrc" ]]; then
    sed -i 's/^ZSH_THEME="[^"]*"/ZSH_THEME="agnoster"/' "$TARGET_HOME/.zshrc"
fi

# List of configuration files to copy
declare -a config_files=(
    ".vimrc"
    ".opencommit"
    ".act"
    ".tmux.conf"
    ".p10k.zsh"
    ".digrc"
)

# Copy configuration files safely
for config_file in "${config_files[@]}"; do
    if [[ -f "$config_file" ]]; then
        safe_copy_user "$config_file" "$TARGET_HOME/$config_file"
    else
        log "WARN" "Configuration file not found: $config_file"
    fi
done

log "INFO" "Configuration files copied successfully"

# --- Claude config setup ---
claude_dir="$TARGET_HOME/.claude"
claude_settings_src="./claude/settings.json"
claude_settings_dest="$claude_dir/settings.json"

# Create ~/.claude if it does not exist
if [[ ! -d "$claude_dir" ]]; then
    safe_mkdir_user "$claude_dir"
    log "INFO" "Created $claude_dir directory."
fi

# Copy settings.json if present
if [[ -f "$claude_settings_src" ]]; then
    safe_copy_user "$claude_settings_src" "$claude_settings_dest"
    log "INFO" "Copied $claude_settings_src to $claude_settings_dest."
else
    log "WARN" "$claude_settings_src not found, skipping Claude settings copy."
fi

log "INFO" "Setting up VSCode configuration..."
vscode_dir="$TARGET_HOME/.vscode"

if [[ -d "$vscode_dir" ]]; then
    log "INFO" "Backing up existing $vscode_dir directory..."
    backup_ext=".backup.$(date +%Y%m%d_%H%M%S)"
    mv "$vscode_dir" "$vscode_dir$backup_ext"
    set_ownership "$vscode_dir$backup_ext" true
fi

if [[ -d .vscode ]]; then
    cp -a .vscode "$vscode_dir"
    set_ownership "$vscode_dir" true
    log "INFO" "VSCode configuration set up successfully"
else
    log "WARN" "VSCode configuration directory not found in dotfiles"
fi

#if ! [ -d ~/.continue ]; then
#  mkdir -p ~/.continue
#fi
#cp .continue/config.json ~/.continue

log "INFO" "Setting up tmux plugins..."
safe_mkdir_user "$TARGET_HOME/.tmux/plugins"

git_clone_or_update_user "https://github.com/tmux-plugins/tpm" "$TARGET_HOME/.tmux/plugins/tpm"
log "INFO" "Tmux plugins set up successfully"

log "INFO" "Setting up Vim plugins and themes..."
safe_mkdir_user "$TARGET_HOME/.vim/pack/plugin/start"
safe_mkdir_user "$TARGET_HOME/.vim/pack/themes/start"

# Check bash version for associative array support
if (( BASH_VERSINFO[0] < 4 )); then
    log "WARN" "Bash version ${BASH_VERSION} detected. Associative arrays require Bash 4+. Skipping Vim plugin installation."
    log "INFO" "To enable Vim plugin installation, please install Bash 4+ (e.g., 'brew install bash' on macOS)"
else
    # Vim plugins configuration
    declare -A vim_plugins=(
        ["vim-airline"]="https://github.com/vim-airline/vim-airline"
        ["nerdtree"]="https://github.com/preservim/nerdtree.git"
        ["fzf"]="https://github.com/junegunn/fzf.vim.git"
        ["vim-gitgutter"]="https://github.com/airblade/vim-gitgutter.git"
        ["vim-fugitive"]="https://github.com/tpope/vim-fugitive.git"
        ["vim-terraform"]="https://github.com/hashivim/vim-terraform.git"
    )

    # Vim themes configuration
    declare -A vim_themes=(
        ["vim-code-dark"]="https://github.com/tomasiser/vim-code-dark"
    )

    # Install/update Vim plugins and themes
    install_plugin_collection vim_plugins "$TARGET_HOME/.vim/pack/plugin/start" "Vim plugins"
    install_plugin_collection vim_themes "$TARGET_HOME/.vim/pack/themes/start" "Vim themes"
    
    # Special handling for vim-polyglot with shallow clone
    git_clone_or_update_user "https://github.com/sheerun/vim-polyglot" \
        "$TARGET_HOME/.vim/pack/plugin/start/vim-polyglot" "--depth 1"
fi

log "INFO" "Vim plugins and themes set up successfully"

log "INFO" "Setting up Zsh and Oh My Zsh..."
oh_my_zsh_dir="$TARGET_HOME/.oh-my-zsh"

if [[ ! -d "$oh_my_zsh_dir" ]]; then
    log "INFO" "Installing Oh My Zsh..."
    # Download and install Oh My Zsh as the target user
    run_as_user_with_home 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended' || {
        # Retry with network retry logic
        retry_network_operation run_as_user_with_home 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
    }
else
    log "INFO" "Oh My Zsh already installed"
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

    # Install/update Zsh plugins
    install_plugin_collection zsh_plugins "$oh_my_zsh_dir/custom/plugins" "Zsh plugins"
else
    log "WARN" "Bash version ${BASH_VERSION} detected. Installing Zsh plugins individually without associative arrays."

    # Install plugins individually
    git_clone_or_update_user "https://github.com/zsh-users/zsh-autosuggestions.git" "$oh_my_zsh_dir/custom/plugins/zsh-autosuggestions"
    git_clone_or_update_user "https://github.com/zsh-users/zsh-syntax-highlighting.git" "$oh_my_zsh_dir/custom/plugins/zsh-syntax-highlighting"
    git_clone_or_update_user "https://github.com/conda-incubator/conda-zsh-completion.git" "$oh_my_zsh_dir/custom/plugins/conda-zsh-completion"
    git_clone_or_update_user "https://github.com/cda0/zsh-tfenv.git" "$oh_my_zsh_dir/custom/plugins/zsh-tfenv"
    git_clone_or_update_user "https://github.com/yuhonas/zsh-aliases-lsd.git" "$oh_my_zsh_dir/custom/plugins/zsh-aliases-lsd"
fi

log "INFO" "Downloading Azure CLI completion..."
az_completion_file="$oh_my_zsh_dir/custom/az.zsh"
run_as_user_with_home "curl -fsSL 'https://raw.githubusercontent.com/Azure/azure-cli/dev/az.completion' -o '$az_completion_file'" || {
    retry_network_operation run_as_user_with_home "curl -fsSL 'https://raw.githubusercontent.com/Azure/azure-cli/dev/az.completion' -o '$az_completion_file'"
}
set_ownership "$az_completion_file"

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
safe_mkdir_user "$TARGET_HOME/.local/bin"
safe_mkdir_user "$TARGET_HOME/.oh-my-posh/themes"

log "INFO" "Installing Oh My Posh..."
# Install Oh My Posh as the target user
run_as_user_with_home "curl -s https://ohmyposh.dev/install.sh | bash -s -- -d '$TARGET_HOME/.local/bin' -t '$TARGET_HOME/.oh-my-posh/themes'" || {
    retry_network_operation run_as_user_with_home "curl -s https://ohmyposh.dev/install.sh | bash -s -- -d '$TARGET_HOME/.local/bin' -t '$TARGET_HOME/.oh-my-posh/themes'"
}

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
            safe_mkdir_user "$TARGET_HOME/.local/bin"

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

git_clone_or_update_user "https://github.com/tfutils/tfenv.git" "$tfenv_dir" "--depth=1"

log "INFO" "Initializing tfenv..."
run_as_user_with_home "'$tfenv_dir/bin/tfenv' init" 2>&1 || log "WARN" "tfenv init failed or already initialized"

log "INFO" "Installing latest Terraform version..."
run_as_user_with_home "'$tfenv_dir/bin/tfenv' install" 2>&1 || log "WARN" "tfenv install failed or already installed"

log "INFO" "Setting Terraform version..."
run_as_user_with_home "'$tfenv_dir/bin/tfenv' use" 2>&1 || log "WARN" "tfenv use failed or version already set"

log "INFO" "Terraform version manager set up successfully"

# Commented out PowerShell module installation
# This would require PowerShell to be installed and may need user interaction
#if run_as_user "command -v pwsh >/dev/null 2>&1"; then
#    log "INFO" "Installing PowerShell modules..."
#    run_as_user 'pwsh -NoProfile -NonInteractive -Command "Install-Module -Name Terminal-Icons -Repository PSGallery -AllowClobber -Force"' || log "WARN" "Failed to install Terminal-Icons module"
#    run_as_user 'pwsh -NoProfile -NonInteractive -Command "Install-Module -Name z -Repository PSGallery -AllowClobber -Force"' || log "WARN" "Failed to install z module"
#fi

log "INFO" "Dotfiles installation completed successfully!"

if [[ "$CLOUD_INIT_MODE" == "true" ]]; then
    log "INFO" "Cloud-init installation completed for user: $TARGET_USER"
    log "INFO" "Configuration installed to: $TARGET_HOME"
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
