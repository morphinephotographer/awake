import AppKit
import SwiftUI

extension Color {
    static let awakeGreen = Color(red: 0.24, green: 0.88, blue: 0.48)
}

enum Motion {
    /// Panel growing out of the notch.
    static let grow = Animation.spring(response: 0.55, dampingFraction: 0.78)
    /// Panel shrinking back into the notch.
    static let shrink = Animation.spring(response: 0.42, dampingFraction: 0.92)
    static let ears = Animation.spring(response: 0.45, dampingFraction: 0.82)
}

// MARK: - Shapes

/// Notch silhouette: concave flares at the top, rounded bottom corners.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let b = min(bottom, r.height / 2, max(0, (r.width - top * 2) / 2))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + b, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - b), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Analog clock in the style of macOS Clock: white dial, black hands, orange second hand.
/// It shows the time that is LEFT, so the hands run backwards; for ∞ they run forward.
struct CountdownClock: View {
    let awake: Awake
    var on: Bool
    var size: CGFloat = 15

    static let orange = Color(red: 1, green: 0.58, blue: 0)

    var body: some View {
        let t = awake.remaining.map { $0.rounded(.up) } ?? awake.elapsed
        ZStack {
            Circle().fill(Color(white: 0.97))
            ForEach(0..<12, id: \.self) { i in
                Capsule()
                    .fill(Color(white: i % 3 == 0 ? 0.1 : 0.55))
                    .frame(width: size * 0.05, height: size * (i % 3 == 0 ? 0.13 : 0.08))
                    .offset(y: -size * 0.39)
                    .rotationEffect(.degrees(Double(i) * 30))
            }
            hand(length: 0.26, width: 0.085, color: Color(white: 0.08), angle: t / 120)   // hours
            hand(length: 0.37, width: 0.065, color: Color(white: 0.08), angle: t / 10)    // minutes
            hand(length: 0.40, width: 0.035, color: Self.orange, angle: t * 6)            // seconds
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: t)
            Circle().fill(Self.orange).frame(width: size * 0.13, height: size * 0.13)
        }
        .frame(width: size, height: size)
        .scaleEffect(on ? 1 : 0.01)
        .opacity(on ? 1 : 0)
    }

    private func hand(length: CGFloat, width: CGFloat, color: Color, angle: Double) -> some View {
        Capsule()
            .fill(color)
            .frame(width: max(0.8, size * width), height: size * length)
            .offset(y: -size * length / 2)
            .rotationEffect(.degrees(angle))
    }
}

extension AnyTransition {
    /// Content appearing out of the notch.
    static var sprout: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.9, anchor: .top))
                .animation(.spring(response: 0.45, dampingFraction: 0.85).delay(0.1)),
            removal: .opacity.animation(.easeIn(duration: 0.1))
        )
    }
}

// MARK: - Root

struct NotchView: View {
    let model: NotchModel
    let awake: Awake

    var body: some View {
        let size = Layout.size(model)
        let c = Layout.corners(model.isExpanded)
        let visible = model.hasNotch || model.earsVisible || model.isExpanded

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if model.isExpanded {
                    ExpandedContent(model: model, awake: awake)
                        .transition(.sprout)
                } else if model.earsVisible {
                    CollapsedContent(model: model, awake: awake)
                        .transition(.opacity.animation(.easeOut(duration: 0.18)))
                }
            }
            .padding(.horizontal, c.top)
            .frame(width: size.width + c.top * 2, height: size.height, alignment: .top)
            .background(Color.black)
            .clipShape(NotchShape(top: c.top, bottom: c.bottom))
            .shadow(color: .black.opacity(model.isExpanded ? 0.5 : 0), radius: 10, y: 5)
            .opacity(visible ? 1 : 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(model.isExpanded ? Motion.grow : Motion.shrink, value: model.isExpanded)
        .environment(\.colorScheme, .dark)
        .onAppear {
            model.earsVisible = awake.isActive
            model.dotOn = awake.isActive
        }
        .onChange(of: awake.isActive) { _, active in
            if active {
                withAnimation(Motion.ears) { model.earsVisible = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard awake.isActive else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { model.dotOn = true }
                }
            } else {
                withAnimation(.easeIn(duration: 0.25)) { model.dotOn = false }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !awake.isActive else { return }
                    withAnimation(Motion.ears) { model.earsVisible = false }
                }
            }
        }
    }
}

// MARK: - Collapsed

private struct CollapsedContent: View {
    let model: NotchModel
    let awake: Awake

