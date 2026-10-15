import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("软件更新")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.secondary)
                .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Wordglide \(updater.currentVersion)").font(.system(size: 13, weight: .medium))
                        Text(updater.status).font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let date = updater.lastCheckDate {
                            Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("检查更新…") { updater.checkForUpdates() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(!updater.canCheckForUpdates)
                }.padding(.vertical, 14)

                Rectangle().fill(AppTheme.line).frame(height: 0.5)

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("自动检查更新").font(.system(size: 13))
                        Text("发现新版时提醒，由你确认下载与安装。")
                            .font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("自动检查更新", isOn: $updater.automaticChecksEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(!updater.isStarted)
                }.padding(.vertical, 14)

                Text("检查更新会连接发布服务器；不包含翻译原文、译文或截图。")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.cornerRadius).stroke(AppTheme.line, lineWidth: 0.5))
        }
    }
}
