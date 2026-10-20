import SwiftUI
import MoonlightCore

/// Russian and English, with Russian as the source of truth.
///
/// The design is written in Russian and its strings are the specification — the
/// English column is a translation of them, not the other way round. Strings
/// live in one table rather than in `.strings` files because the language
/// switch in Settings changes them live, and a bundle-based lookup would need a
/// relaunch to follow.
public enum L {

    public static func t(_ key: Key, _ locale: AppLocale) -> String {
        locale == .ru ? key.ru : key.en
    }

    public enum Key {
        // Navigation and page headers
        case navConnect, navSubscription, navSettings
        case collapseSidebar, expandSidebar, quit
        case titleConnect, subtitleConnect
        case titleSubscription, subtitleSubscription
        case titleSettings, subtitleSettings
        case titleImport, subtitleImport

        // Header actions
        case ping, pinging, refresh, refreshing, theme, themeDark, themeLight

        // Connect
        case secured, disconnected, connecting, disconnecting, connectionTime
        case bigConnect, bigConnected
        case hintConnect, hintDisconnect
        case downloaded, uploaded, remaining, trafficLeft, timeLeft
        case servers, auto, autoSubtitle, autoPicked
        case noSubscription, noSubscriptionHint, addSubscription

        // Sidebar card
        case remainingCaps, active, expired, trafficOf

        // Subscription
        case plan, planUnknown, traffic
        case trafficCaps, subscriptionLink, copy, copied
        case refreshSubscription, refreshMetaIdle, refreshMetaSyncing, refreshMetaStop, refreshMetaDone
        case extendSubscription, extendSubtitle, personalAccount, personalAccountSub
        case addSubscriptionRow, addSubscriptionSubtitle
        case validUntil, unlimited

        // Import
        case importIntro, importPlaceholder, importAdd
        case pasteFromClipboard, openTelegramBot, telegramBotSubtitle
        case backToSubscription, importDone, importDoneSubtitle, connectNow
        case removeSubscription

        // App picker and search fields
        case searchApps, installedApps

        // Settings
        case sectionSystem, sectionApp, sectionSupport, sectionTunnel
        case launchAtLogin, launchAtLoginSub
        case menuBarIcon, menuBarIconSub
        case autoConnect, autoConnectSub
        case language, notifications, notificationsSub
        case liquidGlass, liquidGlassSub
        case ourChannel, ourChannelSub, support, supportSub
        case version, checkUpdates, keysStayHere
        case modeSystemProxy, modeSystemProxySub, modeTun, modeTunSub, modeProxyShort
        case refreshDone, refreshDoneDetail, refreshFailed, refreshStopped, refreshStoppedDetail
        case stopRefresh
        case helperInstall, helperInstallSub, helperRemove, helperInstalled
        case coreVersion, viewLog, viewLogSub, install, remove
        // Logs
        case navLogs, titleLogs, subtitleLogs
        case logAll, logClient, logCore, logEmpty, logCopy, logCopied, logCopyLine
        case logTime, logLevel, logSource, logMessage
        // Connections
        case navConnections, titleConnections, subtitleConnections
        case activeConnections, closeAll, closeProcess, closeConnection
        case noConnections, connectionsNeedTunnel
        case colProcess, colChain, colRule, colNetwork, colDown, colUp, colTime
        // Updates
        case updateChecking, updateUpToDate, updateAvailable, updateDownloading
        case updateInstalling, updateInstall, updateFailed
        case updateVerifying, updateVerifyingHint, updateRestartHint, updateTo, updateDownloadHint
        case updateBannerTitle, updateBannerBody
        // Menu bar tray
        case routingRule, routingGlobal, routingDirect, pingAll, pingOne, searchServers
        case openWindow, connectAction, disconnectAction, keepOpen, stopKeepingOpen
        case nothingFound, helperStale, helperStaleSub, helperInstallFailed, helperRemoveFailed
        // Subscription service extras
        case autoUpdate, autoUpdateSub, autoUpdateOff, hoursShort, lastUpdated, neverUpdated
        case trafficResets, removeSubscriptionSub, hideAnnounce
        case collapseAnnounce, expandAnnounce
        // Rules
        case navRules, titleRules, subtitleRules, rulesMine, rulesProfile, rulesFilter
        case rulesAdd, rulesEdit, rulesOwnCount, rulesProfileCount
        case colType, colValue, colTarget, colPriority
        case ruleType, ruleValue, ruleTarget, rulePriority, ruleChooseApp, ruleRunning
        case targetBuiltIn, targetGroups, targetDirect, targetReject, targetMissing
        case priorityOverride, priorityOverrideSub, priorityExtend, priorityExtendSub
        case familyDomain, familyIP, familyPort, familyProcess, familyOther
        case ruleCancel, ruleSave, ruleEditHint, ruleDeleteHint, ruleDragHint, ruleTunOnly, ruleNeedsDownload
        case rulesUnsaved, rulesReset, rulesApply, rulesApplying, rulesApplyFailed
        case rulesDownloading, rulesDownloadBlocked, rulesDownloadBlockedASN
        case rulesEmpty, rulesEmptyHint, rulesProfileEmpty, rulesModeNote
        case invalidEmpty, invalidComma, invalidRegex, invalidPort, invalidCIDR, invalidASN, invalidNetwork
        // Links that open the app
        case linkTitle, linkBody, linkReplaces, linkSame, linkAdd, linkAdding, linkLater
        case linkClose, linkRetry, linkFailedTitle, linkInvalidTitle, linkInvalidBody
        // Issues
        case issueInvalidLink, issueNoSubscription, issueOffline, issueServerUnavailable
        case issueErrorCode, issueTryLater, issueLinkRejected, issueEmpty, issueNoUsable, issueNoServersSent
        case issueDeviceLimit, issueDeviceNotSupported, issueCoreFailed, issueCoreStopped
        case issueRoutesTaken, issueTunFailed, issueHelperMissing, issueHelperOutdated
        case issueDatabaseBlocked, issueDatabaseBlockedASN
        // Notifications
        case notifyExpiringTitle, notifyExpiringBody, notifyExpiredTitle, notifyExpiredBody
        case notifyTrafficLowTitle, notifyTrafficLowBody, notifyTrafficOutTitle, notifyTrafficOutBody

