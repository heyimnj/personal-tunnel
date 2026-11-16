# Политика конфиденциальности Personal Tunnel

[English version below](#personal-tunnel-privacy-policy)

Personal Tunnel — VPN-клиент для iPhone. Серверы и подписки в него добавляете вы сами. Ниже написано, что приложение
делает с данными на самом деле. Всё взято из исходного кода этого репозитория, а не из шаблона.

## Коротко

- Нет аналитики, телеметрии, рекламы, учётных записей и своих серверов. Разработчик не получает ничего.
- Приложение подключается только к адресам подписок, которые вы добавили, к вашим VPN-серверам и к `www.gstatic.com`
  для проверки задержки.
- Провайдер подписки может получить HWID, модель iPhone, версию iOS и язык. Это отключается.
- Всё хранится только на iPhone. Кнопка «Удалить все данные» стирает это одним нажатием.

## 1. Что приложение не собирает

- Нет сторонних SDK, аналитики, рекламы и счётчиков. В сборку входят только ядро sing-box (форк sing-box-lx), Xray-core
  и код самого приложения.
- У приложения нет своего сервера. Отчёты о падениях, журналы и статистика никуда не отправляются: они лежат на
  iPhone, пока вы сами их не скопируете или не удалите.
- Нет учётных записей, оплаты и регистрации.
- Камера включается только для сканирования QR-кода, изображение не сохраняется. Face ID нужен только для
  блокировки приложения, если вы её включили, и проверяется самой iOS.

## 2. Куда приложение подключается само

| Куда | Когда | Что уходит |
|------|-------|------------|
| Адрес подписки, который вы добавили | при добавлении; по кнопке «Обновить»; один раз после обновления приложения (все подписки); после подключения VPN — если перед этим подписка не загрузилась без VPN | HTTP-запрос, заголовки — в разделе 3 |
| Ваши VPN-серверы | когда VPN включён | трафик устройства по протоколу сервера |
| Адреса ваших серверов напрямую | при проверке задержки (пинг): TCP-подключение, иногда TLS-рукопожатие с именем сервера | ничего, кроме самого подключения |
| `www.gstatic.com/generate_204` через сервер | при проверке задержки; при «Автовыборе» — каждые 3 минуты, пока VPN включён | пустой запрос; режим «Альтернативный» использует `http://`, остальные `https://` |
| `www.gstatic.com/generate_204` напрямую | по кнопке «Проверка соединения» | запрос `HEAD` |
| DNS-резолверы | пока VPN включён | см. ниже |

**DNS.** Имена сайтов разрешаются через выбранный резолвер (по умолчанию 1.1.1.1) **через VPN-сервер**: по HTTPS и по
TCP одновременно. Без VPN, обычным UDP, разрешаются только адреса ваших серверов, а при включённом «Обходе российских
сайтов» — ещё российские домены. Такие запросы уходят одновременно выбранному резолверу, Яндексу (77.88.8.8) и Google
(8.8.8.8). Провайдер интернета видит эти имена.

Сам по себе, без вашего действия или подключения VPN, приложение в сеть не выходит.

## 3. Что получает провайдер подписки

При загрузке подписки приложение представляется другим клиентом, потому что панели отдают полный список серверов только
известным приложениям. Оно пробует по очереди, пока панель не отдаст серверы:

1. `User-Agent: INCY/2.7.2`
2. `User-Agent: Happ/3.13.0`
3. `User-Agent: PersonalTunnel/2.0`

Всегда передаются `Accept: text/plain, application/json, */*` и ваш IP-адрес: провайдер видит его, как любой сайт.
Если панель вернула Xray JSON, приложение делает второй запрос как `PersonalTunnel/2.0`, без данных устройства, и
добавляет серверы, которых не было в первом ответе.

**Данные устройства** уходят только с INCY и Happ и только если у подписки включён переключатель «Передавать данные
устройства провайдеру»:

| Заголовок | Значение |
|-----------|----------|
| `X-HWID` | идентификатор устройства, 32 символа |
| `X-Device-OS` | `iOS` |
| `X-Ver-OS` | версия iOS, например `26.1` |
| `X-Device-Model` | модель, например `iPhone17,1` |
| `X-Device-Locale` | язык и регион системы, например `ru_RU` |

**Как получается HWID.** С версии 3.2.1 новый HWID — случайный (UUID без дефисов). Если HWID уже был, он сохраняется,
чтобы панели не посчитали iPhone новым устройством. Раньше HWID делался из первых 32 символов `identifierForVendor`
или переносился из версии 1.x. Хранится в Keychain («только на этом устройстве»). Его копия лежит в настройках
приложения, а настройки попадают в резервную копию — значит, при восстановлении из неё HWID переедет на новый iPhone.
Один и тот же HWID уходит всем панелям, у которых включена передача.

**Как отключить.**
- *Настройки → Конфиденциальность → «Для новых подписок»* — выключите до добавления подписки. Иначе первый же запрос
  уйдёт с данными устройства.
- *Настройки → Конфиденциальность* — отдельный переключатель у каждой подписки. Он же есть в «Управлении подписками» и
  в меню «…» у подписки в стиле «Классика».
- Без данных устройства некоторые панели не отдают серверы или считают iPhone новым устройством.

Чего приложение пока не делает (см. `audit/security-2026-11.md`, PT-13): не убирает эти заголовки, если панель
перенаправляет запрос на другой адрес.

## 4. Что хранится на iPhone

| Что | Где | Защита |
|-----|-----|--------|
| Подписки (их адреса), серверы и их ключи, выбранный сервер | общая папка приложения и VPN-расширения (App Group): `PersonalTunnel/library.json` | защита файлов iOS «до первой разблокировки» |
| Конфигурация, которую запускает VPN | там же: `PersonalTunnel/tunnel.json`, `tunnel-xray.json`; копия от ядра — `configuration.json` | то же |
| Журнал расширения, журнал Xray-core, отчёты о падениях ядра (с копией конфигурации) | там же: `PersonalTunnel/tunnel-events.log`, `Library/Caches/…` | то же |
| Данные версии 1.x, если вы обновлялись с неё | там же: `settings.db`, `configs/` | то же |
| HWID | Keychain, «только на этом устройстве» + копия в настройках | Keychain iOS |
| Настройки, избранное, порядок и фильтры серверов | настройки приложения (UserDefaults) | — |
| Шрифт, который вы выбрали сами | папка приложения `Application Support/Fonts` | — |
| Статистика трафика, результаты пинга, журнал ядра на экране | только в памяти, пропадают при закрытии приложения | — |

Ключи хранятся в JSON без дополнительного шифрования, только под защитой iOS. Файлы App Group и настройки **попадают в
резервную копию iCloud и компьютера**: в незашифрованной копии на компьютере они лежат открытым текстом.
«Резервные копии» в настройках создают файл со всеми ключами — храните его как пароль.

**Как удалить всё.** *Настройки → Конфиденциальность → «Удалить все данные»*. VPN отключается, его настройка удаляется
из iOS, стираются подписки и серверы, статистика, результаты пинга, журналы, отчёты о падениях, копии конфигурации,
данные 1.x, временные файлы и HWID (Keychain и копия). Настройки интерфейса и сети остаются. Нажмите кнопку **до**
удаления приложения: записи Keychain iOS при удалении приложения не стирает.

## 5. Журналы

- Журнал ядра виден в «Журнале службы» (до 1000 строк). Короткий журнал расширения (запуски, остановки, память)
  хранится в файле. Сами они никуда не отправляются.
- При копировании журнала, отчёта о падении или результата диагностики текст проходит через фильтр. Вырезаются
  ссылки серверов (`vless://`, `ss://`, `hysteria2://` и другие), адреса подписок с путём, значения полей `uuid`,
  `password`, `token`, `auth`, `private_key`, `public_key`, `short_id`, `psk`, `hwid`, `secret`, все UUID, а также имена
  ваших серверов и IP-адреса в строках с ними.
- **Остаются** домены и адреса сайтов, к которым шли соединения: при обычном уровне журнала ядро пишет каждое
  соединение. Прочитайте журнал, прежде чем отправлять его кому-то.
- Известные пробелы фильтра (audit PT-16): ссылки `socks4://`, `http-proxy://`, `https-proxy://`, токены после `Bearer`,
  поля `username` и `peer_public_key`.

## 6. Блокировка рекламы

Списки встроены в приложение и меняются только с его обновлением. Проверка идёт на iPhone, ни один запрос никуда не
отправляется. Заблокированное имя получает ответ `0.0.0.0` / `::`.

| Список | Источник | Лицензия |
|--------|----------|----------|
| `category-ads-all` | SagerNet sing-geosite (данные v2fly domain-list-community) | GPL-3.0 |
| Light, Pro, Pro++ (уровни «Базовый», «Стандартный», «Расширенный») | HaGeZi DNS Blocklists | GPL-3.0 |
| Encrypted DNS Bypass (DoH/DoT и iCloud Private Relay) | HaGeZi DNS Blocklists | GPL-3.0 |
| Российские и мобильные рекламные серверы | AdGuard Filters | GPL-3.0 |

Тексты лицензий и версии списков — в `PacketTunnel/Rules/*.NOTICE.txt`. При включённой блокировке зашифрованный DNS
приложений и iCloud Private Relay блокируются: их запросы идут через DNS туннеля и его блокировку.

## 7. Что видит провайдер VPN-сервера и чего приложение не скрывает

VPN прячет ваш трафик от провайдера интернета, но **не от владельца VPN-сервера**. Он видит:
- ваш настоящий IP-адрес, время подключения и объём трафика;
- куда вы подключаетесь: IP-адреса, имена сайтов (имя из TLS, заголовок `Host`) и DNS-запросы, которые идут через сервер;
- содержимое всего нешифрованного трафика (`http://`).

Мимо VPN — и потому видно провайдеру интернета — идут:
- российские сайты и адреса при «Обходе российских сайтов» (по умолчанию включён) и локальная сеть при «Локальной
  сети». Сайт может подгрузить что-то с российского адреса и так сопоставить ваш настоящий IP с IP VPN;
- адреса и домены ваших серверов (для пинга при включённом VPN) — audit PT-06;
- push-уведомления Apple и службы оператора (звонки, SMS) — даже при включённом kill switch;
- весь трафик, пока VPN переподключается или перезапускается, если kill switch выключен (по умолчанию выключен).

Известные недостатки этой версии описаны в `audit/security-2026-11.md`. Самый важный для конфиденциальности (PT-01):
пока работает сервер, который ведёт Xray-core, на iPhone открыт локальный SOCKS-порт без пароля, и другое приложение
может через него узнать IP сервера.

---

Действует для **Personal Tunnel 3.2.1 (PTBeta, beta 1, сборка 249)**. Дата: **16 ноября 2026 г.** При изменении
поведения приложения политика обновляется вместе с ним.

---

# Personal Tunnel privacy policy

Personal Tunnel is a VPN client for iPhone. You add its servers and subscriptions yourself. This page says what the
app actually does with data. It is taken from the source code of this repository, not from a template.

## In short

- No analytics, telemetry, ads, accounts or servers of its own. The developer receives nothing.
- The app connects only to the subscription addresses you added, your VPN servers, and `www.gstatic.com` for latency
  checks.
- A subscription provider may get the HWID, iPhone model, iOS version and language. This can be turned off.
- Everything stays on the iPhone. “Delete all data” erases it in one tap.

## 1. What the app does not collect

- No third-party SDKs, analytics, ads or counters. The build contains only the sing-box core (the sing-box-lx fork),
  Xray-core and the app's own code.
- The app has no server. Crash reports, logs and statistics are never sent anywhere: they stay on the iPhone until you
  copy or delete them.
- No accounts, payments or sign-up.
- The camera is used only to scan a QR code; nothing is saved. Face ID is used only for the app lock, if you turn it
  on, and is checked by iOS itself.

## 2. Where the app connects by itself

| Where | When | What is sent |
|-------|------|--------------|
| A subscription address you added | when added; on “Update”; once after an app update (every subscription); after the VPN connects, if the subscription failed to load without it | an HTTP request; headers in section 3 |
| Your VPN servers | while the VPN is on | the device's traffic, over the server's protocol |
| Your servers' addresses directly | during a latency check (ping): a TCP connection, sometimes a TLS handshake with the server's name | nothing but the connection itself |
| `www.gstatic.com/generate_204` through a server | during a latency check; with “Auto select”, every 3 minutes while the VPN is on | an empty request; the “Alternative” mode uses `http://`, the others `https://` |
| `www.gstatic.com/generate_204` directly | on “Connection check” | a `HEAD` request |
| DNS resolvers | while the VPN is on | see below |

**DNS.** Site names are resolved by the chosen resolver (1.1.1.1 by default) **through the VPN server**, over HTTPS and
TCP at once. Outside the VPN, over plain UDP, only your servers' addresses are resolved, plus Russian domains when
“Bypass Russian sites” is on. Those queries go at once to the chosen resolver, Yandex (77.88.8.8) and Google
(8.8.8.8). Your internet provider sees these names.

The app does not go online on its own without an action of yours or the VPN connecting.

## 3. What the subscription provider gets

When it downloads a subscription, the app introduces itself as another client, because panels give the full server
list only to clients they know. It tries in turn until the panel returns servers:

1. `User-Agent: INCY/2.7.2`
2. `User-Agent: Happ/3.13.0`
3. `User-Agent: PersonalTunnel/2.0`

Always sent: `Accept: text/plain, application/json, */*`, and your IP address, which the provider sees like any
website does. When the panel returns Xray JSON, the app makes a second request as `PersonalTunnel/2.0`, without device
data, and adds the servers the first answer lacked.

**Device data** is sent only with INCY and Happ, and only when the subscription's “Share device data with the provider”
switch is on:

| Header | Value |
|--------|-------|
| `X-HWID` | device identifier, 32 characters |
| `X-Device-OS` | `iOS` |
| `X-Ver-OS` | iOS version, e.g. `26.1` |
| `X-Device-Model` | model, e.g. `iPhone17,1` |
| `X-Device-Locale` | system language and region, e.g. `en_US` |

**How the HWID is made.** From 3.2.1 a new HWID is random (a UUID without dashes). An existing HWID is kept, so panels
do not count the iPhone as a new device. Earlier versions took the first 32 characters of `identifierForVendor`, or
carried the HWID over from 1.x. It is stored in the Keychain (“this device only”). A copy sits in the app's settings,
and settings go into backups, so restoring a backup moves the HWID to a new iPhone. The same HWID goes to every panel
that has sharing on.

**How to turn it off.**
- *Settings → Privacy → “For new subscriptions”*: turn it off before adding a subscription. Otherwise the very first
  request goes out with device data.
- *Settings → Privacy*: a switch for each subscription. It is also in “Manage subscriptions” and in a subscription's
  “…” menu in the “Classic” style.
- Without device data some panels give no servers or count the iPhone as a new device.

Not done yet (see `audit/security-2026-11.md`, PT-13): the headers are not removed when a panel redirects the request
to another address.

## 4. What is stored on the iPhone

| What | Where | Protection |
|------|-------|------------|
| Subscriptions (their addresses), servers and their keys, the chosen server | the folder the app shares with its VPN extension (App Group): `PersonalTunnel/library.json` | iOS file protection “until first unlock” |
| The configuration the VPN runs | same place: `PersonalTunnel/tunnel.json`, `tunnel-xray.json`; the core's copy, `configuration.json` | same |
| The extension's log, Xray-core's log, core crash reports (with a copy of the configuration) | same place: `PersonalTunnel/tunnel-events.log`, `Library/Caches/…` | same |
| Data of version 1.x, if you updated from it | same place: `settings.db`, `configs/` | same |
| HWID | Keychain, “this device only”, plus a copy in settings | iOS Keychain |
| Settings, favourites, server order and filters | app settings (UserDefaults) | — |
| A font you picked yourself | the app's `Application Support/Fonts` folder | — |
| Traffic statistics, ping results, the on-screen core log | memory only; gone when the app closes | — |

Keys are stored as JSON with no encryption beyond iOS's own protection. App Group files and settings **go into iCloud
and computer backups**; an unencrypted computer backup holds them as plain text. “Backups” in Settings creates a file
with every key: keep it like a password.

**How to delete everything.** *Settings → Privacy → “Delete all data”*. The VPN disconnects and its configuration is
removed from iOS. Erased: subscriptions and servers, statistics, ping results, logs, crash reports, configuration
copies, 1.x data, temporary files and the HWID (the Keychain item and its copy). Interface and network settings stay.
Tap it **before** deleting the app: iOS does not erase Keychain items when an app is deleted.

## 5. Logs

- The core's log is shown in “Service log” (up to 1000 lines). The extension's short log (starts, stops, memory) is
  kept in a file. Neither is sent anywhere by itself.
- When you copy the log, a crash report or a diagnostics result, the text goes through a filter. Removed: server links
  (`vless://`, `ss://`, `hysteria2://` and others), subscription addresses with a path, the values of `uuid`,
  `password`, `token`, `auth`, `private_key`, `public_key`, `short_id`, `psk`, `hwid`, `secret`, every UUID, and your
  servers' names together with the IP addresses on their lines.
- **Kept:** the domains and addresses of sites connections went to; at the normal log level the core logs every
  connection. Read the log before sending it to anyone.
- Known gaps in the filter (audit PT-16): `socks4://`, `http-proxy://`, `https-proxy://` links, tokens after `Bearer`,
  the `username` and `peer_public_key` fields.

## 6. Ad blocking

The lists are built into the app and change only with an app update. Matching happens on the iPhone; no request is
sent anywhere. A blocked name gets the answer `0.0.0.0` / `::`.

| List | Source | Licence |
|------|--------|---------|
| `category-ads-all` | SagerNet sing-geosite (data from v2fly domain-list-community) | GPL-3.0 |
| Light, Pro, Pro++ (levels “Basic”, “Standard”, “Extended”) | HaGeZi DNS Blocklists | GPL-3.0 |
| Encrypted DNS Bypass (DoH/DoT and iCloud Private Relay) | HaGeZi DNS Blocklists | GPL-3.0 |
| Russian and mobile ad servers | AdGuard Filters | GPL-3.0 |

Licence texts and list versions are in `PacketTunnel/Rules/*.NOTICE.txt`. With blocking on, apps' own encrypted DNS and
iCloud Private Relay are blocked, so their queries go through the tunnel's DNS and its blocking.

## 7. What the VPN server's provider sees, and what the app does not hide

A VPN hides your traffic from your internet provider, **not from whoever runs the VPN server**. That party sees:
- your real IP address, connection times and traffic volume;
- where you connect: IP addresses, site names (the TLS name, the `Host` header) and the DNS queries that go through
  the server;
- the full content of any unencrypted traffic (`http://`).

Outside the VPN, and so visible to your internet provider:
- Russian sites and addresses with “Bypass Russian sites” (on by default), and the local network with “Local
  network”. A site can load something from a Russian address and so match your real IP with the VPN's;
- your servers' addresses and domains (for ping while the VPN is on), audit PT-06;
- Apple push notifications and carrier services (calls, SMS), even with the kill switch on;
- all traffic while the VPN reconnects or restarts, if the kill switch is off (it is off by default).

Known weaknesses of this version are described in `audit/security-2026-11.md`. The most important one for privacy
(PT-01): while a server run by Xray-core is in use, the iPhone has a local SOCKS port without a password, and another
app can learn the server's IP through it.

---

Applies to **Personal Tunnel 3.2.1 (PTBeta, beta 1, build 249)**. Date: **16 November 2026**. The policy is updated
whenever the app's behaviour changes.
