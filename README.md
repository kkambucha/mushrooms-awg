# Mushrooms-AWG — установщик AmneziaWG

Интерактивный установщик для Ubuntu: поднимает **AmneziaWG** в Docker (образ **amneziavpn/amneziawg-go:3.1.20260828**).  
Домен обязателен. Клиентские конфиги используют домен как Endpoint — после смены IP сервера достаточно обновить A-запись.

## Установка

Две команды подряд на чистом Ubuntu:

```bash
curl -fsSL https://raw.githubusercontent.com/kkambucha/mushrooms-awg/main/bootstrap.sh | sudo bash
cd /opt/mushrooms-awg-src && sudo bash install.sh
```

После первой ждать `OK: bootstrap finished` (при сбое — `ERROR: bootstrap failed`).  
После второй — визард (домен; при переносе — путь к `server.json` или вставка JSON до строки `END`), затем `Done.` и `/opt/mushrooms-awg/DEPLOY.txt`.

## Проверка

```bash
cat /opt/mushrooms-awg/DEPLOY.txt
cd /opt/mushrooms-awg && docker compose ps
docker exec mushrooms_awg awg show
```

- Нет `/opt/mushrooms-awg` или нет `DEPLOY.txt` — установка не дошла до конца; смотри вывод `install.sh`.
- Клиент: приложение **AmneziaWG** — скан QR (`clients/<имя>.png`) или импорт `clients/<имя>.conf`.
- Полный список прямых сетей (опционально): импорт `clients/<имя>.full.conf`, затем удалить короткий туннель.

## Тот же сервер на новой машине

1. Сохрани текст `/opt/mushrooms-awg/state/server.json` (менеджер паролей / копия у себя).
2. Укажи A-запись домена на новый IP.
3. Две команды bootstrap + `install.sh`; тот же домен; путь к файлу оставь пустым и вставь JSON до строки `END` (или укажи путь к файлу).

Ключи и порт не меняются — уже выданные клиентские конфиги продолжают работать.

## Что генерируется само

Порт UDP, ключи сервера и клиентов, PSK, параметры обфускации AmneziaWG (`Jc`/`Jmin`/`Jmax`/`S1`–`S4`/`H1`–`H4`).  
В визарде достаточно домена (при переносе — вставка или путь к `server.json`).
