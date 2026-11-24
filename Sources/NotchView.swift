import AppKit
import SwiftUI

extension Color {
    static let awakeGreen = Color(red: 0.24, green: 0.88, blue: 0.48)
}

/// True while the panel is rendered into a picture for the README (native menus can't be drawn there).
private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var snapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
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
        let visible = model.hasNotch || model.earShown || model.isExpanded || model.intro

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if model.isExpanded {
                    PanelInnerGlow()
                        .transition(.opacity.animation(.easeOut(duration: 0.5)))
                }
                if model.isExpanded && model.onboarding {
                    OnboardingContent(model: model, awake: awake)
                        .transition(.sprout)
                } else if model.isExpanded {
                    ExpandedContent(model: model, awake: awake)
                        .transition(.sprout)
                } else if model.intro {
                    IntroContent(model: model)
                        .transition(.opacity.animation(.easeOut(duration: 0.2)))
                } else if model.earShown {
                    CollapsedContent(model: model, awake: awake)
                        .transition(.opacity.animation(.easeOut(duration: 0.18)))
                }
            }
            .padding(.horizontal, c.top)
            .frame(width: size.width + c.top * 2, height: size.height, alignment: .top)
            .background(Color.black)
            .clipShape(NotchShape(top: c.top, bottom: c.bottom))
            .shadow(color: .black.opacity(model.isExpanded ? 0.5 : 0), radius: 10, y: 5)
            .offset(x: Layout.offsetX(model))
            .background(alignment: .top) { DawnGlow(model: model) }
            .background(alignment: .top) {
                if model.isExpanded {
                    PanelGlow(height: size.height)
                        .transition(.opacity.animation(.easeOut(duration: 0.5)))
                }
            }
            .opacity(visible ? 1 : 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(model.isExpanded ? Motion.grow : Motion.shrink, value: model.isExpanded)
        .environment(\.colorScheme, .dark)
        .id(model.langVersion)
        .onAppear {
            model.earsVisible = awake.isActive
            model.appsMode = awake.isActive && awake.reason == .apps
            model.dotOn = awake.isActive
        }
        .onChange(of: awake.isActive && awake.reason == .apps) { _, apps in
            withAnimation(Motion.ears) { model.appsMode = apps }
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

    /// Right ear only: app icons while an app renders, otherwise the time left.
    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if awake.isActive && awake.reason == .apps && !awake.watcher.active.isEmpty {
                    AppStack(awake: awake, size: 16)
                        .transition(.scale.combined(with: .opacity))
                } else if awake.isActive && awake.reason == .monitor {
                    Image(systemName: "display")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text(awake.shortText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(width: Layout.ear)
            .opacity(model.dotOn ? 1 : 0)
            .scaleEffect(model.dotOn ? 1 : 0.6)
        }
        .frame(height: model.notchSize.height)
    }
}

/// Launch "Восход": "awake." appears out of a blur on the right, a 1-px line of light along the bottom.
private struct IntroContent: View {
    let model: NotchModel

    var body: some View {
        ZStack(alignment: .bottom) {
            // Dawn inside the notch: a soft green light rising from its lower edge.
            RadialGradient(colors: [Color.awakeGreen.opacity(0.38), Color.awakeGreen.opacity(0.10), .clear],
                           center: .bottom, startRadius: 0, endRadius: (model.notchSize.height + Layout.introDrop) * 1.1)
                .scaleEffect(x: (model.notchSize.width + Layout.introWing * 2) / ((model.notchSize.height + Layout.introDrop) * 2.2) * 0.75,
                             y: 1, anchor: .bottom)
                .opacity(model.introGlow ? 1 : 0)
                .allowsHitTesting(false)
            HStack {
                Spacer(minLength: 0)
                (Text("awake").foregroundStyle(.white.opacity(0.92)) + Text(".").foregroundStyle(Color.awakeGreen))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .tracking(0.3)
                    .opacity(model.introText ? 1 : 0)
                    .blur(radius: model.introText ? 0 : 3)
                    .offset(y: model.introText ? 0 : 2)
            }
            .padding(.horizontal, 18)
            .frame(height: model.notchSize.height)
            .frame(maxHeight: .infinity, alignment: .top)
            LinearGradient(colors: [.clear, Color(red: 0.47, green: 0.94, blue: 0.65).opacity(0.55),
                                    Color(red: 0.47, green: 0.94, blue: 0.65).opacity(0.55), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: model.introLine ? model.notchSize.width + 60 : 0, height: 1)
                .opacity(model.introLine ? 1 : 0)
        }
        .frame(height: model.notchSize.height + Layout.introDrop)
    }
}

/// Static soft glow under the open panel. Drawn only while the panel is open (removed from the view
/// tree when it closes), no animation loop — rendered once, so it costs nothing while it stays open.
private struct PanelGlow: View {
    let height: CGFloat

    var body: some View {
        Ellipse()
            .fill(RadialGradient(colors: [Color.awakeGreen.opacity(0.28), Color.awakeGreen.opacity(0.09), .clear],
                                 center: .top, startRadius: 0, endRadius: 190))
            .frame(width: 420, height: 70)
            .blur(radius: 8)
            .offset(y: height - 12)
            .allowsHitTesting(false)
    }
}

/// Soft light rising from the lower edge inside the open panel.
private struct PanelInnerGlow: View {
    var body: some View {
        RadialGradient(colors: [Color.awakeGreen.opacity(0.24), Color.awakeGreen.opacity(0.08), .clear],
                       center: .bottom, startRadius: 0, endRadius: 150)
            .scaleEffect(x: 1.8, y: 0.75, anchor: .bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }
}

/// Soft green dawn rising from under the notch during the launch animation.
private struct DawnGlow: View {
    let model: NotchModel

    var body: some View {
        Ellipse()
            .fill(RadialGradient(colors: [Color.awakeGreen.opacity(0.32), Color.awakeGreen.opacity(0.10), .clear],
                                 center: .top, startRadius: 0, endRadius: 130))
            .frame(width: 260, height: 70)
            .blur(radius: 6)
            .scaleEffect(x: model.introGlow ? 1 : 0.55, y: model.introGlow ? 1 : 0.7, anchor: .top)
            .offset(y: model.notchSize.height + Layout.introDrop - 8 + (model.introGlow ? -6 : 14))
            .opacity(model.introGlow ? 1 : 0)
            .allowsHitTesting(false)
    }
}

/// First launch: the apps awake. found on this Mac.
private struct OnboardingContent: View {
    let model: NotchModel
    let awake: Awake

    var body: some View {
        let w = awake.watcher
        let found = w.rules.filter { w.installed.contains($0.id) }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("awake.")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: model.notchSize.height)

            Text(Loc.foundApps(found.count))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            HStack(spacing: 5) {
                ForEach(Array(found.prefix(9))) { rule in
                    AppIconView(image: w.icon(for: rule), title: rule.title, size: 18)
                        .help(rule.title)
                }
                if found.count > 9 {
                    Text("+\(found.count - 9)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            HStack(spacing: 8) {
                Button { model.finishOnboarding?(true) } label: {
                    Text(tr("Следить"))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 14)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.awakeGreen))
                }
                .buttonStyle(PressStyle())
                Button { model.finishOnboarding?(false) } label: {
                    Text(tr("Не нужно"))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 14)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(PressStyle())
                Spacer(minLength: 0)
                Text(tr("настройка — в ⋯"))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
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
                Text("awake.")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize()
                Spacer(minLength: 0)
                if awake.endingSoon {
                    Button { awake.adjust(by: 15 * 60) } label: {
                        Text(tr("+15м"))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(Capsule().fill(Color.awakeGreen))
                    }
                    .buttonStyle(PressStyle())
                    .transition(.scale.combined(with: .opacity))
                }
                if awake.isActive && awake.reason == .apps && !awake.watcher.active.isEmpty {
                    AppStack(awake: awake, size: 15)
                } else {
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
                    HStack(spacing: 4) {
                        IconButton(symbol: "arrow.clockwise", on: model.loginEnabled,
                                   help: model.loginEnabled ? tr("Автозапуск включён") : tr("Запускать при входе в систему")) {
                            LoginItem.toggle()
                            model.loginEnabled = LoginItem.isEnabled
                        }
                        IconButton(symbol: awake.keepDisplay ? "sun.max.fill" : "moon.fill",
                                   on: awake.keepDisplay,
                                   help: awake.keepDisplay ? tr("Экран не гаснет") : tr("Экран может погаснуть, Mac не уснёт")) {
                            awake.setKeepDisplay(!awake.keepDisplay)
                        }
                        IconButton(symbol: "laptopcomputer", on: awake.lidMode,
                                   help: awake.lidMode ? tr("Работает с закрытой крышкой") : tr("Работать с закрытой крышкой")) {
                            awake.setLidMode(!awake.lidMode)
                        }
                        IconButton(symbol: "film", on: awake.watcher.enabled,
                                   help: awake.watcher.enabled ? tr("Следит за рендером в твоих программах") : tr("Не следить за программами")) {
                            awake.setWatchEnabled(!awake.watcher.enabled)
                        }
                        Spacer(minLength: 0)
                        RunningApps(model: model, awake: awake)
                        Spacer(minLength: 0)
                        OptionsButton(model: model, awake: awake)
                        IconButton(symbol: "xmark", on: false, danger: true, help: tr("Выйти из awake.")) {
                            awake.stop()
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .contentShape(Rectangle())
        .contextMenu { SettingsMenu(model: model, awake: awake) }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: awake.endingSoon)
    }
}

/// The extra options: right-click on the panel or the ⋯ button. Kept short — details live in submenus.
private struct SettingsMenu: View {
    let model: NotchModel
    let awake: Awake

    var body: some View {
        Toggle(isOn: Binding(
            get: { awake.isActive && awake.reason == .activity },
            set: { on in if on { awake.startActivity() } else { awake.stop() } }
        )) { Label(tr("Пока идёт работа"), systemImage: "cpu") }

        Toggle(isOn: Binding(
            get: { awake.monitorMode },
            set: { awake.setMonitorMode($0) }
        )) { Label(tr("Пока подключён монитор"), systemImage: "display") }

        Menu {
            ForEach(NotchController.untilChoices(), id: \.self) { date in
                Button(tr("до %@", Awake.hm.string(from: date))) { awake.start(until: date) }
            }
        } label: { Label(tr("До времени"), systemImage: "clock") }

        if awake.isActive && awake.endDate != nil {
            Button { awake.adjust(by: 15 * 60) } label: { Label(tr("Ещё 15 минут"), systemImage: "plus") }
            Button { awake.adjust(by: -15 * 60) } label: { Label(tr("Минус 15 минут"), systemImage: "minus") }
        }

        Divider()

        Menu {
            Toggle(tr("Иконка программы в чёлке"), isOn: Binding(
                get: { model.iconInNotch },
                set: { on in
                    UserDefaults.standard.set(on, forKey: "iconInNotch")
                    withAnimation(Motion.ears) { model.iconInNotch = on }
                }
            ))
            Toggle(tr("Уведомлять, когда готово"), isOn: Binding(
                get: { awake.notifyDone },
                set: { awake.setNotifyDone($0) }
            ))
            Picker(selection: Binding(
                get: { awake.afterDone },
                set: { awake.setAfterDone($0) }
            )) {
                Text(tr("Ничего не делать")).tag(Awake.AfterDone.nothing)
                Text(tr("Выключить экран")).tag(Awake.AfterDone.display)
                Text(tr("Усыпить Mac")).tag(Awake.AfterDone.sleep)
            } label: { Text(tr("Когда всё готово")) }
            .pickerStyle(.menu)
            Divider()
            if awake.watcher.visibleRules.isEmpty {
                Text(tr("Нет знакомых программ"))
            }
            ForEach(awake.watcher.visibleRules) { rule in
                Picker(selection: Binding(
                    get: { rule.mode },
                    set: { awake.setWatchMode($0, for: rule.id) }
                )) {
                    ForEach(WatchMode.allCases, id: \.self) { mode in
                        Text(mode.short).tag(mode)
                    }
                } label: { Text(rule.title) }
                .pickerStyle(.menu)
            }
            Divider()
            Button(tr("Добавить программу…")) { awake.watcher.addCustomApp() }
        } label: { Label(tr("Программы"), systemImage: "film") }

        Picker(selection: Binding(
            get: { awake.batteryLimit },
            set: { awake.setBatteryLimit($0) }
        )) {
            Text(tr("Никогда")).tag(0)
            Text("10%").tag(10)
            Text("20%").tag(20)
            Text("30%").tag(30)
        } label: { Label(tr("Выключать при заряде"), systemImage: "battery.25") }
        .pickerStyle(.menu)

        Picker(selection: Binding(
            get: { Loc.preference },
            set: { Loc.set($0); model.langVersion += 1 }
        )) {
            Text(tr("Как в системе")).tag("auto")
            Divider()
            Text("English").tag("en")
            Text("Українська").tag("uk")
            Text("Русский").tag("ru")
        } label: { Label(tr("Язык"), systemImage: "globe") }
        .pickerStyle(.menu)

        Divider()

        Menu {
            Button(tr("Проверить обновления")) {
                Task { await awake.updater.check(manual: true) }
            }
            Button(tr("Скопировать ссылку для «Быстрых команд»")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("awake://start?minutes=60", forType: .string)
            }
            if LidGuard.isInstalled {
                Button(tr("Удалить помощник закрытой крышки…")) { awake.uninstallLidGuard() }
            }
            Divider()
            Text(tr("⌥⌘A — включить или выключить"))
            Text(tr("⌘Q на открытой панели — выйти"))
            Text(tr("Колёсико над чёлкой — ±15 минут"))
            Text(tr("Клик по ушку чёлки — выключить"))
        } label: { Label(tr("Ещё"), systemImage: "ellipsis.circle") }

        Divider()
        if let version = awake.updater.available {
            Button { awake.updater.install() } label: {
                Label(awake.updater.busy ? tr("Обновляю…") : tr("Обновить до %@", version), systemImage: "arrow.down.circle")
            }
            .disabled(awake.updater.busy)
        }
        Text(tr("awake. %@ · создано Morphine", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""))
    }
}

/// ⋯ in the bottom row: the same menu as the right click.
private struct OptionsButton: View {
    let model: NotchModel
    let awake: Awake
    @State private var hover = false
    @Environment(\.snapshot) private var snapshot

    var body: some View {
        if snapshot {
            dots
        } else {
            Menu {
                SettingsMenu(model: model, awake: awake)
            } label: { dots }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hover = $0 }
            .help(awake.updater.available != nil ? tr("Есть обновление") : tr("Ещё настройки"))
        }
    }

    /// A small green dot when a new version is waiting in the menu.
    private var dots: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(hover ? 0.75 : 0.45))
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.white.opacity(hover ? 0.12 : 0.07)))
            .overlay(alignment: .topTrailing) {
                if awake.updater.available != nil {
                    Circle().fill(Color.awakeGreen).frame(width: 6, height: 6).offset(x: -1, y: 1)
                }
            }
            .contentShape(Circle())
    }
}

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
        .help(awake.isActive ? tr("Разрешить сон") : tr("Не давать Mac уснуть"))
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
        let ids = Array(awake.watcher.uniqueByIcon(awake.watcher.active).prefix(2))
        HStack(spacing: -size * 0.3) {
            ForEach(ids, id: \.self) { id in
                if let rule = awake.watcher.rule(id) {
                    AppIconView(image: awake.watcher.icon(for: rule), title: rule.title, size: size)
                }
            }
        }
    }
}

