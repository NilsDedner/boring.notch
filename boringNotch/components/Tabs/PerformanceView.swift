//
//  PerformanceView.swift
//  boringNotch
//
//  Performance tab: CPU, memory, network, battery and thermal state.
//

import SwiftUI

struct PerformanceView: View {
    @ObservedObject private var manager = PerformanceManager.shared

    var body: some View {
        HStack(spacing: 10) {
            cpuCard
            memoryCard
            VStack(spacing: 8) {
                networkCard
                batteryThermalCard
            }
        }
        .padding(.horizontal, 4)
        .onAppear { manager.startSampling() }
        .onDisappear { manager.stopSampling() }
    }

    // MARK: - Cards
    private var cpuCard: some View {
        card(title: "CPU", icon: "cpu") {
            Text(percent(manager.cpuUsage))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Sparkline(values: manager.cpuHistory, tint: tint(for: manager.cpuUsage))
                .frame(height: 34)
        }
    }

    private var memoryCard: some View {
        card(title: "Memory", icon: "memorychip") {
            Text(percent(manager.memoryUsage))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            ProgressView(value: manager.memoryUsage)
                .tint(tint(for: manager.memoryUsage))
            Text("\(gigabytes(manager.memoryUsedBytes)) of \(gigabytes(manager.memoryTotalBytes))")
                .font(.caption2)
                .foregroundStyle(.gray)
        }
    }

    private var networkCard: some View {
        card(title: "Network", icon: "arrow.up.arrow.down") {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down").foregroundStyle(.green)
                Text(rate(manager.downloadBytesPerSec))
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.up").foregroundStyle(.orange)
                Text(rate(manager.uploadBytesPerSec))
            }
        }
        .font(.caption)
        .monospacedDigit()
    }

    private var batteryThermalCard: some View {
        card(title: "System", icon: "thermometer.medium") {
            HStack(spacing: 4) {
                Image(systemName: manager.isCharging ? "battery.100.bolt" : "battery.75")
                Text(manager.batteryPercent.map { "\($0)%" } ?? "–")
            }
            HStack(spacing: 4) {
                Circle().fill(thermalColor).frame(width: 7, height: 7)
                Text(thermalText)
            }
        }
        .font(.caption)
        .monospacedDigit()
    }

    // MARK: - Layout helper
    private func card<Content: View>(
        title: String, icon: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.gray)
            content()
            Spacer(minLength: 0)
        }
        .padding(10)
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
        while value >= 1024, index < units.count - 1 {
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
        case .serious: return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
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
    PerformanceView().frame(width: 420, height: 110).background(.black)
}
