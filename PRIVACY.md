# Политика конфиденциальности Personal Tunnel

[English version below](#personal-tunnel-privacy-policy)

Personal Tunnel — VPN-клиент для iPhone. Серверы и подписки в него добавляете вы сами. Ниже написано, что приложение
делает с данными на самом деле. Всё взято из исходного кода этого репозитория, а не из шаблона.

## Коротко

- Нет аналитики, телеметрии, рекламы, учётных записей и своих серверов. Разработчик не получает ничего.
- Приложение подключается только к адресам подписок, которые вы добавили, к вашим VPN-серверам, к `www.gstatic.com`
  для проверки задержки и к выбранным резолверам DNS.
- Перед каждым добавлением приложение показывает, что именно добавляется, и спрашивает про данные устройства.
- Провайдер подписки может получить HWID (свой для каждой новой подписки), модель iPhone, а при необходимости версию
  iOS и язык. Это отключается.
- Всё хранится только на iPhone. «Удалить все данные» стирает это одним нажатием.

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
| Адрес подписки, который вы добавили (только `https://`) | после «Добавить» на экране подтверждения; по кнопке «Обновить»; один раз после обновления приложения (все подписки); после подключения VPN — если перед этим подписка не загрузилась без VPN | HTTP-запрос, заголовки — в разделе 3 |
| Ваши VPN-серверы | когда VPN включён | трафик устройства по протоколу сервера |
| Адреса ваших серверов напрямую | при проверке задержки (пинг): TCP-подключение, иногда TLS-рукопожатие с именем сервера | ничего, кроме самого подключения |
| `www.gstatic.com/generate_204` через сервер | при проверке задержки; при «Автовыборе» — каждые 3 минуты, пока VPN включён | пустой запрос; режим «Альтернативный» использует `http://`, остальные `https://` |
| `www.gstatic.com/generate_204` напрямую | по кнопке «Проверка соединения» | запрос `HEAD` |
| DNS-резолверы | пока VPN включён и при пинге | см. ниже |

**Пинг при включённом VPN.** Ядро приложения, которое проверяет задержку серверов, подключается к ним по физической сети
(Wi-Fi, сотовая): так оно измеряет сам сервер, а в туннеле для этого нет никаких обходов. С kill switch iOS ничего не
выпускает мимо туннеля, и тогда пинг идёт через него.

**DNS.** Имена сайтов разрешаются через резолвер 1.1.1.1 **через VPN-сервер**: по HTTPS и по TCP одновременно. Мимо
туннеля разрешаются только адреса ваших серверов — по DNS over HTTPS через резолверы из настройки «DNS вне туннеля»
(по умолчанию Cloudflare и Google; можно выбрать Cloudflare, Google, Quad9 или Яндекс). При включённом «Обходе
российских сайтов» российские домены разрешаются через Яндекс, тоже по HTTPS. Провайдер интернета видит, что вы
обращаетесь к этим резолверам, но не видит имён. Если сеть не пропускает DNS over HTTPS, те же резолверы
спрашиваются обычным DNS — тогда провайдер видит имена серверов; DNS over HTTPS пробуется снова через 2 минуты.

Сам по себе, без вашего действия или подключения VPN, приложение в сеть не выходит.

## 3. Что получает провайдер подписки

**Перед добавлением.** Ссылка из буфера, QR-код, файл или введённый текст сначала показываются на экране
подтверждения: для подписки — только её хост (без пути и токена) и переключатель «Передавать данные устройства
провайдеру», для серверов — их число и протоколы. Пока вы не нажали «Добавить», по сети ничего не уходит. Адреса
`http://` не принимаются: адрес с токеном и данные устройства ушли бы без шифрования.

**Как представляется приложение.** Панели отдают полный список серверов только известным приложениям, поэтому приложение
представляется другим клиентом. Оно пробует по очереди, пока панель не отдаст серверы:

1. `User-Agent: INCY/2.7.2`
2. `User-Agent: Happ/3.13.0`
3. `User-Agent: PersonalTunnel/2.0` (без данных устройства)

Всегда передаются `Accept: text/plain, application/json, */*` и ваш IP-адрес: провайдер видит его, как любой сайт.
Если панель вернула Xray JSON, приложение делает второй запрос как `PersonalTunnel/2.0`, без данных устройства, и
добавляет серверы, которых не было в первом ответе.

**Данные устройства** уходят только с INCY и Happ и только если у подписки включён переключатель «Передавать данные
устройства провайдеру». Сначала — без версии iOS и языка. Они добавляются, только если без них панель серверы не отдала:

| Заголовок | Значение | Когда |
|-----------|----------|-------|
| `X-HWID` | идентификатор, 32 символа | всегда (при включённом переключателе) |
| `X-Device-OS` | `iOS` | всегда |
| `X-Device-Model` | модель, например `iPhone17,1` | всегда |
| `X-Ver-OS` | версия iOS, например `26.1` | только при второй попытке |
| `X-Device-Locale` | язык и регион системы, например `ru_RU` | только при второй попытке |

Если панель перенаправляет запрос на другой хост, данные устройства туда не передаются. Перенаправление на `http://`
не выполняется: загрузка останавливается.

**Как получается HWID.** У iPhone есть свой идентификатор: случайный (UUID без дефисов), созданный при первом
обращении. Если он был ещё в прежних версиях, он сохраняется: тогда он получен из `identifierForVendor` или перенесён
из 1.x. Хранится только в Keychain, «только на этом устройстве»: в резервные копии он не попадает и на другой iPhone не
переезжает. Подписка, добавленная начиная с 3.2.1, отправляет не его, а свой HWID: HMAC-SHA256 от него и хоста панели,
первые 32 символа. Разные панели не могут сопоставить ваше устройство по HWID. Подписки, добавленные раньше,
отправляют прежний общий HWID, чтобы панели не посчитали iPhone новым устройством.

**Как отключить.**
- На экране подтверждения при добавлении — переключатель «Передавать данные устройства провайдеру».
- *Настройки → Конфиденциальность → «Для новых подписок»* — значение этого переключателя по умолчанию.
- *Настройки → Конфиденциальность* — отдельный переключатель у каждой подписки. Он же есть в «Управлении подписками» и
  в меню «…» у подписки в стиле «Классика».
- Без данных устройства некоторые панели не отдают серверы или считают iPhone новым устройством.

## 4. Что хранится на iPhone

| Что | Где | Защита | В бэкапе |
|-----|-----|--------|----------|
| Подписки (их адреса), серверы и их ключи, выбранный сервер | общая папка приложения и VPN-расширения (App Group): `PersonalTunnel/library.json` | файл открывается только при разблокированном iPhone | нет |
| Конфигурация, которую запускает VPN | там же: `PersonalTunnel/tunnel.json`, `tunnel-xray.json` | «до первой разблокировки» (VPN по требованию запускается и на заблокированном iPhone) | нет |
| Журнал расширения | `PersonalTunnel/tunnel-events.log` | то же | нет |
| Журнал Xray-core, отчёты о падениях ядра (хранятся 7 дней) | `Library/Caches/…` в App Group | то же | нет |
| Данные версии 1.x, если вы обновлялись с неё | App Group: `settings.db`, `configs/` — не удаляются при обновлении | то же | нет |
| HWID | Keychain, «только на этом устройстве» | Keychain iOS | нет |
| Настройки, избранное, порядок и фильтры серверов (без ключей) | настройки приложения (UserDefaults) | — | да |
| Шрифт, который вы выбрали сами | папка приложения `Application Support/Fonts` | — | да |
| Статистика трафика, результаты пинга, журнал ядра на экране | только в памяти, пропадают при закрытии приложения | — | — |

Ключи хранятся в JSON без дополнительного шифрования, под защитой файлов iOS. Ядро больше не делает своих копий
конфигурации (`configuration.json`), а сделанные прежними версиями удаляются при запуске. Ядра sing-box и Xray-core
работают в одном процессе и передают соединения друг другу в памяти: локального порта, к которому могло бы
подключиться другое приложение, нет. Единственное исключение (3.2.7) — при включённом kill switch VPN-расширение
слушает один порт на 127.0.0.1 для проверки задержки серверов приложением: только с логином и паролем, которые
случайно созданы на этом устройстве и известны лишь приложению, и только напрямую к серверам проверки. Без
kill switch этого порта нет.

«Резервные копии» в настройках создают файл со всеми ключами — храните его как пароль. Временная копия удаляется сразу
после сохранения. Восстановление из копии сначала спрашивает подтверждение. Ссылки, скопированные приложением, видны
только на этом iPhone (без Universal Clipboard) и пропадают из буфера через 2 минуты.

**Как удалить всё.** *Настройки → Конфиденциальность → «Удалить все данные»*. VPN отключается, его настройка удаляется
из iOS, стираются подписки и серверы, статистика, результаты пинга, журналы, отчёты о падениях, копии конфигурации,
данные 1.x, временные файлы, HWID в Keychain и скопированная приложением ссылка, если она ещё в буфере. Настройки
интерфейса и сети остаются. Нажмите кнопку **до** удаления приложения: записи Keychain iOS при удалении приложения не
стирает.

## 5. Журналы

- Ядро пишет только предупреждения и ошибки. «Подробный журнал для диагностики» в меню «Журнала службы» включает
  запись каждого соединения на 30 минут и выключается сам, даже если приложение закрыто. «Подробный журнал» — каждый
  пакет, для разработки.
- Журнал виден в «Журнале службы» (до 1000 строк). Короткий журнал расширения (запуски, остановки, память) хранится
  в файле. Сами они никуда не отправляются.
- При копировании журнала, отчёта о падении или результата диагностики текст проходит через фильтр. Вырезаются:
  - ссылки серверов — все схемы, которые приложение понимает;
  - адреса подписок с путём или параметрами, токены после `Bearer`;
  - значения полей `uuid`, `password`, `username`, `token`, `auth`, ключи, `short_id`, `pbk`, `sid`, `psk`, `hwid`,
    `id` и подобные, в том числе внутри экранированного JSON; все UUID;
  - имена ваших серверов;
  - адреса сайтов, к которым шли соединения (`<назначение>`);
  - все IP-адреса, кроме адресов самого туннеля (`<адрес>`).

## 6. Блокировка рекламы

Списки встроены в приложение и меняются только с его обновлением. Проверка идёт на iPhone, ни один запрос никуда не
отправляется. Заблокированное имя получает ответ `0.0.0.0` / `::`.

| Список | Источник | Лицензия |
|--------|----------|----------|
| `category-ads-all` | SagerNet sing-geosite (данные v2fly domain-list-community) | GPL-3.0 |
| Light, Pro, Pro++ (уровни «Базовый», «Стандартный», «Расширенный») | HaGeZi DNS Blocklists | GPL-3.0 |
| Encrypted DNS Bypass (DoH/DoT и iCloud Private Relay) | HaGeZi DNS Blocklists | GPL-3.0 |
| Российские и мобильные рекламные серверы | AdGuard Filters | GPL-3.0 |

Тексты лицензий, версии списков и коммиты источников — в `PacketTunnel/Rules/*.NOTICE.txt`. При включённой блокировке
зашифрованный DNS приложений и iCloud Private Relay блокируются: их запросы идут через DNS туннеля и его блокировку.

## 7. Что видит провайдер VPN-сервера и чего приложение не скрывает

VPN прячет ваш трафик от провайдера интернета, но **не от владельца VPN-сервера**. Он видит:
- ваш настоящий IP-адрес, время подключения и объём трафика;
- куда вы подключаетесь: IP-адреса, имена сайтов (имя из TLS, заголовок `Host`) и DNS-запросы, которые идут через сервер;
- содержимое всего нешифрованного трафика (`http://`).

Мимо VPN — и потому видно провайдеру интернета — идут:
- российские сайты и адреса при «Обходе российских сайтов» (по умолчанию включён) и локальная сеть при «Локальной
  сети». Сайт может подгрузить что-то с российского адреса и так увидеть ваш настоящий IP рядом с IP VPN;
- push-уведомления Apple и службы оператора (звонки, SMS) — так устроена iOS, даже при включённом kill switch;
- без kill switch — весь трафик, пока VPN переподключается или перезапускается системой. Kill switch включён по
  умолчанию у новых установок; у обновившихся сохранено прежнее значение. Смена сервера при включённом VPN больше не
  выключает туннель.

Сервер без проверки сертификата отмечен в списке как «сертификат не проверяется»: соединение с ним можно перехватить.

Что сознательно оставлено как есть (подробно — в `audit/security-2026-11.md`):
- приложение представляется клиентами INCY и Happ — иначе часть панелей не отдаёт серверы;
- ключи хранятся в файлах под защитой iOS, а не в Keychain: расширению они нужны и на заблокированном iPhone, так что
  Keychain дал бы ту же защиту;
- данные 1.x при обновлении не удаляются (остаются для отката), но в резервные копии не попадают.

---

Действует для **Personal Tunnel 3.2.1 (сборка 255)**. Дата: **16 ноября 2026 г.** При изменении
поведения приложения политика обновляется вместе с ним.

---

# Personal Tunnel privacy policy

Personal Tunnel is a VPN client for iPhone. You add its servers and subscriptions yourself. This page says what the
app actually does with data. It is taken from the source code of this repository, not from a template.

## In short

- No analytics, telemetry, ads, accounts or servers of its own. The developer receives nothing.
- The app connects only to the subscription addresses you added, your VPN servers, `www.gstatic.com` for latency checks
  and the DNS resolvers you chose.
- Before anything is added, the app shows what it is and asks about device data.
- A subscription provider may get an HWID (its own for each new subscription), the iPhone model and, if needed, the
  iOS version and language. This can be turned off.
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
| A subscription address you added (`https://` only) | after “Add” on the confirmation screen; on “Update”; once after an app update (every subscription); after the VPN connects, if the subscription failed to load without it | an HTTP request; headers in section 3 |
| Your VPN servers | while the VPN is on | the device's traffic, over the server's protocol |
| Your servers' addresses directly | during a latency check (ping): a TCP connection, sometimes a TLS handshake with the server's name | nothing but the connection itself |
| `www.gstatic.com/generate_204` through a server | during a latency check; with “Auto select”, every 3 minutes while the VPN is on | an empty request; the “Alternative” mode uses `http://`, the others `https://` |
| `www.gstatic.com/generate_204` directly | on “Connection check” | a `HEAD` request |
| DNS resolvers | while the VPN is on, and during ping | see below |

**Ping with the VPN on.** The app's own core that measures servers reaches them over the physical network (Wi-Fi,
cellular): it measures the server itself, and the tunnel keeps no way around itself for that. With the kill switch iOS
lets nothing around the tunnel, and then ping goes through it.

