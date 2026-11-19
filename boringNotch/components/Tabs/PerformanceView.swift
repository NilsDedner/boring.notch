//
//  PerformanceView.swift
//  boringNotch
//
//  Performance tab: CPU, memory, network, battery and thermal state.
//

import SwiftUI

struct PerformanceView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var manager = PerformanceManager.shared
    /// App whose quit buttons are currently expanded (two-step confirmation).
    @State private var confirmingPID: pid_t?

    /// How much of the app list header peeks out below the stats, hinting that the tab scrolls.
    private let peek: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        cpuCard
                        memoryCard
                        systemCard
                    }
                    .frame(height: max(geo.size.height - peek - 8, 60))

                    topAppsSection
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
        }
        .frame(maxHeight: .infinity)   // fill the notch like Shelf, so it isn't centered/shifted
        .onHover { vm.isHoveringScrollable = $0 }
        .onAppear { manager.startSampling() }
        .onDisappear {
            manager.stopSampling()
            vm.isHoveringScrollable = false
            confirmingPID = nil
        }
    }

    // MARK: - Top apps
    private var topAppsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                Text("Top-Apps nach Arbeitsspeicher")
            }
            .font(.caption2)
            .foregroundStyle(.gray)
            .frame(height: peek - 4)

            if manager.topApps.isEmpty {
                Text("Wird geladen …")
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .padding(8)
            } else {
                ForEach(manager.topApps) { app in
                    appRow(app)
                }
            }
        }
    }

    private func appRow(_ app: TopApp) -> some View {
        HStack(spacing: 8) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: "app").frame(width: 18, height: 18)
            }
            Text(app.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(memoryString(app.bytes))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.gray)

            if manager.terminating.contains(app.pid) {
                ProgressView().controlSize(.small).frame(width: 22)
            } else if confirmingPID == app.pid {
                Button("Beenden") {
                    manager.terminate(app, force: false)
                    confirmingPID = nil
                }
                .buttonStyle(PillButtonStyle(color: .red))
                Button("Erzwingen") {
                    manager.terminate(app, force: true)
                    confirmingPID = nil
                }
                .buttonStyle(PillButtonStyle(color: .orange))
                .help("Sofort beenden, ungespeicherte Änderungen gehen verloren")
                Button {
                    confirmingPID = nil
                } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.gray)
            } else {
                Button {
                    withAnimation(.smooth(duration: 0.2)) { confirmingPID = app.pid }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .help("\(app.name) beenden")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .secondarySystemFill)))
    }

    private func memoryString(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    // MARK: - Cards
    private var cpuCard: some View {
        card(title: "CPU", icon: "cpu") {
            Text(percent(manager.cpuUsage))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Sparkline(values: manager.cpuHistory, tint: tint(for: manager.cpuUsage))
                .frame(height: 28)
        }
    }

    private var memoryCard: some View {
        card(title: "Arbeitsspeicher", icon: "memorychip") {
            Text(percent(manager.memoryUsage))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
            ProgressView(value: manager.memoryUsage)
                .tint(tint(for: manager.memoryUsage))
            Text("\(gigabytes(manager.memoryUsedBytes)) von \(gigabytes(manager.memoryTotalBytes))")
                .font(.caption2)
                .foregroundStyle(.gray)
        }
    }

    private var systemCard: some View {
        card(title: "Netzwerk & System", icon: "arrow.up.arrow.down", spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down").foregroundStyle(.green)
                Text(rate(manager.downloadBytesPerSec))
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.up").foregroundStyle(.orange)
                Text(rate(manager.uploadBytesPerSec))
            }
            HStack(spacing: 4) {
                Image(systemName: manager.isCharging ? "battery.100.bolt" : "battery.75")
                Text(manager.batteryPercent.map { "\($0)%" } ?? "–")
            }
            HStack(spacing: 4) {
                Circle().fill(thermalColor).frame(width: 7, height: 7)
                Text(thermalText)
            }
        }
        .font(.caption2)
        .monospacedDigit()
    }

    // MARK: - Layout helper
    private func card<Content: View>(
        title: String, icon: String, spacing: CGFloat = 4, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.gray)
            content()
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .secondarySystemFill)))
        .foregroundStyle(.white)
    }

    // MARK: - Formatting
    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    private func rate(_ bytesPerSec: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSec
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: index == 0 ? "%.0f %@" : "%.1f %@", value, units[index])
    }

    private func tint(for value: Double) -> Color {
        value < 0.6 ? .green : (value < 0.85 ? .yellow : .red)
    }

    private var thermalText: String {
        switch manager.thermalState {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Heiß"
        case .critical: return "Kritisch"
        @unknown default: return "Unbekannt"
        }
    }

    private var thermalColor: Color {
        switch manager.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }
}

private struct PillButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(configuration.isPressed ? 0.6 : 0.85)))
            .foregroundStyle(.white)
    }
}

private struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let step = geo.size.width / CGFloat(max(values.count - 1, 1))
            Path { path in
                for (i, v) in values.enumerated() {
                    let point = CGPoint(
                        x: CGFloat(i) * step,
                        y: geo.size.height * (1 - CGFloat(min(max(v, 0), 1)))
                    )
                    i == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}

#Preview {
    PerformanceView().environmentObject(BoringViewModel()).frame(width: 600, height: 130).background(.black)
}
