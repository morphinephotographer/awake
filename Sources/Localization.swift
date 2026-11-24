import Foundation

/// Interface languages. "auto" follows the macOS language list (Ukrainian, Russian, otherwise English).
enum Loc {
    static let supported = ["en", "uk", "ru"]

    nonisolated(unsafe) static var current: String = resolve()

    /// What the user picked in the menu: "auto", "en", "uk" or "ru".
    static var preference: String {
        UserDefaults.standard.string(forKey: "language") ?? "auto"
    }

    static func set(_ preference: String) {
        UserDefaults.standard.set(preference, forKey: "language")
        current = resolve()
    }

    static func resolve() -> String {
        let pref = preference
        if pref != "auto", supported.contains(pref) { return pref }
        for lang in Locale.preferredLanguages {
            let code = String(lang.prefix(2)).lowercased()
            if supported.contains(code) { return code }
        }
        return "en"
    }

    /// "1 app / 2 apps", "1 программу / 2 программы / 5 программ", "1 програму / 2 програми / 5 програм".
    static func foundApps(_ n: Int) -> String {
        switch current {
        case "ru":
            return n == 1
                ? "Нашёл у тебя 1 программу — Mac не уснёт, пока она рендерит или экспортирует."
                : "Нашёл у тебя \(n) \(slavic(n, "программу", "программы", "программ")) — Mac не уснёт, пока они рендерят или экспортируют."
        case "uk":
            return n == 1
                ? "Знайшов у тебе 1 програму — Mac не засне, поки вона рендерить або експортує."
                : "Знайшов у тебе \(n) \(slavic(n, "програму", "програми", "програм")) — Mac не засне, поки вони рендерять або експортують."
        default:
            return n == 1
                ? "Found 1 app — your Mac won't sleep while it renders or exports."
                : "Found \(n) apps — your Mac won't sleep while they render or export."
        }
    }

    private static func slavic(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
        return many
    }