/// Only the watched apps that are open right now, in the free space of the bottom row.
/// Green dot = this app keeps the Mac awake. Hover → popover with how it works.
private struct RunningApps: View {
    let model: NotchModel
    let awake: Awake
    static let maxIcons = 3

    var body: some View {
        let w = awake.watcher
        let all = w.enabled ? w.rules.filter { $0.mode != .off && w.running.contains($0.id) } : []
        // One badge per icon: the ChatGPT app and Codex CLI share one, the busy one speaks for both.
        let ordered = all.filter { w.active.contains($0.id) } + all.filter { !w.active.contains($0.id) }
        let firstIDs = Set(w.uniqueByIcon(ordered.map(\.id)))
        let open = all.filter { firstIDs.contains($0.id) }
        let shown = open.count > Self.maxIcons ? Array(open.prefix(Self.maxIcons - 1)) : open
        HStack(spacing: 4) {
            ForEach(shown) { rule in
                AppBadge(model: model, awake: awake, rule: rule, active: w.active.contains(rule.id))
                    .transition(.scale.combined(with: .opacity))
            }
            if let suggestion = w.suggestions.first, open.count < Self.maxIcons {
                SuggestionBadge(model: model, awake: awake, suggestion: suggestion)
                    .transition(.scale.combined(with: .opacity))
            }
            if open.count > shown.count {
                Text("+\(open.count - shown.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .help(open.dropFirst(shown.count).map(\.title).joined(separator: ", "))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: open.map(\.id))
        .animation(.easeOut(duration: 0.2), value: w.active)
    }
}

private struct AppBadge: View {
    let model: NotchModel
    let awake: Awake
    let rule: WatchRule
    let active: Bool
    @State private var show = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        AppIconView(image: awake.watcher.icon(for: rule), title: rule.title, size: 18)
            .opacity(active ? 1 : 0.55)
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
            .contentShape(Rectangle())
            .onHover { inside in
                hoverTask?.cancel()
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(inside ? 300 : 150))
                    guard !Task.isCancelled else { return }
                    show = inside
                }
            }
            .popover(isPresented: $show, arrowEdge: .bottom) {
                WatchInfo(rule: rule, active: active)
            }
            .onChange(of: show) { _, open in model.popoverOpen = open }
            .onDisappear { model.popoverOpen = false }
    }
}

