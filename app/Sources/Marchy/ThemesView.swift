import SwiftUI
import AppKit

struct ThemesView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var runner: Runner
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Themes").font(.title2.bold())
                Text("One switch restyles the bar, window borders, Ghostty, Neovim, btop, the wallpaper and light/dark mode. Super+Ctrl+Shift+Space opens the same picker from the keyboard.")
                    .foregroundStyle(.secondary)
                if !Paths.isSetUp { NeedsSetup() }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.themes) { t in
                        Button { Task { await store.applyTheme(t) } } label: { ThemeTile(t: t) }
                            .buttonStyle(.plain).disabled(runner.running)
                    }
                }
            }
            .padding(24)
        }
        .task { await store.refreshThemes() }
    }
}

struct ThemeTile: View {
    let t: Theme
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(Color(hex: t.background))
                if let p = t.preview, let img = NSImage(contentsOfFile: p) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .frame(height: 124).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(t.current ? Color(hex: t.accent) : .clear, lineWidth: 3))
            HStack(spacing: 6) {
                Circle().fill(Color(hex: t.accent)).frame(width: 10, height: 10)
                Text(t.title).font(.callout.weight(t.current ? .semibold : .regular))
                Spacer()
                Text(t.mode).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
