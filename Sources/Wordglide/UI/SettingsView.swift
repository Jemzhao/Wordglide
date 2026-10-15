// Portions derived from HoverTranslate, Copyright (c) 2026 Kianzzz (MIT).
// See ThirdParty/HoverTranslate-LICENSE.
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showsPermissionHelp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("设置").font(.system(size: 20, weight: .semibold))
                    Text("调整取词方式，让翻译跟上你的阅读节奏。")
                        .font(.system(size: 12)).foregroundStyle(AppTheme.secondary)
                }

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        sectionTitle("运行准备")
                        Spacer()
                        Button("重新检测") { model.recheckPermissions() }
                            .buttonStyle(.plain).foregroundStyle(AppTheme.accent)
                            .font(.system(size: 12))
                    }.padding(.horizontal, 2)

                    VStack(alignment: .leading, spacing: 0) {
                        permissionRow(
                            "accessibility", title: "辅助功能",
                            detail: "读取鼠标附近与选中的文字。",
                            status: model.accessibility ? "已授权" : "待授权",
                            ready: model.accessibility,
                            actionTitle: model.accessibility ? "查看授权" : "前往授权"
                        ) { model.requestAccessibility() }

                        rowDivider

                        permissionRow(
                            "viewfinder", title: "屏幕录制",
                            detail: "为图片和无法直接取词的内容提供 OCR 识别。",
                            status: model.screenPermission ? "已授权" : "可选授权",
                            ready: model.screenPermission,
                            actionTitle: model.screenPermission ? "查看授权" : "前往授权"
                        ) { model.requestScreen() }

                        rowDivider

                        permissionRow(
                            "character.bubble", title: "中英文语言包",
                            detail: model.languageStatus,
                            status: model.preparing ? "准备中" : (model.languageReady ? "已就绪" : "待准备"),
                            ready: model.languageReady,
                            actionTitle: model.preparing ? "准备中…" : "准备语言包",
                            isLoading: model.preparing,
                            showsAction: !model.languageReady
                        ) { model.prepareLanguage() }

                        if !model.preparationMessage.isEmpty {
                            Text(model.preparationMessage)
                                .font(.system(size: 12)).foregroundStyle(AppTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 38).padding(.bottom, 14)
                        }

                        rowDivider

                        permissionHelp
                    }
                    .padding(.horizontal, 16)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: AppTheme.cornerRadius).stroke(AppTheme.line, lineWidth: 0.5))

                    if !model.accessibility {
                        Label("完成辅助功能授权后，即可在其他应用中取词。", systemImage: "info.circle")
                            .font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 2)
                    }
                }

                settingsSection("快捷替换") {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("直接替换快捷键").font(.system(size: 13))
                            Text("在输入框中按下，即可翻译并替换。")
                                .font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                        }
                        Spacer(minLength: 8)
                        Picker("直接替换快捷键", selection: $model.directShortcut) {
                            ForEach(DirectReplacementShortcut.allCases) { shortcut in
                                Text(shortcut.displayName).tag(shortcut)
                            }
                        }
                        .labelsHidden().frame(width: 230).controlSize(.small)
                    }.padding(.vertical, 14)

                    rowDivider

                    HStack(spacing: 16) {
                        Text("目标语言").font(.system(size: 13))
                        Spacer(minLength: 8)
                        Picker("快捷替换目标语言", selection: $model.directTargetLanguage) {
                            Text("自动中英互译").tag("auto")
                            Text("英语").tag("en")
                            Text("简体中文").tag("zh-Hans")
                        }
                        .labelsHidden().frame(width: 230).controlSize(.small)
                    }.padding(.vertical, 14)

                    rowDivider

                    VStack(alignment: .leading, spacing: 7) {
                        Text("有选区时替换选区，没有选区时替换整个输入框。仅处理已确认可编辑的输入框，最多 8,000 个字符。")
                        Text("先完成输入法选词再按快捷键。翻译期间继续输入或切换输入框，会取消本次替换。")
                        if !model.directShortcutIssue.isEmpty {
                            Label(model.directShortcutIssue, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Color.orange)
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 13)
                }

                settingsSection("触发与识别") {
                    settingToggle("悬停翻译", detail: "停留后出现“译”图标，移入图标展开译文。", value: $model.hoverEnabled)
                    rowDivider
                    settingToggle("选区翻译", detail: "选中文字后自动中英互译；可编辑选区点击“替换”即可提交。", value: $model.selectionEnabled)
                    rowDivider
                    settingToggle("OCR 补充识别", detail: "需要辅助功能与屏幕录制权限，仅识别鼠标附近的文字。", value: $model.ocrEnabled)
                    rowDivider
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("悬停识别范围").font(.system(size: 13))
                            Text("OCR 当前支持鼠标所在行。")
                                .font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                        }
                        Spacer(minLength: 8)
                        Picker("悬停识别范围", selection: $model.wordMode) {
                            Text("句子 / 短语").tag(false)
                            Text("单词").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .frame(width: 210).controlSize(.small)
                    }.padding(.vertical, 14)
                }

                settingsSection("悬停时间") {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("图标出现等待").font(.system(size: 13))
                            Spacer()
                            timeValue("\(Int((model.delay * 1000).rounded())) ms")
                        }
                        Slider(value: $model.delay, in: 0.3...1.5, step: 0.1)
                            .accessibilityLabel("图标出现等待时间")
                        HStack {
                            Text("更灵敏")
                            Spacer()
                            Text("更从容")
                        }.font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                    }.padding(.vertical, 14)

                    rowDivider

                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 10) {
                            Text("移开后关闭").font(.system(size: 13))
                            Spacer()
                            timeValue(model.closeDelay == 0 ? "立即关闭" : "\(Int((model.closeDelay * 1000).rounded())) ms")
                            Button("立即关闭") { model.closeDelay = 0 }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(model.closeDelay == 0)
                        }
                        Slider(value: $model.closeDelay, in: 0...1, step: 0.05)
                            .accessibilityLabel("移开后关闭等待时间")
                        Text("仅影响悬停译文。选区浮窗保留至点击外部或关闭，固定浮窗保持显示。")
                            .font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 14)
                }

                UpdateSettingsView(updater: model.updates)

                VStack(alignment: .leading, spacing: 7) {
                    Label("在本机处理", systemImage: "lock.shield")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.ink)
                    Text("不自动读取剪贴板，不记录翻译历史，不上传截图或文字。")
                    Text("关闭窗口后仍可从菜单栏使用；按 ⌘Q 退出 Wordglide。")
                }
                .font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
            }
            .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .foregroundStyle(AppTheme.ink)
        .tint(AppTheme.accent)
        .onAppear { model.refreshPermissions() }
    }

    private var permissionHelp: some View {
        DisclosureGroup(isExpanded: $showsPermissionHelp) {
            VStack(alignment: .leading, spacing: 10) {
                Text("开关已开启却仍未就绪？旧版本的授权可能未对当前版本生效。请移除旧条目，重新添加当前 Wordglide，再点击“重新检测”。")
                Text("在系统权限页点“添加 / +”后，按 ⇧⌘G 并粘贴下方路径，按回车后点“打开”，再开启 Wordglide。系统要求时请退出并重新打开应用。")
                Text(model.applicationPath)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.subtle, in: RoundedRectangle(cornerRadius: 7))
                HStack(spacing: 8) {
                    Button("复制应用路径") { model.copyApplicationPath() }
                    Button("在访达中显示") { model.revealApplication() }
                }.buttonStyle(.bordered).controlSize(.small)
                Text("授权时请使用此处的当前应用路径。同一签名身份下的更新通常可沿用授权；更换签名证书或移动应用后，可能需要重新授权。")
            }
            .font(.system(size: 12)).foregroundStyle(AppTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 9).padding(.bottom, 3)
        } label: {
            Text("授权帮助与应用路径").font(.system(size: 12))
        }
        .padding(.vertical, 13)
    }

    private var rowDivider: some View {
        Rectangle().fill(AppTheme.line).frame(height: 0.5)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.secondary)
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle(title).padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.cornerRadius).stroke(AppTheme.line, lineWidth: 0.5))
        }
    }

    private func permissionRow(
        _ symbol: String, title: String, detail: String, status: String, ready: Bool,
        actionTitle: String, isLoading: Bool = false, showsAction: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17))
                .foregroundStyle(AppTheme.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    HStack(spacing: 4) {
                        if isLoading {
                            ProgressView().controlSize(.mini)
                        } else if ready {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                        }
                        Text(status).font(.system(size: 11))
                    }.foregroundStyle(ready ? AppTheme.accent : AppTheme.secondary)
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if showsAction {
                Button(actionTitle, action: action).buttonStyle(.bordered).controlSize(.small)
                    .disabled(isLoading).fixedSize()
            }
        }.padding(.vertical, 14)
    }

    private func settingToggle(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.padding(.vertical, 14)
    }

    private func timeValue(_ value: String) -> some View {
        Text(value).font(.system(size: 12, design: .monospaced))
            .monospacedDigit().foregroundStyle(AppTheme.secondary)
    }
}