**DNS.** Site names are resolved by 1.1.1.1 **through the VPN server**, over HTTPS and TCP at once. Outside the tunnel
only your servers' addresses are resolved, over DNS over HTTPS by the resolvers of the “DNS outside the tunnel” setting
(Cloudflare and Google by default; Cloudflare, Google, Quad9 or Yandex can be chosen). With “Bypass Russian sites” on,
Russian domains are resolved by Yandex, over HTTPS too. Your internet provider sees that you talk to these resolvers,
not the names. If the network blocks DNS over HTTPS, the same resolvers are asked over plain DNS, and the provider
then sees your servers' names; DNS over HTTPS is tried again after 2 minutes.

The app does not go online on its own without an action of yours or the VPN connecting.

## 3. What the subscription provider gets

**Before anything is added.** A link from the clipboard, a QR code, a file or typed text is first shown on a
confirmation screen: for a subscription only its host (no path, no token) and the “Share device data with the
provider” switch; for servers their number and protocols. Nothing goes over the network until you tap “Add”. `http://`
addresses are refused: the address with its token and the device data would travel unencrypted.

**How the app introduces itself.** Panels give the full server list only to clients they know, so the app introduces
itself as another client. It tries in turn until the panel returns servers:

1. `User-Agent: INCY/2.7.2`
2. `User-Agent: Happ/3.13.0`
3. `User-Agent: PersonalTunnel/2.0` (no device data)

