# Wan2GP Dockerfile - Güncel Versiyon
# PyTorch base image with CUDA support
FROM pytorch/pytorch:2.7.1-cuda12.8-cudnn9-devel

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    ffmpeg \
    wget \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Clone the latest Wan2GP repository
RUN git clone https://github.com/deepbeepmeep/Wan2GP.git .

# Install Python dependencies
RUN pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128
RUN pip3 install -r requirements.txt

# Install optional performance enhancements
RUN pip3 install sageattention==1.0.6 || echo "SageAttention installation failed, continuing..."
RUN pip3 install flash-attn==2.7.2.post1 || echo "Flash attention installation failed, continuing..."

# Create necessary directories
RUN mkdir -p /app/ckpts /app/outputs /app/settings /app/loras \
    /app/loras_hunyuan /app/loras_hunyuan_i2v /app/loras_i2v /app/loras_ltxv

# Copy the start script
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# Expose the default port
EXPOSE 7860

# Set environment variables
ENV PYTHONUNBUFFERED=1
ENV CUDA_VISIBLE_DEVICES=0

# Use the start script as entrypoint
ENTRYPOINT ["/app/start.sh"]