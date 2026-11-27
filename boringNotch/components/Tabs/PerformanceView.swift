//
//  PerformanceView.swift
//  boringNotch
//
//  Performance tab: CPU/GPU, memory, network/system tiles (swipe with two fingers
//  to flip a tile) and the top apps by memory.
//

import Defaults
import SwiftUI

struct PerformanceView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var manager = PerformanceManager.shared
    @Default(.performanceWarnings) private var performanceWarnings
    /// App whose quit buttons are currently expanded (two-step confirmation).
    @State private var confirmingPID: pid_t?

    /// How much of the app list header peeks out below the stats, hinting that the tab scrolls.
    private let peek: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        PagedCard(pages: 2, help: "Wischen: CPU / GPU") { page in
                            if page == 0 { cpuPage } else { gpuPage }
                        }
                        .frame(width: (geo.size.width - 8) * 0.44)   // room for one block per core
                        PagedCard(pages: 2, help: "Wischen: Auslastung / Aufteilung") { page in
                            if page == 0 { memoryPage } else { memoryBreakdownPage }
                        }
                        PagedCard(pages: 3, help: "Wischen: Netzwerk / Energie / System") { page in
                            switch page {
                            case 0: networkPage
                            case 1: energyPage
                            default: systemPage
                            }
                        }
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
                Text("Top-Apps nach")
                Menu {
                    Picker("Sortieren nach", selection: $manager.topAppSort) {
                        ForEach(TopAppSort.allCases, id: \.self) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 3) {
                        Text(manager.topAppSort.title)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .bold))
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sortierung wählen")
                Spacer(minLength: 4)
                Button {
                    performanceWarnings.toggle()
                } label: {
                    Image(systemName: performanceWarnings ? "bell.fill" : "bell.slash")
                }
                .buttonStyle(.plain)
                .help(performanceWarnings
                      ? "Warnungen im Notch an: CPU oder GPU dauerhaft hoch, hoher Stromverbrauch, Speicher knapp, Swap wächst schnell, Mac heiß"
                      : "Warnungen im Notch aus")
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
            ZStack(alignment: .bottomTrailing) {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                } else {
                    Image(systemName: app.isVM ? "server.rack" : "app")
                        .font(.system(size: 12))
                        .frame(width: 18, height: 18)
                }
                if app.isVM && app.icon != nil {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 7))
                        .padding(1.5)
                        .background(Circle().fill(Color.black))
                        .offset(x: 3, y: 3)
                }
            }
            Text(app.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(String(format: "%.0f %%", app.cpu * 100))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(manager.topAppSort == .cpu ? .white : .gray)
                .frame(width: 40, alignment: .trailing)
                .help("CPU-Last wie in der Aktivitätsanzeige (100 % = ein Kern)")
            Text(wattString(app.watts))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(manager.topAppSort == .energy ? .white : .gray)
                .frame(width: 40, alignment: .trailing)
                .help("Stromverbrauch, den macOS den Prozessen zurechnet (Mittel über 2 s)")
            Text(memoryString(app.bytes))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(manager.topAppSort == .memory ? .white : .gray)
                .frame(width: 54, alignment: .trailing)

            if app.isVM {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.gray)
                    .frame(width: 14)
                    .help(app.name.hasPrefix("Lima · ")
                          ? "Virtuelle Maschine. Beenden mit: limactl stop \(app.name.dropFirst(7))"
                          : "Virtuelle Maschine. Beende sie in der App, die sie gestartet hat.")
            } else if manager.terminating.contains(app.pid) {
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

    private func wattString(_ watts: Double) -> String {
        watts >= 10 ? String(format: "%.0f W", watts) : String(format: "%.1f W", watts)
    }

    private func memoryString(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    // MARK: - Tile pages

    private func header(_ title: String, icon: String, value: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.gray)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let value {
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    /// One small block per core, coloured by core kind and filled by its load.
    private var cpuPage: some View {
        VStack(alignment: .leading, spacing: 5) {
            header("CPU", icon: "cpu", value: percent(manager.cpuUsage))
            ForEach(manager.coreGroups) { group in
                CoreGroupRow(
                    group: group,
                    loads: group.cores.map { manager.coreUsage.indices.contains($0) ? manager.coreUsage[$0] : 0 },
                    color: CoreGroupRow.color(for: group)
                )
                .frame(maxHeight: .infinity)
            }
        }
        .background(alignment: .bottom) {
            // Faint history of the total load behind the blocks.
            AreaChart(values: Array(manager.cpuHistory.suffix(60)), color: .white, fillOpacity: 0.06, lineOpacity: 0.14)
                .frame(height: 34)
        }
    }

    /// Same look as the CPU: a meter of blocks (one per GPU core) that lights up with the load.
    /// macOS only reports the load of the whole GPU, not per core.
    private var gpuPage: some View {
        let usage = manager.gpuUsage ?? 0
        let cores = manager.gpuCoreCount ?? 40
        return VStack(alignment: .leading, spacing: 5) {
            header("GPU", icon: "cube.transparent", value: manager.gpuUsage.map(percent) ?? "–")
            HStack(spacing: 4) {
                Circle().fill(Color.purple).frame(width: 5, height: 5)
                Text("\(cores) Kerne")
                Spacer(minLength: 2)
                Text("Speicher \(gigabytes(manager.gpuMemoryBytes))").monospacedDigit()
                    .help("Vom Grafikprozessor belegter Arbeitsspeicher. Apple Silicon hat kein eigenes VRAM, GPU und CPU teilen sich den RAM.")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.gray)

            GPUBlockMeter(usage: usage, blocks: cores, color: .purple)
                .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                gpuStage("Shader", manager.gpuRenderer)
                gpuStage("Geometrie", manager.gpuTiler)
            }
        }
        .background(alignment: .bottom) {
            AreaChart(values: Array(manager.gpuHistory.suffix(60)), color: .purple, fillOpacity: 0.08, lineOpacity: 0.2)
                .frame(height: 34)
        }
    }

    private func gpuStage(_ title: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.gray)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.purple.opacity(0.18))
                    Capsule().fill(Color.purple.opacity(0.85)).frame(width: geo.size.width * CGFloat(value))
                }
            }
            .frame(height: 4)
            Text(percent(value)).monospacedDigit().frame(width: 26, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .medium))
        .animation(.easeOut(duration: 0.4), value: value)
    }

    /// System power from the SMC plus fan speeds.
    private var energyPage: some View {
        let peak = max(manager.powerHistory.max() ?? 0, 10)
        return VStack(alignment: .leading, spacing: 4) {
            header("Energie", icon: "bolt.fill", value: manager.powerWatts.map { String(format: "%.1f W", $0) } ?? "–")
            AreaChart(values: manager.powerHistory.map { $0 / peak }, color: .yellow, fillOpacity: 0.25, lineOpacity: 0.9, guides: true)
                .frame(maxHeight: .infinity)
                .help("Stromverbrauch des ganzen Macs, letzte Minute (max \(String(format: "%.0f W", peak)))")
            if manager.fans.isEmpty {
                Text("Keine Lüfter").font(.system(size: 9, weight: .medium)).foregroundStyle(.gray)
            } else {
                ForEach(Array(manager.fans.enumerated()), id: \.offset) { index, fan in
                    fanRow(index: index, fan: fan)
                }
            }
        }
    }

    private func fanRow(index: Int, fan: PerformanceManager.Fan) -> some View {
        let share = fan.max > 0 ? min(max(fan.rpm / fan.max, 0), 1) : 0
        return HStack(spacing: 4) {
            Image(systemName: "fanblades.fill")
                .foregroundStyle(fan.rpm > 0 ? .cyan : .gray)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.cyan.opacity(0.15))
                    Capsule().fill(Color.cyan.opacity(0.85)).frame(width: geo.size.width * CGFloat(share))
                }
            }
            .frame(height: 4)
            Text(fan.rpm > 0 ? "\(Int(fan.rpm.rounded())) U/min" : "aus")
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .medium))
        .animation(.easeOut(duration: 0.4), value: fan.rpm)
        .help("Lüfter \(index + 1): \(Int(fan.rpm)) von max. \(Int(fan.max)) U/min")
    }

    private var memoryPage: some View {
        VStack(alignment: .leading, spacing: 4) {
            header("Arbeitsspeicher", icon: "memorychip")
            Text(percent(manager.memoryUsage))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
            ProgressView(value: manager.memoryUsage)
                .tint(tint(for: manager.memoryUsage))
            Text("\(gigabytes(manager.memoryUsedBytes)) von \(gigabytes(manager.memoryTotalBytes))")
                .font(.caption2)
                .foregroundStyle(.gray)
            Spacer(minLength: 0)
        }
    }

    /// Segmented bar like Activity Monitor, plus swap and memory pressure.
    private var memoryBreakdownPage: some View {
        let total = Double(max(manager.memoryTotalBytes, 1))
        let segments: [(String, UInt64, Color)] = [
            ("Apps", manager.memoryAppBytes, .blue),
            ("System", manager.memoryWiredBytes, .orange),
            ("Komprimiert", manager.memoryCompressedBytes, .purple),
            ("Cache", manager.memoryCachedBytes, .gray),
        ]
        return VStack(alignment: .leading, spacing: 5) {
            header("Aufteilung", icon: "chart.bar.fill")
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(segments, id: \.0) { segment in
                        Rectangle()
                            .fill(segment.2)
                            .frame(width: max(0, geo.size.width * CGFloat(Double(segment.1) / total) - 1))
                    }
                    Spacer(minLength: 0)
                }
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .animation(.easeOut(duration: 0.4), value: manager.memoryAppBytes)
            }
            .frame(height: 9)

            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<2, id: \.self) { col in
                            let segment = segments[row * 2 + col]
                            HStack(spacing: 3) {
                                Circle().fill(segment.2).frame(width: 5, height: 5)
                                Text(segment.0).foregroundStyle(.gray)
                                Text(gigabytes(segment.1)).monospacedDigit()
                            }
                        }
                    }
                }
            }
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)

            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Circle().fill(pressureColor).frame(width: 6, height: 6)
                Text("Druck: \(pressureText)")
                Spacer(minLength: 2)
                Text("Swap \(gigabytes(manager.swapUsedBytes))").monospacedDigit()
                    .foregroundStyle(manager.swapUsedBytes > 1_073_741_824 ? .orange : .gray)
            }
            .font(.system(size: 9, weight: .medium))
        }
        .help("System = fest belegter Speicher des Systemkerns. Cache = Dateien im Speicher, macOS gibt ihn bei Bedarf sofort frei.")
    }

    private var networkPage: some View {
        let peak = max(manager.downloadHistory.max() ?? 0, manager.uploadHistory.max() ?? 0, 1024)
        return VStack(alignment: .leading, spacing: 4) {
            header("Netzwerk", icon: "arrow.up.arrow.down")
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down").foregroundStyle(.green)
                    Text(rate(manager.downloadBytesPerSec))
                }
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up").foregroundStyle(.orange)
                    Text(rate(manager.uploadBytesPerSec))
                }
            }
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            ZStack {
                AreaChart(values: manager.downloadHistory.map { $0 / peak }, color: .green, fillOpacity: 0.25, lineOpacity: 0.9, guides: true)
                AreaChart(values: manager.uploadHistory.map { $0 / peak }, color: .orange, fillOpacity: 0.12, lineOpacity: 0.9)
            }
            .frame(maxHeight: .infinity)
            HStack {
                Text("1 Min.")
                Spacer()
                Text("max \(rate(peak))").monospacedDigit()
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.gray)
        }
    }

    private var systemPage: some View {
        VStack(alignment: .leading, spacing: 5) {
            header("System", icon: "macbook")
            HStack(spacing: 5) {
                Image(systemName: manager.isCharging ? "battery.100.bolt" : "battery.75").frame(width: 18)
                Text(manager.batteryPercent.map { "\($0)%" } ?? "–")
                Text(manager.isCharging ? "lädt" : "").foregroundStyle(.gray)
            }
            HStack(spacing: 5) {
                Circle().fill(thermalColor).frame(width: 7, height: 7).frame(width: 18)
                Text("Temperatur: \(thermalText)")
            }
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath").frame(width: 18)
                Text("Laufzeit \(uptimeText)")
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .monospacedDigit()
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

    private var uptimeText: String {
        let minutes = Int(ProcessInfo.processInfo.systemUptime / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return "\(days) T \(hours) Std." }
        if hours > 0 { return "\(hours) Std. \(mins) Min." }
        return "\(mins) Min."
    }

    private var pressureText: String {
        switch manager.memoryPressureLevel {
        case 4: return "kritisch"
        case 2: return "erhöht"
        default: return "normal"
        }
    }

    private var pressureColor: Color {
        switch manager.memoryPressureLevel {
        case 4: return .red
        case 2: return .yellow
        default: return .green
        }
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

/// "Super · 6   34%" label plus one block per core that fills from the bottom.
private struct CoreGroupRow: View {
    let group: CoreGroup
    let loads: [Double]
    let color: Color

    /// At most this many blocks per line; bigger groups wrap (e.g. Ultra chips).
    private let maxPerLine = 12

    static func color(for group: CoreGroup) -> Color {
        switch group.name.lowercased() {
        case let n where n.contains("super"): return .orange
        case let n where n.contains("perf"): return .cyan
        case let n where n.contains("eff"): return .green
        default: return [Color.orange, .cyan, .green, .purple][min(group.level, 3)]
        }
    }

    private var displayName: String {
        switch group.name.lowercased() {
        case "efficiency": return "Effizienz"
        default: return group.name
        }
    }

    private var average: Double {
        loads.isEmpty ? 0 : loads.reduce(0, +) / Double(loads.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text("\(displayName) · \(loads.count)")
                Spacer(minLength: 2)
                Text("\(Int((average * 100).rounded()))%").monospacedDigit()
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.gray)

            let lines = stride(from: 0, to: loads.count, by: maxPerLine).map {
                Array(loads[$0..<min($0 + maxPerLine, loads.count)])
            }
            VStack(spacing: 2) {
                ForEach(lines.indices, id: \.self) { line in
                    HStack(spacing: 2) {
                        ForEach(lines[line].indices, id: \.self) { i in
                            CoreBlock(load: lines[line][i], color: color)
                        }
                        // Keep blocks the same width as in full lines.
                        if lines.count > 1 && lines[line].count < maxPerLine {
                            ForEach(0..<(maxPerLine - lines[line].count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct CoreBlock: View {
    let load: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2.5).fill(color.opacity(0.16))
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(color.opacity(0.55 + 0.45 * min(max(load, 0), 1)))
                    .frame(height: max(geo.size.height * CGFloat(min(max(load, 0), 1)), load > 0.005 ? 1.5 : 0))
            }
        }
        .frame(maxWidth: 16)
        .animation(.easeOut(duration: 0.45), value: load)
        .help("\(Int((load * 100).rounded()))%")
    }
}

/// A tile that flips between pages with a horizontal two-finger swipe (or by clicking the dots).
private struct PagedCard<Content: View>: View {
    let pages: Int
    let help: String
    @ViewBuilder let content: (Int) -> Content
    @State private var page: Int? = 0

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<pages, id: \.self) { index in
                        content(index)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                            .padding(.bottom, 12)   // room for the page dots
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 4) {
                ForEach(0..<pages, id: \.self) { index in
                    Circle()
                        .fill(Color.white.opacity((page ?? 0) == index ? 0.8 : 0.22))
                        .frame(width: 4, height: 4)
                        .contentShape(Rectangle().inset(by: -4))
                        .onTapGesture { withAnimation(.smooth) { page = index } }
                }
            }
            .padding(.bottom, 4)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .secondarySystemFill)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
        .help(help)
    }
}

/// Blocks that light up from left to right with the load (two rows), in the CPU block style.
private struct GPUBlockMeter: View {
    let usage: Double
    let blocks: Int
    let color: Color

    var body: some View {
        let perRow = max(Int((Double(blocks) / 2).rounded(.up)), 1)
        let lit = min(max(usage, 0), 1) * Double(blocks)
        VStack(spacing: 2) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<perRow, id: \.self) { column in
                        let index = row * perRow + column
                        let fill = index < blocks ? min(max(lit - Double(index), 0), 1) : 0
                        GeometryReader { geo in
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 2).fill(color.opacity(index < blocks ? 0.16 : 0))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(color.opacity(0.9))
                                    .frame(height: geo.size.height * CGFloat(fill))
                            }
                        }
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.45), value: usage)
    }
}

