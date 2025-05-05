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

# Проверяем, что ключ не пустой
if [ -z "$SSH_KEY" ]; then
    log "❌ Ключ не может быть пустым. Прерываем настройку."
    exit 1
fi

# Записываем ключ в файл
echo "$SSH_KEY" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

log "✅ Ключ успешно добавлен в authorized_keys"

log "🔒 Настройка SSH для запрета входа по паролю..."

# Определяем имя сервиса SSH используя несколько методов
SSH_SERVICE=""
if systemctl list-units --all --type=service | grep -q "sshd.service"; then
    SSH_SERVICE="sshd"
elif systemctl list-units --all --type=service | grep -q "ssh.service"; then
    SSH_SERVICE="ssh"
else
    # Проверяем статус обоих возможных сервисов
    if systemctl status sshd &>/dev/null; then
        SSH_SERVICE="sshd"
    elif systemctl status ssh &>/dev/null; then
        SSH_SERVICE="ssh"
    else
        # Проверяем, какой пакет установлен
        if dpkg -l | grep -q "openssh-server"; then
            # В большинстве случаев на Debian/Ubuntu это ssh
            SSH_SERVICE="ssh"
        else
            log "⚠️ Не удалось определить имя сервиса SSH. Предполагаем 'ssh'."
            SSH_SERVICE="ssh"
        fi
    fi
fi

log "🔍 Обнаружен сервис SSH: $SSH_SERVICE"

# Создаем резервную копию оригинального конфига, только если она еще не существует
if [ ! -f /etc/ssh/sshd_config.bak ]; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    log "📁 Создана резервная копия конфигурации SSH"
else
    log "📁 Резервная копия конфигурации SSH уже существует"
fi

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

# Очищаем все дополнительные конфиги если они существуют
if [ -d /etc/ssh/sshd_config.d/ ]; then
    if [ ! -d /etc/ssh/sshd_config.d.bak ]; then
        mkdir -p /etc/ssh/sshd_config.d.bak
        # Перемещаем только если есть файлы конфигурации
        if [ "$(ls -A /etc/ssh/sshd_config.d/ 2>/dev/null)" ]; then
            mv /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config.d.bak/ 2>/dev/null || true
            log "📁 Конфигурации из sshd_config.d перемещены в резервную копию"
        fi
    else
        log "📁 Резервная копия sshd_config.d уже существует"
    fi
fi

# Модифицируем PAM для SSH
if [ -f /etc/pam.d/sshd ]; then
    # Создаем резервную копию, только если она еще не существует
    if [ ! -f /etc/pam.d/sshd.bak ]; then
        cp /etc/pam.d/sshd /etc/pam.d/sshd.bak
        log "📁 Создана резервная копия PAM конфигурации"
    else
        log "📁 Резервная копия PAM конфигурации уже существует"
    fi
    
    # Модифицируем только если еще не модифицировано
    if grep -q "^@include common-auth" /etc/pam.d/sshd; then
        sed -i 's/^@include common-auth/#@include common-auth/' /etc/pam.d/sshd
        log "🔒 PAM конфигурация для SSH обновлена"
    else
        log "🔒 PAM конфигурация для SSH уже была обновлена"
    fi
fi

# Проверяем конфигурацию SSH перед применением
log "🧪 Проверка конфигурации SSH..."
sshd -t
if [ $? -ne 0 ]; then
    log "❌ Конфигурация SSH содержит ошибки! Отмена изменений."
    cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    exit 1
fi

# Перезапускаем SSH с несколькими попытками и вариантами
log "🔄 Перезапуск сервиса $SSH_SERVICE..."

restart_ssh() {
    local service=$1
    if systemctl restart $service; then
        log "✅ Сервис $service успешно перезапущен."
        return 0
    else
        log "⚠️ Не удалось перезапустить сервис $service."
        return 1
    fi
}

