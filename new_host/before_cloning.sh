#!/bin/bash

# Удаляем machine-id и создаем новый при первом запуске
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo ln -s /etc/machine-id /var/lib/dbus/machine-id

# Удаляем старые DHCP lease
sudo rm -f /var/lib/dhcp/dhclient.*.leases

# Удаляем сетевые правила udev
sudo rm -f /etc/udev/rules.d/70-persistent-net.rules

# Удаляем флаг /etc/setup_completed, если он существует (только для эталонной ВМ)
sudo rm -f /etc/setup_completed

# Очищаем историю терминала для пользователя root
sudo truncate -s 0 /root/.bash_history
history -c

# Удаляем логи, чтобы избежать переноса на клоны
sudo find /var/log -type f -exec truncate -s 0 {} \;

# Создаем скрипт для первого запуска на клонах
cat <<'EOF' > /usr/local/bin/firstboot-setup.sh
#!/bin/bash

# Проверяем наличие флага, чтобы не выполнять скрипт повторно
if [ -f /etc/setup_completed ]; then
  echo "Скрипт уже выполнен ранее, пропускаем настройку."
  exit 0
fi

# Удаляем и создаем символическую ссылку для machine-id
truncate -s 0 /etc/machine-id
rm /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

# Проверяем и настраиваем dhcp-identifier в netplan
if grep -q 'dhcp-identifier: mac' /etc/netplan/*.yaml; then
  echo "dhcp-identifier уже настроен на MAC."
else
  sudo tee /etc/netplan/01-netcfg.yaml <<EOF2
network:
  version: 2
  renderer: networkd
  ethernets:
    default:
      match:
        name: e*
      dhcp4: yes
      dhcp-identifier: mac
EOF2
fi

# Применяем настройки Netplan
sudo netplan apply

# Удаляем старые DHCP lease
sudo rm -f /var/lib/dhcp/dhclient.*.leases

# Настройка systemd-networkd с ClientIdentifier=mac
if [ -f /etc/systemd/network/default.network ]; then
  sudo sed -i '/\[Network\]/a ClientIdentifier=mac' /etc/systemd/network/default.network
else
  sudo mkdir -p /etc/systemd/network
  sudo tee /etc/systemd/network/default.network <<EOF3
[Match]
Name=e*

[Network]
DHCP=ipv4
ClientIdentifier=mac
EOF3
fi

# Перезапускаем systemd-networkd, чтобы применить изменения
sudo systemctl restart systemd-networkd

# Создаем флаг-файл, чтобы знать, что скрипт уже выполнен
touch /etc/setup_completed

# Очищаем историю терминала
history -c
sudo truncate -s 0 ~/.bash_history

# Удаляем сам скрипт после завершения
sudo rm -f /usr/local/bin/firstboot-setup.sh

echo "Настройка завершена. Машина готова к работе."
EOF

# Делаем скрипт исполняемым
chmod +x /usr/local/bin/firstboot-setup.sh

# Добавляем скрипт в автозапуск
if [ ! -f /etc/rc.local ]; then
  sudo touch /etc/rc.local
  sudo chmod +x /etc/rc.local
fi

if ! grep -q '/usr/local/bin/firstboot-setup.sh' /etc/rc.local; then
  echo "/usr/local/bin/firstboot-setup.sh" | sudo tee -a /etc/rc.local
fi

# Удаляем флаг-файл, если он существует
sudo rm -f /etc/setup_completed

# Эталонная ВМ готова для клонирования
echo "Эталонная ВМ готова для клонирования."

# Удаляем сам скрипт после завершения
sudo rm -f /root/before_cloning.sh

# Ожидание 4 секунды перед выключением
sleep 4

# Грейсфулл шатдаун системы
sudo shutdown -h now