/// Line with a soft fill below; values 0...1, oldest first.
private struct AreaChart: View {
    let values: [Double]
    let color: Color
    var fillOpacity: Double = 0.25
    var lineOpacity: Double = 0.9
    var guides: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if guides {
                    Path { p in
                        let y = geo.size.height * 0.5
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                }
                area(in: geo.size)
                    .fill(LinearGradient(colors: [color.opacity(fillOpacity), color.opacity(fillOpacity * 0.15)],
                                         startPoint: .top, endPoint: .bottom))
                line(in: geo.size)
                    .stroke(color.opacity(lineOpacity), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
        }
    }

    private func point(_ i: Int, _ v: Double, in size: CGSize) -> CGPoint {
        let step = size.width / CGFloat(max(values.count - 1, 1))
        return CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(min(max(v, 0), 1))))
    }

    private func line(in size: CGSize) -> Path {
        Path { p in
            for (i, v) in values.enumerated() {
                i == 0 ? p.move(to: point(i, v, in: size)) : p.addLine(to: point(i, v, in: size))
            }
        }
    }

    private func area(in size: CGSize) -> Path {
        Path { p in
            guard !values.isEmpty else { return }
            p.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in values.enumerated() { p.addLine(to: point(i, v, in: size)) }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
        }
    }
}

#Preview {
    PerformanceView().environmentObject(BoringViewModel()).frame(width: 600, height: 130).background(.black)
}
