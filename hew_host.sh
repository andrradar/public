#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_SUSPEND=1

LOGFILE="/var/log/base_setup.log"

log() {
    echo "$(date +"%Y-%m-%d %T") - $1" | tee -a "$LOGFILE"
}

log "🔐 Проверка прав root..."
if [[ $EUID -ne 0 ]]; then
    log "❌ Скрипт должен быть запущен от root."
    exit 1
fi

log "📁 Создание ~/.ssh для root..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh

log "---------------------------------------------"
log "🔑 ВАЖНО: Введите ваш публичный SSH-ключ"
log "Пример: ssh-rsa AAAAB3... user@host"
log "---------------------------------------------"
read -p "Введите ключ: " SSH_KEY

# Записываем ключ в файл
echo "$SSH_KEY" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

log "✅ Ключ успешно добавлен в authorized_keys"

log "🔒 Настройка SSH для запрета входа по паролю..."

# Создаем резервную копию оригинального конфига
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Полностью переписываем основной конфиг SSH
cat > /etc/ssh/sshd_config << 'EOF'
# Базовые настройки
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Логирование
SyslogFacility AUTH
LogLevel INFO

# Аутентификация
LoginGraceTime 60
PermitRootLogin prohibit-password
StrictModes yes
MaxAuthTries 3
MaxSessions 10

# Запрет входа по паролю
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
AuthenticationMethods publickey

# Другие настройки
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

# Очищаем все дополнительные конфиги
if [ -d /etc/ssh/sshd_config.d/ ]; then
    mkdir -p /etc/ssh/sshd_config.d.bak
    mv /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config.d.bak/ 2>/dev/null || true
fi

# Модифицируем PAM для SSH
if [ -f /etc/pam.d/sshd ]; then
    cp /etc/pam.d/sshd /etc/pam.d/sshd.bak
    sed -i 's/@include common-auth/#@include common-auth/' /etc/pam.d/sshd
fi

# Перезапускаем SSH
systemctl restart sshd
log "✅ SSH перезапущен с новыми настройками."

# Проверяем, что SSH работает
if ! systemctl is-active --quiet sshd; then
    log "⚠️ SSH не запустился! Восстанавливаем из резервной копии..."
    cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    systemctl restart sshd
    log "❌ Не удалось применить настройки. Используйте ручную настройку."
    exit 1
fi

log "---------------------------------------------"
log "✅ Настройка SSH завершена!"
log "🔒 Вход по паролю отключен. Теперь можно входить ТОЛЬКО по ключу."
log "🔑 Убедитесь, что ваш ключ работает, прежде чем закрывать это соединение!"
log "---------------------------------------------"

# Установка драйверов Mellanox
log "🌐 Подготовка к установке драйверов Mellanox..."

# Установка необходимых зависимостей
log "📦 Установка необходимых пакетов..."
apt update
apt install -y perl python3 python3-distutils tcl tk pciutils make gcc libnl-3-200 libnl-route-3-200 libnl-3-dev libnl-route-3-dev

# Поиск драйвера Mellanox в директории /tmp
log "🔍 Поиск драйвера Mellanox в директории /tmp..."
MELLANOX_TGZ=$(find /tmp -name "MLNX_OFED_LINUX-*.tgz" | sort -V | tail -n 1)

if [ -n "$MELLANOX_TGZ" ]; then
    log "✅ Найден файл драйвера Mellanox: $MELLANOX_TGZ"
    
    # Спрашиваем пользователя, хочет ли он установить драйвер
    log "Хотите установить драйвер Mellanox? (y/n)"
    read install_driver
    
    if [[ "$install_driver" == "y" || "$install_driver" == "Y" ]]; then
        # Распаковка и установка
        log "📦 Распаковка драйвера..."
        EXTRACT_DIR=$(mktemp -d)
        tar -xzf "$MELLANOX_TGZ" -C "$EXTRACT_DIR"
        
        # Переходим в директорию с распакованным драйвером
        INSTALL_DIR=$(find "$EXTRACT_DIR" -type d -name "MLNX_OFED_LINUX-*" | head -n 1)
        
        if [ -n "$INSTALL_DIR" ]; then
            log "🔄 Установка драйвера Mellanox..."
            cd "$INSTALL_DIR"
            ./mlnxofedinstall --force --all
            
            # Проверка успешности установки
            if [ $? -eq 0 ]; then
                log "✅ Драйвер Mellanox успешно установлен."
                
                # Перезапуск сервиса
                log "🔄 Перезапуск сервиса openibd..."
                /etc/init.d/openibd restart
                
                # Настройка автозагрузки
                log "⚙️ Настройка автозагрузки сервиса..."
                systemctl enable openibd
                
                # Проверка установки
                if command -v ofed_info &> /dev/null; then
                    OFED_VERSION=$(ofed_info -s)
                    log "✅ Драйвер Mellanox OFED успешно установлен. Версия: $OFED_VERSION"
                else
                    log "⚠️ Не удалось проверить версию драйвера. Возможно, установка не завершена."
                fi
            else
                log "❌ Ошибка установки драйвера Mellanox."
            fi
            
            # Очистка
            log "🧹 Очистка временных файлов..."
            cd /
            rm -rf "$EXTRACT_DIR"
        else
            log "❌ Не удалось найти директорию с распакованным драйвером."
        fi
    else
        log "⏭️ Пропускаем установку драйвера Mellanox по запросу пользователя."
    fi
