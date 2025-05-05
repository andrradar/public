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

# Определяем имя сервиса SSH
SSH_SERVICE=""
if systemctl list-units --type=service | grep -q "sshd.service"; then
    SSH_SERVICE="sshd"
elif systemctl list-units --type=service | grep -q "ssh.service"; then
    SSH_SERVICE="ssh"
else
    log "⚠️ Не удалось определить имя сервиса SSH. Попробуем оба варианта."
    if systemctl status sshd &>/dev/null; then
        SSH_SERVICE="sshd"
    elif systemctl status ssh &>/dev/null; then
        SSH_SERVICE="ssh"
    else
        log "❌ Не удалось определить сервис SSH. Продолжение может быть опасным."
        log "Хотите продолжить настройку, предполагая что сервис называется 'ssh'? (y/n)"
        read continue_setup
        if [[ "$continue_setup" == "y" || "$continue_setup" == "Y" ]]; then
            SSH_SERVICE="ssh"
        else
            log "❌ Настройка SSH прервана пользователем."
            exit 1
        fi
    fi
fi

log "🔍 Обнаружен сервис SSH: $SSH_SERVICE"

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
log "🔄 Перезапуск сервиса $SSH_SERVICE..."
if ! systemctl restart $SSH_SERVICE; then
    log "⚠️ Не удалось перезапустить сервис $SSH_SERVICE. Пробуем альтернативный вариант..."
    if [[ "$SSH_SERVICE" == "sshd" ]]; then
        if systemctl restart ssh; then
            SSH_SERVICE="ssh"
            log "✅ Сервис ssh успешно перезапущен."
        else
            log "❌ Не удалось перезапустить сервис SSH."
            log "Восстанавливаем конфигурацию из резервной копии..."
            cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
            systemctl restart ssh || systemctl restart sshd || true
            exit 1
        fi
    else
        if systemctl restart sshd; then
            SSH_SERVICE="sshd"
            log "✅ Сервис sshd успешно перезапущен."
        else
            log "❌ Не удалось перезапустить сервис SSH."
            log "Восстанавливаем конфигурацию из резервной копии..."
            cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
            systemctl restart ssh || systemctl restart sshd || true
            exit 1
        fi
    fi
fi

log "✅ SSH перезапущен с новыми настройками."

# Проверяем, что SSH работает
if ! systemctl is-active --quiet $SSH_SERVICE; then
    log "⚠️ SSH не запустился! Восстанавливаем из резервной копии..."
    cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    systemctl restart $SSH_SERVICE || true
    log "❌ Не удалось применить настройки. Используйте ручную настройку."
    exit 1
fi

log "---------------------------------------------"
log "✅ Настройка SSH завершена!"
log "🔒 Вход по паролю отключен. Теперь можно входить ТОЛЬКО по ключу."
log "🔑 Убедитесь, что ваш ключ работает, прежде чем закрывать это соединение!"
log "---------------------------------------------"

# Остальная часть скрипта остается без изменений
# ...
