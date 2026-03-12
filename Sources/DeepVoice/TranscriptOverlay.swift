import AppKit
import Combine
import SwiftUI

private let transcriptVisibilityKey = "transcriptVisible"

struct TranscriptEntry: Identifiable {
    let id = UUID()
    let role: String
    var text: String
    var isFinal: Bool

    var isUser: Bool { role == "user" }

    static func merge(
        into entries: inout [TranscriptEntry],
        role: String, text: String, isFinal: Bool,
        maxEntries: Int
    ) {
        if let last = entries.last, last.role == role, !last.isFinal {
            entries[entries.count - 1].text = text
            entries[entries.count - 1].isFinal = isFinal
        } else {
            entries.append(TranscriptEntry(role: role, text: text, isFinal: isFinal))
        }
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }
}

@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var entries: [TranscriptEntry] = []
    @Published var isVisible: Bool {
        didSet { UserDefaults.standard.set(isVisible, forKey: transcriptVisibilityKey) }
    }

    private static let maxEntries = 20
    private var defaultsObserver: AnyCancellable?

    init() {
        isVisible = UserDefaults.standard.bool(forKey: transcriptVisibilityKey)
        defaultsObserver = UserDefaults.standard
            .publisher(for: \.transcriptVisible)
            .receive(on: RunLoop.main)
            .sink { [weak self] newValue in
                guard let self, self.isVisible != newValue else { return }
                self.isVisible = newValue
            }
    }

    func handleTranscript(role: String, text: String, isFinal: Bool) {
        TranscriptEntry.merge(into: &entries, role: role, text: text, isFinal: isFinal, maxEntries: Self.maxEntries)
    }

    func clear() {
        entries.removeAll()
    }
}

extension UserDefaults {
    @objc dynamic var transcriptVisible: Bool {
        bool(forKey: transcriptVisibilityKey)
    }
}

struct TranscriptOverlay: View {
    @ObservedObject var store: TranscriptStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(store.entries) { entry in
                        TranscriptBubble(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: store.entries.count) { _, _ in
                if let last = store.entries.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(width: 260, height: 200)
        .background(.ultraThinMaterial.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TranscriptBubble: View {
    let entry: TranscriptEntry

    var body: some View {
        HStack {
            if !entry.isUser { Spacer(minLength: 20) }
            Text(entry.text)
                .font(.system(size: 12))
                .foregroundStyle(entry.isFinal ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if entry.isUser { Spacer(minLength: 20) }
        }
    }

    private var bubbleBackground: some ShapeStyle {
        entry.isUser
            ? AnyShapeStyle(Color.accentColor.opacity(0.15))
            : AnyShapeStyle(Color(white: 0.5, opacity: 0.12))
    }
}