Always sent: `Accept: text/plain, application/json, */*`, and your IP address, which the provider sees like any
website does. When the panel returns Xray JSON, the app makes a second request as `PersonalTunnel/2.0`, without device
data, and adds the servers the first answer lacked.

**Device data** is sent only with INCY and Happ, and only when the subscription's “Share device data with the provider”
switch is on. First without the iOS version and language; they are added only if the panel gave no servers without
them:

| Header | Value | When |
|--------|-------|------|
| `X-HWID` | identifier, 32 characters | always (with the switch on) |
| `X-Device-OS` | `iOS` | always |
| `X-Device-Model` | model, e.g. `iPhone17,1` | always |
| `X-Ver-OS` | iOS version, e.g. `26.1` | on the second try only |
| `X-Device-Locale` | system language and region, e.g. `en_US` | on the second try only |

When a panel redirects the request to another host, the device data does not go there. A redirect to `http://` is not
followed: the download stops.

**How the HWID is made.** The iPhone has an identifier of its own: random (a UUID without dashes), made when first
needed. If it existed in an earlier version it is kept; it then came from `identifierForVendor` or was carried over
from 1.x. It is stored only in the Keychain, “this device only”: it does not go into backups or move to another iPhone.
A subscription added from 3.2.1 on does not send it but an HWID of its own: HMAC-SHA256 of it and the panel's host, the
first 32 characters. Different panels cannot match your device by its HWID. Subscriptions added earlier send the
former shared HWID, so panels do not count the iPhone as a new device.

