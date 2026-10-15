// Portions derived from HoverTranslate, Copyright (c) 2026 Kianzzz (MIT).
// See ThirdParty/HoverTranslate-LICENSE.
import SwiftUI
import AppKit
import Translation

struct MainView: View {
    @ObservedObject var model: AppModel

    private static let brandIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    private var selectedPage: Binding<String> {
        Binding(
            get: { model.page == "settings" ? "settings" : "try" },
            set: { model.page = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            navigation
            Divider().overlay(AppTheme.line)
            Group {
                if model.page == "settings" {
                    SettingsView(model: model)
                } else {
                    TryView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(AppTheme.line)
            statusBar
        }
        .frame(minWidth: 660, minHeight: 520)
        .foregroundStyle(AppTheme.ink)
        .background(AppTheme.window)
        .tint(AppTheme.accent)
        .translationTask(model.preparationConfig) { session in
            do {
                try await session.prepareTranslation()
                await model.languagePreparationFinished()
            } catch {
                await model.languagePreparationFinished(error: error)
            }
        }
    }

    private var navigation: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                Group {
                    if let icon = Self.brandIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    } else {
                        Image(systemName: "character.bubble")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(AppTheme.accent)
                    }
                }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
                Text("Wordglide")
                    .font(.system(size: 15, weight: .semibold))
            }
            Spacer(minLength: 10)
            Picker("页面", selection: selectedPage) {
                Text("翻译").tag("try")
                Text("设置").tag("settings")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 144)
            Spacer(minLength: 10)
            HStack(spacing: 8) {
                Text("全局翻译")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.secondary)
                Toggle("全局翻译", isOn: Binding(
                    get: { model.enabled },
                    set: { if $0 != model.enabled { model.toggleEnabled() } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(model.enabled ? "暂停悬停与选区翻译" : "开启悬停与选区翻译")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 16)
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.enabled ? AppTheme.accent : AppTheme.secondary.opacity(0.65))
                .frame(width: 5, height: 5)
            Text(model.status)
                .font(.system(size: 11))
                .lineLimit(1)
                .help(model.status)
            Spacer(minLength: 14)
            Text("\(model.directShortcut.symbols) 替换  ·  ⌃⌥T 翻译")
                .font(.system(size: 11))
                .fixedSize()
        }
        .foregroundStyle(AppTheme.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }
}

// Both existing routes lead to the same compact translation workspace.
struct HomeView: View {
    @ObservedObject var model: AppModel
    var body: some View { TryView(model: model) }
}

struct TryView: View {
    @ObservedObject var model: AppModel
    @State private var showsHoverSample = false

