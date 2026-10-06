import SwiftUI

// MARK: - Output device section

/// Current output device (expands to the device list) and its volume.
struct OutputDeviceSection: View {
    @ObservedObject private var devices = DeviceService.shared
    @State private var showDevices = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let current = devices.defaultOutput {
                OutputDeviceRow(device: current, isExpanded: $showDevices)
                if showDevices {
                    DeviceListView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                DeviceVolumeRow()
            } else {
                Text(L("Çıkış aygıtı bulunamadı", "No output device found"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
        }
    }
}

// MARK: - OutputDeviceRow

struct OutputDeviceRow: View {
    let device: AudioDevice
    @Binding var isExpanded: Bool
    @State private var isHovered = false

    var body: some View {
        HStack {
            MenuItemIcon(systemName: device.symbolName, color: .blue)
                .accessibilityHidden(true)
            Text(device.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isExpanded.toggle() }
        }
        .onHover { isHovered = $0 }
        .help(L("Çıkış aygıtını değiştirmek için tıklayın", "Click to change the output device"))
        .accessibilityLabel(L("Çıkış aygıtı: \(device.name)", "Output device: \(device.name)"))
        .accessibilityHint(L("Aygıt listesini açar veya kapatır", "Opens or closes the device list"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Device list

struct DeviceListView: View {
    @ObservedObject private var devices = DeviceService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(devices.outputDevices) { device in
                DeviceListRow(device: device, isCurrent: device.uid == devices.defaultOutputUID)
            }
        }
        .padding(.vertical, 2)
    }
}

struct DeviceListRow: View {
    let device: AudioDevice
    let isCurrent: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            MenuItemIcon(systemName: device.symbolName, color: isCurrent ? .blue : .gray)
                .accessibilityHidden(true)
            Text(device.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            if !device.hasHardwareVolume {
                Badge(text: L("Yazılım", "Software"), color: .orange)
                    .help(L("Bu aygıtın donanım ses denetimi yok", "This device has no hardware volume control"))
            }
            Spacer()
            if isCurrent {
                Text(L("Geçerli", "Current"))
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isCurrent else { return }
            DeviceService.shared.setDefaultOutput(device)
        }
        .onHover { isHovered = $0 }
        .help(isCurrent ? L("Geçerli çıkış aygıtı", "Current output device") : L("Bu aygıta geç", "Switch to this device"))
        .accessibilityLabel(isCurrent ? L("\(device.name), geçerli", "\(device.name), current") : device.name)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Badge

/// Small coloured label ("Software", "Muted", "Boost").
struct Badge: View {
    let text: String
    var color: Color = .blue

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .cornerRadius(3)
    }
}

// MARK: - Device volume

struct DeviceVolumeRow: View {
    @ObservedObject private var volume = DeviceVolumeService.shared
    @State private var localVolume: Double = 1
    @State private var isDragging = false
    @State private var valueHighlighted = false
    @State private var highlightTask: Task<Void, Never>?

    private var isSoftware: Bool { volume.tier == .software }

    private var speakerIcon: String {
        if volume.isMuted || localVolume == 0 { return "speaker.slash.fill" }
        if localVolume < 0.34 { return "speaker.wave.1.fill" }
        if localVolume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        VStack(spacing: 2) {
            // Control mode indicator, like FreeDisplay's DDC/Software dot.
            HStack(spacing: 4) {
                Spacer()
                Circle()
                    .fill(isSoftware ? Color.orange : Color.green)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text(isSoftware ? L("Yazılım", "Software") : L("Donanım", "Hardware"))
                    .font(.caption2)
                    .foregroundColor(isSoftware ? .orange : .green)
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .help(isSoftware
                  ? L("Bu aygıtın donanım ses denetimi yok. FreeAudio yazılım ses düzeyini sonraki bir sürümde sağlayacak.",
                      "This device has no hardware volume control. FreeAudio will provide software volume in a later version.")
                  : L("Ses düzeyi doğrudan aygıtta ayarlanır", "Volume is set on the device itself"))
            .accessibilityElement(children: .combine)

            HStack(spacing: 6) {
                Button {
                    volume.setMuted(!volume.isMuted)
                } label: {
                    Image(systemName: speakerIcon)
                        .font(.caption)
                        .foregroundColor(volume.isMuted ? .red : .secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .disabled(!volume.canMute)
                .help(volume.isMuted ? L("Sesi aç", "Unmute") : L("Sesi kapat", "Mute"))
                .accessibilityLabel(volume.isMuted ? L("Sesi aç", "Unmute") : L("Sesi kapat", "Mute"))

                Slider(value: $localVolume, in: 0...1) { editing in
                    isDragging = editing
                    if !editing {
                        volume.setVolume(localVolume)
                        withAnimation(.easeOut(duration: 0.3)) { valueHighlighted = true }
                        highlightTask?.cancel()
                        highlightTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            withAnimation(.easeOut(duration: 0.3)) { valueHighlighted = false }
                        }
                    }
                }
                .disabled(isSoftware)
                .onChange(of: localVolume) { _, newValue in
                    guard isDragging else { return }
                    volume.setVolume(newValue)
                }
                .accessibilityLabel(L("Çıkış ses düzeyi", "Output volume"))
                .accessibilityValue("\(Int((localVolume * 100).rounded()))%")
                .help(isSoftware ? L("Yazılım ses düzeyi henüz yok", "Software volume isn't available yet")
                                 : L("Ses düzeyini ayarlamak için sürükleyin", "Drag to adjust the volume"))

                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text("\(Int((localVolume * 100).rounded()))%")
                    .font(.caption)
                    .foregroundColor(valueHighlighted ? .accentColor : .secondary)
                    .frame(width: 36, alignment: .trailing)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .onAppear { localVolume = volume.volume }
        .onChange(of: volume.volume) { _, newValue in
            // Pick up changes from the keyboard, System Settings or another app.
            if !isDragging, abs(newValue - localVolume) >= 0.005 { localVolume = newValue }
        }
        .onChange(of: volume.deviceUID) { _, _ in localVolume = volume.volume }
    }
}