        var ru: String {
            switch self {
            case .navConnect: return "Подключение"
            case .navSubscription: return "Подписка"
            case .navSettings: return "Настройки"
            case .collapseSidebar: return "Свернуть меню"
            case .expandSidebar: return "Развернуть меню"
            case .quit: return "Выйти"
            case .titleConnect: return "Подключение"
            case .subtitleConnect: return "Выберите узел и включите туннель"
            case .titleSubscription: return "Подписка"
            case .subtitleSubscription: return "Тариф и трафик"
            case .titleSettings: return "Настройки"
            case .subtitleSettings: return "Система, приложение и поддержка"
            case .titleImport: return "Добавить подписку"
            case .subtitleImport: return "Ссылка из бота или личного кабинета"

            case .ping: return "Пинг"
            case .pinging: return "Замер…"
            case .refresh: return "Обновить"
            case .refreshing: return "Обновление"
            case .theme: return "Тема"
            case .themeDark: return "Тёмная"
            case .themeLight: return "Светлая"

            case .secured: return "Защищено"
            case .disconnected: return "Отключено"
            case .connecting: return "Подключение"
            case .disconnecting: return "Отключение"
            case .connectionTime: return "Время подключения"
            case .bigConnect: return "Подключить"
            case .bigConnected: return "Подключено"
            case .hintConnect: return "нажмите, чтобы подключиться"
            case .hintDisconnect: return "нажмите, чтобы отключить"
            case .downloaded: return "СКАЧАНО"
            case .uploaded: return "ОТДАНО"
            case .remaining: return "ОСТАЛОСЬ"
            case .trafficLeft: return "ТРАФИКА"
            case .timeLeft: return "ОСТАЛОСЬ"
            case .servers: return "СЕРВЕРЫ"
            case .auto: return "Авто"
            case .autoSubtitle: return "Ближайший узел по пингу"
            case .autoPicked: return "Выбран"
            case .noSubscription: return "Нет подписки"
            case .noSubscriptionHint: return "Добавьте ссылку из бота, чтобы увидеть серверы"
            case .addSubscription: return "Добавить подписку"

            case .remainingCaps: return "ОСТАЛОСЬ"
            case .active: return "Активна"
            case .expired: return "Истекла"
            case .trafficOf: return "трафика"

            case .plan: return "Тариф"
            case .planUnknown: return "Подписка"
            case .traffic: return "ТРАФИК"
            case .trafficCaps: return "ТРАФИК"
            case .subscriptionLink: return "ССЫЛКА ПОДПИСКИ"
            case .copy: return "Скопировать"
            case .copied: return "Скопировано"
            case .refreshSubscription: return "Обновить подписку"
            case .refreshMetaIdle: return "Проверить серверы, дни и трафик"
            case .refreshMetaSyncing: return "Синхронизация с сервером…"
            case .refreshMetaStop: return "Синхронизация затянулась — нажмите, чтобы остановить"
            case .refreshMetaDone: return "Обновлено только что"
            case .extendSubscription: return "Продлить подписку"
            case .extendSubtitle: return "В Telegram-боте"
            case .personalAccount: return "Личный кабинет"
            case .personalAccountSub: return "Устройства и подписка на сайте"
            case .addSubscriptionRow: return "Добавить подписку"
            case .addSubscriptionSubtitle: return "Вставить ссылку из бота"
            case .validUntil: return "действует до"
            case .unlimited: return "без лимита"

            case .importIntro:
                return "Вставьте ссылку подписки из Telegram-бота или личного кабинета. Ключи останутся на этом компьютере."
            case .importPlaceholder: return "https://sub.moonlight.vpn/…"
            case .importAdd: return "Добавить"
            case .pasteFromClipboard: return "Вставить из буфера"
            case .openTelegramBot: return "Открыть Telegram-бота"
            case .telegramBotSubtitle: return "Ссылка придёт в чат и добавится сама"
            case .backToSubscription: return "Назад к подписке"
            case .importDone: return "Подписка активирована!"
            case .importDoneSubtitle: return "Готово к подключению"
            case .connectNow: return "Подключиться"
            case .removeSubscription: return "Удалить подписку"
            case .searchApps: return "Поиск"
            case .installedApps: return "ПРОГРАММЫ"

            case .sectionSystem: return "СИСТЕМА"
            case .sectionApp: return "ПРИЛОЖЕНИЕ"
            case .sectionSupport: return "ПОДДЕРЖКА"
            case .sectionTunnel: return "ТУННЕЛЬ"
            case .launchAtLogin: return "Запускать при входе в систему"
            case .launchAtLoginSub: return "Клиент стартует свёрнутым"
            case .menuBarIcon: return "Значок в строке меню"
            case .menuBarIconSub: return "Управление подключением из строки меню"
            case .autoConnect: return "Подключаться автоматически"
            case .autoConnectSub: return "Сразу после запуска клиента"
            case .language: return "Язык"
            case .notifications: return "Уведомления"
            case .notificationsSub: return "Об окончании подписки и трафика"
            case .liquidGlass: return "Liquid Glass"
            case .liquidGlassSub: return "Стекло и размытый фон окна. Без них приложение расходует меньше энергии"
            case .ourChannel: return "Наш канал"
            case .ourChannelSub: return "Новости и обновления"
            case .support: return "Поддержка"
            case .supportSub: return "Мы на связи 24/7"
            case .version: return "Версия"
            case .checkUpdates: return "Проверить обновления"
            case .keysStayHere: return "Ключи хранятся только на этом компьютере"
            case .modeSystemProxy: return "Системный прокси"
            case .modeSystemProxySub: return "Без пароля. Идут только программы, которые уважают настройки прокси"
            case .modeTun: return "TUN"
            case .modeTunSub: return "Весь трафик и правила по программам. Нужен системный помощник"
            case .modeProxyShort: return "Прокси"
            case .refreshDone: return "Подписка обновлена"
            case .refreshDoneDetail: return "Серверы, дни и трафик — актуальные"
            case .refreshFailed: return "Подписка не обновлена"
            case .refreshStopped: return "Обновление остановлено"
            case .refreshStoppedDetail: return "Список серверов не изменился"
            case .stopRefresh: return "Остановить обновление"
            case .helperInstall: return "Установить помощник"
            case .helperInstallSub: return "Один запрос пароля администратора"
            case .helperRemove: return "Удалить помощник"
            case .helperInstalled: return "Помощник установлен"
            case .coreVersion: return "Ядро"
            case .viewLog: return "Журнал ядра"
            case .viewLogSub: return "Последние строки от mihomo"
            case .install: return "Установить"
            case .remove: return "Удалить"
            case .navLogs: return "Логи"
            case .titleLogs: return "Логи"
            case .subtitleLogs: return "Что делают клиент и ядро"
            case .logAll: return "Все"
            case .logClient: return "Клиент"
            case .logCore: return "Ядро"
            case .logEmpty: return "Пока пусто"
            case .logCopy: return "Скопировать показанные строки"
            case .logCopied: return "Скопировано"
            case .logCopyLine: return "Скопировать строку"
            case .logTime: return "ВРЕМЯ"
            case .logLevel: return "УРОВЕНЬ"
            case .logSource: return "ИСТОЧНИК"
            case .logMessage: return "СООБЩЕНИЕ"
            case .navConnections: return "Подключения"
            case .titleConnections: return "Подключения"
            case .subtitleConnections: return "Какие программы и куда идут прямо сейчас"
            case .activeConnections: return "Активно"
            case .closeAll: return "Закрыть все"
            case .closeProcess: return "Закрыть подключения этой программы"
            case .closeConnection: return "Закрыть это подключение"
            case .noConnections: return "Нет активных подключений"
            case .connectionsNeedTunnel: return "Подключения появятся, когда туннель заработает"
            case .colProcess: return "ПРОЦЕСС"
            case .colChain: return "ЦЕПОЧКА"
            case .colRule: return "ПРАВИЛО"
            case .colNetwork: return "СЕТЬ"
            case .colDown: return "СКАЧАНО"
            case .colUp: return "ОТДАНО"
            case .colTime: return "ВРЕМЯ"
            case .updateChecking: return "Проверяем…"
            case .updateUpToDate: return "Установлена последняя версия"
            case .updateBannerTitle: return "Доступно обновление"
            case .updateBannerBody: return "moonlight {version} — нажмите, чтобы установить"
            case .updateAvailable: return "Доступна версия"
            case .updateDownloading: return "Загрузка"
            case .updateInstalling: return "Перезапуск…"
            case .updateInstall: return "Обновить"
            case .updateFailed: return "Не удалось обновить"
            case .updateVerifying: return "Проверка…"
            case .updateVerifyingHint: return "Сверяем загрузку с контрольной суммой"
            case .updateRestartHint: return "moonlight закроется и откроется уже новой версией"
            case .updateTo: return "Обновление до"
            case .updateDownloadHint: return "Затем проверим файл, и moonlight перезапустится уже новой версией"
            case .routingRule: return "По правилам"
            case .routingGlobal: return "Глобальный"
            case .routingDirect: return "Напрямую"
            case .pingAll: return "Пинг всех"
            case .pingOne: return "Проверить пинг"
            case .searchServers: return "Поиск серверов"
            case .openWindow: return "Открыть"
            case .connectAction: return "Подключиться"
            case .disconnectAction: return "Отключиться"
            case .keepOpen: return "Не закрывать"
            case .stopKeepingOpen: return "Закрывать при клике мимо"
            case .nothingFound: return "Ничего не найдено"
            case .helperStale: return "Помощник нужно обновить"
            case .helperStaleSub: return "Он из прошлой версии moonlight — обновите, чтобы TUN работал как надо"
            case .helperInstallFailed: return "Не удалось установить помощник. Попробуйте ещё раз — подробности в логах"
            case .helperRemoveFailed: return "Не удалось удалить помощник. Попробуйте ещё раз — подробности в логах"
            case .autoUpdate: return "Автообновление подписки"
            case .autoUpdateSub: return "Как часто проверять серверы, дни и трафик"
            case .autoUpdateOff: return "Выкл"
            case .hoursShort: return "ч"
            case .lastUpdated: return "Обновлено"
            case .neverUpdated: return "Ещё не обновлялась"
            case .trafficResets: return "Трафик обновится"
            case .removeSubscriptionSub: return "Ссылка будет удалена с этого Mac"
            case .hideAnnounce: return "Скрыть"
            case .collapseAnnounce: return "Свернуть"
            case .expandAnnounce: return "Развернуть"
            case .navRules: return "Правила"
            case .titleRules: return "Правила"
            case .subtitleRules: return "Куда идёт трафик: ваши правила и правила подписки"
            case .rulesMine: return "Мои правила"
            case .rulesProfile: return "Правила подписки"
            case .rulesFilter: return "Фильтр по типу, значению или цели"
            case .rulesAdd: return "Добавить правило"
            case .rulesEdit: return "Изменить правило"
            case .rulesOwnCount: return "Своих"
            case .rulesProfileCount: return "Правил"
            case .colType: return "ТИП"
            case .colValue: return "ЗНАЧЕНИЕ"
            case .colTarget: return "ЦЕЛЬ"
            case .colPriority: return "ПРИОРИТЕТ"
            case .ruleType: return "Тип"
            case .ruleValue: return "Значение"
            case .ruleTarget: return "Цель"
            case .rulePriority: return "Приоритет"
            case .ruleChooseApp: return "Выбрать приложение"
            case .ruleRunning: return "Запущенные"
            case .targetBuiltIn: return "ВСТРОЕННЫЕ"
            case .targetGroups: return "ГРУППЫ ПОДПИСКИ"
            case .targetDirect: return "Мимо VPN"
            case .targetReject: return "Блокировать соединение"
            case .targetMissing: return "Этой группы больше нет в подписке — правило пропускается"
            case .priorityOverride: return "Override"
            case .priorityOverrideSub: return "Применяется до правил подписки"
            case .priorityExtend: return "Extend"
            case .priorityExtendSub: return "Применяется после правил подписки"
            case .familyDomain: return "ДОМЕН"
            case .familyIP: return "IP"
            case .familyPort: return "ПОРТ"
            case .familyProcess: return "ПРОЦЕСС"
            case .familyOther: return "ДРУГОЕ"
            case .ruleCancel: return "Отмена"
            case .ruleSave: return "Сохранить"
            case .ruleEditHint: return "Изменить"
            case .ruleDeleteHint: return "Удалить"
            case .ruleDragHint: return "Перетащите, чтобы изменить порядок"
            case .ruleTunOnly: return "Работает только в режиме TUN"
            case .ruleNeedsDownload: return "Для этого правила VPN один раз скачает базу номеров AS — около 9\u{00A0}МБ. Там, где загрузка заблокирована, правило не применится."
            case .rulesUnsaved: return "Изменения не применены"
            case .rulesReset: return "Сбросить"
            case .rulesApply: return "Применить"
            case .rulesApplying: return "Применяются…"
            case .rulesApplyFailed: return "Ядро не приняло эти правила — подробности в логах"
            case .rulesDownloading: return "Скачивается база для IP-ASN, около 9\u{00A0}МБ…"
            case .rulesDownloadBlocked: return "Не удалось скачать базу для этих правил"
            case .rulesDownloadBlockedASN: return "Не удалось скачать базу для IP-ASN"
            case .rulesEmpty: return "Своих правил пока нет"
            case .rulesEmptyHint: return "Пустите сайт мимо VPN, заблокируйте его или направьте через группу. Свои правила переживают обновление подписки."
            case .rulesProfileEmpty: return "В подписке нет правил"
            case .rulesModeNote: return "Правила действуют в режиме «По правилам» — сейчас выбран другой"
            case .invalidEmpty: return "Укажите значение"
            case .invalidComma: return "В значении не может быть запятой"
            case .invalidRegex: return "Это не регулярное выражение"
            case .invalidPort: return "Порт от 0 до 65535, диапазон через «-» или несколько через «/»"
            case .invalidCIDR: return "Нужна подсеть, например 192.168.1.0/24"
            case .invalidASN: return "Только номер AS, например 13335"
            case .invalidNetwork: return "tcp или udp"
            case .linkTitle: return "Добавить подписку?"
            case .linkBody: return "Ссылка с сайта или из чата хочет добавить подписку в moonlight."
            case .linkReplaces: return "Она заменит текущую подписку."
            case .linkSame: return "Это ваша текущая подписка — она обновится."
            case .linkAdd: return "Добавить"
            case .linkAdding: return "Загружаем подписку…"
            case .linkLater: return "Позже"
            case .linkClose: return "Закрыть"
            case .linkRetry: return "Ещё раз"
            case .linkFailedTitle: return "Подписка не добавлена"
            case .linkInvalidTitle: return "Эту ссылку не открыть"
            case .linkInvalidBody: return "В ней нет ссылки на подписку."
            case .issueInvalidLink: return "Это не похоже на ссылку подписки"
            case .issueNoSubscription: return "Сначала добавьте подписку"
            case .issueOffline: return "Нет подключения к интернету"
            case .issueServerUnavailable: return "Сервер подписки временно недоступен"
            case .issueErrorCode: return "ошибка"
            case .issueTryLater: return "Попробуйте позже."
            case .issueLinkRejected: return "Ссылка больше не действует. Возьмите новую в боте."
            case .issueEmpty: return "В подписке нет серверов"
            case .issueNoUsable: return "В подписке нет серверов, которые поддерживает приложение"
            case .issueNoServersSent: return "Сервис не прислал серверы — список остался прежним"
            case .issueDeviceLimit: return "Достигнут лимит устройств. Отключите другое устройство в личном кабинете."
            case .issueDeviceNotSupported: return "Подписка не принимает это устройство"
            case .issueCoreFailed: return "Не удалось запустить VPN. Подробности — в логах."
            case .issueCoreStopped: return "VPN остановился, и перезапустить его не удалось. Подключитесь снова."
            case .issueRoutesTaken: return "Маршруты заняты другим VPN. Закройте его или включите режим системного прокси."
            case .issueTunFailed: return "Не удалось создать TUN-интерфейс. Подробности — в логах."
            case .issueHelperMissing: return "Для TUN нужен системный помощник — установите его в настройках"
            case .issueHelperOutdated: return "Системный помощник устарел — переустановите его в настройках"
            case .issueDatabaseBlocked: return "Не удалось скачать базу, нужную правилам, а без неё VPN не запустится. Попробуйте из другой сети."
            case .issueDatabaseBlockedASN: return "Не удалось скачать базу номеров AS для правил IP-\u{2060}ASN, а без неё VPN не запустится. Попробуйте из другой сети или выключите свои правила IP-\u{2060}ASN."
            case .notifyExpiringTitle: return "Подписка заканчивается"
            case .notifyExpiringBody: return "Осталось {days}. Продлите её в боте, чтобы не остаться без VPN."
            case .notifyExpiredTitle: return "Подписка закончилась"
            case .notifyExpiredBody: return "Продлите её в боте, чтобы снова подключиться."
            case .notifyTrafficLowTitle: return "Трафик почти закончился"
            case .notifyTrafficLowBody: return "Осталось {left} из {total}."
            case .notifyTrafficOutTitle: return "Трафик закончился"
            case .notifyTrafficOutBody: return "Продлите подписку в боте, чтобы снова подключиться."
            }
        }

