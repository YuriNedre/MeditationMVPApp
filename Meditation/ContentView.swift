import SwiftUI
import Combine
import AVFoundation
import UserNotifications

// MARK: - Локализация языка приложения
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ru, uk, fr, es_US, pt_PT
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return String(localized: "settings.language.system")
        case .en: return "English"
        case .ru: return "Русский"
        case .uk: return "Українська"
        case .fr: return "Français"
        case .es_US: return "Español (US)"
        case .pt_PT: return "Português (PT)"
        }
    }
    var localeId: String? {
        switch self {
        case .system: return nil
        case .en: return "en"
        case .ru: return "ru"
        case .uk: return "uk"
        case .fr: return "fr"
        case .es_US: return "es-US"
        case .pt_PT: return "pt-PT"
        }
    }
}

// MARK: - Модели
enum SessionState: Equatable { case idle, running, paused, finished }

enum Phase: CaseIterable {
    case inhale, hold1, exhale, hold2
    var labelKey: String {
        switch self {
        case .inhale: return "inhale.label"
        case .hold1:  return "hold1.label"
        case .exhale: return "exhale.label"
        case .hold2:  return "hold2.label"
        }
    }
}

struct BreathPattern: Equatable {
    var inhale: Double = 4
    var hold1:  Double = 4
    var exhale: Double = 4
    var hold2:  Double = 2
    var total:  Double { inhale + hold1 + exhale + hold2 }
}

// MARK: - Таймер сессии
final class SessionTimer: ObservableObject {
    @Published var state: SessionState = .idle
    @Published var phase: Phase = .inhale
    @Published var elapsedInPhase: Double = 0
    @Published var progress: Double = 0
    @Published var remainingSeconds: Int = 0

    private var totalSeconds: Int
    private var targetEndDate: Date?
    private var timer: Timer?
    private var phaseDurations: [Phase: Double]
    private let order: [Phase] = Phase.allCases
    private var idx = 0

    init(lengthMinutes: Int, pattern: BreathPattern) {
        totalSeconds = max(1, lengthMinutes * 60)
        phaseDurations = [.inhale: pattern.inhale,
                          .hold1:  pattern.hold1,
                          .exhale: pattern.exhale,
                          .hold2:  pattern.hold2]
        remainingSeconds = totalSeconds
    }

    func apply(lengthMinutes: Int, pattern: BreathPattern) {
        pause()
        totalSeconds = max(1, lengthMinutes * 60)
        remainingSeconds = totalSeconds
        phaseDurations[.inhale] = pattern.inhale
        phaseDurations[.hold1]  = pattern.hold1
        phaseDurations[.exhale] = pattern.exhale
        phaseDurations[.hold2]  = pattern.hold2
        idx = 0
        phase = .inhale
        elapsedInPhase = 0
        progress = 0
        state = .idle
        targetEndDate = nil
    }

    func start() {
        guard state == .idle || state == .paused else { return }
        state = .running
        targetEndDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))
        scheduleTick()
    }

    func pause() {
        guard state == .running else { return }
        state = .paused
        timer?.invalidate(); timer = nil
    }

    func reset() {
        timer?.invalidate(); timer = nil
        state = .idle
        phase = .inhale
        elapsedInPhase = 0
        progress = 0
        remainingSeconds = totalSeconds
        idx = 0
        targetEndDate = nil
    }

    private func scheduleTick() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = timer { RunLoop.current.add(t, forMode: .common) }
    }

    private func tick() {
        guard state == .running else { return }
        remainingSeconds = max(0, Int(targetEndDate?.timeIntervalSinceNow ?? 0))
        if remainingSeconds == 0 { finish() }
        advancePhase()
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        state = .finished
        let content = UNMutableNotificationContent()
        content.title = String(localized: "session.complete.title")
        content.body  = String(localized: "session.complete.body")
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func advancePhase() {
        let cur = phaseDurations[phase] ?? 1
        elapsedInPhase += 0.016
        if elapsedInPhase >= cur {
            elapsedInPhase = 0
            idx = (idx + 1) % order.count
            phase = order[idx]
        }
        progress = min(1, elapsedInPhase / (phaseDurations[phase] ?? 1))
    }
}

// MARK: - Аудио-фон
final class AmbientAudio: ObservableObject {
    @Published var isOn: Bool = false { didSet { isOn ? play() : pause() } }
    @Published private(set) var currentIndex: Int = 0

    private var player: AVAudioPlayer?
    var tracks: [String] = [
        "meditation-music-338902",
        "meditation-music-409195",
        "meditation-yoga-409201",
        "rain-forest-cinematic-223986",
        "ambient-forest-rain-375365",
        "autumn-forest-248158"
    ]

    func loadCurrentTrack() {
        guard !tracks.isEmpty else { return }
        loadNamed(tracks[currentIndex])
    }

