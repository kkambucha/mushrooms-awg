# Mushrooms-AWG — установщик AmneziaWG

Интерактивный установщик для Ubuntu: поднимает **AmneziaWG** в Docker (образ **amneziavpn/amneziawg-go:3.1.20260828**).  
Домен обязателен. Клиентские конфиги используют домен как Endpoint — после смены IP сервера достаточно обновить A-запись.

Нужен сервер amd64 (обычный Intel/AMD). На ARM установщик останавливается и не трогает файрвол, пока не установлен эмулятор `qemu-user-static`.

Файрвол включается после успешного старта туннеля. Открывается порт, по которому сейчас заходите на сервер, и порт туннеля (tcp или udp). Если порт входа определить не удалось, файрвол не включается. Зависание на «Configuring firewall» из‑за бесконечного `ufw delete` исправлено.

По умолчанию туннель — **TCP 443**. В визарде можно сменить порт и транспорт (tcp/udp). На сервере TCP задаётся через UAPI (`awg/transport.uapi` + `start.sh`): в `awg0.conf` нет строк `Network`/`Format*` — `awg setconf` в образе их не принимает. В клиентском `.conf`/`QR` по-прежнему `Network` и Format*. После смены порта/транспорта заново раздай conf/QR. Клиент: AmneziaWG / Amnezia VPN с поддержкой `Network=tcp`.

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
- Через туннель идёт IPv4, кроме домашних и служебных сетей и списков прямого доступа. IPv6 остаётся у провайдера телефона.

## Тот же сервер на новой машине

1. Сохрани текст `/opt/mushrooms-awg/state/server.json` (менеджер паролей / копия у себя).
2. Укажи A-запись домена на новый IP.
3. Две команды bootstrap + `install.sh`; тот же домен; путь к файлу оставь пустым и вставь JSON до строки `END` (или укажи путь к файлу).

Ключи не меняются — уже выданные клиентские конфиги продолжают работать, пока те же порт и транспорт. После смены порта/transport в визарде нужны новые conf/QR.

## Что генерируется само

Ключи сервера и клиентов, PSK, параметры обфускации AmneziaWG (`Jc`/`Jmin`/`Jmax`/`S1`–`S4`/`H1`–`H4`). Порт по умолчанию 443, транспорт **tcp** (можно сменить в визарде).  
В визарде достаточно домена (при переносе — вставка или путь к `server.json`).
