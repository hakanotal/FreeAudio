import SwiftUI

/// Apps playing audio, each with its own level (0–200%), mute and output.
struct AppListSection: View {
    @ObservedObject private var appAudio = AppAudioService.shared
    @ObservedObject private var taps = TapService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Uygulamalar", "Apps"))
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)

            if taps.state == .needsPermission {
                NoticeRow(
                    icon: "lock.fill", color: .orange,
                    text: L("Uygulama ses düzeyleri için Sistem Sesi Kaydı izni gerekli.",
                            "Per-app volume needs System Audio Recording permission."),
                    buttonTitle: L("Ayarları Aç", "Open Settings")
                ) { PermissionService.shared.openSystemSettings() }
            } else if taps.state == .stuck {
                NoticeRow(
                    icon: "exclamationmark.triangle.fill", color: .orange,
                    text: L("Ses motoru yanıt vermiyor. Başka bir ses uygulaması çakışıyor olabilir.",
                            "The audio engine isn't responding. Another audio app may be interfering."),
                    buttonTitle: L("Yeniden Başlat", "Restart")
                ) { TapService.shared.restartAll() }
            }

            if !taps.conflictingApps.isEmpty, !taps.activeKeys.isEmpty {
                NoticeRow(
                    icon: "exclamationmark.triangle.fill", color: .yellow,
                    text: L("\(taps.conflictingApps.joined(separator: ", ")) çalışıyor; uygulama ses düzeyleriyle çakışabilir.",
                            "\(taps.conflictingApps.joined(separator: ", ")) is running and may interfere with per-app volume."),
                    buttonTitle: L("Yeniden Başlat", "Restart")
                ) { TapService.shared.restartAll() }
            }

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

// MARK: - NoticeRow

/// A tinted message with one action (permission, engine problems).
struct NoticeRow: View {
    let icon: String
    let color: Color
    let text: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
        .cornerRadius(6)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
}

// MARK: - AppVolumeRow

struct AppVolumeRow: View {
    let app: AudioApp
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var devices = DeviceService.shared
    /// Level in percent, 0–200 (100 = unchanged, in the middle of the slider).
    @State private var localLevel: Double = 100
    @State private var isDragging = false
    @State private var isHovered = false
    @State private var isExpanded = false
    @State private var valueHighlighted = false
    @State private var highlightTask: Task<Void, Never>?

    private var setting: AppSetting { settings.appSetting(for: app.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(nsImage: AppAudioService.shared.icon(for: app))
                        .resizable()
                        .frame(width: 20, height: 20)
                        .opacity(app.isPlaying ? 1 : 0.6)
                        .accessibilityHidden(true)
                    Text(app.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let routedUID = setting.outputDeviceUID {
                        let device = devices.outputDevices.first { $0.uid == routedUID }
                        let name = device?.name ?? setting.outputDeviceName ?? routedUID
                        Image(systemName: device?.symbolName ?? "speaker.slash")
                            .font(.caption2)
                            .foregroundColor(device != nil ? .blue : .secondary)
                            .help(device != nil ? L("Çıkış: \(name)", "Output: \(name)")
                                                : L("Çıkış: \(name) (bağlı değil, sistem varsayılanı kullanılıyor)", "Output: \(name) (not connected, using the system default)"))
                            .accessibilityLabel(L("Çıkış: \(name)", "Output: \(name)"))
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isExpanded.toggle() }
                }
                .help(L("Ayrıntılar için tıklayın", "Click for details"))

                Button {
                    settings.updateAppSetting(app.id, name: app.name) { $0.muted.toggle() }
                } label: {
                    Image(systemName: setting.muted ? "speaker.slash.fill" : "speaker.fill")
                        .font(.caption)
                        .foregroundColor(setting.muted ? .red : .secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .help(setting.muted ? L("\(app.name) sesini aç", "Unmute \(app.name)") : L("\(app.name) sesini kapat", "Mute \(app.name)"))
                .accessibilityLabel(setting.muted ? L("Sesi aç", "Unmute") : L("Sesi kapat", "Mute"))

                VolumeSlider(percent: $localLevel, range: 0...VolumeCurve.maxAppPercent, neutralValue: 100) { editing in
                    isDragging = editing
                    if !editing {
                        commit(localLevel)
                        withAnimation(.easeOut(duration: 0.3)) { valueHighlighted = true }
                        highlightTask?.cancel()
                        highlightTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            withAnimation(.easeOut(duration: 0.3)) { valueHighlighted = false }
                        }
                    }
                }
                .controlSize(.small)
                .frame(width: 112)
                .opacity(setting.muted ? 0.5 : 1)
                .onChange(of: localLevel) { _, newValue in
                    guard isDragging else { return }
                    commit(newValue)
                }
                .accessibilityLabel(L("\(app.name) ses düzeyi", "\(app.name) volume"))
                .accessibilityValue("\(Int(localLevel.rounded()))%")
                .help(L("\(app.name) ses düzeyi: %100 değişmeden, %200'e kadar yükseltir",
                        "\(app.name) volume: 100% is unchanged, up to 200% boosts it"))

                Text("\(Int(localLevel.rounded()))%")
                    .font(.caption)
                    .foregroundColor(valueHighlighted ? .accentColor : .secondary)
                    .frame(width: 36, alignment: .trailing)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(isHovered ? 0.06 : 0))
            .onHover { isHovered = $0 }

            if isExpanded {
                AppDetailView(app: app)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear { localLevel = setting.level }
        .onChange(of: setting.level) { _, newValue in
            if !isDragging, abs(newValue - localLevel) >= 0.5 { localLevel = newValue }
        }
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.bundleID ?? app.name, forType: .string)
            } label: {
                Label(L("Paket kimliğini kopyala", "Copy Bundle ID"), systemImage: "doc.on.doc")
            }
            Button {
                SettingsService.shared.resetAppSetting(app.id)
            } label: {
                Label(L("Varsayılana döndür", "Reset to Default"), systemImage: "arrow.counterclockwise")
            }
            .disabled(setting.isDefault)
        }
    }

    private func commit(_ value: Double) {
        settings.updateAppSetting(app.id, name: app.name) { setting in
            setting.level = value
            // Moving the slider unmutes, like the system volume.
            if setting.muted, value > 0 { setting.muted = false }
        }
    }
}