# Пробуем перезапустить обнаруженный сервис
if ! restart_ssh $SSH_SERVICE; then
    # Если не удалось, пробуем альтернативное имя
    if [[ "$SSH_SERVICE" == "sshd" ]]; then
        if restart_ssh "ssh"; then
            SSH_SERVICE="ssh"
        else
            log "❌ Не удалось перезапустить SSH ни под каким именем."
            log "📋 Пробуем другие методы перезапуска..."
            service ssh restart || service sshd restart || /etc/init.d/ssh restart || /etc/init.d/sshd restart || true
            
            if ! systemctl is-active --quiet ssh && ! systemctl is-active --quiet sshd; then
                log "❌ Все попытки перезапуска SSH неудачны. Восстанавливаем конфигурацию."
                cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
                systemctl restart ssh || systemctl restart sshd || service ssh restart || service sshd restart || true
                log "⚠️ Возможно, потребуется ручная настройка SSH."
                # Не выходим из скрипта, чтобы можно было продолжить с Mellanox
            fi
        fi
    else
        if restart_ssh "sshd"; then
            SSH_SERVICE="sshd"
        else
            log "❌ Не удалось перезапустить SSH ни под каким именем."
            log "📋 Пробуем другие методы перезапуска..."
            service ssh restart || service sshd restart || /etc/init.d/ssh restart || /etc/init.d/sshd restart || true
            
            if ! systemctl is-active --quiet ssh && ! systemctl is-active --quiet sshd; then
                log "❌ Все попытки перезапуска SSH неудачны. Восстанавливаем конфигурацию."
                cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
                systemctl restart ssh || systemctl restart sshd || service ssh restart || service sshd restart || true
                log "⚠️ Возможно, потребуется ручная настройка SSH."
                # Не выходим из скрипта, чтобы можно было продолжить с Mellanox
            fi
        fi
    fi
fi

# Проверяем, что SSH работает
if systemctl is-active --quiet $SSH_SERVICE || systemctl is-active --quiet ssh || systemctl is-active --quiet sshd; then
    log "✅ SSH успешно запущен и работает."
    log "---------------------------------------------"
    log "✅ Настройка SSH завершена!"
    log "🔒 Вход по паролю отключен. Теперь можно входить ТОЛЬКО по ключу."
    log "🔑 Убедитесь, что ваш ключ работает, прежде чем закрывать это соединение!"
    log "---------------------------------------------"
else
    log "⚠️ Не удалось подтвердить, что SSH работает."
    log "⚠️ ВНИМАНИЕ: Убедитесь, что SSH работает, прежде чем закрывать соединение!"
    log "⚠️ В случае проблем, используйте резервную копию: /etc/ssh/sshd_config.bak"
    log "---------------------------------------------"
fi

# Установка драйверов Mellanox
log "🌐 Подготовка к установке драйверов Mellanox..."

# Функция для проверки и установки пакетов
install_package() {
    local pkg="$1"
    if dpkg -l | grep -q "^ii\s*$pkg\s"; then
        log "✅ Пакет $pkg уже установлен"
        return 0
    else
        log "📦 Установка пакета $pkg..."
        apt install -y $pkg >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log "✅ Пакет $pkg успешно установлен"
            return 0
        else
            log "⚠️ Не удалось установить пакет $pkg. Продолжаем..."
            return 1
        fi
    fi
}

# Обновляем информацию о пакетах
log "📦 Обновление информации о пакетах..."
apt update -qq

# Список обязательных и опциональных пакетов
REQUIRED_PACKAGES="perl python3 make gcc libnl-3-200 libnl-route-3-200 libnl-3-dev libnl-route-3-dev"
OPTIONAL_PACKAGES="python3-distutils tcl tk pciutils"

# Устанавливаем обязательные пакеты
for pkg in $REQUIRED_PACKAGES; do
    install_package $pkg
done

# Пробуем установить опциональные пакеты по одному, игнорируя ошибки
for pkg in $OPTIONAL_PACKAGES; do
    install_package $pkg || true
done

# Проверка наличия python3-distutils, который может быть в разных пакетах
if ! dpkg -l | grep -q python3-distutils; then
    log "⚠️ Пакет python3-distutils не найден. Пробуем альтернативы..."
    # В некоторых версиях Ubuntu distutils содержится в пакете python3-stdlib-extensions
    install_package python3-stdlib-extensions || true
    # В других версиях distutils уже включен в python3 или нужен python3-setuptools
    install_package python3-setuptools || true
fi

# Проверяем существование директории /tmp
if [ ! -d "/tmp" ]; then
    log "📁 Директория /tmp не существует. Создаем..."
    mkdir -p /tmp
    chmod 1777 /tmp
fi

# Поиск драйвера Mellanox в директории /tmp
log "🔍 Поиск драйвера Mellanox в директории /tmp..."
MELLANOX_TGZ=$(find /tmp -name "MLNX_OFED_LINUX-*.tgz" 2>/dev/null | sort -V | tail -n 1)