    var body: some View {
        HStack {
            if awake.isActive && awake.reason == .apps && !awake.watcher.active.isEmpty {
                AppStack(awake: awake, size: 15)
                    .transition(.scale.combined(with: .opacity))
            } else {
                CountdownClock(awake: awake, on: model.dotOn)
            }
            Spacer(minLength: 0)
            Text(awake.shortText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .frame(height: model.notchSize.height)
    }
}

// MARK: - Expanded

private struct ExpandedContent: View {
    let model: NotchModel
    let awake: Awake

    var body: some View {
        VStack(spacing: 0) {
            // Row inside the notch height (camera in the middle): clock left, time right.
            HStack {
                CountdownClock(awake: awake, on: model.dotOn, size: 16)
                    .overlay(alignment: .leading) {
                        if !model.dotOn {
                            Text("awake.")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.9))
                                .fixedSize()
                        }
                    }
                Spacer(minLength: 0)
                if awake.endingSoon {
                    Button { awake.adjust(by: 15 * 60) } label: {
                        Text("+15м")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(Capsule().fill(Color.awakeGreen))
                    }
                    .buttonStyle(PressStyle())
                    .transition(.scale.combined(with: .opacity))
                }
                HStack(spacing: 5) {
                    if awake.isActive && awake.reason == .apps && !awake.watcher.active.isEmpty {
                        AppStack(awake: awake, size: 15)
                    }
                    Text(awake.longText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(awake.isActive ? 1 : 0.4))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: model.notchSize.height)

            HStack(spacing: 10) {
                BigPower(awake: awake)
                VStack(alignment: .leading, spacing: 6) {
                    DurationTrack(awake: awake)
                    HStack(spacing: 6) {
                        IconButton(symbol: awake.keepDisplay ? "sun.max.fill" : "moon.fill",
                                   on: awake.keepDisplay,
                                   help: awake.keepDisplay ? "Экран не гаснет" : "Экран может погаснуть, Mac не уснёт") {
                            awake.setKeepDisplay(!awake.keepDisplay)
                        }
                        IconButton(symbol: "laptopcomputer", on: awake.lidMode,
                                   help: awake.lidMode ? "Работает с закрытой крышкой" : "Работать с закрытой крышкой") {
                            awake.setLidMode(!awake.lidMode)
                        }
                        IconButton(symbol: "arrow.clockwise", on: model.loginEnabled,
                                   help: model.loginEnabled ? "Автозапуск включён" : "Запускать при входе в систему") {
                            LoginItem.toggle()
                            model.loginEnabled = LoginItem.isEnabled
                        }
                        IconButton(symbol: "film", on: awake.watcher.enabled,
                                   help: awake.watcher.enabled ? "Следит за рендером в твоих программах" : "Не следить за программами") {
                            awake.setWatchEnabled(!awake.watcher.enabled)
                        }
                        Spacer(minLength: 0)
                        IconButton(symbol: "xmark", on: false, danger: true, help: "Выйти из awake.") {
                            awake.stop()
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)

            WatchRow(awake: awake)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
        .contentShape(Rectangle())
        .contextMenu { SettingsMenu(model: model, awake: awake) }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: awake.endingSoon)
    }
}

/// Everything extra lives in the right-click menu, so the panel itself stays as it is.
private struct SettingsMenu: View {
    let model: NotchModel
    let awake: Awake

    var body: some View {
        Menu("Следить за программами") {
            Toggle("Следить", isOn: Binding(
                get: { awake.watcher.enabled },
                set: { awake.setWatchEnabled($0) }
            ))
            Divider()
            ForEach(awake.watcher.rules) { rule in
                Menu("\(rule.title) — \(rule.mode.title.lowercased())") {
                    ForEach(WatchMode.allCases, id: \.self) { mode in
                        Toggle(mode.title, isOn: Binding(
                            get: { rule.mode == mode },
                            set: { _ in awake.setWatchMode(mode, for: rule.id) }
                        ))
                    }
                }
            }
            Divider()
            Button("Добавить программу…") { awake.watcher.addCustomApp() }
        }
        Toggle("Пока идёт работа (экспорт, рендер, загрузка)", isOn: Binding(
            get: { awake.isActive && awake.reason == .activity },
            set: { on in if on { awake.startActivity() } else { awake.stop() } }
        ))
        Menu("До времени") {
            ForEach(NotchController.untilChoices(), id: \.self) { date in
                Button("до \(Awake.hm.string(from: date))") { awake.start(until: date) }
            }
        }
        if awake.isActive && awake.endDate != nil {
            Button("+15 минут") { awake.adjust(by: 15 * 60) }
            Button("−15 минут") { awake.adjust(by: -15 * 60) }
        }
        Divider()
        Menu("Выключать при заряде батареи") {
            ForEach([0, 10, 20, 30], id: \.self) { pct in
                let title: String = pct == 0 ? "Никогда" : "≤ \(pct)%"
                Toggle(title, isOn: Binding(
                    get: { awake.batteryLimit == pct },
                    set: { _ in awake.setBatteryLimit(pct) }
                ))
            }
        }
        if LidGuard.isInstalled {
            Button("Удалить помощник закрытой крышки…") { awake.uninstallLidGuard() }
        }
        Divider()
        Text("⌥⌘A — включить / выключить")
        Text("Колёсико над панелью или ушками — ±15 мин")
        Text("Клик по ушкам чёлки — выключить")
        Button("Скопировать ссылку для «Быстрых команд»") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("awake://start?minutes=60", forType: .string)
        }
    }
}

/// The main on/off button (twice the old in-track size).
private struct BigPower: View {
    let awake: Awake
    @State private var hover = false

    var body: some View {
        Button { awake.toggle() } label: {
            Image(systemName: "power")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(awake.isActive ? Color.black : Color.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(awake.isActive ? Color.awakeGreen : Color.white.opacity(hover ? 0.17 : 0.11)))
                .shadow(color: Color.awakeGreen.opacity(awake.isActive ? 0.6 : 0), radius: 10)
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.18), value: awake.isActive)
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help(awake.isActive ? "Разрешить сон · правый клик — ещё" : "Не давать Mac уснуть · правый клик — ещё")
    }
}

/// Durations in one capsule with a sliding pill.
private struct DurationTrack: View {
    let awake: Awake
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Awake.durations, id: \.self) { d in
                let lit = awake.isActive && awake.activePreset == d
                let selected = awake.isActive ? lit : awake.savedPreset == d
                Button {
                    if lit { awake.stop() } else { awake.start(preset: d) }
                } label: {
                    Text(Awake.label(d))
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(selected ? (lit ? Color.black : Color.white) : Color.white.opacity(0.5))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(lit ? Color.white : Color.white.opacity(0.14))
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: awake.activePreset)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: awake.savedPreset)
        .animation(.easeOut(duration: 0.18), value: awake.isActive)
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Small round icon button: green when the setting is on, grey when off.
private struct IconButton: View {
    let symbol: String
    let on: Bool
    var danger = false
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 26, height: 26)
                .background(Circle().fill(background))
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.15), value: hover)
                .animation(.easeOut(duration: 0.2), value: on)
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help(help)
    }

    private var foreground: Color {
        if danger { return hover ? Color(red: 1, green: 0.42, blue: 0.4) : .white.opacity(0.4) }
        return on ? .awakeGreen : .white.opacity(hover ? 0.6 : 0.4)
    }

    private var background: Color {
        if danger { return hover ? Color(red: 1, green: 0.3, blue: 0.28).opacity(0.18) : .white.opacity(0.07) }
        if on { return Color.awakeGreen.opacity(hover ? 0.24 : 0.16) }
        return .white.opacity(hover ? 0.12 : 0.07)
    }
}

