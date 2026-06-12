# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Описание проекта

Reverse Proxy Manager — система управления реверс-прокси на базе Docker, Nginx и Node.js с автоматической интеграцией CloudFlare DNS и Let's Encrypt SSL-сертификатами. Проект предназначен для развертывания в Proxmox LXC-контейнерах или Docker.

## Архитектура системы

### Контейнеризация (Docker Compose)

Проект состоит из трех основных Docker-контейнеров:

1. **nginx_webserver** — Nginx 1.25-alpine для проксирования HTTP/HTTPS трафика
2. **webadmin-app** — Node.js 20.18 веб-приложение для управления (порт 8881)
3. **acme_sh** — контейнер acme.sh для получения SSL-сертификатов через Let's Encrypt

### Структура данных

- **Persistent хранилище:**
  - `/data/user.json` — данные пользователя (username, passwordHash, cf_token, sync_interval)
  - `/data/items.json` — прокси-записи с кешированной DNS информацией
  - `/acme/` — SSL-сертификаты от Let's Encrypt
  - `/configs/nginx/sites/` — конфигурационные файлы Nginx для каждого домена

- **Формат записи (item):**
  ```javascript
  {
    id: number,
    domain: string,
    dest: string,              // URL назначения
    ssl: boolean,
    active: boolean,           // включено ли проксирование
    notes: string,
    cf_ip: string|null,        // IP в CloudFlare DNS (кеш)
    cf_record_id: string|null, // ID DNS записи (кеш)
    cf_zone_id: string|null,   // CloudFlare Zone ID (кеш)
    cf_last_sync: string|null, // ISO timestamp последней синхронизации
    server_ip: string|null     // внешний IP сервера (кеш)
  }
  ```

### Ключевые компоненты

#### WebAdmin (server.js)

Основной сервер управления на Express.js:

- **Порт:** 8881
- **Аутентификация:** session-based с bcrypt
- **Логика создания/обновления записей:**
  - При создании/изменении записи автоматически генерируется nginx конфиг из шаблонов
  - Выполняется `nginx -t` для проверки конфигурации
  - При успешной проверке nginx перезагружается (`nginx -s reload`)
  - При ошибках происходит откат изменений

- **Шаблоны nginx:**
  - `/app/nginx/template.conf` — HTTP-проксирование
  - `/app/nginx/template_ssl.conf` — HTTPS-проксирование
  - Плейсхолдеры: `{host}`, `{destination}`, `{new_host}`, `{domain}`

- **CloudFlare API интеграция:**
  - Ручная реализация HTTPS-запросов (без axios)
  - Операции: getZoneId, getARecord, createARecord, updateARecord, deleteARecord
  - Кеширование DNS информации в items.json для быстрого отображения статуса

#### DNS Auto-Sync (sync-scheduler.js)

Планировщик автоматической синхронизации DNS-записей:

- **Интервалы:** 30 мин / 1 час / 12 часов / 24 часа
- **Логика:**
  - Проверяет только активные записи (active: true)
  - Сравнивает IP в CloudFlare с внешним IP сервера
  - Автоматически обновляет DNS при несовпадении
  - Сохраняет историю синхронизаций

#### SSL-сертификаты

- **Тип:** Wildcard сертификаты (`*.domain.com`)
- **Валидация:** DNS-01 challenge через CloudFlare API
- **Хранение:** `/acme.sh/*.domain.com_ecc/`
- **Автопродление:** через cron в контейнере acme_sh

### Важные паттерны работы

1. **Проверка SSL перед включением:**
   При включении SSL система проверяет наличие wildcard-сертификата для корневого домена. Если сертификат отсутствует, операция отклоняется с инструкцией получить его через меню "🔐 Получить сертификат".

2. **Откат при ошибках Nginx:**
   Все операции с записями (создание/обновление/удаление) выполняют откат изменений если `nginx -t` или `nginx -s reload` завершается с ошибкой.

3. **Импорт настроек:**
   При импорте из ZIP автоматически отключается SSL и active для всех записей (для безопасности).

4. **Извлечение корневого домена:**
   Функция `getRootDomain()` извлекает базовый домен из поддомена (например: `sub.example.com` → `example.com`).

## Команды для разработки

### Docker Compose

```bash
# Запуск всех контейнеров
docker-compose up -d

# Просмотр логов
docker-compose logs -f
docker-compose logs webadmin-app
docker-compose logs nginx

# Перезапуск конкретного сервиса
docker-compose restart webadmin-app
docker-compose restart nginx

# Остановка
docker-compose down

# Проверка статуса
docker-compose ps
```

### Работа с Nginx

```bash
# Проверка конфигурации
docker exec nginx_webserver nginx -t

# Перезагрузка без простоя
docker exec nginx_webserver nginx -s reload

# Просмотр логов
docker exec nginx_webserver tail -f /var/log/nginx/error.log
docker exec nginx_webserver tail -f /var/log/nginx/access.log
```