    /// Russian source string → translation.
    static let table: [String: [String: String]] = [
        "en": [
            "Иконка программы в чёлке": "App icon in the notch",
            "Пока агент работает": "While the agent works",
            "Агент работает": "Agent at work",
            "агент": "agent",
            "Пока %@ выполняет задачу — думает, пишет код или управляет Маком — Mac не уснёт. Когда агент затихнет на 3 минуты, awake. вернёт обычный сон.":
                "While %@ is on a task — thinking, writing code or driving your Mac — the Mac won't sleep. When the agent has been quiet for 3 minutes, awake. restores normal sleep.",
            "+15м": "+15m",
            "%ldм": "%ldm",
            "%ldч": "%ldh",
            "%ldч%@": "%ldh%@",
            "%@ %@. awake. может не давать Mac уснуть, пока программа работает, и отпускать сон через 2 минуты после окончания.":
                "%@ %@. awake. can keep the Mac awake while the app works and let it sleep 2 minutes after it's done.",
            "сам просит Mac не засыпать": "asks macOS not to sleep",
            "больше минуты сильно грузит процессор": "has been working the CPU hard for over a minute",
            "awake. не следит за этой программой.": "awake. doesn't follow this app.",
            "awake. удалит помощник для закрытой крышки.": "awake. will remove the closed-lid helper.",
            "awake. хочет, чтобы Mac работал с закрытой крышкой.": "awake. wants to keep your Mac working with the lid closed.",
            "Автозапуск включён": "Launches at login",
            "Выйти из awake.": "Quit awake.",
            "Выключать при заряде": "Stop at battery level",
            "До времени": "Until",
            "Добавить программу…": "Add app…",
            "Ещё 15 минут": "15 more minutes",
            "Ещё настройки": "More settings",
            "Ещё": "More",
            "Загрузка": "Downloads",
            "Запускать при входе в систему": "Launch at login",
            "Клик по ушку чёлки — выключить": "Click next to the notch — turn off",
            "Колёсико над чёлкой — ±15 минут": "Scroll over the notch — ±15 minutes",
            "Минус 15 минут": "15 minutes less",
            "Не давать Mac уснуть": "Keep the Mac awake",
            "Не нужно": "No thanks",
            "Не предлагать": "Don't suggest",
            "Не следить за программами": "Not following apps",
            "Не следить": "Off",
            "Нет знакомых программ": "No known apps",
            "Никогда": "Never",
            "Пока %@ качает файлы, Mac не уснёт. После окончания загрузки awake. подождёт 2 минуты и вернёт обычный сон.":
                "While %@ downloads, the Mac won't sleep. When the download is done, awake. waits 2 minutes and restores normal sleep.",
            "Пока %@ открыт, Mac не уснёт. Закроешь программу — сон вернётся.":
                "While %@ is open, the Mac won't sleep. Quit the app and sleep comes back.",
            "Пока %@ рендерит или экспортирует — заметно нагружает процессор или записывает файлы — awake. не даёт Mac уснуть. Когда работа закончится, awake. подождёт 2 минуты и вернёт обычный сон. Если выключить ⏻ вручную, awake. включится снова только при следующем рендере.":
                "While %@ renders or exports — noticeably loads the CPU or writes files — awake. keeps the Mac awake. When the job is done, awake. waits 2 minutes and restores normal sleep. If you turn ⏻ off by hand, awake. comes back only with the next render.",
            "Пока идёт работа": "While working",
            "Пока качает": "While downloading",
            "Пока открыта": "While open",
            "Пока открыто": "While open",
            "Пока работает (рендер, экспорт)": "While working (render, export)",
            "Программы": "Apps",
            "Работает с закрытой крышкой": "Works with the lid closed",
            "Работать с закрытой крышкой": "Keep working with the lid closed",
            "Разрешить сон": "Allow sleep",
            "Режим меняется в меню ⋯ → Программы.": "Change the mode in ⋯ → Apps.",
            "Рендер и экспорт": "Render and export",
            "Скопировать ссылку для «Быстрых команд»": "Copy link for Shortcuts",
            "Следит за рендером в твоих программах": "Following renders in your apps",
            "Следить за %@?": "Follow %@?",
            "Следить": "Follow",
            "Удалить помощник закрытой крышки…": "Remove closed-lid helper…",
            "Экран может погаснуть, Mac не уснёт": "Display may sleep, the Mac stays awake",
            "Экран не гаснет": "Display stays on",
            "авто": "auto",
            "без ограничений": "no limit",
            "выкл": "off",
            "держит Mac": "keeping awake",
            "до %@": "until %@",
            "ждёт работы": "idle",
            "качает": "downloading",
            "настройка — в ⋯": "settings in ⋯",
            "не спит": "awake",
            "открыт": "open",
            "раб": "work",
            "работа": "working",
            "рендер": "render",
            "⌘Q на открытой панели — выйти": "⌘Q on the open panel — quit",
            "⌥⌘A — включить или выключить": "⌥⌘A — turn on or off",
            "awake. %@ · создано Morphine": "awake. %@ · made by Morphine",
            "Язык": "Language",
            "Как в системе": "Same as macOS"
        ],
        "uk": [
            "Иконка программы в чёлке": "Іконка програми у вирізі",
            "Пока агент работает": "Поки агент працює",
            "Агент работает": "Агент працює",
            "агент": "агент",
            "Пока %@ выполняет задачу — думает, пишет код или управляет Маком — Mac не уснёт. Когда агент затихнет на 3 минуты, awake. вернёт обычный сон.":
                "Поки %@ виконує завдання — думає, пише код або керує Маком — Mac не засне. Коли агент затихне на 3 хвилини, awake. поверне звичайний сон.",
            "+15м": "+15хв",
            "%ldм": "%ldхв",
            "%ldч": "%ldгод",
            "%ldч%@": "%ldг%@",
            "%@ %@. awake. может не давать Mac уснуть, пока программа работает, и отпускать сон через 2 минуты после окончания.":
                "%@ %@. awake. може не давати Mac заснути, поки програма працює, і відпускати сон через 2 хвилини після завершення.",
            "сам просит Mac не засыпать": "сам просить Mac не засинати",
            "больше минуты сильно грузит процессор": "понад хвилину сильно навантажує процесор",
            "awake. не следит за этой программой.": "awake. не стежить за цією програмою.",
            "awake. удалит помощник для закрытой крышки.": "awake. видалить помічник для закритої кришки.",
            "awake. хочет, чтобы Mac работал с закрытой крышкой.": "awake. хоче, щоб Mac працював із закритою кришкою.",
            "Автозапуск включён": "Автозапуск увімкнено",
            "Выйти из awake.": "Вийти з awake.",
            "Выключать при заряде": "Вимикати при заряді",
            "До времени": "До часу",
            "Добавить программу…": "Додати програму…",
            "Ещё 15 минут": "Ще 15 хвилин",
            "Ещё настройки": "Більше налаштувань",
            "Ещё": "Ще",
            "Загрузка": "Завантаження",
            "Запускать при входе в систему": "Запускати під час входу в систему",
            "Клик по ушку чёлки — выключить": "Клік біля вирізу екрана — вимкнути",
            "Колёсико над чёлкой — ±15 минут": "Коліщатко над вирізом — ±15 хвилин",
            "Минус 15 минут": "Мінус 15 хвилин",
            "Не давать Mac уснуть": "Не давати Mac заснути",
            "Не нужно": "Не треба",
            "Не предлагать": "Не пропонувати",
            "Не следить за программами": "Не стежити за програмами",
            "Не следить": "Не стежити",
            "Нет знакомых программ": "Немає знайомих програм",
            "Никогда": "Ніколи",
            "Пока %@ качает файлы, Mac не уснёт. После окончания загрузки awake. подождёт 2 минуты и вернёт обычный сон.":
                "Поки %@ завантажує файли, Mac не засне. Після завершення завантаження awake. зачекає 2 хвилини й поверне звичайний сон.",
            "Пока %@ открыт, Mac не уснёт. Закроешь программу — сон вернётся.":
                "Поки %@ відкрито, Mac не засне. Закриєш програму — сон повернеться.",
            "Пока %@ рендерит или экспортирует — заметно нагружает процессор или записывает файлы — awake. не даёт Mac уснуть. Когда работа закончится, awake. подождёт 2 минуты и вернёт обычный сон. Если выключить ⏻ вручную, awake. включится снова только при следующем рендере.":
                "Поки %@ рендерить або експортує — помітно навантажує процесор або записує файли — awake. не дає Mac заснути. Коли робота завершиться, awake. зачекає 2 хвилини й поверне звичайний сон. Якщо вимкнути ⏻ вручну, awake. увімкнеться знову лише під час наступного рендеру.",
            "Пока идёт работа": "Поки триває робота",
            "Пока качает": "Поки завантажує",
            "Пока открыта": "Поки відкрита",
            "Пока открыто": "Поки відкрито",
            "Пока работает (рендер, экспорт)": "Поки працює (рендер, експорт)",
            "Программы": "Програми",
            "Работает с закрытой крышкой": "Працює із закритою кришкою",
            "Работать с закрытой крышкой": "Працювати із закритою кришкою",
            "Разрешить сон": "Дозволити сон",
            "Режим меняется в меню ⋯ → Программы.": "Режим змінюється в меню ⋯ → Програми.",
            "Рендер и экспорт": "Рендер і експорт",
            "Скопировать ссылку для «Быстрых команд»": "Скопіювати посилання для «Швидких команд»",
            "Следит за рендером в твоих программах": "Стежить за рендером у твоїх програмах",
            "Следить за %@?": "Стежити за %@?",
            "Следить": "Стежити",
            "Удалить помощник закрытой крышки…": "Видалити помічник закритої кришки…",
            "Экран может погаснуть, Mac не уснёт": "Екран може згаснути, Mac не засне",
            "Экран не гаснет": "Екран не гасне",
            "авто": "авто",
            "без ограничений": "без обмежень",
            "выкл": "вимк",
            "держит Mac": "тримає Mac",
            "до %@": "до %@",
            "ждёт работы": "чекає роботи",
            "качает": "завантажує",
            "настройка — в ⋯": "налаштування — в ⋯",
            "не спит": "не спить",
            "открыт": "відкрито",
            "раб": "роб",
            "работа": "робота",
            "рендер": "рендер",
            "⌘Q на открытой панели — выйти": "⌘Q на відкритій панелі — вийти",
            "⌥⌘A — включить или выключить": "⌥⌘A — увімкнути або вимкнути",
            "awake. %@ · создано Morphine": "awake. %@ · створено Morphine",
            "Язык": "Мова",
            "Как в системе": "Як у системі"
        ]
    ]
}

/// Translate a Russian source string into the current interface language.
func tr(_ ru: String) -> String {
    Loc.current == "ru" ? ru : (Loc.table[Loc.current]?[ru] ?? ru)
}

/// Translate a Russian format string and fill it in.
func tr(_ ru: String, _ args: CVarArg...) -> String {
    String(format: tr(ru), arguments: args)
}
