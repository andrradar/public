#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_SUSPEND=1

LOGFILE=/var/log/base_setup.log
SSH_CONFIG=/etc/ssh/sshd_config
BACKUP_EXT=.bak

log() { echo "$(date '+%F %T')  $*" | tee -a "$LOGFILE"; }

cleanup() {
  log "⚠️  Ошибка (код $?) на строке ${BASH_LINENO[0]}. Смотри лог."
  exit 1
}
trap cleanup ERR

require_root() {
  (( EUID == 0 )) || { log "❌ Запусти скрипт от root"; exit 1; }
}

install_pkgs() {
  log "📦 apt update/upgrade…"
  apt -qq update
  # базовые + опциональные пакеты
  local pkgs=(perl python3 make gcc libnl-3-200 libnl-route-3-200 \
              libnl-3-dev libnl-route-3-dev python3-distutils tcl tk pciutils)
  apt -y install "${pkgs[@]}" </dev/null
}

install_mellanox() {
  local tgz
  tgz=$(find /tmp -maxdepth 1 -name 'MLNX_OFED_LINUX-*.tgz' | sort -V | tail -1 || true)

  if [[ -z $tgz ]]; then
    log "⏭️  Mellanox‑драйвер не найден в /tmp — пропускаю."
    return
  fi

  if command -v ofed_info &>/dev/null; then
    log "ℹ️  OFED уже стоит ($(ofed_info -s)). Переустанавливать? [y/N]"
    read -r ans; [[ ${ans:-n} =~ ^[Yy]$ ]] || return
  fi

  log "📦 Распаковка $tgz"
  local workdir
  workdir=$(mktemp -d)
  tar -xf "$tgz" -C "$workdir"

  local src
  src=$(find "$workdir" -mindepth 1 -maxdepth 1 -type d -name 'MLNX_OFED_LINUX-*' | head -1)
  [[ -d $src ]] || { log "❌ Не нашёл директорию драйвера"; return; }

  log "🔄 Устанавливаю OFED… (ждём)"
  chmod +x "$src/mlnxofedinstall"
  "$src/mlnxofedinstall" --force --all --without-python | tee /tmp/mellanox_install.log

  if command -v ofed_info &>/dev/null; then
    log "✅ Mellanox OFED $(ofed_info -s) установлен."
    systemctl enable --now openibd 2>/dev/null || true
  else
    log "⚠️  Установка Mellanox не подтверждена, см. /tmp/mellanox_install.log"
  fi
  rm -rf "$workdir"
}

get_ssh_key() {
  log "🔑 Вставь публичный SSH‑ключ (строка ssh‑rsa | ed25519):"
  read -r SSH_KEY
  [[ -n $SSH_KEY ]] || { log "❌ Ключ пустой"; exit 1; }

  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  echo "$SSH_KEY" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  log "✅ Ключ добавлен"
}

configure_ssh() {
  local svc
  svc=$(systemctl list-unit-files | awk '/^ssh[d]?\.service/ {sub(/\.service/,"");print;exit}')
  svc=${svc:-ssh}

  [[ -f ${SSH_CONFIG}${BACKUP_EXT} ]] || cp "$SSH_CONFIG" "${SSH_CONFIG}${BACKUP_EXT}"

  cat >"$SSH_CONFIG" <<'EOF'
Port 22
Protocol 2
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
AuthenticationMethods publickey
X11Forwarding yes
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

  log "🧪 Проверка sshd -t"
  sshd -t

  log "🔄 Перезапуск $svc"
  systemctl restart "$svc"
  systemctl is-active --quiet "$svc" && log "✅ SSH запущен." || {
      log "❌ SSH не стартовал, откатываю конфиг."
      mv -f "${SSH_CONFIG}${BACKUP_EXT}" "$SSH_CONFIG"; systemctl restart "$svc"; exit 1; }
}

final_steps() {
  log "📦 Финальное apt upgrade/clean"
  apt -qq update && apt -y upgrade && apt -y autoremove

  log "🏁 Всё готово. Нажми Enter, чтобы перезагрузить."
  read -r
  rm -- "$0"
  reboot
}

main() {
  require_root
  install_pkgs         # 1. пакеты
  install_mellanox     # 2. драйвер
  get_ssh_key          # 3. ключ
  configure_ssh        # 4. ssh
  final_steps
}
main "$@"