    func nextTrack() {
        guard !tracks.isEmpty else { return }
        currentIndex = (currentIndex + 1) % tracks.count
        loadNamed(tracks[currentIndex])
        if isOn { player?.play() }
    }

    func stop() { player?.stop(); player = nil; isOn = false }
    func pause() { player?.pause() }
    func resume() { player?.play() }

    private func play() {
        if player == nil { loadCurrentTrack() }
        player?.play()
    }

    private func loadNamed(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else { return }
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print("AVAudioSession error: \(error)") }
        #endif
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
        } catch { print("AVAudioPlayer error: \(error)") }
    }
}

// MARK: - Круг дыхания
struct BreathingCircle: View {
    let phase: Phase
    let progress: Double
    let isRunning: Bool
    let onTap: () -> Void

    private var fillColor: Color {
        switch phase {
        case .inhale: return Color.green.opacity(0.25)
        case .exhale: return Color.blue.opacity(0.22)
        case .hold1:  return Color.yellow.opacity(0.28)
        case .hold2:  return Color.gray.opacity(0.22)
        }
    }
    private var scale: CGFloat {
        switch phase {
        case .inhale: return CGFloat(1.0 + progress * 0.5) // 1.0→1.5
        case .hold1:  return 1.5
        case .exhale: return CGFloat(1.5 - progress * 0.5) // 1.5→1.0
        case .hold2:  return 1.0
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(fillColor)
                .overlay(Circle().stroke(.gray.opacity(0.6), lineWidth: 8))
                .scaleEffect(scale)
                .animation(.easeInOut(duration: 0.8), value: phase)
                .animation(.easeInOut(duration: 0.16), value: progress)

            Text(isRunning ? LocalizedStringKey(phase.labelKey) : LocalizedStringKey("start.label"))
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .contentShape(Circle())
        .onTapGesture { onTap() }
    }
}

// MARK: - Главный экран (один файл)
struct ContentView: View {
    @AppStorage("appLanguage") private var appLanguageRaw: String = AppLanguage.system.rawValue
    private var appLanguage: AppLanguage {
        get { AppLanguage(rawValue: appLanguageRaw) ?? .system }
        set { appLanguageRaw = newValue.rawValue }
    }

    @State private var minutes: Int = 5
    @State private var pattern = BreathPattern()
    @StateObject private var timerVM = SessionTimer(lengthMinutes: 5, pattern: BreathPattern())
    @StateObject private var audio = AmbientAudio()
    @State private var showSettings = false

