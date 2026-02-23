# Ghost Chat - Инструкция по деплою

## Требования

- Выделенный сервер с Linux (Ubuntu 20.04+ / Debian 11+)
- Docker и Docker Compose
- Домен с настроенным DNS (A-запись на IP сервера)
- Открытые порты: 80, 443, 3478, 5349, 49152-65535

## Шаг 1: Подготовка сервера

```bash
# Установка Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Установка Docker Compose
sudo apt install docker-compose-plugin

# Перелогиньтесь для применения групп
exit
```

## Шаг 2: Загрузка проекта на сервер

```bash
# Создаём директорию
mkdir -p /opt/ghost-chat
cd /opt/ghost-chat

# Копируем файлы (или используем git/scp)
# scp -r ./messanger/* user@server:/opt/ghost-chat/
```

## Шаг 3: Конфигурация

### 3.1 Замените плейсхолдеры

```bash
cd /opt/ghost-chat/deploy

# Замените YOUR_DOMAIN.com на ваш домен
sed -i 's/YOUR_DOMAIN.com/ваш-домен.com/g' nginx.conf turnserver.conf setup-ssl.sh

# Замените YOUR_SERVER_PUBLIC_IP на IP сервера
sed -i 's/YOUR_SERVER_PUBLIC_IP/123.45.67.89/g' turnserver.conf

# Сгенерируйте пароль для TURN
TURN_PASSWORD=$(openssl rand -hex 16)
sed -i "s/REPLACE_WITH_STRONG_PASSWORD/$TURN_PASSWORD/g" turnserver.conf
echo "TURN Password: $TURN_PASSWORD"
```

### 3.2 Обновите TURN в клиенте

Откройте `client/js/webrtc.js` и замените turnServers на:

```javascript
const turnServers = [
  {
    urls: 'turn:ваш-домен.com:3478',
    username: 'ghostchat',
    credential: 'ВАШ_TURN_ПАРОЛЬ'
  },
  {
    urls: 'turn:ваш-домен.com:5349?transport=tcp',
    username: 'ghostchat',
    credential: 'ВАШ_TURN_ПАРОЛЬ'
  },
  {
    urls: 'turns:ваш-домен.com:5349',
    username: 'ghostchat',
    credential: 'ВАШ_TURN_ПАРОЛЬ'
  }
];
```

## Шаг 4: SSL Сертификаты

```bash
cd /opt/ghost-chat/deploy

# Делаем скрипт исполняемым
chmod +x setup-ssl.sh firewall.sh

# Получаем сертификат (требуется открытый порт 80)
sudo ./setup-ssl.sh
```

## Шаг 5: Настройка Firewall

```bash
sudo ./firewall.sh
```

## Шаг 6: Запуск

```bash
cd /opt/ghost-chat/deploy

# Сборка и запуск
docker-compose up -d

# Проверка логов
docker-compose logs -f
```

## Проверка работоспособности

1. Откройте `https://ваш-домен.com` в браузере
2. Создайте комнату
3. Откройте в другом браузере/устройстве и присоединитесь
4. Проверьте текстовые сообщения
5. Проверьте голосовой звонок
6. Включите "Скрыть IP" и проверьте соединение через TURN

## Мониторинг

```bash
# Статус контейнеров
docker-compose ps

# Логи приложения
docker-compose logs ghost-chat

# Логи nginx
docker-compose logs nginx

# Проверка TURN сервера
docker logs ghost-turn
```

## Обновление

```bash
cd /opt/ghost-chat/deploy

# Остановка
docker-compose down

# Обновление файлов (git pull или scp)

# Пересборка и запуск
docker-compose up -d --build
```

## Бэкап

Проект stateless - данных для бэкапа нет. Сохраняйте только:
- SSL сертификаты (`deploy/ssl/`)
- Конфигурационные файлы

## Безопасность

| Компонент | Защита |
|-----------|--------|
| HTTPS | TLS 1.3, HSTS, современные шифры |
| WebSocket | WSS (TLS) |
| Headers | CSP, X-Frame-Options, Referrer-Policy |
| Сообщения | E2E AES-256-GCM |
| Звонки | DTLS-SRTP |
| IP | Собственный TURN relay |
| Сервер | Без логов, без хранения данных |

## Troubleshooting

### Не работает TURN

1. Проверьте что порты открыты: `sudo netstat -tlnp | grep turn`
2. Проверьте credentials в turnserver.conf и webrtc.js
3. Тест: `turnutils_uclient -T -u ghostchat -w ПАРОЛЬ ваш-домен.com`

### Не работает WebSocket

1. Проверьте nginx logs: `docker-compose logs nginx`
2. Проверьте что upgrade headers проходят

### Сертификат не обновляется

```bash
certbot renew --dry-run
docker-compose restart nginx
```