### Работа с acme.sh

```bash
# Получение сертификата (вручную)
docker exec -e CF_Token='your_token' acme_sh acme.sh --issue --dns dns_cf -d *.example.com -d example.com

# Список сертификатов
docker exec acme_sh acme.sh --list

# Информация о сертификате
docker exec acme_sh acme.sh --info -d *.example.com

# Принудительное обновление
docker exec -e CF_Token='your_token' acme_sh acme.sh --renew -d *.example.com --force
```

### WebAdmin Node.js

```bash
# Вход в контейнер
docker exec -it webadmin-app sh

# Просмотр логов в реальном времени
docker-compose logs -f webadmin-app

# Перезапуск после изменения кода
docker-compose restart webadmin-app
```

### Работа с данными

```bash
# Резервная копия данных
tar -czf backup_$(date +%Y%m%d).tar.gz data/ acme/ configs/nginx/sites/

# Просмотр конфигурационных файлов
ls -la configs/nginx/sites/

# Просмотр данных
cat data/items.json
cat data/user.json
```

## Скрипты установки и обновления

### install.sh
Автоматическое создание LXC-контейнера в Proxmox:
- Находит свободный CTID
- Устанавливает Docker и Docker Compose
- Скачивает latest.zip с GitHub
- Запускает docker-compose

### update.sh
Обновление приложения внутри контейнера:
- Создает резервную копию в `/var/reverse_proxy_backup_*`
- Останавливает контейнеры
- Сохраняет config, configs, data, acme, .env
- Обновляет файлы приложения
- Восстанавливает сохраненные данные
- Запускает контейнеры

## Структура конфигурации Nginx

Основной nginx.conf находится в `configs/nginx/nginx.conf`:
- Worker processes: auto
- Gzip включен
- Security headers
- Client max body size: 100M
- Включает все файлы из `/etc/nginx/conf.d/*.conf`

Конфиги сайтов генерируются из шаблонов в `/app/nginx/` и сохраняются в `configs/nginx/sites/{domain}.conf`.

## API Endpoints (основные)

### Управление записями
- GET /api/items — список записей
- POST /api/items — создание записи
- PUT /api/items/:id — обновление записи
- DELETE /api/items/:id — удаление записи
- PATCH /api/items/:id/toggle-ssl — переключение SSL
- PATCH /api/items/:id/toggle-active — переключение активности

### DNS CloudFlare
- POST /api/sync-all-dns — синхронизация всех DNS
- POST /api/items/:id/sync-dns — синхронизация одной записи
- POST /api/cloudflare/create-dns — создание DNS записи
- POST /api/cloudflare/update-dns — обновление IP
- POST /api/cloudflare/delete-dns — удаление DNS записи

### SSL сертификаты
- GET /api/ssl-certificates — список сертификатов
- POST /api/get-ssl-certificate — получение сертификата
- POST /api/delete-ssl-certificate — удаление сертификата
- POST /api/delete-all-ssl-certificates — удаление всех сертификатов

### Автосинхронизация
- GET /api/sync-settings — получение настроек
- POST /api/sync-settings — изменение интервала
- POST /api/manual-sync — ручной запуск
- GET /api/sync-history — история синхронизаций

### Настройки
- POST /api/save-cf-token — сохранение CloudFlare токена
- POST /api/clear-cf-token — удаление токена
- GET /api/cf-token-status — статус токена
- POST /api/change-password — смена пароля
- GET /api/export-settings — экспорт в ZIP
- POST /api/import-settings — импорт из ZIP

## Учетные данные по умолчанию

- **Логин:** admin
- **Пароль:** password123
- **Веб-интерфейс:** http://SERVER_IP:8881

## Важные пути в контейнерах

WebAdmin контейнер:
- `/app` — код приложения
- `/data` — persistent данные (user.json, items.json)
- `/nginx_config` — конфиги nginx
- `/acme.sh` — SSL сертификаты
- `/var/run/docker.sock` — для управления nginx контейнером

Nginx контейнер:
- `/etc/nginx/conf.d/` — конфиги сайтов
- `/var/www/acme-webroot` — для ACME HTTP-01 валидации
- `/acme` — доступ к сертификатам
- `/var/log/nginx` — логи

## Особенности разработки

1. **Изменения в webadmin/server.js:**
   После изменений необходим перезапуск: `docker-compose restart webadmin-app`

2. **Изменения в nginx шаблонах:**
   Шаблоны находятся в `webadmin/nginx/template*.conf` и копируются внутрь контейнера

3. **Тестирование nginx конфигов:**
   Всегда используйте `nginx -t` перед перезагрузкой

4. **Работа с DNS:**
   DNS изменения распространяются 5-10 минут, учитывайте при тестировании SSL

5. **Безопасность:**
   - CloudFlare токен требует права Zone:DNS:Edit
   - Session secret захардкоден в коде (изменить для production)
   - Пароль хешируется с помощью bcrypt (salt rounds: 10)