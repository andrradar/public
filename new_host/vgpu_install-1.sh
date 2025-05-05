#!/bin/bash

set -e

log() {
    echo -e "\e[1;34m[$(date '+%Y-%m-%d %H:%M:%S')]\e[0m $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "\e[1;31mЭтот скрипт должен быть запущен с правами root.\e[0m"
        exit 1
    fi
}

check_root

log "Подготовка системы: установка необходимых пакетов и отключение Nouveau"
apt update
apt install -y build-essential dkms libvulkan1 pkg-config libglvnd-dev

cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

update-initramfs -u

# Проверка установлен ли драйвер vGPU
if nvidia-smi &>/dev/null; then
    log "vGPU-драйвер уже установлен. Пропускаем установку."
else
    log "Поиск драйвера NVIDIA vGPU в /tmp"
    DRIVER_FILE=$(find /tmp -name "NVIDIA-Linux-x86_64-*-grid.run" | head -n 1)

    if [ -z "$DRIVER_FILE" ]; then
        echo -e "\e[1;33mВНИМАНИЕ:\e[0m Файл драйвера vGPU не найден в /tmp."
        echo "Пожалуйста, загрузите файл драйвера в директорию /tmp"
        echo -e "Пример имени файла: \e[1mNVIDIA-Linux-x86_64-550.90.07-grid.run\e[0m"
        read -p "Когда файл будет загружен, нажмите Enter для продолжения..."
        DRIVER_FILE=$(find /tmp -name "NVIDIA-Linux-x86_64-*-grid.run" | head -n 1)
        if [ -z "$DRIVER_FILE" ]; then
            echo -e "\e[1;31mФайл по-прежнему не найден. Прерывание установки.\e[0m"
            exit 1
        fi
    fi

    log "Найден драйвер vGPU: $DRIVER_FILE"
    chmod +x "$DRIVER_FILE"

    log "Установка драйвера vGPU..."
    "$DRIVER_FILE" --silent --dkms --no-cc-version-check
fi

# Настройка лицензирования
log "Настройка лицензирования vGPU"
mkdir -p /etc/nvidia/ClientConfigToken/

if [ ! -f /etc/nvidia/gridd.conf ]; then
    cat > /etc/nvidia/gridd.conf << EOF
ServerAddress=10.10.4.44
ServerPort=443
FeatureType=1
EnableUI=FALSE
EOF
else
    log "Файл gridd.conf уже существует. Пропускаем."
fi

if compgen -G "/etc/nvidia/ClientConfigToken/*.tok" > /dev/null; then
    log "Токен лицензии уже существует. Пропускаем загрузку."
else
    log "Получение токена лицензии"
    curl --insecure -L -X GET https://10.10.4.44/-/client-token \
        -o "/etc/nvidia/ClientConfigToken/client_configuration_token_$(date '+%d-%m-%Y-%H-%M-%S').tok"
    chmod 644 /etc/nvidia/ClientConfigToken/*.tok
fi

systemctl restart nvidia-gridd

log "\e[1;32mУстановка vGPU-драйвера завершена успешно.\e[0m"

log "\e[1;33mСейчас начнется установка CUDA Toolkit. В ИНТЕРАКТИВНОМ МЕНЮ НЕОБХОДИМО СНЯТЬ ГАЛОЧКУ ТОЛЬКО С \"Driver\".\e[0m"
echo -e "После завершения установки CUDA, запустите скрипт \e[1mvgpu_install-2.sh\e[0m для продолжения установки."
read -p "Нажмите Enter для запуска установки CUDA..."

CUDA_RUN_FILE=$(find /tmp -name "cuda_*_linux.run" | head -n 1)
if [ -z "$CUDA_RUN_FILE" ]; then
    log "Скачивание CUDA Toolkit 12.4 в /tmp"
    CUDA_RUN_FILE="/tmp/cuda_12.4.0_550.54.14_linux.run"
    wget -O "$CUDA_RUN_FILE" https://developer.download.nvidia.com/compute/cuda/12.4.0/local_installers/cuda_12.4.0_550.54.14_linux.run
fi

chmod +x "$CUDA_RUN_FILE"

log "⚠️ Сейчас начнется установка CUDA Toolkit."
echo -e "\e[1;33mВ ИНТЕРАКТИВНОМ МЕНЮ СНИМИТЕ ГАЛОЧКУ ТОЛЬКО С «Driver». Остальное оставьте как есть.\e[0m"
echo "После окончания установки CUDA, запустите скрипт ./vgpu_install-2.sh"
read -p "Нажмите Enter, чтобы запустить CUDA-установщик..."

"$CUDA_RUN_FILE" --toolkit --samples --no-opengl-libs
