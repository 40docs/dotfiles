# Personal Dotfiles

A portable developer environment configuration repository for rapid, reproducible setup across machines, dev containers, and cloud-init automation.

## 🚀 Quick Start

```bash
# Clone the repository
git clone https://github.com/40docs/dotfiles.git
cd dotfiles

# Install all configurations and tools
bash install.sh
```

## 📁 What's Included

### Configuration Files
- **`.vimrc`** - Vim editor configuration with plugins and themes
- **`.tmux.conf`** - Terminal multiplexer settings
- **`.zshrc`** - Zsh shell configuration
- **`.p10k.zsh`** - Powerlevel10k prompt theme
- **`.digrc`** - DNS lookup tool configuration
- **`.opencommit`** - AI-powered commit message configuration
- **`.act`** - GitHub Actions local runner configuration

### Development Tools
- **VSCode Settings** (`.vscode/`) - Editor preferences and extensions
- **PowerShell Profile** - Cross-platform PowerShell configuration
- **iTerm2 Colors** - Terminal color scheme
- **Oh My Posh Theme** - Cross-shell prompt customization

### Automated Setup
- **Vim Plugins** - airline, nerdtree, fzf, gitgutter, fugitive, polyglot, terraform
- **Zsh Plugins** - autosuggestions, syntax-highlighting, conda completion, tfenv, lsd aliases
- **Development Tools** - tfenv (Terraform version manager), lsd (modern ls), fonts

## 🔧 Installation Features

- **🤖 Fully Automated** - No user prompts, perfect for CI/CD and cloud-init
- **📊 Verbose Logging** - All errors and progress visible in logs
- **🔄 Idempotent** - Safe to run multiple times
- **🌐 Cross-Platform** - Handles Linux, macOS, and cloud environments
- **⚡ Cloud-Ready** - Environment variable handling for automated deployments

## 🐳 Dev Container Support

This repository includes a dev container configuration for consistent development environments:

```bash
# Using VS Code
code .
# Select "Reopen in Container" when prompted

# Using GitHub Codespaces
# Click "Code" → "Codespaces" → "Create codespace"
```

The dev container uses `ghcr.io/40docs/devcontainer:latest` with all tools pre-installed.

## ☁️ Cloud-Init Integration

Perfect for automated server setup and cloud deployments:

```yaml
#cloud-config
packages:
  - git
  - curl
  - zsh

runcmd:
  - |
    cd /tmp
    git clone https://github.com/40docs/dotfiles.git
    cd dotfiles
    # Use --cloud-init flag for proper user detection and ownership
    bash install.sh --cloud-init
    rm -rf /tmp/dotfiles
```

## 🔍 What Gets Installed

### Shell Environment
- **Oh My Zsh** with custom plugins and themes
- **Oh My Posh** prompt with Powerlevel10k theme
- **Meslo Nerd Font** for proper icon display
- **Azure CLI completion** and auto-upgrade configuration

### Development Tools
- **Terraform Version Manager (tfenv)** for managing Terraform versions
- **Modern ls replacement (lsd)** with enhanced file listing
- **Z jump tool** for fast directory navigation
- **Various Zsh productivity plugins**

### Editor Setup
- **Vim** with comprehensive plugin ecosystem
- **VSCode** settings and preferences
- **Tmux** terminal multiplexer configuration

### Cloud & DevOps
- **PowerShell profiles** for both Azure and standard environments
- **Conda initialization** (if present)
- **Azure CLI** optimization

## 🛠️ Customization

The script automatically detects your environment and adapts:

- **Platform Detection** - Linux-specific tools only install on Linux
- **Environment Awareness** - Different PowerShell profiles for Azure vs standard
- **Conditional Setup** - Only configures tools that are present (Conda, Azure CLI, etc.)

## 📋 Requirements

- **bash** (for running the installer)
- **curl** (for downloading tools and plugins)
- **git** (for cloning repositories)

Additional tools are installed automatically as needed.

## 🔧 Troubleshooting

All operations redirect errors to stdout for easy debugging:

```bash
# Run with verbose output
bash -x install.sh

# Check specific sections
bash install.sh 2>&1 | grep "ERROR\|FAIL"
```

The script provides detailed logging with context-specific messages for each installation step.

## 🤝 Contributing

Feel free to fork and customize for your own needs. The installation script follows clear patterns for adding new tools and configurations.

## 📚 References

Inspired by and built upon best practices from:
- [Jamie's Dev Setup](https://medium.com/@jamiekt/my-dev-setup-march-2022-e89d21b19fe6)
- [VSCode DevContainer with Zsh](https://medium.com/@jamiekt/vscode-devcontainer-with-zsh-oh-my-zsh-and-agnoster-theme-8adf884ad9f6)
- [VSCode Dev Containers Guide](https://benmatselby.dev/post/vscode-dev-containers/)
- [Zsh in Docker](https://github.com/deluan/zsh-in-docker)

---

**💡 Pro Tip**: After installation, restart your terminal or run `source ~/.zshrc` to apply all changes.
