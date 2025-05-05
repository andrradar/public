#!/bin/bash

set -e

log() {
    echo -e "\e[1;34m[$(date '+%Y-%m-%d %H:%M:%S')]\e[0m $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "\e[1;31mЭтот скрипт должен быть запущен с правами root.\e[0m"
        exit 1
    fi
}

check_root

### === Настройка переменных окружения CUDA ===
CUDA_VERSION=$(ls -d /usr/local/cuda-* 2>/dev/null | grep -o '[0-9.]*$' | head -1)

if [ -n "$CUDA_VERSION" ]; then
    log "Настройка переменных окружения для CUDA $CUDA_VERSION"
    cat > /etc/profile.d/cuda.sh << EOF
export PATH=/usr/local/cuda-$CUDA_VERSION/bin\${PATH:+:\${PATH}}
export LD_LIBRARY_PATH=/usr/local/cuda-$CUDA_VERSION/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}
EOF
    chmod +x /etc/profile.d/cuda.sh
    source /etc/profile.d/cuda.sh
    ln -sfn /usr/local/cuda-$CUDA_VERSION /usr/local/cuda
    ldconfig
else
    log "\e[1;31mCUDA не обнаружена в /usr/local. Скрипт прерывается.\e[0m"
    exit 1
fi

### === Установка cuDNN ===
if ! ldconfig -p | grep -q libcudnn; then
    log "Установка cuDNN из локального репозитория"
    . /etc/os-release
    UBUNTU_VER="${VERSION_ID//./}"
    CUDNN_DEB="cudnn-local-repo-ubuntu${UBUNTU_VER}-9.8.0_1.0-1_amd64.deb"

    if [ ! -f "/tmp/$CUDNN_DEB" ]; then
        wget -O "/tmp/$CUDNN_DEB" "https://developer.download.nvidia.com/compute/cudnn/9.8.0/local_installers/$CUDNN_DEB"
    fi

    dpkg -i "/tmp/$CUDNN_DEB"
    cp /var/cudnn-local-repo-ubuntu*/cudnn-*-keyring.gpg /usr/share/keyrings/
    apt-get update
    apt-get -y install cudnn-cuda-12
else
    log "cuDNN уже установлен — пропускаем"
fi

### === Установка NVIDIA Container Toolkit ===
if ! command -v docker &>/dev/null || ! docker info | grep -q 'nvidia'; then
    log "Установка NVIDIA Container Toolkit и Docker"
    apt-get install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | apt-key add -
    curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | tee /etc/apt/sources.list.d/nvidia-docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io nvidia-container-toolkit

    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'EOF'
{
    "default-runtime": "nvidia",
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
EOF
    systemctl restart docker
else
    log "Docker и NVIDIA Container Toolkit уже установлены — пропускаем"
fi

### === Проверка CUDA через простой тест ===
if [ ! -f /root/cuda_test/vector_add.cu ]; then
    log "Создание CUDA-теста vector_add.cu"
    mkdir -p /root/cuda_test
    cat > /root/cuda_test/vector_add.cu << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
__global__ void vectorAdd(const float *A, const float *B, float *C, int numElements) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;
    if (i < numElements) {
        C[i] = A[i] + B[i];
    }
}
int main(void) {
    int numElements = 50000;
    size_t size = numElements * sizeof(float);
    float *h_A = (float *)malloc(size);
    float *h_B = (float *)malloc(size);
    float *h_C = (float *)malloc(size);
    for (int i = 0; i < numElements; ++i) {
        h_A[i] = rand() / (float)RAND_MAX;
        h_B[i] = rand() / (float)RAND_MAX;
    }
    float *d_A = NULL; cudaMalloc((void **)&d_A, size);
    float *d_B = NULL; cudaMalloc((void **)&d_B, size);
    float *d_C = NULL; cudaMalloc((void **)&d_C, size);
    cudaMemcpy(d_A, h_A, size, cudaMemcpyHostToDevice);
    cudaMemcpy(d_B, h_B, size, cudaMemcpyHostToDevice);
    int threadsPerBlock = 256;
    int blocksPerGrid = (numElements + threadsPerBlock - 1) / threadsPerBlock;
    vectorAdd<<<blocksPerGrid, threadsPerBlock>>>(d_A, d_B, d_C, numElements);
    cudaMemcpy(h_C, d_C, size, cudaMemcpyDeviceToHost);
    for (int i = 0; i < numElements; ++i) {
        if (fabs(h_A[i] + h_B[i] - h_C[i]) > 1e-5) {
            fprintf(stderr, "Mismatch at %d\n", i);
            return 1;
        }
    }
    printf("Test PASSED\n");
    cudaFree(d_A); cudaFree(d_B); cudaFree(d_C);
    free(h_A); free(h_B); free(h_C);
    return 0;
}
EOF
fi

log "Компиляция CUDA-теста"
cd /root/cuda_test
nvcc -o vector_add vector_add.cu
./vector_add

log "🔄 Финальное обновление системы и очистка..."
apt update && apt upgrade -y && apt autoremove -y

log "\e[1;32mВся установка завершена успешно. Система готова к использованию GPU.\e[0m"

log "🧹 Удаление установочных скриптов..."
rm -f /root/vgpu_install-1.sh /root/vgpu_install-2.sh
