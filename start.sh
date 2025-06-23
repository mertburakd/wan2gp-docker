#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

echo "🚀 Wan2GP Container Started - All-in-One Setup"
echo "=============================================="
echo "Timestamp: $(date)"

# --- Ensure /app directory exists ---
echo "📁 Ensuring /app directory exists..."
if [ ! -d "/app" ]; then
    echo "Creating /app directory..."
    mkdir -p /app
    echo "✅ /app directory created"
fi

# --- Check if we need to clone the repository ---
echo "📦 Checking Wan2GP repository..."
if [ ! -f "/app/wgp.py" ]; then
    echo "Repository not found. Cloning latest Wan2GP..."
    cd /app
    git clone https://github.com/deepbeepmeep/Wan2GP.git temp_repo
    
    # Move contents from temp directory to /app
    mv temp_repo/* . 2>/dev/null || true
    mv temp_repo/.* . 2>/dev/null || true
    rm -rf temp_repo
    
    echo "✅ Repository cloned successfully"
else
    echo "✅ Repository already exists"
fi

# --- Update repository if needed ---
echo "🔄 Checking for updates..."
cd /app
if [ -d ".git" ]; then
    git fetch origin
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse origin/main)
    
    if [ "$LOCAL" != "$REMOTE" ]; then
        echo "🆕 Updates available. Pulling latest changes..."
        git pull origin main
        echo "✅ Repository updated"
    else
        echo "✅ Repository is up to date"
    fi
fi

# --- Install/Update Python Dependencies ---
echo "🐍 Setting up Python environment..."
echo "Using Python from base PyTorch image (Conda environment)."

# Check if requirements.txt exists and install dependencies
if [ -f "requirements.txt" ]; then
    echo "📋 Installing/updating Python dependencies..."
    
    # Install PyTorch if not present - RTX 3080 Ti Stable Version
    python -c "import torch" 2>/dev/null || {
        echo "Installing PyTorch 2.6.0 for RTX 3080 Ti..."
        pip3 install torch==2.6.0 torchvision torchaudio --index-url https://download.pytorch.org/whl/test/cu124
    }
    
    # Install requirements
    pip3 install -r requirements.txt
    
    # Install optional performance enhancements - RTX 3080 Ti optimized
    echo "🚀 Installing performance enhancements for RTX 3080 Ti..."
    
    # SageAttention - 30% hız artışı, hızlı kurulum
    pip3 install sageattention==1.0.6 || echo "⚠️  SageAttention installation failed, continuing..."
    
    # Flash Attention - Sadece precompiled wheel kullan, compile etme
    echo "🔧 Checking for precompiled Flash Attention wheel..."
    pip3 install flash-attn==2.7.2.post1 --no-build-isolation || echo "⚠️  Flash attention precompiled wheel not available, skipping compilation to save time..."
    
    echo "✅ Dependencies installed"
else
    echo "⚠️  requirements.txt not found, skipping dependency installation"
fi

# --- Environment Sanity Checks ---
echo "--- Environment Checks ---"
echo "User: $(whoami)"
echo "Workdir: $(pwd)" # Should be /app
echo "Python version: $(python --version)"
echo "PyTorch version: $(python -c 'import torch; print(torch.__version__)' 2>/dev/null || echo 'Not installed')"
echo "CUDA available: $(python -c 'import torch; print(torch.cuda.is_available())' 2>/dev/null || echo 'Cannot check')"
if python -c 'import torch; exit(not torch.cuda.is_available())' 2>/dev/null; then
    echo "CUDA device count: $(python -c 'import torch; print(torch.cuda.device_count())')"
    if [ "$(python -c 'import torch; print(torch.cuda.device_count())')" -gt "0" ]; then
      echo "Current CUDA device: $(python -c 'import torch; print(torch.cuda.current_device())')"
      echo "Device name: $(python -c 'import torch; print(torch.cuda.get_device_name(torch.cuda.current_device()))')"
    fi
else
    echo "WARNING: PyTorch cannot find CUDA. Check GPU drivers, Docker runtime, and base image."
fi
echo "NVIDIA SMI:"
nvidia-smi || echo "nvidia-smi command not found or failed."
echo "------------------------"

# --- Define Key Application Paths (these are the paths wgp.py expects or that we will manage) ---
APP_BASE_DIR="/app"
APP_CKPTS_DIR="${APP_BASE_DIR}/ckpts"
APP_OUTPUTS_DIR="${APP_BASE_DIR}/outputs" # wgp.py writes here by default
APP_SETTINGS_DIR="${APP_BASE_DIR}/settings"
APP_LORAS_DIR="${APP_BASE_DIR}/loras" # Central LoRA directory

# Specific LoRA type paths that wgp.py might expect (these will be symlinked to APP_LORAS_DIR)
APP_LORAS_HUNYUAN_DIR="${APP_BASE_DIR}/loras_hunyuan"
APP_LORAS_HUNYUAN_I2V_DIR="${APP_BASE_DIR}/loras_hunyuan_i2v"
APP_LORAS_I2V_DIR="${APP_BASE_DIR}/loras_i2v"
APP_LORAS_LTXV_DIR="${APP_BASE_DIR}/loras_ltxv"

# Helper function to handle symlinking a managed directory with a mountpoint check
# and auto-creation of the W2GP_ specified path if it doesn't exist.
# Usage: handle_managed_dir TARGET_APP_PATH W2GP_ENV_VAR_VALUE W2GP_ENV_VAR_NAME
handle_managed_dir() {
    local target_dir="$1" # e.g., /app/loras (the path inside /app)
    local w2gp_value="$2" # e.g., value of $W2GP_LORAS (can be empty, e.g. /workspace/Wan2GP/Loras)
    local w2gp_name="$3"  # e.g., "W2GP_LORAS"

    if [ -n "$w2gp_value" ]; then # If the W2GP_ environment variable is set
        echo "${w2gp_name} is set to '$w2gp_value'."

        # Check if the directory specified by w2gp_value exists, and create it if it doesn't.
        # This applies to the path on the persistent volume (e.g., /workspace/Wan2GP/Loras)
        if [ ! -d "$w2gp_value" ]; then
            echo "Directory '$w2gp_value' for ${w2gp_name} does not exist. Creating it..."
            mkdir -p "$w2gp_value"
            if [ $? -eq 0 ]; then
                echo "Successfully created directory '$w2gp_value'."
            else
                echo "ERROR: Failed to create directory '$w2gp_value'. Please check permissions and path."
                # Decide if you want to exit or continue with a broken symlink
                # exit 1 # Or just let it proceed to create a broken symlink
            fi
        else
            echo "Directory '$w2gp_value' for ${w2gp_name} already exists."
        fi

        is_mountpoint=false
        # Check if target_dir (e.g. /app/loras) is a mount point.
        # This detects if the user did a direct docker bind mount to /app/loras
        if command -v mountpoint >/dev/null && mountpoint -q "$target_dir"; then
            is_mountpoint=true
        fi

        if $is_mountpoint; then
            echo "INFO: ${target_dir} is a direct bind mount."
            echo "      The ${w2gp_name} environment variable ('$w2gp_value') will be IGNORED for symlinking ${target_dir}."
            echo "      The direct bind mount for ${target_dir} will be used."
            # Even if it's a mountpoint, the w2gp_value directory (e.g. /workspace/Wan2GP/Loras)
            # might still be useful if other logic in the app or user setup relies on it.
            # The creation logic above ensures it exists if specified.
        else
            echo "Symlinking ${target_dir} to '$w2gp_value'..."
            # This rm -rf removes the content from the image layer (e.g., README.txt in /app/loras)
            # to allow the path itself to become a symlink.
            rm -rf "${target_dir}"
            ln -s "$w2gp_value" "${target_dir}"
            echo "Symlinked ${target_dir} -> $w2gp_value"
        fi
    else
        # W2GP_ variable is not set for this path
        echo "${w2gp_name} is not set."
        # Special handling for APP_LORAS_DIR: ensure it exists if W2GP_LORAS is not set,
        # because other LoRA directories will be symlinked to it.
        # This is safe even if APP_LORAS_DIR is a direct bind mount (mkdir -p won't delete content).
        if [ "$target_dir" == "${APP_LORAS_DIR}" ]; then
            echo "Ensuring default ${target_dir} directory exists (for LoRA symlink targets)."
        fi
        
        # Create directory if it doesn't exist
        if [ ! -d "${target_dir}" ]; then
            mkdir -p "${target_dir}"
            echo "Created directory: ${target_dir}"
        fi

        echo "Using default application directory: ${target_dir}"
    fi
}

# --- Setup Application Directories ---
echo "--- Setting up Application Directories ---"
handle_managed_dir "${APP_CKPTS_DIR}" "${W2GP_MODELS}" "W2GP_MODELS"
handle_managed_dir "${APP_OUTPUTS_DIR}" "${W2GP_OUTPUTS}" "W2GP_OUTPUTS"
handle_managed_dir "${APP_SETTINGS_DIR}" "${W2GP_SETTINGS}" "W2GP_SETTINGS"
handle_managed_dir "${APP_LORAS_DIR}" "${W2GP_LORAS}" "W2GP_LORAS"

# --- Create LoRA Type Symlinks ---
# These symlinks ensure that wgp.py can find the proper LoRA directories regardless of which
# specific LoRA type it's looking for. They all point to the central APP_LORAS_DIR.
echo "Setting up specific LoRA type symlinks to point to ${APP_LORAS_DIR}..."
LORA_TYPE_TARGET_DIRS=(
    "${APP_LORAS_HUNYUAN_DIR}"
    "${APP_LORAS_HUNYUAN_I2V_DIR}"
    "${APP_LORAS_I2V_DIR}"
    "${APP_LORAS_LTXV_DIR}"
)
for lora_type_target_dir in "${LORA_TYPE_TARGET_DIRS[@]}"; do
    rm -rf "${lora_type_target_dir}"
    ln -s "${APP_LORAS_DIR}" "${lora_type_target_dir}"
    echo "Symlinked ${lora_type_target_dir} -> ${APP_LORAS_DIR}"
done

echo "Application directory and LoRA symlink setup complete."
echo "  Checkpoints/Models will use: ${APP_CKPTS_DIR} (resolved: $(readlink -f "${APP_CKPTS_DIR}" 2>/dev/null || echo "${APP_CKPTS_DIR}"))"
echo "  Outputs will use:            ${APP_OUTPUTS_DIR} (resolved: $(readlink -f "${APP_OUTPUTS_DIR}" 2>/dev/null || echo "${APP_OUTPUTS_DIR}"))"
echo "  Settings will use:           ${APP_SETTINGS_DIR} (resolved: $(readlink -f "${APP_SETTINGS_DIR}" 2>/dev/null || echo "${APP_SETTINGS_DIR}"))"
echo "  Central LoRA storage at:     ${APP_LORAS_DIR} (resolved: $(readlink -f "${APP_LORAS_DIR}" 2>/dev/null || echo "${APP_LORAS_DIR}"))"
echo "  Hunyuan LoRAs path:          ${APP_LORAS_HUNYUAN_DIR} (-> ${APP_LORAS_DIR})"
echo "  Hunyuan I2V LoRAs path:      ${APP_LORAS_HUNYUAN_I2V_DIR} (-> ${APP_LORAS_DIR})"
echo "  I2V LoRAs path:              ${APP_LORAS_I2V_DIR} (-> ${APP_LORAS_DIR})"
echo "  LTXV LoRAs path:             ${APP_LORAS_LTXV_DIR} (-> ${APP_LORAS_DIR})"
echo "------------------------"

# --- Construct Wan2GP Command ---
# Base command
COMMAND_ARGS=("python" "wgp.py")

# --- Handle "sticky default listen" ---
# Default to adding --listen, unless W2GP_LISTEN is explicitly "false"
add_listen_flag=true
if [ -n "$W2GP_LISTEN" ] && [[ "$W2GP_LISTEN" == "false" ]]; then
    echo "W2GP_LISTEN is set to 'false'. The --listen flag will be omitted."
    add_listen_flag=false
else
    if [ -n "$W2GP_LISTEN" ] && [[ "$W2GP_LISTEN" == "true" ]]; then
        echo "W2GP_LISTEN is set to 'true'. The --listen flag will be included."
    else
        echo "W2GP_LISTEN is not set or not 'false'. Defaulting to include --listen flag."
    fi
fi

if $add_listen_flag; then
    COMMAND_ARGS+=("--listen")
fi

# --- Handle other W2GP_ core arguments independently ---
# W2GP_PROFILE
if [ -n "$W2GP_PROFILE" ]; then
    COMMAND_ARGS+=("--profile" "$W2GP_PROFILE")
    echo "Using profile: $W2GP_PROFILE"
else
    echo "W2GP_PROFILE not set. wgp.py will use its default profile."
fi

# W2GP_SERVER_PORT
if [ -n "$W2GP_SERVER_PORT" ]; then
    COMMAND_ARGS+=("--server-port" "$W2GP_SERVER_PORT")
    echo "Using server port: $W2GP_SERVER_PORT"
fi

# W2GP_SERVER_NAME
if [ -n "$W2GP_SERVER_NAME" ]; then
    COMMAND_ARGS+=("--server-name" "$W2GP_SERVER_NAME")
    echo "Using server name: $W2GP_SERVER_NAME"
fi

# Add any other arguments passed via Dockerfile CMD or `docker run ... image cmd_arg1 cmd_arg2`
# These are appended after the W2GP-derived arguments.
if [ "$#" -gt 0 ]; then
    echo "Appending additional arguments from CMD/run: $@"
    COMMAND_ARGS+=("$@")
fi

echo "--- Starting Wan2GP ---"
echo "Final command to be executed: ${COMMAND_ARGS[*]}"
echo "🌐 Application will be available at http://localhost:7860"
echo "========================"

# Execute the command
exec "${COMMAND_ARGS[@]}"