/// A busy app outside the list: click → "follow it?".
private struct SuggestionBadge: View {
    let model: NotchModel
    let awake: Awake
    let suggestion: WatchSuggestion
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            AppIconView(image: awake.watcher.icon(for: suggestion), title: suggestion.title, size: 18)
                .opacity(0.8)
                .overlay(alignment: .bottomTrailing) {
                    Text("?")
                        .font(.system(size: 7.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.black)
                        .frame(width: 9, height: 9)
                        .background(Circle().fill(Color.white))
                        .overlay(Circle().stroke(Color.black, lineWidth: 1))
                        .offset(x: 2.5, y: 2.5)
                }
        }
        .buttonStyle(PressStyle())
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(tr("Следить за %@?", suggestion.title)).font(.system(size: 13, weight: .semibold))
                Text(tr("%@ %@. awake. может не давать Mac уснуть, пока программа работает, и отпускать сон через 2 минуты после окончания.", suggestion.title, suggestion.reason))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(tr("Не предлагать")) { show = false; awake.watcher.dismiss(suggestion) }
                    Spacer()
                    Button(tr("Следить")) { show = false; awake.watcher.accept(suggestion) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 280)
        }
        .onChange(of: show) { _, open in model.popoverOpen = open }
        .onDisappear { model.popoverOpen = false }
    }
}