    private var inputIsEmpty: Bool { TextLogic.clean(model.manualText).isEmpty }
    private var inputIsTooLong: Bool { model.manualText.count > TextLogic.maximumInputLength }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("文本翻译")
                        .font(.system(size: 17, weight: .semibold))
                    Text("输入或粘贴中英文，在浮窗中查看译文。")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.secondary)
                }
                if let recovery = model.replacementRecovery {
                    ReplacementRecoveryCard(model: model, recovery: recovery)
                        .id(recovery.id)
                }
                inputCard
                hoverSample
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("原文")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(model.manualText.count.formatted()) / 8,000")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(inputIsTooLong ? Color.red : AppTheme.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            ZStack(alignment: .topLeading) {
                if model.manualText.isEmpty {
                    Text("输入或粘贴要翻译的内容…")
                        .font(.system(size: 16))
                        .foregroundStyle(AppTheme.secondary.opacity(0.75))
                        .padding(.horizontal, 5)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.manualText)
                    .font(.system(size: 16))
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("要翻译的原文")
            }
            .frame(height: 154)
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 12)

            Divider().overlay(AppTheme.line)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: model.languageReady ? "checkmark.circle" : "arrow.down.circle")
                        .foregroundStyle(model.languageReady ? AppTheme.accent : AppTheme.secondary)
                    Text("Apple 本机翻译 · \(model.languageStatus)")
                        .foregroundStyle(AppTheme.secondary)
                    Spacer(minLength: 8)
                    if !model.languageReady {
                        Button("前往设置") { model.settings() }
                            .buttonStyle(.borderless)
                            .foregroundStyle(AppTheme.accent)
                    }
                }
                .font(.system(size: 11))

                HStack(spacing: 10) {
                    Button { model.clipboard() } label: {
                        Label("翻译剪贴板", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    Spacer(minLength: 12)
                    Button { model.manualTranslate() } label: {
                        Label("打开翻译浮窗", systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(inputIsEmpty || inputIsTooLong)
                    .help("翻译输入的文字（⌘↩）")
                }
                .controlSize(.regular)
                .font(.system(size: 12))

                if inputIsTooLong {
                    Text("单次最多翻译 8,000 个字符，请缩短原文。")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                .stroke(AppTheme.line, lineWidth: 1)
        }
    }

    private var hoverSample: some View {
        DisclosureGroup(isExpanded: $showsHoverSample) {
            VStack(alignment: .leading, spacing: 10) {
                Text("鼠标停在英文上，移入出现的“译”图标查看译文。")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.secondary)
                DemoSentence(model: model, english: "Good design makes complex things feel simple.")
                DemoSentence(model: model, english: "Stay curious. There is always more to discover.")
                Text("此处使用真实本机翻译，无需全局取词权限。其他应用中可选中文字，或按 ⌃⌥T 翻译。")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 10)
            .padding(.bottom, 2)
        } label: {
            HStack(spacing: 8) {
                Label("试试悬停翻译", systemImage: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if !showsHoverSample {
                    Text("无需全局取词权限")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.secondary)
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }
}

/// Keeps only the most recent unfinished operation visible without changing the
/// text currently being edited in the main translation workspace.
struct ReplacementRecoveryCard: View {
    @ObservedObject var model: AppModel
    let recovery: ReplacementRecovery
    @State private var showsSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: recovery.hasTranslation ? "doc.text" : "exclamationmark.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(recovery.hasTranslation ? "本次译文已保留" : "翻译未完成")
                        .font(.system(size: 13, weight: .semibold))
                    Text(recovery.message)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button { model.dismissReplacementRecovery() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭本次恢复内容")
                .accessibilityLabel("关闭本次恢复内容")
            }

            if let translation = recovery.translation, recovery.hasTranslation {
                ScrollView {
                    Text(translation)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("保留的译文")
            }

            DisclosureGroup(isExpanded: $showsSource) {
                ScrollView {
                    Text(recovery.source)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.secondary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 100)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .accessibilityLabel("本次原文")
            } label: {
                Text("本次原文")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.secondary)
            }

            HStack(spacing: 10) {
                if recovery.hasTranslation {
                    Button { model.showRecoveredTranslation() } label: {
                        Label("在浮窗查看", systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.bordered)
                    Spacer(minLength: 8)
                    Button { model.copyRecoveredTranslation() } label: {
                        Label("复制译文", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("重新翻译后在浮窗中查看。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.secondary)
                    Spacer(minLength: 8)
                    Button { model.retryRecoveredTranslation() } label: {
                        Label("重新翻译", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.regular)
            .font(.system(size: 12))
        }
        .padding(16)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                .stroke(AppTheme.accent.opacity(0.28), lineWidth: 1)
        }
    }
}

@MainActor
final class DemoInteraction: ObservableObject {
    @Published var hovering = false
    var task: Task<Void, Never>?
}

struct DemoSentence: View {
    @ObservedObject var model: AppModel
    let english: String
    @StateObject private var interaction = DemoInteraction()

    var body: some View {
        Text(english)
            .font(.system(size: 14))
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(interaction.hovering ? AppTheme.accent.opacity(0.08) : AppTheme.subtle)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .background(HoverSampleSensor { inside, rect in
                interaction.hovering = inside
                interaction.task?.cancel()
                if inside {
                    interaction.task = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(model.delay * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        model.preview(english, bounds: rect)
                    }
                }
            })
            .onDisappear {
                interaction.task?.cancel()
                interaction.hovering = false
            }
    }
}

struct HoverSampleSensor: NSViewRepresentable {
    let changed: (Bool, CGRect) -> Void

    func makeNSView(context: Context) -> SensorView {
        let view = SensorView()
        view.changed = changed
        return view
    }

    func updateNSView(_ nsView: SensorView, context: Context) { nsView.changed = changed }

    final class SensorView: NSView {
        var changed: ((Bool, CGRect) -> Void)?
        private var tracking: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { report(true) }
        override func mouseExited(with event: NSEvent) { report(false) }

        private func report(_ inside: Bool) {
            guard let window, window.isVisible else { return }
            changed?(inside, window.convertToScreen(convert(bounds, to: nil)))
        }
    }
}
