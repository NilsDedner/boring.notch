//
//  ClipboardView.swift
//  boringNotch
//
//  Clipboard history tab: horizontally scrollable cards. Click copies an entry
//  back to the clipboard, drag drops it into another app.
//

import SwiftUI

struct ClipboardView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var manager = ClipboardManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if manager.items.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(manager.items) { item in
                            ClipboardCard(
                                item: item,
                                copied: manager.lastCopiedID == item.id
                            )
                            .onTapGesture { manager.copy(item) }
                            .onDrag { manager.itemProvider(for: item) }
                            .contextMenu {
                                Button("Kopieren") { manager.copy(item) }
                                Button(item.isPinned ? "Lösen" : "Anheften") { manager.togglePin(item) }
                                Divider()
                                Button("Entfernen", role: .destructive) { manager.remove(item) }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .onHover { vm.isHoveringScrollable = $0 }
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { vm.isHoveringScrollable = false }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.clipboard")
            Text("Zwischenablage")
            Text("\(manager.items.count)")
                .monospacedDigit()
                .foregroundStyle(.gray)
            Spacer()
            Text("Klicken = kopieren · Ziehen = einfügen")
                .foregroundStyle(.gray)
            if !manager.items.isEmpty {
                Button {
                    manager.clearUnpinned()
                } label: {
                    Label("Leeren", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.gray)
                .help("Alle nicht angehefteten Einträge entfernen")
            }
        }
        .font(.caption)
        .foregroundStyle(.white)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 22))
            Text("Noch nichts kopiert")
                .font(.callout)
            Text("Alles, was du ab jetzt kopierst, erscheint hier. Passwörter werden nicht gespeichert.")
                .font(.caption2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.gray)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ClipboardCard: View {
    let item: ClipboardItem
    let copied: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 4) {
                if let icon = item.sourceAppIcon {
                    Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                }
                Text(item.date, style: .relative)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if item.isPinned {
                    Image(systemName: "pin.fill").foregroundStyle(.yellow)
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.gray)
        }
        .padding(8)
        .frame(width: 150)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .secondarySystemFill).opacity(hovering ? 1.6 : 1))
        )
        .overlay {
            if copied {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.black.opacity(0.55))
                    .overlay(Label("Kopiert", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)))
                    .transition(.opacity)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(hovering ? 0.25 : 0), lineWidth: 1))
        .foregroundStyle(.white)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: copied)
        .help(helpText)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.content {
        case .text(let text):
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.caption)
                .lineLimit(5)
        case .image(let image, _):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .files(let urls):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(urls.prefix(3), id: \.self) { url in
                    HStack(spacing: 4) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().frame(width: 16, height: 16)
                        Text(url.lastPathComponent).font(.caption).lineLimit(1)
                    }
                }
                if urls.count > 3 {
                    Text("+\(urls.count - 3) weitere").font(.caption2).foregroundStyle(.gray)
                }
            }
        }
    }

    private var helpText: String {
        switch item.content {
        case .text(let s): return String(s.prefix(500))
        case .image: return "Bild"
        case .files(let urls): return urls.map(\.lastPathComponent).joined(separator: ", ")
        }
    }
}
