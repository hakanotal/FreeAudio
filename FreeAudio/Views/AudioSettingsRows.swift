import SwiftUI

/// Audio rows of the Settings section: permission status, saved app settings, engine restart.
struct AudioSettingsRows: View {
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var permission = PermissionService.shared
    @ObservedObject private var devices = DeviceService.shared
    @State private var showSaved = false
    @State private var keysTrusted = VolumeKeyService.isTrusted

    private var permissionText: (String, Color) {
        switch permission.status {
        case .authorized: return (L("İzin verildi", "Granted"), .green)
        case .denied: return (L("Reddedildi", "Denied"), .red)
        case .notDetermined: return (L("Henüz sorulmadı", "Not asked yet"), .secondary)
        case .unavailable: return (L("Bilinmiyor", "Unknown"), .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // System Audio Recording permission
            HStack(spacing: 6) {
                MenuItemIcon(systemName: "waveform.badge.mic", color: .orange)
                    .accessibilityHidden(true)
                Text(L("Sistem sesi kaydı", "System audio recording"))
                    .font(.body)
                Spacer(minLength: 8)
                Text(permissionText.0)
                    .font(.caption)
                    .foregroundColor(permissionText.1)
                if permission.status == .denied || permission.status == .notDetermined {
                    Button(L("Aç", "Open")) { PermissionService.shared.openSystemSettings() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .help(L("Uygulama ses düzeyleri için gerekir. Gizlilik ve Güvenlik → Ekran ve Sistem Sesi Kaydı altında yönetilir.",
                    "Needed for per-app volume. Managed under Privacy & Security → Screen & System Audio Recording."))

            // Volume keys (only relevant with a software-volume output)
            if devices.outputDevices.contains(where: { !$0.hasHardwareVolume || settings.deviceSetting(for: $0.uid).forceSoftware }) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "keyboard", color: .blue)
                        .accessibilityHidden(true)
                    Text(L("Ses tuşları", "Volume keys"))
                        .font(.body)
                    Spacer(minLength: 8)
                    Text(keysTrusted ? L("Hazır", "Ready") : L("Erişilebilirlik izni gerekli", "Needs Accessibility"))
                        .font(.caption)
                        .foregroundColor(keysTrusted ? .green : .orange)
                    if !keysTrusted {
                        Button(L("Aç", "Open")) { VolumeKeyService.shared.openAccessibilitySettings() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 12)
                .help(L("Yazılım ses düzeyli bir çıkışta (ör. HDMI monitör) ses tuşlarını FreeAudio yönetir. Bunun için Gizlilik ve Güvenlik → Erişilebilirlik altında izin gerekir.",
                        "On an output with software volume (e.g. an HDMI monitor) FreeAudio handles the volume keys. This needs permission under Privacy & Security → Accessibility."))
                .onAppear { keysTrusted = VolumeKeyService.isTrusted }
            }

            // Saved per-app settings
            HStack(spacing: 6) {
                MenuItemIcon(systemName: "slider.horizontal.3", color: .purple)
                    .accessibilityHidden(true)
                Text(L("Kayıtlı uygulama ayarları", "Saved app settings"))
                    .font(.body)
                Spacer(minLength: 8)
                Text("\(settings.appSettings.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(showSaved ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: showSaved)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { showSaved.toggle() }
            }
            .help(L("Varsayılandan farklı ayarı olan uygulamalar", "Apps whose settings differ from default"))
            .accessibilityAddTraits(.isButton)

            if showSaved {
                SavedAppSettingsList()
                    .padding(.leading, 32)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Restart the audio engine
            HStack(spacing: 6) {
                MenuItemIcon(systemName: "arrow.triangle.2.circlepath", color: .gray)
                    .accessibilityHidden(true)
                Text(L("Ses motoru", "Audio engine"))
                    .font(.body)
                Spacer(minLength: 8)
                Button(L("Yeniden başlat", "Restart")) { TapService.shared.restartAll() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .help(L("Tüm uygulama dokunuşlarını kaldırıp yeniden kurar. Bir uygulamanın sesi takılırsa kullanın.",
                    "Removes and rebuilds every app tap. Use it if an app's audio gets stuck."))
        }
    }
}

struct SavedAppSettingsList: View {
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if settings.appSettings.isEmpty {
                Text(L("Tüm uygulamalar varsayılan ayarda", "All apps are at default settings"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
            } else {
                ForEach(settings.appSettings.keys.sorted(), id: \.self) { key in
                    if let setting = settings.appSettings[key] {
                        SavedAppSettingRow(key: key, setting: setting)
                    }
                }
                HStack {
                    Spacer()
                    Button(L("Tümünü sıfırla", "Reset all")) { settings.resetAllAppSettings() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SavedAppSettingRow: View {
    let key: String
    let setting: AppSetting
    @State private var isHovered = false

    private var summary: String {
        var parts = ["\(Int(setting.level.rounded()))%"]
        if setting.muted { parts.append(L("sessiz", "muted")) }
        if setting.outputDeviceUID != nil { parts.append("→ " + (setting.outputDeviceName ?? L("aygıt", "device"))) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(setting.name ?? key)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(summary)
                .font(.caption2)
                .foregroundColor(.secondary)
            Button {
                SettingsService.shared.resetAppSetting(key)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundColor(isHovered ? .primary : .secondary)
            .help(L("Varsayılana döndür", "Reset to default"))
            .accessibilityLabel(L("\(setting.name ?? key) ayarını sıfırla", "Reset \(setting.name ?? key)"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .onHover { isHovered = $0 }
    }
}
