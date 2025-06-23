# Wan2GP Dockerfile - RTX 3080 Ti Optimized Setup
# PyTorch base image with CUDA support
FROM pytorch/pytorch:2.6.0-cuda12.4-cudnn9-devel

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    ffmpeg \
    wget \
    curl \
    unzip \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Copy the start script that will handle everything
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# Expose the default port
EXPOSE 7860

# Set environment variables
ENV PYTHONUNBUFFERED=1
ENV CUDA_VISIBLE_DEVICES=0

# Use the start script as entrypoint
ENTRYPOINT ["/app/start.sh"]