    private var localeBinding: Locale {
        if let id = appLanguage.localeId { return Locale(identifier: id) }
        return Locale(identifier: Locale.preferredLanguages.first ?? "en")
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                // 1) вычисляем доступные размеры и безопасную «коробку» для круга
                let fullW = geo.size.width
                let fullH = geo.size.height
                let horizontalPadding: CGFloat = 20

                // 🔧 ТЕ САМЫЕ «прошлые параметры», которыми удобно крутить отступы
                let topInset = max(geo.safeAreaInsets.top, 8)
                let bottomInset = max(geo.safeAreaInsets.bottom, 24)
                let headerApprox: CGFloat = 44          // примерная высота навбара/заголовка
                let spaceUnderHeader: CGFloat = 0       // ОТСТУП ПОД ЗАГОЛОВКОМ (увеличь/уменьшай)
                let spaceToTimer: CGFloat = 44          // расстояние от круга до таймера
                let timerHeight: CGFloat = 52
                let buttonsBlock: CGFloat = 14 + 44     // отступ + высота кнопок
                let toggleBlock: CGFloat = 8 + 44       // отступ + высота тумблера

                // Сколько вертикали остаётся под контейнер для круга с учётом max scale 1.5x
                let availableH = fullH
                               - topInset
                               - headerApprox
                               - spaceUnderHeader
                               - spaceToTimer
                               - timerHeight
                               - buttonsBlock
                               - toggleBlock
                               - bottomInset

                // Контейнер под круг (на него влезет круг, который потом расширяется до 1.5x)
                let containerSide = min(fullW - horizontalPadding * 2,
                                        max(260, min(availableH, 380)))   // мягкие рамки
                let baseDiameter = containerSide / 1.5                    // базовый диаметр


                VStack(spacing: 24) {
                    // Верхний зазор под заголовком
                    Spacer().frame(height: 8) // 🔧 уменьшай до 0, если круг всё ещё низко

                    // Контейнер, который резервирует место под круг при масштабировании
                    ZStack {
                        BreathingCircle(
                            phase: timerVM.phase,
                            progress: timerVM.progress,
                            isRunning: timerVM.state != .idle,
                            onTap: circleTapped
                        )
                        .frame(width: baseDiameter, height: baseDiameter)
                        .animation(.easeInOut(duration: 0.8), value: timerVM.phase)
                        .animation(.easeInOut(duration: 0.16), value: timerVM.progress)
                    }
                    // Высота контейнера — чтобы при 1.5x круг не вылезал
                    .frame(height: baseDiameter * 1.5)

                    // без отрицательного паддинга — позицию теперь задаёт spaceUnderHeader

                    // Таймер
                    Text(formatTime(timerVM.remainingSeconds))
                        .font(.system(size: 52, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .padding(.top, 4)

                    // Кнопки
                    HStack(spacing: 16) {
                        Button {
                            timerVM.reset()
                            audio.stop()
                        } label: {
                            Label(String(localized: "reset.button"), systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            audio.nextTrack()
                        } label: {
                            Label(String(localized: "nextTrack.button"), systemImage: "forward.end")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!audio.isOn)
                    }
                    .padding(.top, 8)

                    // 3) Локализованный переключатель фоновой музыки
                    Toggle("ambient.title", isOn: $audio.isOn)
                        .padding(.top, 8)
                        .onChange(of: audio.isOn) { _, new in
                            if new {
                                audio.loadCurrentTrack()
                                audio.resume()
                            } else {
                                audio.pause()
                            }
                        }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, horizontalPadding)
            }
            // 2) Локализованный заголовок с «листиком»
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "leaf.fill")
                            .font(.system(size: 22, weight: .bold))  // 🔼 размер иконки
                            .foregroundColor(.green)
                        Text("app.title")
                            .font(.system(size: 24, weight: .bold, design: .rounded)) // 🔼 размер шрифта
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title3)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    minutes: $minutes,
                    pattern: $pattern,
                    appLanguage: Binding(
                        get: { appLanguage },
                        set: { newVal in appLanguageRaw = newVal.rawValue }
                    )
                ) {
                    timerVM.apply(lengthMinutes: minutes, pattern: pattern)
                }
                .environment(\.locale, localeBinding)
            }
        }
        .environment(\.locale, localeBinding)
        .onAppear {
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    // MARK: - Actions
    private func circleTapped() {
        switch timerVM.state {
        case .idle:
            timerVM.start()
            if audio.isOn { audio.resume() }
        case .running:
            timerVM.pause()
            if audio.isOn { audio.pause() }
        case .paused:
            timerVM.start()
            if audio.isOn { audio.resume() }
        case .finished:
            timerVM.reset()
            timerVM.start()
            if audio.isOn { audio.resume() }
        }
        #if os(iOS)
        let gen = UINotificationFeedbackGenerator()
        gen.notificationOccurred(.success)
        #endif
    }

    private func formatTime(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Настройки
struct SettingsView: View {
    @Binding var minutes: Int
    @Binding var pattern: BreathPattern
    @Binding var appLanguage: AppLanguage
    var onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("settings.language.section")) {
                    Picker("settings.language.picker", selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.title).tag(lang)
                        }
                    }
                }
                Section(header: Text("settings.session.section")) {
                    Stepper(value: $minutes, in: 1...60) {
                        HStack {
                            Text("settings.session.length")
                            Spacer()
                            HStack(spacing: 4) {
                                Text("\(minutes)")
                                Text("min.suffix")
                            }
                        }
                    }
                }
                Section(header: Text("settings.pattern.section")) {
                    Stepper { row("inhale.label", value: Int(pattern.inhale)) } onIncrement: {
                        pattern.inhale = min(15, pattern.inhale + 1)
                    } onDecrement: {
                        pattern.inhale = max(1, pattern.inhale - 1)
                    }
                    Stepper { row("hold1.label", value: Int(pattern.hold1)) } onIncrement: {
                        pattern.hold1 = min(15, pattern.hold1 + 1)
                    } onDecrement: {
                        pattern.hold1 = max(0, pattern.hold1 - 1)
                    }
                    Stepper { row("exhale.label", value: Int(pattern.exhale)) } onIncrement: {
                        pattern.exhale = min(20, pattern.exhale + 1)
                    } onDecrement: {
                        pattern.exhale = max(1, pattern.exhale - 1)
                    }
                    Stepper { row("hold2.label", value: Int(pattern.hold2)) } onIncrement: {
                        pattern.hold2 = min(15, pattern.hold2 + 1)
                    } onDecrement: {
                        pattern.hold2 = max(0, pattern.hold2 - 1)
                    }
                }
                Section(footer: Text("settings.tip")) { EmptyView() }
            }
            .navigationTitle(Text("settings.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("close.button") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("apply.button") {
                        onApply()
                        dismiss()
                    }
                }
            }
        }
    }

    private func row(_ key: LocalizedStringKey, value: Int) -> some View {
        HStack {
            Text(key)
            Spacer()
            Text("\(value)")
        }
    }
}
