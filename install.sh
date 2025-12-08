#!/bin/bash

# ============================================
# Скрипт автоматического создания LXC-контейнера в Proxmox
# ============================================

# --- НАСТРОЙКИ КОНТЕЙНЕРА ---
HOSTNAME="reverseproxy"                      # Имя хоста
PASSWORD="yourpassword"                     # Пароль root
STORAGE="local-lvm"                         # Хранилище для rootfs
DISK_SIZE=8                                 # Размер диска в GB
MEMORY=2048                                 # RAM в MB
SWAP=512                                    # SWAP в MB
CORES=2                                     # Количество ядер CPU
BRIDGE="vmbr0"                             # Сетевой мост
IP="dhcp"                                   # IP адрес
GATEWAY=""                                  # Шлюз
NAMESERVER="8.8.8.8"                       # DNS

# --- ПОИСК ДОСТУПНОГО ТЕМПЛЕЙТА ---
echo "Поиск доступных темплейтов..."
TEMPLATE=$(pveam list local | grep -i "debian\|ubuntu" | head -n1 | awk '{print $1}')

if [ -z "$TEMPLATE" ]; then
    echo "Темплейты не найдены!"
    echo "Доступные темплейты:"
    pveam list local
    echo ""
    echo "Скачайте темплейт командой:"
    echo "  pveam download local debian-12-standard_12.7-1_amd64.tar.zst"
    exit 1
fi

echo "Используется темплейт: $TEMPLATE"

# --- ПОИСК СВОБОДНОГО ID ---
echo "Поиск свободного ID..."
CTID=100

id_exists() {
    pct status $1 &>/dev/null && return 0
    qm status $1 &>/dev/null && return 0
    return 1
}

while id_exists $CTID; do
    CTID=$((CTID + 1))
    [ $CTID -gt 999 ] && { echo "Нет свободных ID!"; exit 1; }
done

echo "Найден свободный ID: $CTID"

# --- ПАРАМЕТР СЕТИ ---
if [ "$IP" == "dhcp" ]; then
    NET_CONFIG="name=eth0,bridge=$BRIDGE,ip=dhcp"
else
    NET_CONFIG="name=eth0,bridge=$BRIDGE,ip=$IP"
    [ -n "$GATEWAY" ] && NET_CONFIG="$NET_CONFIG,gw=$GATEWAY"
fi

# --- СОЗДАНИЕ КОНТЕЙНЕРА ---
echo "Создание контейнера $CTID..."

pct create $CTID $TEMPLATE \
    --hostname $HOSTNAME \
    --password $PASSWORD \
    --storage $STORAGE \
    --rootfs $STORAGE:$DISK_SIZE \
    --memory $MEMORY \
    --swap $SWAP \
    --cores $CORES \
    --net0 $NET_CONFIG \
    --nameserver $NAMESERVER \
    --features nesting=1 \
    --unprivileged 1 \
    --onboot 1

[ $? -ne 0 ] && { echo "Ошибка создания!"; exit 1; }

echo "Запуск контейнера..."
pct start $CTID
sleep 15

# --- УСТАНОВКА ПО ---
echo "Установка и настройка..."

pct exec $CTID -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt update && apt upgrade -y
    apt install -y curl wget git vim htop net-tools sudo unzip openssh-server locales

    # Настройка локалей
    echo '=== Настройка локалей ==='
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
    locale-gen
    update-locale LANG=en_US.UTF-8

    # Настройка SSH
    echo '=== Настройка SSH ==='
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
    systemctl enable ssh
    systemctl restart ssh

    # Docker
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker

    # Docker Compose
    apt install -y docker-compose

    # Скачивание и установка reverse_proxy
    echo '=== Скачивание reverse_proxy ==='
    cd /var
    wget https://github.com/itnos/reverse_proxy/archive/refs/tags/latest.zip -O reverse_proxy.zip
    unzip -q reverse_proxy.zip -d tmp_reverse_proxy
    rm -rf reverse_proxy
    mv tmp_reverse_proxy/* reverse_proxy
    rmdir tmp_reverse_proxy
    cd reverse_proxy

    echo '=== Запуск Docker Compose ==='
    docker compose -f docker-compose.yml up -d

    cd /root

    apt autoremove -y
    apt clean

    echo '=== Установка завершена ==='
"


[ $? -eq 0 ] && {
    # Получаем IP-адрес контейнера с несколькими попытками
    echo "Получение IP-адреса..."
    CONTAINER_IP=""
    for i in {1..5}; do
        CONTAINER_IP=$(pct exec $CTID -- hostname -I 2>/dev/null | awk '{print $1}')
        [ -n "$CONTAINER_IP" ] && break
        sleep 2
    done

    echo ""
    echo "============================================"
    echo "✓ Контейнер $CTID готов!"
    echo "============================================"
    echo "ID: $CTID"
    echo "Hostname: $HOSTNAME"
    echo "IP: ${CONTAINER_IP:-DHCP (определяется...)}"
    echo "Веб-интерфейс: http://${CONTAINER_IP:-IP}:8881"
    echo "Логин: admin"
    echo "Пароль: password123"
    echo "SSH: ssh root@${CONTAINER_IP:-IP}"
    echo "Пароль SSH: $PASSWORD"
    echo "Подключение: pct enter $CTID"
    echo "============================================"
} || {
    echo "Ошибка настройки!"
    exit 1
}