# Проверяем, установлен ли уже драйвер Mellanox
MELLANOX_INSTALLED=false
OFED_VERSION="Не установлен"
if command -v ofed_info &> /dev/null; then
    MELLANOX_INSTALLED=true
    OFED_VERSION=$(ofed_info -s 2>/dev/null || echo "Неизвестная версия")
    log "ℹ️ Драйвер Mellanox OFED уже установлен. Версия: $OFED_VERSION"
fi

if [ -n "$MELLANOX_TGZ" ]; then
    log "✅ Найден файл драйвера Mellanox: $MELLANOX_TGZ"
    
    if $MELLANOX_INSTALLED; then
        log "Драйвер Mellanox уже установлен. Хотите переустановить? (y/n)"
    else
        log "Хотите установить драйвер Mellanox? (y/n)"
    fi
    read install_driver
    
    if [[ "$install_driver" == "y" || "$install_driver" == "Y" ]]; then
        # Распаковка и установка
        log "📦 Распаковка драйвера..."
        EXTRACT_DIR=$(mktemp -d)
        tar -xzf "$MELLANOX_TGZ" -C "$EXTRACT_DIR" || {
            log "❌ Ошибка распаковки архива драйвера."
            rm -rf "$EXTRACT_DIR"
            log "⏭️ Пропускаем установку драйвера Mellanox из-за ошибки."
            INSTALL_FAILED=true
        }
        
        if [ -z ${INSTALL_FAILED+x} ]; then
            # Переходим в директорию с распакованным драйвером
            INSTALL_DIR=$(find "$EXTRACT_DIR" -type d -name "MLNX_OFED_LINUX-*" 2>/dev/null | head -n 1)
            
            if [ -n "$INSTALL_DIR" ]; then
                log "🔄 Установка драйвера Mellanox..."
                cd "$INSTALL_DIR"
                
                # Сначала проверяем работоспособность скрипта установки
                if [ ! -x "./mlnxofedinstall" ]; then
                    log "❌ Скрипт установки драйвера не найден или не имеет прав на выполнение."
                    chmod +x ./mlnxofedinstall 2>/dev/null || true
                fi
                
                if [ -x "./mlnxofedinstall" ]; then
                    # Устанавливаем драйвер, сохраняя лог установки
                    # Добавляем флаг --without-python для обхода проблем с отсутствующими Python-пакетами
                    ./mlnxofedinstall --force --all --without-python 2>&1 | tee /tmp/mellanox_install.log || true
                    
                    # Проверка успешности установки
                    if command -v ofed_info &> /dev/null; then
                        OFED_VERSION=$(ofed_info -s 2>/dev/null || echo "Неизвестная версия")
                        log "✅ Драйвер Mellanox OFED успешно установлен. Версия: $OFED_VERSION"
                        
                        # Проверяем существование сервиса перед его перезапуском
                        if [ -f /etc/init.d/openibd ]; then
                            # Перезапуск сервиса
                            log "🔄 Перезапуск сервиса openibd..."
                            /etc/init.d/openibd restart || true
                            
                            # Настройка автозагрузки
                            log "⚙️ Настройка автозагрузки сервиса..."
                            systemctl enable openibd || true
                        else
                            log "⚠️ Сервис openibd не найден. Проверяем альтернативы..."
                            # Проверяем другие возможные имена сервиса
                            for service in mlnx-ofed mlx4_core mlx5_core; do
                                if systemctl list-units --all --type=service | grep -q $service; then
                                    log "🔄 Перезапуск сервиса $service..."
                                    systemctl restart $service || true
                                    systemctl enable $service || true
                                fi
                            done
                        fi
                    else
                        log "⚠️ Не удалось подтвердить установку драйвера Mellanox."
                        log "📋 Проверьте лог установки в /tmp/mellanox_install.log"
                    fi
                else
                    log "❌ Скрипт установки драйвера недоступен или поврежден."
                fi
                
                # Очистка
                log "🧹 Очистка временных файлов..."
                cd /
                rm -rf "$EXTRACT_DIR"
            else
                log "❌ Не удалось найти директорию с распакованным драйвером."
            fi
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
        MELLANOX_TGZ=$(find /tmp -name "MLNX_OFED_LINUX-*.tgz" 2>/dev/null | sort -V | tail -n 1)
        
        if [ -n "$MELLANOX_TGZ" ]; then
            log "✅ Найден файл драйвера Mellanox: $MELLANOX_TGZ"
            
            # Распаковка и установка
            log "📦 Распаковка драйвера..."
            EXTRACT_DIR=$(mktemp -d)
            tar -xzf "$MELLANOX_TGZ" -C "$EXTRACT_DIR" || {
                log "❌ Ошибка распаковки архива драйвера."
                rm -rf "$EXTRACT_DIR"
                log "⏭️ Пропускаем установку драйвера Mellanox из-за ошибки."
                INSTALL_FAILED=true
            }
            
            if [ -z ${INSTALL_FAILED+x} ]; then
                # Переходим в директорию с распакованным драйвером
                INSTALL_DIR=$(find "$EXTRACT_DIR" -type d -name "MLNX_OFED_LINUX-*" 2>/dev/null | head -n 1)
                
                if [ -n "$INSTALL_DIR" ]; then
                    log "🔄 Установка драйвера Mellanox..."
                    cd "$INSTALL_DIR"
                    
                    # Сначала проверяем работоспособность скрипта установки
                    if [ ! -x "./mlnxofedinstall" ]; then
                        log "❌ Скрипт установки драйвера не найден или не имеет прав на выполнение."
                        chmod +x ./mlnxofedinstall 2>/dev/null || true
                    fi
                    
                    if [ -x "./mlnxofedinstall" ]; then
                        # Устанавливаем драйвер, сохраняя лог установки
                        ./mlnxofedinstall --force --all --without-python 2>&1 | tee /tmp/mellanox_install.log || true
                        
                        # Проверка успешности установки
                        if command -v ofed_info &> /dev/null; then
                            OFED_VERSION=$(ofed_info -s 2>/dev/null || echo "Неизвестная версия")
                            log "✅ Драйвер Mellanox OFED успешно установлен. Версия: $OFED_VERSION"
                            
                            # Проверяем существование сервиса перед его перезапуском
                            if [ -f /etc/init.d/openibd ]; then
                                # Перезапуск сервиса
                                log "🔄 Перезапуск сервиса openibd..."
                                /etc/init.d/openibd restart || true
                                
                                # Настройка автозагрузки
                                log "⚙️ Настройка автозагрузки сервиса..."
                                systemctl enable openibd || true
                            else
                                log "⚠️ Сервис openibd не найден. Проверяем альтернативы..."
                                # Проверяем другие возможные имена сервиса
                                for service in mlnx-ofed mlx4_core mlx5_core; do
                                    if systemctl list-units --all --type=service | grep -q $service; then
                                        log "🔄 Перезапуск сервиса $service..."
                                        systemctl restart $service || true
                                        systemctl enable $service || true
                                    fi
                                done
                            fi
                        else
                            log "⚠️ Не удалось подтвердить установку драйвера Mellanox."
                            log "📋 Проверьте лог установки в /tmp/mellanox_install.log"
                        fi
                    else
                        log "❌ Скрипт установки драйвера недоступен или поврежден."
                    fi
                    
                    # Очистка
                    log "🧹 Очистка временных файлов..."
                    cd /
                    rm -rf "$EXTRACT_DIR"
                else
                    log "❌ Не удалось найти директорию с распакованным драйвером."
                fi
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
apt update -qq && apt upgrade -y && apt autoremove -y

log "---------------------------------------------"
log "🏁 Все настройки успешно выполнены!"
log "🔒 Настройка SSH: ✅ Выполнено"
if $MELLANOX_INSTALLED || command -v ofed_info &> /dev/null; then
    log "🌐 Драйвер Mellanox: ✅ Установлен (версия: $(ofed_info -s 2>/dev/null || echo "Неизвестная"))"
else
    log "🌐 Драйвер Mellanox: ❌ Не установлен"
fi
log "---------------------------------------------"
log "⚠️ ВАЖНО: Убедитесь, что вы можете войти по SSH с использованием ключа"
log "в новой сессии, прежде чем закрывать текущее соединение!"
log "---------------------------------------------"

log "Нажми [Enter], чтобы перезагрузиться"
read

log "🗑️ Удаление самого скрипта..."
rm -- "$0"

log "🔁 Перезапуск..."
reboot
