import SwiftUI

/// How much video a paired Mac may send: as much as the network carries, or
/// up to a cap the user picks. The host still lowers the rate on loss either way.
struct VideoQualityView: View {
    let target: HostTarget
    let model: ViewerModel
    /// In a sheet, which needs a way to close; a popover closes on its own.
    var showsDone = false
    @Environment(\.dismiss) private var dismiss
    @State private var automatic = true
    @State private var megabits: Double = 40
    @State private var showsStatistics = StatisticsPreferences.isShown

    /// The host's floor (`HostSession.minimumBitRate`) to its full-desktop ceiling.
    static let range: ClosedRange<Double> = 6...120

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Video Quality").font(.headline)
                Text(target.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Picker("Video Quality", selection: $automatic) {
                Text("Automatic").tag(true)
                Text("Limited").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if automatic {
                Text("Up to 80 Mbps for each window and 120 Mbps for the full desktop, less whenever the network drops video.")
                    .explanation()
            } else {
                HStack(spacing: 10) {
                    // No `step`: on macOS it draws a tick for every value.
                    Slider(value: $megabits, in: Self.range) {
                        Text("Maximum")
                    } minimumValueLabel: {
                        Text("\(Int(Self.range.lowerBound))")
                    } maximumValueLabel: {
                        Text("\(Int(Self.range.upperBound))")
                    } onEditingChanged: { editing in
                        if !editing { save() }
                    }
                    .labelsHidden()
                    Text("\(megabitsShown) Mbps")
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                Text(hint).explanation()
            }
            Divider()
            // For every Mac: it shows what this setting achieves.
            Toggle("Show Statistics over Remote Windows", isOn: $showsStatistics)
                .onChange(of: showsStatistics) { StatisticsPreferences.isShown = showsStatistics }
            if showsDone {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 360, alignment: .leading)
        .onAppear {
            let bitRate = model.maximumBitRate(target)
            automatic = bitRate == nil
            if let bitRate { megabits = min(max(Double(bitRate) / 1_000_000, Self.range.lowerBound), Self.range.upperBound) }
        }
        .onChange(of: automatic) { save() }
        // Keyboard changes don't end an edit; keep them too.
        .onDisappear(perform: save)
    }

    private var megabitsShown: Int { Int(megabits.rounded()) }

    private var hint: String {
        let use = switch megabits {
        case ..<15: String(localized: "Suits slow Wi-Fi and connections over the internet; small text blurs while things move.")
        case ..<40: String(localized: "Suits most Wi-Fi networks.")
        default: String(localized: "Suits wired and fast Wi-Fi networks.")
        }
        return String(localized: "\(use) Each window and the full desktop use up to this much.")
    }

    private func save() {
        model.setMaximumBitRate(target, automatic ? nil : megabitsShown * 1_000_000)
    }
}

private extension Text {
    func explanation() -> some View {
        font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
