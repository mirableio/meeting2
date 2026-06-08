import AppKit
import SwiftUI

struct RecordingsWindowView: View {
    @ObservedObject var viewModel: RecordingsLibraryViewModel
    @State private var itemPendingDelete: LibraryItem?
    @FocusState private var listFocused: Bool

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { keyboardShortcuts }
            .confirmationDialog(
                "Delete this recording?",
                isPresented: Binding(
                    get: { itemPendingDelete != nil },
                    set: { if !$0 { itemPendingDelete = nil } }
                ),
                presenting: itemPendingDelete
            ) { item in
                Button("Move to Trash", role: .destructive) {
                    viewModel.delete(item)
                    itemPendingDelete = nil
                }
                Button("Cancel", role: .cancel) { itemPendingDelete = nil }
            } message: { item in
                Text("“\(item.name)” will be moved to the Trash. You can restore it from there.")
            }
    }

    @ViewBuilder private var content: some View {
        let sections = viewModel.visibleSections
        if sections.isEmpty {
            ContentUnavailableView {
                Label(viewModel.items.isEmpty ? "No recordings yet" : "Nothing matches", systemImage: "waveform")
            } description: {
                Text(viewModel.items.isEmpty
                    ? "Start one from the menu bar."
                    : "Try a different search or filter.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                            RecordingRow(item: item, viewModel: viewModel, isEven: index.isMultiple(of: 2)) { itemPendingDelete = $0 }
                                .id(item.id)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets()) // remove the List's default row gap
                        }
                    }
                }
            }
            .listStyle(.inset)
            // There's no selection — the hovered row is the active one. The List is focusable only
            // so Return reaches the handler below (rename the row under the cursor).
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onAppear { listFocused = true }
            .onKeyPress(.return) {
                guard viewModel.renamingID == nil, let id = viewModel.hoveredID else { return .ignored }
                viewModel.renamingID = id
                return .handled
            }
        }
    }

    // ⌘O / ⌘⌫ as invisible buttons: in SwiftUI a `.keyboardShortcut` has to live on a control, so
    // these sit (transparent) in the view tree purely to own the shortcuts. They act on the hovered
    // (active) row, same as Return.
    @ViewBuilder private var keyboardShortcuts: some View {
        ZStack {
            Button("") { openHovered() }
                .keyboardShortcut("o", modifiers: .command)
            Button("") { deleteHovered() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func openHovered() {
        guard let item = viewModel.hoveredItem else { return }
        if item.hasTranscript { viewModel.openTranscript(item) } else { viewModel.openFolder(item) }
    }

    private func deleteHovered() {
        guard let item = viewModel.hoveredItem, !item.isBusy, viewModel.renamingID == nil else { return }
        itemPendingDelete = item
    }
}

/// One recording's row. There is no selection: the row under the cursor is the "active" one — it
/// shows the hover ring and the floating action pill, and the window's keyboard shortcuts all act
/// on it. Double-click renames inline; right-click opens the AppKit menu (see `RightClickMenu`).
private struct RecordingRow: View {
    let item: LibraryItem
    @ObservedObject var viewModel: RecordingsLibraryViewModel
    let isEven: Bool
    let onRequestDelete: (LibraryItem) -> Void

    @State private var draftName = ""
    @State private var isHovered = false
    @FocusState private var nameFocused: Bool

    private var isRenaming: Bool { viewModel.renamingID == item.id }

    var body: some View {
        HStack(spacing: 10) {
            statusIndicator
            nameView
            if let seconds = item.durationSeconds, seconds > 0 {
                Text(Self.duration(seconds)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(item.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        // Inset the content so the full-width stripe / hover highlight extends past the dot and
        // time rather than hugging them.
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background { rowBackground }
        // The action pill floats on top of the row, so it reserves no layout space — the trailing
        // area doesn't stay blank when the window is wide. Padded well in from the right edge so it
        // usually lands on the empty gap left of the time rather than over it.
        .overlay(alignment: .trailing) {
            hoverPill
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 0.96, anchor: .trailing)
                .allowsHitTesting(isHovered)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .padding(.trailing, 52)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            // `isHovered` is local — it drives this row's ring and pill. `hoveredID` is shared on
            // the view-model — it's the "active row" the keyboard shortcuts target. Only clear the
            // shared one if we're still the row that set it (the next row sets it before we exit).
            isHovered = hovering
            if hovering { viewModel.hoveredID = item.id }
            else if viewModel.hoveredID == item.id { viewModel.hoveredID = nil }
        }
        .onTapGesture(count: 2) { viewModel.renamingID = item.id }
        // Right-click menu via AppKit, not SwiftUI's `.contextMenu`, which would draw its own row
        // selection highlight that clashes with our hover ring.
        .overlay(RightClickMenu(items: contextMenuItems))
    }

    // Full-width zebra stripe on even rows (`primary` so it inverts sensibly in dark mode); on
    // hover, just an inset rounded accent-colour border rather than a fill.
    @ViewBuilder private var rowBackground: some View {
        ZStack {
            if isEven { Color.primary.opacity(0.035) }
            if isHovered {
                // The only highlight: an accent-colour ring on the row under the cursor.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
            }
        }
    }

    @ViewBuilder private var nameView: some View {
        if isRenaming {
            TextField("Name", text: $draftName)
                .textFieldStyle(.plain)
                .fontWeight(.medium)
                .focused($nameFocused)
                .onAppear { draftName = item.name; nameFocused = true }
                .onSubmit(commitRename)
                .onExitCommand { viewModel.renamingID = nil }
                // Clicking outside ends editing without Return; commit like Finder so the field
                // doesn't linger and leave the duration/time shifted right.
                .onChange(of: nameFocused) { _, focused in
                    if !focused, isRenaming { commitRename() }
                }
        } else {
            Text(item.name).fontWeight(.medium).lineLimit(1)
        }
    }

    // A subtle outlined dot, colour-coded by status (spinner while transcribing). Hover it for
    // the status word.
    @ViewBuilder private var statusIndicator: some View {
        Group {
            if item.status == .transcribing {
                ProgressView().controlSize(.mini)
            } else {
                Circle().strokeBorder(dotColor, lineWidth: dotLineWidth).frame(width: 9, height: 9)
            }
        }
        .frame(width: 14, height: 14)
        .contentShape(Rectangle())
        .help(item.statusLabel)
    }

    private var dotColor: Color {
        switch item.status {
        case .recording: return .red
        case .transcribed: return .green
        case .failed, .needsAttention: return .orange
        case .transcribing, .notTranscribed: return .secondary
        }
    }

    // The red recording ring reads heavier than the muted dots, so draw it a touch thinner.
    private var dotLineWidth: CGFloat {
        item.status == .recording ? 0.85 : 1
    }

    private var hoverPill: some View {
        HStack(spacing: 2) {
            pillButton("doc.text", "Open transcript", enabled: item.hasTranscript) { viewModel.openTranscript(item) }
            pillButton("folder", "Show in Finder", enabled: true) { viewModel.openFolder(item) }
            Menu {
                pillMenu
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .modifier(IconHover())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 5, y: 1)
    }

    @ViewBuilder private func pillButton(_ symbol: String, _ tip: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .modifier(IconHover())
        }
        .buttonStyle(.plain)
        .help(tip)
        .disabled(!enabled)
    }

    /// The pill's ••• menu: omits Open Transcript / Show in Finder — those are the pill's two
    /// icons right next to it.
    @ViewBuilder private var pillMenu: some View {
        Button("Rename") { viewModel.renamingID = item.id }
        Button("Re-transcribe") { viewModel.reTranscribe(item) }
            .disabled(item.isBusy)
        Divider()
        Button(role: .destructive) { onRequestDelete(item) } label: {
            // macOS doesn't tint destructive *menu* items, so colour the label explicitly.
            Text("Move to Trash").foregroundStyle(.red)
        }
        .disabled(item.isBusy)
    }

    /// The right-click menu: the full set (there are no icons there to duplicate).
    private var contextMenuItems: [RightClickMenu.Item] {
        [
            .button(title: "Open Transcript", enabled: item.hasTranscript) { viewModel.openTranscript(item) },
            .button(title: "Show in Finder", enabled: true) { viewModel.openFolder(item) },
            .separator,
            .button(title: "Rename", enabled: true) { viewModel.renamingID = item.id },
            .button(title: "Re-transcribe", enabled: !item.isBusy) { viewModel.reTranscribe(item) },
            .separator,
            .button(title: "Move to Trash", enabled: !item.isBusy, destructive: true) { onRequestDelete(item) },
        ]
    }

    private func commitRename() {
        viewModel.rename(item, to: draftName)
        viewModel.renamingID = nil
    }

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total / 60) % 60, secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(secs)s"
    }
}

/// Presents a right-click `NSMenu` without SwiftUI `.contextMenu`'s row-selection highlight (which
/// clashed with our hover ring). A transparent overlay claims only right-/control-clicks — every
/// other event passes straight through to the row's own buttons and gestures.
private struct RightClickMenu: NSViewRepresentable {
    enum Item {
        case button(title: String, enabled: Bool, destructive: Bool = false, action: () -> Void)
        case separator
    }

    var items: [Item]

    func makeNSView(context: Context) -> NSView { ClickThroughMenuView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ClickThroughMenuView)?.items = items
    }

    private final class ClickThroughMenuView: NSView {
        var items: [Item] = []

        override func hitTest(_ point: NSPoint) -> NSView? {
            // hitTest gets no event, so read the one being dispatched. Claim it only if it's a
            // right- or control-click; returning nil for everything else lets normal clicks,
            // hovers, and the pill buttons reach the SwiftUI row underneath.
            guard let event = NSApp.currentEvent else { return nil }
            let isContextClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isContextClick ? self : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items {
                switch item {
                case .separator:
                    menu.addItem(.separator())
                case let .button(title, enabled, destructive, action):
                    let menuItem = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
                    menuItem.target = self
                    menuItem.isEnabled = enabled
                    menuItem.representedObject = Handler(action)
                    if destructive {
                        menuItem.attributedTitle = NSAttributedString(
                            string: title, attributes: [.foregroundColor: NSColor.systemRed]
                        )
                    }
                    menu.addItem(menuItem)
                }
            }
            return menu
        }

        @objc private func invoke(_ sender: NSMenuItem) {
            (sender.representedObject as? Handler)?.action()
        }
    }

    private final class Handler {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }
}

/// A subtle rounded background under an icon while the mouse is over it, so each pill action
/// visibly highlights on hover (borderless buttons give no hover feedback otherwise).
private struct IconHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? Color.secondary.opacity(0.22) : .clear)
            )
            .onHover { hovering = $0 }
    }
}