/// How awake. treats this app.
private struct WatchInfo: View {
    let rule: WatchRule
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(rule.title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text(active ? tr("держит Mac") : tr("ждёт работы"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(active ? Color.awakeGreen : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill((active ? Color.awakeGreen : Color.secondary).opacity(0.15)))
            }
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(tr("Режим меняется в меню ⋯ → Программы."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 280)
    }

    private var description: String {
        switch rule.mode {
        case .render:
            return tr("Пока %@ рендерит или экспортирует — заметно нагружает процессор или записывает файлы — awake. не даёт Mac уснуть. Когда работа закончится, awake. подождёт 2 минуты и вернёт обычный сон. Если выключить ⏻ вручную, awake. включится снова только при следующем рендере.", rule.title)
        case .download:
            return tr("Пока %@ качает файлы, Mac не уснёт. После окончания загрузки awake. подождёт 2 минуты и вернёт обычный сон.", rule.title)
        case .agent:
            return tr("Пока %@ выполняет задачу — думает, пишет код или управляет Маком — Mac не уснёт. Когда агент затихнет на 3 минуты, awake. вернёт обычный сон.", rule.title)
        case .open:
            return tr("Пока %@ открыт, Mac не уснёт. Закроешь программу — сон вернётся.", rule.title)
        case .off:
            return tr("awake. не следит за этой программой.")
        }
    }
}
