import SwiftUI

// MARK: - Shared Icon Helper

/// A colored rounded-square SF Symbol icon, consistent with macOS Settings style.
struct MenuItemIcon: View {
    let systemName: String
    var color: Color = .blue

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(color))
    }
}

// MARK: - ExpandableRow

struct ExpandableRow: View {
    let icon: String
    var iconColor: Color = .blue
    let label: String
    var subtitle: String? = nil
    @Binding var isExpanded: Bool
    @State private var isHovered = false

    var body: some View {
        HStack {
            MenuItemIcon(systemName: icon, color: iconColor)
            Text(label).font(.body)
            Spacer()
            if let sub = subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(isExpanded ? L("\(label), genişletildi", "\(label), expanded") : L("\(label), daraltıldı", "\(label), collapsed"))
        .accessibilityHint(L("Bu bölümü genişletmek veya daraltmak için tıklayın", "Click to expand or collapse this section"))
        .accessibilityAddTraits(.isButton)
        .help(L("Bu bölümü genişletmek veya daraltmak için tıklayın", "Click to expand or collapse this section"))
    }
}

struct MenuBarView: View {
    @ObservedObject private var updateService = UpdateService.shared
    @ObservedObject private var settings = SettingsService.shared
    @State private var showSettings: Bool = false
    @State private var quitHovered = false
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                OutputDeviceSection()

                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                AppListSection()

                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                // Settings section
                ExpandableRow(
                    icon: "gearshape.fill",
                    iconColor: .gray,
                    label: L("Ayarlar", "Settings"),
                    isExpanded: $showSettings
                )

                if showSettings {
                    SettingsView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                // Update notice
                if updateService.hasUpdate, let ver = updateService.latestVersion {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.green)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text(L("Yeni sürüm v\(ver) mevcut", "New version v\(ver) available"))
                            .font(.caption)
                            .foregroundColor(.green)
                        Spacer()
                        Button(L("Görüntüle", "View")) { updateService.openReleasePage() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundColor(.blue)
                            .help(L("En son sürümü indirip yükleyin", "Download and install the latest version"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(6)
                    .padding(.horizontal, 8)
                }

            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        // macOS 27 sizes the MenuBarExtra window to the content's minimum size, and a bare
        // ScrollView's minimum height is 0 (only the footer would show). Pin the ScrollView
        // to the measured content height, capped so long content still scrolls.
        .frame(height: min(contentHeight, 640))

        Divider().opacity(0.3)

        // Version and Quit (pinned to the bottom, does not scroll with content)
        HStack {
            Text("FreeAudio v\(updateService.currentVersion)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Spacer()
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "xmark")
                        .accessibilityHidden(true)
                    Text(L("Çıkış", "Quit"))
                }
                .font(.body)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(quitHovered ? Color.primary.opacity(0.06) : .clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(quitHovered ? .red : .secondary)
            .onHover { quitHovered = $0 }
            .help(L("FreeAudio'den çık", "Quit FreeAudio"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        } // end VStack
        // No flexible maxHeight frame here: it let the panel stay taller than its content
        // (content centered with gaps). Height is capped by the ScrollView frame above.
        .frame(width: 340)
        .padding(.vertical, 8)
        // Keeps the panel pinned under the menu bar while it grows/shrinks.
        .windowResizeAnchor(.top)
        // Poll the app list faster while the panel is open.
        .onAppear {
            AppAudioService.shared.panelVisible = true
            PermissionService.shared.refresh()
            // Accessibility may have been granted since the key tap last tried to start.
            if DeviceVolumeService.shared.tier == .software { VolumeKeyService.shared.startIfNeeded() }
        }
        .onDisappear { AppAudioService.shared.panelVisible = false }
        .task {
            if settings.checkUpdatesOnLaunch {
                await updateService.checkForUpdates()
            }
        }
    }
}

// MARK: - SettingsView (embedded in MenuBarView)

struct SettingsView: View {
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Dil / Language
            HStack(spacing: 6) {
                MenuItemIcon(systemName: "globe", color: .indigo)
                    .accessibilityHidden(true)
                Text(L("Dil", "Language"))
                    .font(.body)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { LanguageStore.shared.language },
                    set: { LanguageStore.shared.language = $0 }
                )) {
                    Text(verbatim: "Türkçe").tag(AppLanguage.tr)
                    Text(verbatim: "English").tag(AppLanguage.en)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .help(L("Arayüz dili", "Interface language"))

            // Launch at login
            Toggle(isOn: Binding(
                get: { settings.launchAtLogin },
                set: { newValue in
                    if newValue {
                        LaunchService.shared.enable()
                    } else {
                        LaunchService.shared.disable()
                    }
                    settings.launchAtLogin = newValue
                }
            )) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "power", color: .green)
                        .accessibilityHidden(true)
                    Text(L("Girişte otomatik başlat", "Launch at login"))
                        .font(.body)
                    Spacer(minLength: 8)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help(L("Oturum açıldığında FreeAudio'i otomatik başlat", "Start FreeAudio automatically at login"))

            // First-launch hint: suggest enabling launch at login
            if !settings.launchAtLoginPrompted {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(L("Girişte otomatik başlatma önerilir", "Launch at login is recommended"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(L("Anladım", "Got it")) {
                        settings.launchAtLoginPrompted = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .onAppear {
                    // Mark as prompted so it only shows once
                    // User dismisses manually via "Anladım" button
                }
            }

            // Check for updates on launch
            Toggle(isOn: $settings.checkUpdatesOnLaunch) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "arrow.clockwise.circle", color: .blue)
                        .accessibilityHidden(true)
                    Text(L("Açılışta güncellemeleri denetle", "Check for updates on launch"))
                        .font(.body)
                    Spacer(minLength: 8)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help(L("Her açılışta yeni sürüm olup olmadığını otomatik denetle", "Automatically check for a new version on every launch"))

            AudioSettingsRows()
        }
        .padding(.vertical, 6)
    }
}
