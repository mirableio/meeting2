import AppKit
import SwiftUI

private extension NSToolbarItem.Identifier {
    static let recordingsFilter = NSToolbarItem.Identifier("recordingsFilter")
    static let recordingsSearch = NSToolbarItem.Identifier("recordingsSearch")
}

/// Owns the single recordings window: a native unified toolbar (filter + search) over a SwiftUI
/// list. Also owns — entirely here, on every close path — the `.regular`⇄`.accessory` activation
/// flip, so the window behaves like a normal app window while open and the app is pure menu-bar
/// when it's closed.
@MainActor
final class RecordingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    private let viewModel: RecordingsLibraryViewModel
    private var window: NSWindow?
    private weak var filterSegmented: NSSegmentedControl?
    private var filterMenu: NSMenu?

    init(viewModel: RecordingsLibraryViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        let window = existingOrNewWindow()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        viewModel.startAutoRefresh()
        Task { await viewModel.reload() }
    }

    private func existingOrNewWindow() -> NSWindow {
        if let window { return window }

        let hosting = NSHostingController(rootView: RecordingsWindowView(viewModel: viewModel))
        // Don't let SwiftUI content drive the window size (it otherwise shrinks to a short list).
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "Recordings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 580))
        window.minSize = NSSize(width: 480, height: 360)
        window.center()
        window.setFrameAutosaveName("RecordingsWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self

        let toolbar = NSToolbar(identifier: "RecordingsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly  // no "Filter" / "Search" captions under the items
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.stopAutoRefresh()
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Toolbar (native filter segmented control + search field)

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.recordingsFilter, .flexibleSpace, .recordingsSearch]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.recordingsFilter, .flexibleSpace, .recordingsSearch]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .recordingsFilter:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let segmented = NSSegmentedControl(
                labels: LibraryFilter.allCases.map(\.rawValue),
                trackingMode: .selectOne,
                target: self,
                action: #selector(filterChanged(_:))
            )
            segmented.selectedSegment = LibraryFilter.allCases.firstIndex(of: viewModel.filter) ?? 0
            item.view = segmented
            item.label = "Filter"
            filterSegmented = segmented

            // When the toolbar collapses, NSToolbar uses this menu form instead of the segmented
            // control — a real, selectable submenu (the segmented control isn't usable in the
            // ">>" overflow).
            let menuItem = NSMenuItem(title: "Filter", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (index, filter) in LibraryFilter.allCases.enumerated() {
                let entry = NSMenuItem(title: filter.rawValue, action: #selector(filterMenuChanged(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = index
                entry.state = (filter == viewModel.filter) ? .on : .off
                submenu.addItem(entry)
            }
            menuItem.submenu = submenu
            item.menuFormRepresentation = menuItem
            filterMenu = submenu
            return item
        case .recordingsSearch:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.delegate = self
            return item
        default:
            return nil
        }
    }

    @objc private func filterChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0, index < LibraryFilter.allCases.count else { return }
        applyFilter(LibraryFilter.allCases[index])
    }

    @objc private func filterMenuChanged(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < LibraryFilter.allCases.count else { return }
        applyFilter(LibraryFilter.allCases[sender.tag])
    }

    private func applyFilter(_ filter: LibraryFilter) {
        viewModel.filter = filter
        let index = LibraryFilter.allCases.firstIndex(of: filter) ?? 0
        filterSegmented?.selectedSegment = index
        filterMenu?.items.enumerated().forEach { $1.state = ($0 == index) ? .on : .off }
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSSearchField {
            viewModel.searchText = field.stringValue
        }
    }

    // Esc in the search field resigns first responder (defocus) instead of NSSearchField's
    // default, which only consumes the key. The typed text is kept.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            control.window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}
