import SwiftUI

/// Apps playing audio. Read-only in this version; per-app volume arrives in Phase 2.
struct AppListSection: View {
    @ObservedObject private var appAudio = AppAudioService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Uygulamalar", "Apps"))
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)

            if appAudio.apps.isEmpty {
                Text(L("Şu anda ses çalan uygulama yok", "No apps are playing audio"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            } else {
                ForEach(appAudio.apps) { app in
                    AppVolumeRow(app: app)
                }
            }
        }
    }
}

struct AppVolumeRow: View {
    let app: AudioApp
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppAudioService.shared.icon(for: app))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(app.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Image(systemName: "waveform")
                .font(.caption)
                .foregroundColor(app.isPlaying ? .accentColor : .secondary)
                .opacity(app.isPlaying ? 1 : 0.4)
                .help(app.isPlaying ? L("Ses çalıyor", "Playing audio") : L("Az önce durdu", "Just stopped"))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.bundleID ?? app.name, forType: .string)
            } label: {
                Label(L("Paket kimliğini kopyala", "Copy Bundle ID"), systemImage: "doc.on.doc")
            }
        }
        .help(app.helperBundleIDs.isEmpty ? app.name
              : L("\(app.name) (\(app.pids.count) süreç)", "\(app.name) (\(app.pids.count) processes)"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(app.isPlaying ? L("\(app.name), ses çalıyor", "\(app.name), playing audio") : app.name)
    }
}