else
    log "⚠️ Файл драйвера Mellanox не найден в директории /tmp."
    log "---------------------------------------------"
    log "🔴 ВАЖНО: Для установки драйвера Mellanox необходимо:"
    log "   1. Загрузить файл драйвера в директорию /tmp"
    log "   2. Файл должен иметь название вида: MLNX_OFED_LINUX-XX.XX-X.X.X.X-ubuntu22.04-x86_64.tgz"
    log "      Например: MLNX_OFED_LINUX-24.10-2.1.8.0-ubuntu22.04-x86_64.tgz"
    log "   3. Файл можно скачать с официального сайта NVIDIA/Mellanox:"
    log "      https://network.nvidia.com/products/infiniband-drivers/linux/mlnx_ofed/"
    log "---------------------------------------------"
    
    log "Хотите загрузить драйвер сейчас и повторить попытку? (y/n)"
    read retry_driver_install
    
    if [[ "$retry_driver_install" == "y" || "$retry_driver_install" == "Y" ]]; then
        log "Пожалуйста, загрузите файл драйвера в директорию /tmp и нажмите [Enter]"
        read
        
        # Повторный поиск драйвера
        log "🔍 Повторный поиск драйвера Mellanox..."
        MELLANOX_TGZ=$(find /tmp -name "MLNX_OFED_LINUX-*.tgz" | sort -V | tail -n 1)
        
        if [ -n "$MELLANOX_TGZ" ]; then
            log "✅ Найден файл драйвера Mellanox: $MELLANOX_TGZ"
            
            # Распаковка и установка
            log "📦 Распаковка драйвера..."
            EXTRACT_DIR=$(mktemp -d)
            tar -xzf "$MELLANOX_TGZ" -C "$EXTRACT_DIR"
            
            # Переходим в директорию с распакованным драйвером
            INSTALL_DIR=$(find "$EXTRACT_DIR" -type d -name "MLNX_OFED_LINUX-*" | head -n 1)
            
            if [ -n "$INSTALL_DIR" ]; then
                log "🔄 Установка драйвера Mellanox..."
                cd "$INSTALL_DIR"
                ./mlnxofedinstall --force --all
                
                # Проверка успешности установки
                if [ $? -eq 0 ]; then
                    log "✅ Драйвер Mellanox успешно установлен."
                    
                    # Перезапуск сервиса
                    log "🔄 Перезапуск сервиса openibd..."
                    /etc/init.d/openibd restart
                    
                    # Настройка автозагрузки
                    log "⚙️ Настройка автозагрузки сервиса..."
                    systemctl enable openibd
                    
                    # Проверка установки
                    if command -v ofed_info &> /dev/null; then
                        OFED_VERSION=$(ofed_info -s)
                        log "✅ Драйвер Mellanox OFED успешно установлен. Версия: $OFED_VERSION"
                    else
                        log "⚠️ Не удалось проверить версию драйвера. Возможно, установка не завершена."
                    fi
                else
                    log "❌ Ошибка установки драйвера Mellanox."
                fi
                
                # Очистка
                log "🧹 Очистка временных файлов..."
                cd /
                rm -rf "$EXTRACT_DIR"
            else
                log "❌ Не удалось найти директорию с распакованным драйвером."
            fi
        else
            log "❌ Файл драйвера не найден даже после повторного поиска. Пропускаем установку."
        fi
    else
        log "⏭️ Пропускаем установку драйвера Mellanox."
    fi
fi

log "---------------------------------------------"
log "✅ Настройка хоста завершена!"

log "🔄 Финальное обновление системы..."
apt update && apt upgrade -y && apt autoremove -y

log "Нажми [Enter], чтобы перезагрузиться"
read

log "🗑️ Удаление самого скрипта..."
rm -- "$0"

log "🔁 Перезапуск..."
reboot