**How to turn it off.**
- On the confirmation screen when adding: the “Share device data with the provider” switch.
- *Settings → Privacy → “For new subscriptions”*: that switch's default.
- *Settings → Privacy*: a switch for each subscription. It is also in “Manage subscriptions” and in a subscription's
  “…” menu in the “Classic” style.
- Without device data some panels give no servers or count the iPhone as a new device.

## 4. What is stored on the iPhone

| What | Where | Protection | In backups |
|------|-------|------------|------------|
| Subscriptions (their addresses), servers and their keys, the chosen server | the folder the app shares with its VPN extension (App Group): `PersonalTunnel/library.json` | opens only while the iPhone is unlocked | no |
| The configuration the VPN runs | same place: `PersonalTunnel/tunnel.json`, `tunnel-xray.json` | “until first unlock” (On Demand starts the VPN on a locked iPhone too) | no |
| The extension's log | `PersonalTunnel/tunnel-events.log` | same | no |
| Xray-core's log, core crash reports (kept 7 days) | `Library/Caches/…` in the App Group | same | no |
| Data of version 1.x, if you updated from it | App Group: `settings.db`, `configs/`, not deleted by updates | same | no |
| HWID | Keychain, “this device only” | iOS Keychain | no |
| Settings, favourites, server order and filters (no keys) | app settings (UserDefaults) | — | yes |
| A font you picked yourself | the app's `Application Support/Fonts` folder | — | yes |
| Traffic statistics, ping results, the on-screen core log | memory only; gone when the app closes | — | — |