// MARK: - AppDetailView

/// Expanded panel under an app row: output device, engine status and reset.
struct AppDetailView: View {
    let app: AudioApp
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var taps = TapService.shared
    @ObservedObject private var devices = DeviceService.shared

    private var setting: AppSetting { settings.appSetting(for: app.id) }

    private var routedDeviceMissing: Bool {
        guard let uid = setting.outputDeviceUID else { return false }
        return !devices.outputDevices.contains { $0.uid == uid }
    }

    private var status: (text: String, color: Color) {
        if taps.failedKeys.contains(app.id) {
            return (L("Ses yakalanamadı; birazdan yeniden denenecek", "Couldn't capture audio; will retry shortly"), .orange)
        }
        if setting.isDefault {
            return (L("Varsayılan: FreeAudio bu uygulamaya dokunmuyor", "Default: FreeAudio leaves this app alone"), .secondary)
        }
        if routedDeviceMissing {
            let name = setting.outputDeviceName ?? L("Seçilen aygıt", "The chosen device")
            return (L("\(name) bağlı değil; sistem varsayılanından çalıyor", "\(name) isn't connected; playing on the system default"), .orange)
        }
        if taps.activeKeys.contains(app.id) {
            return (setting.muted ? L("Sessize alındı", "Muted") : L("Ses FreeAudio üzerinden ayarlanıyor", "Volume is controlled by FreeAudio"), .green)
        }
        return (L("Bekliyor", "Waiting"), .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("Çıkış", "Output"))
                    .font(.caption)
                Spacer(minLength: 8)
                Picker("", selection: Binding<String>(
                    get: { setting.outputDeviceUID ?? "" },
                    set: { uid in
                        let name = devices.outputDevices.first { $0.uid == uid }?.name
                        settings.updateAppSetting(app.id, name: app.name) { setting in
                            setting.outputDeviceUID = uid.isEmpty ? nil : uid
                            setting.outputDeviceName = uid.isEmpty ? nil : name
                        }
                    }
                )) {
                    Text(L("Sistem varsayılanı", "System default")).tag("")
                    Divider()
                    ForEach(devices.outputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if routedDeviceMissing, let uid = setting.outputDeviceUID {
                        Text(L("\(setting.outputDeviceName ?? uid) (bağlı değil)", "\(setting.outputDeviceName ?? uid) (not connected)")).tag(uid)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help(L("Bu uygulamanın sesini başka bir çıkışa gönderin; aygıt bağlı değilken sistem varsayılanı kullanılır",
                        "Send this app's audio to another output; while that device isn't connected the system default is used"))
            }

            HStack(spacing: 4) {
                Circle()
                    .fill(status.color)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text(status.text)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button(L("Sıfırla", "Reset")) {
                    settings.resetAppSetting(app.id)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(setting.isDefault)
                .help(L("Ses düzeyini, sessizi ve çıkışı varsayılana döndür", "Reset volume, mute and output to default"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        .cornerRadius(6)
        .padding(.leading, 32)
        .padding(.trailing, 8)
        .padding(.bottom, 4)
    }
}
