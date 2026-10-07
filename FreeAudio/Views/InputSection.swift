import SwiftUI

/// Tools → Input: the default input device (switchable) and its level and mute.
struct InputSection: View {
    @ObservedObject private var devices = DeviceService.shared
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExpandableRow(
                icon: "mic.fill",
                iconColor: .pink,
                label: L("Giriş", "Input"),
                subtitle: devices.defaultInput?.name ?? L("Yok", "None"),
                isExpanded: $isExpanded
            )
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(devices.inputDevices) { device in
                        InputDeviceRow(device: device, isCurrent: device.uid == devices.defaultInputUID)
                    }
                    if devices.defaultInput != nil {
                        InputLevelRow()
                    }
                }
                .padding(.leading, 8)
                .padding(.vertical, 2)
                .transition(Disclosure.content)
            }
        }
    }
}

struct InputDeviceRow: View {
    let device: AudioDevice
    let isCurrent: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            MenuItemIcon(systemName: device.inputSymbolName, color: isCurrent ? .pink : .gray)
                .accessibilityHidden(true)
            Text(device.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if isCurrent {
                Text(L("Geçerli", "Current"))
                    .font(.caption)
                    .foregroundColor(.pink)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isCurrent else { return }
            DeviceService.shared.setDefaultInput(device)
        }
        .onHover { isHovered = $0 }
        .help(isCurrent ? L("Geçerli giriş aygıtı", "Current input device") : L("Bu mikrofona geç", "Switch to this microphone"))
        .accessibilityLabel(isCurrent ? L("\(device.name), geçerli giriş", "\(device.name), current input") : device.name)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

struct InputLevelRow: View {
    @ObservedObject private var input = InputVolumeService.shared
    /// Input level in percent (0–100).
    @State private var localPercent: Double = 100
    @State private var isDragging = false
    @State private var valueHighlighted = false
    @State private var highlightTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    input.setMuted(!input.isMuted)
                } label: {
                    Image(systemName: input.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.caption)
                        .foregroundColor(input.isMuted ? .red : .secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .disabled(!input.canMute)
                .help(input.isMuted ? L("Mikrofonu aç", "Unmute microphone") : L("Mikrofonu kapat", "Mute microphone"))
                .accessibilityLabel(input.isMuted ? L("Mikrofonu aç", "Unmute microphone") : L("Mikrofonu kapat", "Mute microphone"))

                VolumeSlider(percent: $localPercent, range: 0...100) { editing in
                    isDragging = editing
                    if !editing {
                        input.setVolume(localPercent / 100)
                        withAnimation(.easeOut(duration: 0.3)) { valueHighlighted = true }
                        highlightTask?.cancel()
                        highlightTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            withAnimation(.easeOut(duration: 0.3)) { valueHighlighted = false }
                        }
                    }
                }
                .disabled(!input.canSetVolume)
                .onChange(of: localPercent) { _, newValue in
                    // Drags, arrow keys and VoiceOver all land here; syncing from the device is no change.
                    if abs(newValue - input.volume * 100) >= 0.05 { input.setVolume(newValue / 100) }
                }
                .accessibilityLabel(L("Giriş düzeyi", "Input level"))
                .accessibilityValue("\(Int(localPercent.rounded()))%")
                .help(input.canSetVolume ? L("Mikrofon giriş düzeyi", "Microphone input level")
                                         : L("Bu aygıtın giriş düzeyi ayarlanamıyor", "This device's input level can't be changed"))

                Text("\(Int(localPercent.rounded()))%")
                    .font(.caption)
                    .foregroundColor(valueHighlighted ? .accentColor : .secondary)
                    .frame(width: 36, alignment: .trailing)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .opacity(input.canSetVolume ? 1 : 0.4)
            }
            if !input.canSetVolume {
                Text(L("Bu aygıtın giriş düzeyi ayarlanamıyor", "This device's input level can't be changed"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { localPercent = input.volume * 100 }
        .onChange(of: input.volume) { _, newValue in
            if !isDragging, abs(newValue * 100 - localPercent) >= 0.5 { localPercent = newValue * 100 }
        }
        .onChange(of: input.deviceUID) { _, _ in localPercent = input.volume * 100 }
    }
}