Keys are stored as JSON with no encryption beyond iOS file protection. The core no longer makes copies of the
configuration (`configuration.json`), and those earlier versions made are deleted at launch. sing-box and Xray-core run
in one process and hand connections to each other in memory: there is no local port another app could connect to.

“Backups” in Settings creates a file with every key: keep it like a password. The temporary copy is deleted right
after it is saved. Restoring a backup asks first. Links the app copies stay on this iPhone (no Universal Clipboard)
and leave the clipboard after 2 minutes.

**How to delete everything.** *Settings → Privacy → “Delete all data”*. The VPN disconnects and its configuration is
removed from iOS. Erased: subscriptions and servers, statistics, ping results, logs, crash reports, configuration
copies, 1.x data, temporary files, the HWID in the Keychain, and a link the app copied if it is still on the clipboard.
Interface and network settings stay. Tap it **before** deleting the app: iOS does not erase Keychain items when an app
is deleted.

## 5. Logs

- The core logs only warnings and errors. “Diagnostic log” in the “Service log” menu logs every connection for 30
  minutes and turns itself off, even when the app is closed. “Verbose log” logs every packet, for development.
- The log is shown in “Service log” (up to 1000 lines). The extension's short log (starts, stops, memory) is kept in a
  file. Neither is sent anywhere by itself.