// MARK: - Watched apps

/// Real app icon, or a grey tile with initials when the app is not installed.
struct AppIconView: View {
    let image: NSImage?
    let title: String
    let size: CGFloat

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .overlay(
                    Text(String(title.prefix(2)))
                        .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                )
                .frame(width: size, height: size)
        }
    }
}

/// Icons of the apps keeping the Mac awake (up to two, stacked).
private struct AppStack: View {
    let awake: Awake
    let size: CGFloat

    var body: some View {
        let ids = Array(awake.watcher.active.prefix(2))
        HStack(spacing: -size * 0.3) {
            ForEach(ids, id: \.self) { id in
                if let rule = awake.watcher.rule(id) {
                    AppIconView(image: awake.watcher.icon(for: rule), title: rule.title, size: size)
                }
            }
        }
    }
}

/// All watched apps: dim = closed, bright = open, green dot = keeping the Mac awake.
private struct WatchRow: View {
    let awake: Awake

    var body: some View {
        let w = awake.watcher
        HStack(spacing: 7) {
            ForEach(w.rules.filter { $0.mode != .off }) { rule in
                let open = w.running.contains(rule.id)
                let active = w.active.contains(rule.id)
                AppIconView(image: w.icon(for: rule), title: rule.title, size: 20)
                    .opacity(w.enabled ? (open ? 1 : 0.3) : 0.2)
                    .overlay(alignment: .bottomTrailing) {
                        if active {
                            Circle()
                                .fill(Color.awakeGreen)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().stroke(Color.black, lineWidth: 1.2))
                                .offset(x: 2, y: 2)
                                .transition(.scale)
                        }
                    }
                    .help("\(rule.title) — \(active ? rule.mode.verb : (open ? "открыта" : "закрыта")) · \(rule.mode.title.lowercased())")
                    .animation(.easeOut(duration: 0.2), value: active)
                    .animation(.easeOut(duration: 0.2), value: open)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 22)
    }
}
