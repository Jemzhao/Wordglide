// Portions derived from HoverTranslate, Copyright (c) 2026 Kianzzz (MIT).
// See ThirdParty/HoverTranslate-LICENSE.
import SwiftUI

struct HoverBadgeView: View {
    var body: some View {
        Text("译")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(AppTheme.ink)
            .frame(width: 28, height: 28)
            .background(Circle().fill(AppTheme.surface))
            .overlay(Circle().stroke(AppTheme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .accessibilityLabel("悬停翻译，鼠标移入展开译文")
    }
}

struct TranslationCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            reading
            footer
            if !model.replacementMessage.isEmpty { replacementMessage }
        }
        .frame(width: model.cardWidth, height: model.cardHeight, alignment: .top)
        .background(AppTheme.surface)
        .foregroundStyle(AppTheme.ink)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onExitCommand { model.dismiss(force: true) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Text(sourceLanguage)
                    .foregroundStyle(AppTheme.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppTheme.secondary)
                Menu {
                    languageOption("原文", language: "original")
                    languageOption("简体中文", language: "zh-Hans")
                    languageOption("英语", language: "en")
                } label: {
                    HStack(spacing: 5) {
                        Text(targetLabel)
                            .fontWeight(.medium)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(AppTheme.secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.isReplacing)
                .accessibilityLabel("目标语言")
                .accessibilityValue(targetLabel)
            }
            .font(.system(size: 12))
            Spacer(minLength: 4)
            CardIconButton(symbol: model.pinned ? "pin.fill" : "pin",
                           label: model.pinned ? "取消固定" : "固定浮窗",
                           active: model.pinned) { model.pinned.toggle() }
            CardIconButton(symbol: "xmark", label: "关闭浮窗") { model.dismiss(force: true) }
        }
        .padding(.horizontal, 14)
        .frame(height: CardLayout.headerHeight)
        .overlay(alignment: .bottom) { separator }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: CardLayout.sourceGap) {
            if model.showsCardSource {
                ScrollView {
                    Text(model.source)
                        .font(.system(size: CardLayout.sourceFontSize))
                        .lineSpacing(4)
                        .foregroundStyle(AppTheme.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .scrollIndicators(.automatic)
                .frame(height: model.sourceBodyHeight, alignment: .top)
                .accessibilityLabel("原文")
            }
            translationContent
                .frame(height: model.cardBodyHeight, alignment: .topLeading)
        }
        .padding(.horizontal, CardLayout.horizontalPadding)
        .padding(.vertical, CardLayout.bodyVerticalPadding)
    }

    @ViewBuilder
    private var translationContent: some View {
        if model.phase == .choose {
            Text("选择上方语言，查看译文")
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else if model.phase == .loading {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("正在本机翻译…")
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.secondary)
                Spacer(minLength: 6)
                Button("取消") { model.cancelTranslation() }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.accent)
                    .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.result)
                        .font(.system(size: CardLayout.translationFontSize))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.phase == .failure {
                        HStack(spacing: 16) {
                            if model.canRetryTranslation {
                                Button("重试翻译") { model.retryTranslation() }
                            }
                            Button("打开设置") {
                                model.dismiss(force: true)
                                model.settings()
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.accent)
                        .padding(.vertical, 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .accessibilityLabel(model.phase == .failure ? "翻译未完成" : (model.target == "original" ? "原文" : "译文"))
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if model.target != "original" {
                CardActionButton(title: model.showsCardSource ? "收起原文" : "显示原文",
                                 symbol: "text.alignleft") { model.toggleSourceExpanded() }
                    .disabled(model.source.isEmpty)
                    .accessibilityValue(model.showsCardSource ? "已展开" : "已收起")
            } else {
                Text("原文")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.secondary)
                    .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            CardActionButton(title: model.copied ? "已复制" : (model.target == "original" ? "复制原文" : "复制译文"),
                             symbol: model.copied ? "checkmark" : "doc.on.doc", active: model.copied) {
                model.copyResult()
            }
            .disabled(model.phase != .result)
            if model.hasReplacementTarget {
                CardActionButton(title: model.isReplacing ? "正在替换…" : "替换",
                                 prominent: true, loading: model.isReplacing) { model.replaceSelection() }
                    .disabled(!model.canReplaceSelection)
                    .help("用译文替换选区，可在原应用按 ⌘Z 撤销。")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: CardLayout.footerHeight)
        .overlay(alignment: .top) { separator }
    }

    private var replacementMessage: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12))
                .padding(.top, 2)
            ScrollView {
                Text(model.replacementMessage)
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(.automatic)
        }
        .foregroundStyle(AppTheme.secondary)
        .padding(.horizontal, CardLayout.horizontalPadding)
        .padding(.vertical, 10)
        .frame(height: CardLayout.replacementMessageHeight)
        .background(AppTheme.subtle)
        .overlay(alignment: .top) { separator }
    }

    private var sourceLanguage: String {
        TextLogic.language(of: model.source) == "zh-Hans" ? "简体中文" : "英语"
    }

    private var targetLabel: String {
        if model.phase == .choose { return "选择语言" }
        switch model.target {
        case "original": return "原文"
        case "en": return "英语"
        default: return "简体中文"
        }
    }

    private func languageOption(_ title: String, language: String) -> some View {
        Button { model.translate(to: language) } label: {
            if model.phase != .choose && model.target == language {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(AppTheme.line).frame(height: 1).allowsHitTesting(false)
    }
}

private struct CardIconButton: View {
    let symbol: String
    let label: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(active ? AppTheme.accent : (hovering ? AppTheme.ink : AppTheme.secondary))
                .frame(width: 28, height: 28)
                .background(active || hovering ? AppTheme.subtle : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct CardActionButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    var active = false
    var loading = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if loading {
                    ProgressView().controlSize(.mini)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 12))
                }
                Text(title).font(.system(size: 12, weight: prominent ? .medium : .regular))
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .foregroundStyle(prominent || active ? AppTheme.accent : (hovering ? AppTheme.ink : AppTheme.secondary))
            .background(prominent ? AppTheme.accent.opacity(0.12) : (hovering ? AppTheme.subtle : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .opacity(enabled || loading ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}