        var en: String {
            switch self {
            case .navConnect: return "Connection"
            case .navSubscription: return "Subscription"
            case .navSettings: return "Settings"
            case .collapseSidebar: return "Collapse the sidebar"
            case .expandSidebar: return "Expand the sidebar"
            case .quit: return "Quit"
            case .titleConnect: return "Connection"
            case .subtitleConnect: return "Pick a node and switch the tunnel on"
            case .titleSubscription: return "Subscription"
            case .subtitleSubscription: return "Plan and traffic"
            case .titleSettings: return "Settings"
            case .subtitleSettings: return "System, app and support"
            case .titleImport: return "Add a subscription"
            case .subtitleImport: return "A link from the bot or your account"

            case .ping: return "Ping"
            case .pinging: return "Measuring…"
            case .refresh: return "Refresh"
            case .refreshing: return "Refreshing"
            case .theme: return "Theme"
            case .themeDark: return "Dark"
            case .themeLight: return "Light"

            case .secured: return "Secured"
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting"
            case .disconnecting: return "Disconnecting"
            case .connectionTime: return "Connection time"
            case .bigConnect: return "Connect"
            case .bigConnected: return "Connected"
            case .hintConnect: return "click to connect"
            case .hintDisconnect: return "click to disconnect"
            case .downloaded: return "DOWNLOADED"
            case .uploaded: return "UPLOADED"
            case .remaining: return "REMAINING"
            case .trafficLeft: return "TRAFFIC LEFT"
            case .timeLeft: return "TIME LEFT"
            case .servers: return "SERVERS"
            case .auto: return "Auto"
            case .autoSubtitle: return "Fastest node by latency"
            case .autoPicked: return "Using"
            case .noSubscription: return "No subscription"
            case .noSubscriptionHint: return "Add a link from the bot to see servers"
            case .addSubscription: return "Add a subscription"

            case .remainingCaps: return "REMAINING"
            case .active: return "Active"
            case .expired: return "Expired"
            case .trafficOf: return "of traffic"

            case .plan: return "Plan"
            case .planUnknown: return "Subscription"
            case .traffic: return "TRAFFIC"
            case .trafficCaps: return "TRAFFIC"
            case .subscriptionLink: return "SUBSCRIPTION LINK"
            case .copy: return "Copy"
            case .copied: return "Copied"
            case .refreshSubscription: return "Refresh subscription"
            case .refreshMetaIdle: return "Check servers, days and traffic"
            case .refreshMetaSyncing: return "Syncing with the server…"
            case .refreshMetaStop: return "Taking a while — click to stop"
            case .refreshMetaDone: return "Updated just now"
            case .extendSubscription: return "Extend subscription"
            case .extendSubtitle: return "In the Telegram bot"
            case .personalAccount: return "Personal account"
            case .personalAccountSub: return "Devices and subscription on the website"
            case .addSubscriptionRow: return "Add a subscription"
            case .addSubscriptionSubtitle: return "Paste a link from the bot"
            case .validUntil: return "valid until"
            case .unlimited: return "unlimited"

            case .importIntro:
                return "Paste the subscription link from the Telegram bot or your account. The keys stay on this computer."
            case .importPlaceholder: return "https://sub.moonlight.vpn/…"
            case .importAdd: return "Add"
            case .pasteFromClipboard: return "Paste from clipboard"
            case .openTelegramBot: return "Open the Telegram bot"
            case .telegramBotSubtitle: return "The link arrives in the chat and adds itself"
            case .backToSubscription: return "Back to subscription"
            case .importDone: return "Subscription activated!"
            case .importDoneSubtitle: return "Ready to connect"
            case .connectNow: return "Connect"
            case .removeSubscription: return "Remove subscription"
            case .searchApps: return "Search"
            case .installedApps: return "APPS"

            case .sectionSystem: return "SYSTEM"
            case .sectionApp: return "APP"
            case .sectionSupport: return "SUPPORT"
            case .sectionTunnel: return "TUNNEL"
            case .launchAtLogin: return "Launch at login"
            case .launchAtLoginSub: return "Starts minimised"
            case .menuBarIcon: return "Menu bar icon"
            case .menuBarIconSub: return "Control the connection from the menu bar"
            case .autoConnect: return "Connect automatically"
            case .autoConnectSub: return "Right after the client starts"
            case .language: return "Language"
            case .notifications: return "Notifications"
            case .notificationsSub: return "When the plan or traffic runs out"
            case .liquidGlass: return "Liquid Glass"
            case .liquidGlassSub: return "Glass and the blurred backdrop. The app uses less energy without them"
            case .ourChannel: return "Our channel"
            case .ourChannelSub: return "News and updates"
            case .support: return "Support"
            case .supportSub: return "We answer 24/7"
            case .version: return "Version"
            case .checkUpdates: return "Check for updates"
            case .keysStayHere: return "Keys are kept only on this computer"
            case .modeSystemProxy: return "System proxy"
            case .modeSystemProxySub: return "No password. Only apps that honour proxy settings are captured"
            case .modeTun: return "TUN"
            case .modeTunSub: return "All traffic and per-app rules. Needs the system helper"
            case .modeProxyShort: return "Proxy"
            case .refreshDone: return "Subscription updated"
            case .refreshDoneDetail: return "Servers, days and traffic are up to date"
            case .refreshFailed: return "Subscription not updated"
            case .refreshStopped: return "Update stopped"
            case .refreshStoppedDetail: return "The server list is unchanged"
            case .stopRefresh: return "Stop updating"
            case .helperInstall: return "Install the helper"
            case .helperInstallSub: return "One administrator prompt"
            case .helperRemove: return "Remove the helper"
            case .helperInstalled: return "Helper installed"
            case .coreVersion: return "Core"
            case .viewLog: return "Core log"
            case .viewLogSub: return "The last lines from mihomo"
            case .install: return "Install"
            case .remove: return "Remove"
            case .navLogs: return "Logs"
            case .titleLogs: return "Logs"
            case .subtitleLogs: return "What the client and the core are doing"
            case .logAll: return "All"
            case .logClient: return "Client"
            case .logCore: return "Core"
            case .logEmpty: return "Nothing yet"
            case .logCopy: return "Copy the lines shown"
            case .logCopied: return "Copied"
            case .logCopyLine: return "Copy line"
            case .logTime: return "TIME"
            case .logLevel: return "LEVEL"
            case .logSource: return "SOURCE"
            case .logMessage: return "MESSAGE"
            case .navConnections: return "Connections"
            case .titleConnections: return "Connections"
            case .subtitleConnections: return "Which programs are going where, right now"
            case .activeConnections: return "Active"
            case .closeAll: return "Close all"
            case .closeProcess: return "Close this program's connections"
            case .closeConnection: return "Close this connection"
            case .noConnections: return "No active connections"
            case .connectionsNeedTunnel: return "Connections appear once the tunnel is carrying traffic"
            case .colProcess: return "PROCESS"
            case .colChain: return "CHAIN"
            case .colRule: return "RULE"
            case .colNetwork: return "NETWORK"
            case .colDown: return "DOWN"
            case .colUp: return "UP"
            case .colTime: return "TIME"
            case .updateChecking: return "Checking…"
            case .updateUpToDate: return "You are on the latest version"
            case .updateBannerTitle: return "Update available"
            case .updateBannerBody: return "moonlight {version} — click to install"
            case .updateAvailable: return "Version available"
            case .updateDownloading: return "Downloading"
            case .updateInstalling: return "Restarting…"
            case .updateInstall: return "Update"
            case .updateFailed: return "Update failed"
            case .updateVerifying: return "Verifying…"
            case .updateVerifyingHint: return "Checking the download against its checksum"
            case .updateRestartHint: return "moonlight will close and reopen as the new version"
            case .updateTo: return "Updating to"
            case .updateDownloadHint: return "Then the file is checked and moonlight restarts as the new version"
            case .routingRule: return "Rules"
            case .routingGlobal: return "Global"
            case .routingDirect: return "Direct"
            case .pingAll: return "Ping all"
            case .pingOne: return "Check ping"
            case .searchServers: return "Search servers"
            case .openWindow: return "Open"
            case .connectAction: return "Connect"
            case .disconnectAction: return "Disconnect"
            case .keepOpen: return "Keep open"
            case .stopKeepingOpen: return "Close when clicking away"
            case .nothingFound: return "Nothing found"
            case .helperStale: return "The helper needs an update"
            case .helperStaleSub: return "It is from an earlier moonlight — update it so TUN works as it should"
            case .helperInstallFailed: return "The helper could not be installed. Try again — the log has the details"
            case .helperRemoveFailed: return "The helper could not be removed. Try again — the log has the details"
            case .autoUpdate: return "Update the subscription automatically"
            case .autoUpdateSub: return "How often to check servers, days and traffic"
            case .autoUpdateOff: return "Off"
            case .hoursShort: return "h"
            case .lastUpdated: return "Updated"
            case .neverUpdated: return "Not updated yet"
            case .trafficResets: return "Traffic resets"
            case .removeSubscriptionSub: return "Removes the link from this Mac"
            case .hideAnnounce: return "Hide"
            case .collapseAnnounce: return "Collapse"
            case .expandAnnounce: return "Expand"
            case .navRules: return "Rules"
            case .titleRules: return "Rules"
            case .subtitleRules: return "Where traffic goes: your rules and the subscription's"
            case .rulesMine: return "My rules"
            case .rulesProfile: return "Subscription rules"
            case .rulesFilter: return "Filter by type, value or target"
            case .rulesAdd: return "Add rule"
            case .rulesEdit: return "Edit rule"
            case .rulesOwnCount: return "Own"
            case .rulesProfileCount: return "Rules"
            case .colType: return "TYPE"
            case .colValue: return "VALUE"
            case .colTarget: return "TARGET"
            case .colPriority: return "PRIORITY"
            case .ruleType: return "Type"
            case .ruleValue: return "Value"
            case .ruleTarget: return "Target"
            case .rulePriority: return "Priority"
            case .ruleChooseApp: return "Choose an app"
            case .ruleRunning: return "Running"
            case .targetBuiltIn: return "BUILT-IN"
            case .targetGroups: return "SUBSCRIPTION GROUPS"
            case .targetDirect: return "Bypass the VPN"
            case .targetReject: return "Block the connection"
            case .targetMissing: return "This group is no longer in the subscription — the rule is skipped"
            case .priorityOverride: return "Override"
            case .priorityOverrideSub: return "Applied before the subscription's rules"
            case .priorityExtend: return "Extend"
            case .priorityExtendSub: return "Applied after the subscription's rules"
            case .familyDomain: return "DOMAIN"
            case .familyIP: return "IP"
            case .familyPort: return "PORT"
            case .familyProcess: return "PROCESS"
            case .familyOther: return "OTHER"
            case .ruleCancel: return "Cancel"
            case .ruleSave: return "Save"
            case .ruleEditHint: return "Edit"
            case .ruleDeleteHint: return "Delete"
            case .ruleDragHint: return "Drag to reorder"
            case .ruleTunOnly: return "Works in TUN mode only"
            case .ruleNeedsDownload: return "For this rule the VPN downloads a database of AS numbers once — about 9\u{00A0}MB. Where the download is blocked, the rule can't be applied."
            case .rulesUnsaved: return "Changes not applied"
            case .rulesReset: return "Reset"
            case .rulesApply: return "Apply"
            case .rulesApplying: return "Applying…"
            case .rulesApplyFailed: return "The core rejected these rules — the log has the details"
            case .rulesDownloading: return "Downloading the IP-ASN database, about 9\u{00A0}MB…"
            case .rulesDownloadBlocked: return "Couldn't download the database these rules need"
            case .rulesDownloadBlockedASN: return "Couldn't download the IP-ASN database"
            case .rulesEmpty: return "No rules of your own yet"
            case .rulesEmptyHint: return "Send a site around the VPN, block it or route it through a group. Your rules survive subscription updates."
            case .rulesProfileEmpty: return "The subscription has no rules"
            case .rulesModeNote: return "Rules apply in Rule mode — another mode is selected"
            case .invalidEmpty: return "Enter a value"
            case .invalidComma: return "The value cannot contain a comma"
            case .invalidRegex: return "Not a regular expression"
            case .invalidPort: return "A port from 0 to 65535, a range with “-” or several joined by “/”"
            case .invalidCIDR: return "A subnet, e.g. 192.168.1.0/24"
            case .invalidASN: return "The AS number alone, e.g. 13335"
            case .invalidNetwork: return "tcp or udp"
            case .linkTitle: return "Add this subscription?"
            case .linkBody: return "A link from a website or a chat wants to add a subscription to moonlight."
            case .linkReplaces: return "It will replace your current subscription."
            case .linkSame: return "This is your current subscription — it will be updated."
            case .linkAdd: return "Add"
            case .linkAdding: return "Loading the subscription…"
            case .linkLater: return "Later"
            case .linkClose: return "Close"
            case .linkRetry: return "Try again"
            case .linkFailedTitle: return "Subscription not added"
            case .linkInvalidTitle: return "This link can't be opened"
            case .linkInvalidBody: return "It doesn't contain a subscription link."
            case .issueInvalidLink: return "This doesn't look like a subscription link"
            case .issueNoSubscription: return "Add a subscription first"
            case .issueOffline: return "No internet connection"
            case .issueServerUnavailable: return "The subscription server is temporarily unavailable"
            case .issueErrorCode: return "error"
            case .issueTryLater: return "Try again later."
            case .issueLinkRejected: return "This link no longer works. Get a new one from the bot."
            case .issueEmpty: return "The subscription has no servers"
            case .issueNoUsable: return "None of the subscription's servers work with this app"
            case .issueNoServersSent: return "The service sent no servers this time, so the list is unchanged"
            case .issueDeviceLimit: return "Device limit reached. Remove another device in your account."
            case .issueDeviceNotSupported: return "The subscription doesn't accept this device"
            case .issueCoreFailed: return "Couldn't start the VPN. See the logs for details."
            case .issueCoreStopped: return "The VPN stopped and couldn't be restarted. Connect again."
            case .issueRoutesTaken: return "Another VPN owns the system routes. Quit it or use system proxy mode."
            case .issueTunFailed: return "Couldn't create the TUN interface. See the logs for details."
            case .issueHelperMissing: return "TUN needs the system helper — install it in Settings"
            case .issueHelperOutdated: return "The system helper is out of date — reinstall it in Settings"
            case .issueDatabaseBlocked: return "Couldn't download a database the rules need, and the VPN can't start without it. Try another network."
            case .issueDatabaseBlockedASN: return "Couldn't download the AS-number database IP-\u{2060}ASN rules need, and the VPN can't start without it. Try another network, or turn off your IP-\u{2060}ASN rules."
            case .notifyExpiringTitle: return "Your subscription is ending"
            case .notifyExpiringBody: return "{days} left. Renew it in the bot to stay connected."
            case .notifyExpiredTitle: return "Your subscription has ended"
            case .notifyExpiredBody: return "Renew it in the bot to connect again."
            case .notifyTrafficLowTitle: return "Traffic is running out"
            case .notifyTrafficLowBody: return "{left} left of {total}."
            case .notifyTrafficOutTitle: return "You are out of traffic"
            case .notifyTrafficOutBody: return "Renew the subscription in the bot to connect again."
            }
        }
    }
}

