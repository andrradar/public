#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1

LOG=/var/log/base_setup.log
SSH_CFG=/etc/ssh/sshd_config
BKP=.bak

log(){ printf '%(%F %T)T  %s\n' -1 "$*" | tee -a "$LOG"; }
trap 'log "❌ Ошибка (код $?) на строке ${BASH_LINENO[0]}"; exit 1' ERR
(( EUID==0 )) || { log "Запусти скрипт от root"; exit 1; }

# ---------- 1. Пакеты --------------------------------------------------------
install_pkgs(){
  log "📦 apt update..."
  apt -qq update

  local pkgs=(perl python3 make gcc libnl-3-200 libnl-route-3-200 \
              libnl-3-dev libnl-route-3-dev python3-distutils tcl tk pciutils)

  for p in "${pkgs[@]}"; do
    if dpkg -s "$p" &>/dev/null; then
      log "✅ $p уже установлен"
    else
      log "↪️  apt install $p"
      if ! apt -y install "$p" </dev/null; then
        log "⚠️  $p недоступен, пропускаю"
      fi
    fi
  done
}
# ---------- 2. Mellanox ------------------------------------------------------
install_mlx(){
  command -v ofed_info &>/dev/null && { log "ℹ️  OFED уже есть ($(ofed_info -s|tr -d '\n'))"; return; }
  local tgz
  tgz=$(find /tmp -maxdepth 1 -name 'MLNX_OFED_LINUX-*.tgz' | sort -V | tail -1 || true)
  [[ $tgz ]] || { log "⏭️  Mellanox‑архив не найден — пропуск"; return; }

  log "📦 Распаковка $tgz"
  local wd; wd=$(mktemp -d)
  tar -xf "$tgz" -C "$wd"
  local dir; dir=$(find "$wd" -maxdepth 1 -type d -name 'MLNX_OFED_LINUX-*' | head -1)
  [[ -x $dir/mlnxofedinstall ]] || chmod +x "$dir/mlnxofedinstall"

  log "🔄 Установка OFED (ждём)..."
  "$dir/mlnxofedinstall" --force --all --without-python | tee /tmp/mellanox_install.log

  command -v ofed_info &>/dev/null \
    && log "✅ OFED $(ofed_info -s) установлен" \
    || log "⚠️  Проверь /tmp/mellanox_install.log — установка не подтверждена"

  systemctl enable --now openibd 2>/dev/null || true
  rm -rf "$wd"
}
# ---------- 3. SSH -----------------------------------------------------------
ensure_ssh_key(){
  local ak=/root/.ssh/authorized_keys
  mkdir -p /root/.ssh && chmod 700 /root/.ssh

  if [[ -s $ak ]]; then
    log "🔑 authorized_keys уже существует — оставляю как есть"
    return
  fi

  log "Вставь публичный SSH‑ключ и Enter:"
  read -r key
  [[ $key ]] || { log "Ключ пустой, выходим"; exit 1; }
  echo "$key" >"$ak" && chmod 600 "$ak"
  log "✅ Ключ добавлен"
}

configure_ssh(){
  grep -q '^PasswordAuthentication no' "$SSH_CFG" && { log "SSH уже настроен, пропуск"; return; }

  [[ -f ${SSH_CFG}$BKP ]] || cp "$SSH_CFG" "${SSH_CFG}$BKP"

  cat >"$SSH_CFG" <<'EOF'
Port 22
Protocol 2
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
AuthenticationMethods publickey
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

  log "🧪 sshd -t"; sshd -t
  local svc; svc=$(systemctl list-unit-files | awk '/^ssh[d]?\.service/{sub(/\.service/,"");print;exit}')
  svc=${svc:-ssh}
  systemctl restart "$svc"
  systemctl is-active --quiet "$svc" && log "✅ SSH перезапущен" \
                      || { mv "${SSH_CFG}$BKP" "$SSH_CFG"; systemctl restart "$svc"; log "❌ Откатил конфиг"; }
}
# ---------- 4. Финал ---------------------------------------------------------
finish(){
  log "📦 apt upgrade/autoremove"
  apt -qq update && apt -y upgrade && apt -y autoremove
  log "🏁 Готово. Enter — и ребут."
  read -r
  rm -- "$0"
  reboot
}

# ---------- main -------------------------------------------------------------
install_pkgs
install_mlx
ensure_ssh_key
configure_ssh
finish
