#!/bin/bash

# ============================================
# Скрипт обновления reverse_proxy
# ============================================

INSTALL_DIR="/var/reverse_proxy"
BACKUP_DIR="/var/reverse_proxy_backup_$(date +%Y%m%d_%H%M%S)"
DOWNLOAD_URL="https://github.com/itnos/reverse_proxy/archive/refs/tags/latest.zip"

echo "============================================"
echo "Обновление reverse_proxy"
echo "============================================"

# Проверка наличия директории
if [ ! -d "$INSTALL_DIR" ]; then
    echo "Ошибка: Директория $INSTALL_DIR не найдена!"
    exit 1
fi

cd "$INSTALL_DIR" || exit 1

# Остановка контейнеров
echo "Остановка Docker контейнеров..."
docker compose down
if [ $? -ne 0 ]; then
    echo "Ошибка при остановке контейнеров!"
    exit 1
fi

# Создание резервной копии
echo "Создание резервной копии..."
cp -r "$INSTALL_DIR" "$BACKUP_DIR"
echo "Резервная копия создана: $BACKUP_DIR"

# Скачивание новой версии
echo "Скачивание обновления..."
cd /tmp || exit 1
rm -f reverse_proxy.zip
wget "$DOWNLOAD_URL" -O reverse_proxy.zip

if [ $? -ne 0 ]; then
    echo "Ошибка загрузки!"
    echo "Восстановление из резервной копии..."
    rm -rf "$INSTALL_DIR"
    cp -r "$BACKUP_DIR" "$INSTALL_DIR"
    cd "$INSTALL_DIR" || exit 1
    docker compose up -d
    exit 1
fi

# Распаковка
echo "Распаковка обновления..."
rm -rf /tmp/reverse_proxy_update
unzip -q reverse_proxy.zip -d /tmp/reverse_proxy_update

if [ $? -ne 0 ]; then
    echo "Ошибка распаковки!"
    echo "Восстановление из резервной копии..."
    rm -rf "$INSTALL_DIR"
    cp -r "$BACKUP_DIR" "$INSTALL_DIR"
    cd "$INSTALL_DIR" || exit 1
    docker compose up -d
    exit 1
fi

# Обновление файлов (сохраняем конфигурацию)
echo "Обновление файлов..."
cd /tmp/reverse_proxy_update/* || exit 1

# Сохраняем важные файлы и директории
mkdir -p /tmp/backup_configs
[ -f "$INSTALL_DIR/.env" ] && cp "$INSTALL_DIR/.env" /tmp/backup_configs/
[ -d "$INSTALL_DIR/config" ] && cp -r "$INSTALL_DIR/config" /tmp/backup_configs/
[ -d "$INSTALL_DIR/configs" ] && cp -r "$INSTALL_DIR/configs" /tmp/backup_configs/
[ -d "$INSTALL_DIR/data" ] && cp -r "$INSTALL_DIR/data" /tmp/backup_configs/
[ -d "$INSTALL_DIR/acme" ] && cp -r "$INSTALL_DIR/acme" /tmp/backup_configs/

# Удаляем старые файлы (кроме конфигов и данных)
find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name 'config' ! -name 'configs' ! -name 'data' ! -name 'acme' ! -name '.env' -exec rm -rf {} +

# Копируем новые файлы
cp -r ./* "$INSTALL_DIR/"

if [ $? -ne 0 ]; then
    echo "Ошибка обновления файлов!"
    echo "Восстановление из резервной копии..."
    rm -rf "$INSTALL_DIR"
    cp -r "$BACKUP_DIR" "$INSTALL_DIR"
    cd "$INSTALL_DIR" || exit 1
    docker compose up -d
    rm -rf /tmp/backup_configs
    exit 1
fi

# Восстанавливаем конфиги
[ -f /tmp/backup_configs/.env ] && cp /tmp/backup_configs/.env "$INSTALL_DIR/"
[ -d /tmp/backup_configs/config ] && cp -r /tmp/backup_configs/config "$INSTALL_DIR/"
[ -d /tmp/backup_configs/configs ] && cp -r /tmp/backup_configs/configs "$INSTALL_DIR/"
[ -d /tmp/backup_configs/data ] && cp -r /tmp/backup_configs/data "$INSTALL_DIR/"
[ -d /tmp/backup_configs/acme ] && cp -r /tmp/backup_configs/acme "$INSTALL_DIR/"

# Дозаливаем недостающие файлы нового релиза поверх восстановленного configs/ (logrotate и т.п.)
# cp -n не перезаписывает существующие, только дополняет
cp -rn /tmp/reverse_proxy_update/*/configs/logrotate "$INSTALL_DIR/configs/" 2>/dev/null || true

# Чистка гигантских старых логов nginx (освобождаем место, новые логи per-site будут в /var/log/nginx/sites/)
echo "Очистка старых логов nginx..."
rm -f /var/log/nginx/access.log /var/log/nginx/error.log
rm -f /var/log/nginx/*.log.*
rm -rf /var/log/nginx/sites

# Очистка временных файлов
echo "Очистка..."
rm -f /tmp/reverse_proxy.zip
rm -rf /tmp/reverse_proxy_update
rm -rf /tmp/backup_configs

# Запуск контейнеров
echo "Запуск Docker контейнеров..."
cd "$INSTALL_DIR" || exit 1
docker compose up -d

if [ $? -ne 0 ]; then
    echo "Ошибка запуска контейнеров!"
    echo "Восстановление из резервной копии..."
    rm -rf "$INSTALL_DIR"
    cp -r "$BACKUP_DIR" "$INSTALL_DIR"
    cd "$INSTALL_DIR" || exit 1
    docker compose up -d
    exit 1
fi

echo ""
echo "============================================"
echo "✓ Обновление завершено успешно!"
echo "============================================"
echo "Резервная копия: $BACKUP_DIR"
echo "Статус контейнеров:"
docker compose ps
echo "============================================"