private struct LocaleKey: EnvironmentKey {
    static let defaultValue = AppLocale.ru
}

extension EnvironmentValues {
    var appLocale: AppLocale {
        get { self[LocaleKey.self] }
        set { self[LocaleKey.self] = newValue }
    }
}

extension L {
    /// "5 минут назад" / "5 minutes ago".
    static func ago(_ date: Date, _ locale: AppLocale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: locale == .ru ? "ru_RU" : "en_US")
        formatter.unitsStyle = .full
        // Under a minute reads as "now" rather than "in 0 seconds".
        return Date().timeIntervalSince(date) < 60
            ? (locale == .ru ? "только что" : "just now")
            : formatter.localizedString(for: date, relativeTo: Date())
    }

    /// A ``TunnelIssue`` as the user reads it. Never names the service behind
    /// the subscription, never repeats the link or a server address — the one
    /// thing quoted verbatim is the service's own device-limit message, which
    /// it writes for exactly this screen.
    static func issue(_ issue: TunnelIssue, _ locale: AppLocale) -> String {
        switch issue {
        case .invalidLink: return t(.issueInvalidLink, locale)
        case .noSubscription: return t(.issueNoSubscription, locale)
        case .offline: return t(.issueOffline, locale)
        case .serverUnavailable(let code):
            let status = code.map { " (\(t(.issueErrorCode, locale)) \($0))" } ?? ""
            return "\(t(.issueServerUnavailable, locale))\(status). \(t(.issueTryLater, locale))"
        case .linkRejected: return t(.issueLinkRejected, locale)
        case .emptySubscription: return t(.issueEmpty, locale)
        case .noUsableServers: return t(.issueNoUsable, locale)
        case .noServersSent: return t(.issueNoServersSent, locale)
        case .deviceLimit(let message): return message ?? t(.issueDeviceLimit, locale)
        case .deviceNotSupported: return t(.issueDeviceNotSupported, locale)
        case .coreFailed: return t(.issueCoreFailed, locale)
        case .coreStopped: return t(.issueCoreStopped, locale)
        case .routesTaken: return t(.issueRoutesTaken, locale)
        case .tunFailed: return t(.issueTunFailed, locale)
        case .helperMissing: return t(.issueHelperMissing, locale)
        case .helperOutdated: return t(.issueHelperOutdated, locale)
        case .databaseBlocked(let asn): return t(asn ? .issueDatabaseBlockedASN : .issueDatabaseBlocked, locale)
        }
    }
}

extension L {
    /// A rule-type heading in the type picker.
    static func family(_ family: RoutingRule.Kind.Family, _ locale: AppLocale) -> String {
        switch family {
        case .domain: return t(.familyDomain, locale)
        case .ip: return t(.familyIP, locale)
        case .port: return t(.familyPort, locale)
        case .process: return t(.familyProcess, locale)
        case .other: return t(.familyOther, locale)
        }
    }

    /// Why a rule's value cannot be kept, in the user's language.
    static func invalid(_ invalid: RoutingRule.Invalid, _ locale: AppLocale) -> String {
        switch invalid {
        case .empty: return t(.invalidEmpty, locale)
        case .containsComma: return t(.invalidComma, locale)
        case .badRegex: return t(.invalidRegex, locale)
        case .badPort: return t(.invalidPort, locale)
        case .badCIDR: return t(.invalidCIDR, locale)
        case .badASN: return t(.invalidASN, locale)
        case .badNetwork: return t(.invalidNetwork, locale)
        }
    }
}

extension View {
    /// `Text(L.t(.navConnect, locale))` at every call site is noise; this keeps
    /// the string table lookup to one short form.
    func mlLocale(_ locale: AppLocale) -> some View {
        environment(\.appLocale, locale)
    }
}