- When you copy the log, a crash report or a diagnostics result, the text goes through a filter. Removed:
  - server links, every scheme the app understands;
  - subscription addresses with a path or parameters, tokens after `Bearer`;
  - the values of `uuid`, `password`, `username`, `token`, `auth`, keys, `short_id`, `pbk`, `sid`, `psk`, `hwid`, `id`
    and the like, escaped JSON included; every UUID;
  - your servers' names;
  - the addresses of the sites connections went to (`<destination>`);
  - every IP address but the tunnel's own (`<address>`).

## 6. Ad blocking

The lists are built into the app and change only with an app update. Matching happens on the iPhone; no request is
sent anywhere. A blocked name gets the answer `0.0.0.0` / `::`.

| List | Source | Licence |
|------|--------|---------|
| `category-ads-all` | SagerNet sing-geosite (data from v2fly domain-list-community) | GPL-3.0 |
| Light, Pro, Pro++ (levels “Basic”, “Standard”, “Extended”) | HaGeZi DNS Blocklists | GPL-3.0 |
| Encrypted DNS Bypass (DoH/DoT and iCloud Private Relay) | HaGeZi DNS Blocklists | GPL-3.0 |
| Russian and mobile ad servers | AdGuard Filters | GPL-3.0 |

Licence texts, list versions and source commits are in `PacketTunnel/Rules/*.NOTICE.txt`. With blocking on, apps' own
encrypted DNS and iCloud Private Relay are blocked, so their queries go through the tunnel's DNS and its blocking.

## 7. What the VPN server's provider sees, and what the app does not hide

A VPN hides your traffic from your internet provider, **not from whoever runs the VPN server**. That party sees:
- your real IP address, connection times and traffic volume;
- where you connect: IP addresses, site names (the TLS name, the `Host` header) and the DNS queries that go through
  the server;
- the full content of any unencrypted traffic (`http://`).

Outside the VPN, and so visible to your internet provider:
- Russian sites and addresses with “Bypass Russian sites” (on by default), and the local network with “Local
  network”. A site can load something from a Russian address and so see your real IP next to the VPN's;
- Apple push notifications and carrier services (calls, SMS): that is how iOS works, even with the kill switch on;
- without the kill switch, all traffic while the VPN reconnects or is restarted by the system. The kill switch is on
  by default for new installs; updated installs keep their value. Changing the server with the VPN on no longer takes
  the tunnel down.

A server whose certificate is not checked is marked “certificate not checked” in the list: connections to it can be
intercepted.

Left as it is on purpose (details in `audit/security-2026-11.md`):
- the app introduces itself as the INCY and Happ clients: otherwise some panels give no servers;
- keys are stored in files under iOS protection, not in the Keychain: the extension needs them on a locked iPhone too,
  so the Keychain would give the same protection;
- 1.x data is not deleted by updates (kept for a way back), but it does not go into backups.

---

Applies to **Personal Tunnel 3.2.1 (build 255)**. Date: **16 November 2026**. The policy is updated
whenever the app's behaviour changes.
