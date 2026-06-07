import AppKit
import Combine
import Meeting2Core

/// Owns the menu-bar item. We use AppKit's `NSStatusItem` rather than SwiftUI's
/// `MenuBarExtra` for two reasons the design needs and `MenuBarExtra` can't give:
///
///  - **Colour + animation.** `MenuBarExtra` force-templates its label to monochrome, so
///    a red dot showed up white. A non-template `NSImage` keeps its colour, and redrawing
///    it each frame lets the recording dot *breathe* with the audio level.
///  - **Live, but no flicker.** The dropdown is built before it opens and then refreshed
///    while open — but only when its *content* actually changes (a signature check), so a
///    real event (a stop, a warning, "Transcribed …") shows immediately while no-op ticks
///    (the elapsed second) never rebuild it. We have to poll for this because macOS
///    suspends the default run-loop mode during menu tracking, so the usual change
///    notifications don't fire while the menu is down.
///
/// All state and actions live in `RecorderMenuController`; this class is pure presentation.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let controller: RecorderMenuController
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var changeSubscription: AnyCancellable?
    private var breathTimer: Timer?
    private var currentScale: CGFloat = 1
    private var breathPhase: CGFloat = 0
    private var pulsePhase: CGFloat = 0
    private var pulseColor: NSColor = .systemGreen
    private var pulseLevel: CGFloat = 0  // 0 = neutral, 1 = full green; eased on success
    private var menuRefreshTimer: Timer?
    private var lastMenuSignature = ""
    private weak var statusHeaderItem: NSMenuItem?
    private static let breathFPS: CGFloat = 30
    private static let breathPeriodSeconds: CGFloat = 4.5
    private static let breathAmplitude: CGFloat = 0.12
    // The processing pulse is faster than the breath so it reads as "working", not "resting".
    private static let pulsePeriodSeconds: CGFloat = 1.2
    // How fast the success state eases the pulse up to full green (per frame). Quick enough
    // to feel like the pulse settling into green, slow enough not to snap.
    private static let successEase: CGFloat = 0.18

    init(controller: RecorderMenuController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.imageHugsTitle = true  // keep the digits snug to the dot
        // Small monospaced digits — the timer is secondary to the dot.
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 8, weight: .regular)
        menu.delegate = self
        // Manage enabled-state explicitly. With autoenablesItems, the disabled (greyed)
        // status headers come back *enabled* when we rebuild the menu live while it's open,
        // because the auto-validation pass only runs on the normal open cycle.
        menu.autoenablesItems = false
        statusItem.menu = menu

        // Redraw the icon whenever the controller's state changes. `objectWillChange`
        // fires *before* the change applies; `receive(on:)` defers the read to the next
        // run-loop turn, by which point the new values are in place.
        changeSubscription = controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshButton() }
            }

        refreshButton()
    }

    // MARK: - Icon

    private func refreshButton() {
        guard let button = statusItem.button else { return }
        button.image = iconImage()
        let title = controller.menuBarTitle
        button.title = title

        // The icon animates while recording (size breathing), while processing (colour
        // pulse), and through the success ease-and-hold. Everything else is a static frame.
        switch controller.iconState {
        case .recording, .recordingWarning, .processing, .success:
            startAnimating()
        default:
            stopAnimating()
        }
    }

    private func iconImage() -> NSImage {
        switch controller.iconState {
        case .idle:
            return circleImage(scale: 1, color: .labelColor, template: true)
        case .transitioning:
            return circleImage(scale: 1, color: .secondaryLabelColor, template: true)
        case .attention:
            return attentionImage()
        case .recording:
            return circleImage(scale: currentScale, color: .systemRed, template: false)
        case .recordingWarning:
            return circleImage(scale: currentScale, color: .systemOrange, template: false)
        case .processing, .success:
            // `pulseColor` is animated by the timer: oscillating while processing, then
            // eased up to full green and held during the success state.
            return circleImage(scale: 1, color: pulseColor, template: false)
        }
    }

    /// A thin stroked circle. `template: true` lets the system tint it to the menu bar
    /// (adaptive white/black) for the neutral idle look; `false` keeps the given colour.
    /// The image box is fixed so the status item never changes width as the circle
    /// breathes; the circle is drawn with headroom so it can expand without clipping.
    /// A drawing handler (re-invoked per scale factor) keeps it crisp on Retina.
    private func circleImage(scale: CGFloat, color: NSColor, template: Bool) -> NSImage {
        // Keep the transparent margin around the circle small so the dot sits close to
        // both the menu-bar edge and the timer digits — just enough headroom for the
        // breathing peak. (If the breath amplitude grows, widen this to avoid clipping.)
        let box: CGFloat = 16
        let lineWidth: CGFloat = 1.3
        let baseDiameter: CGFloat = 13

        let image = NSImage(size: NSSize(width: box, height: box), flipped: false) { _ in
            let diameter = baseDiameter * scale
            let rect = NSRect(x: (box - diameter) / 2, y: (box - diameter) / 2, width: diameter, height: diameter)
                .insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = lineWidth
            color.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = template
        return image
    }

    /// The processing pulse colour: green fading toward the idle ring's neutral colour and
    /// back. The neutral endpoint is `.labelColor`, but it must be resolved in the **status
    /// button's** appearance (the menu bar's — white on a dark bar) rather than the app's,
    /// which can differ and render the low end black while the idle icon is white. We flatten
    /// the dynamic colour under that appearance, then blend, so the stroke is a concrete
    /// colour that draws the same regardless of where the image is later composited.
    private func pulseStrokeColor(intensity: CGFloat) -> NSColor {
        var neutral = NSColor.labelColor
        if let appearance = statusItem.button?.effectiveAppearance {
            appearance.performAsCurrentDrawingAppearance {
                neutral = NSColor.labelColor.usingColorSpace(.sRGB) ?? NSColor.labelColor
            }
        }
        return NSColor.systemGreen.blended(withFraction: 1 - intensity, of: neutral) ?? .systemGreen
    }

    private func attentionImage() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
        let image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Attention")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }

    // MARK: - Icon animation

    private func startAnimating() {
        guard breathTimer == nil else { return }
        // Added to common modes so it keeps animating (and ticking the timer) even while
        // the menu is open.
        let timer = Timer(timeInterval: 1.0 / Double(Self.breathFPS), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickAnimation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        breathTimer = timer
    }

    private func stopAnimating() {
        breathTimer?.invalidate()
        breathTimer = nil
        if currentScale != 1 {
            currentScale = 1
            statusItem.button?.image = iconImage()
        }
    }

    private func tickAnimation() {
        switch controller.iconState {
        case .recording, .recordingWarning:
            // A slow, symmetric breath around the resting size: grows a little, then shrinks
            // a little below default — like breathing in and out. Steady and gentle, not
            // driven by audio (that read as a twitch); just a calm "recording" pulse. The
            // sine is continuous, so no easing is needed.
            breathPhase += (2 * .pi) / (Self.breathPeriodSeconds * Self.breathFPS)
            if breathPhase > 2 * .pi { breathPhase -= 2 * .pi }
            currentScale = 1.0 + sin(breathPhase) * Self.breathAmplitude
        case .processing:
            // Fade the stroke between green and the idle ring's neutral colour and back.
            // Same size as idle — only the colour moves, so it reads as "thinking" not
            // "recording".
            pulsePhase += (2 * .pi) / (Self.pulsePeriodSeconds * Self.breathFPS)
            if pulsePhase > 2 * .pi { pulsePhase -= 2 * .pi }
            pulseLevel = (sin(pulsePhase) + 1) / 2  // 0…1
            pulseColor = pulseStrokeColor(intensity: pulseLevel)
        case .success:
            // Don't snap to green: ease the pulse up from wherever it was to full green, so
            // the switch reads as the pulse settling, then hold green for the success window.
            pulseLevel += (1 - pulseLevel) * Self.successEase
            pulseColor = pulseStrokeColor(intensity: pulseLevel)
        default:
            break
        }

        statusItem.button?.image = iconImage()
        // Keep the menu-bar timer ticking even while the menu is open: this timer runs in
        // common run-loop modes, whereas the state-driven title refresh is paused during
        // menu tracking.
        statusItem.button?.title = controller.menuBarTitle
    }

    // MARK: - Menu

    /// Build the menu just before it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    /// While the menu is open, macOS suspends the default run-loop mode, so our usual
    /// state-change notifications don't fire. Poll on a common-mode timer instead and
    /// rebuild only when the content signature changes — live updates without per-tick
    /// flicker. (Also refreshes the icon/title for the same suspended-mode reason.)
    func menuWillOpen(_ menu: NSMenu) {
        lastMenuSignature = menuSignature()
        menuRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOpenMenu() }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuRefreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
    }

    private func refreshOpenMenu() {
        refreshButton()
        let signature = menuSignature()
        if signature != lastMenuSignature {
            lastMenuSignature = signature
            populate(menu)
        }
        // The transcription clock ticks even when nothing else changed, so update it on the
        // header item directly rather than via the (signature-gated) full rebuild.
        updateHeaderElapsedInPlace()
    }

    /// Everything the menu *shows* (deliberately excluding the ticking timer, which isn't
    /// in the menu). A change here is a real, user-visible difference worth rebuilding for.
    private func menuSignature() -> String {
        [
            controller.menuStatusHeader,
            controller.canStart ? "start" : "",
            controller.canStop ? "stop" : "",
            controller.attention.map(\.id).joined(separator: ","),
            (controller.currentFolder != nil || controller.lastFolder != nil) ? "reveal" : "",
            controller.isRecording ? "rec" : "",
            // Include the bullet so the open menu rebuilds when work starts/ends, even if the
            // header text alone didn't change.
            headerBulletColor?.description ?? ""
        ].joined(separator: "|")
    }

    /// The ● colour for the menu header, matching the menu-bar icon state. Success has no
    /// bullet — its green "✓ …" header already reads as a positive result.
    private var headerBulletColor: NSColor? {
        switch controller.iconState {
        case .recording: return .systemRed
        case .recordingWarning: return .systemOrange
        case .processing: return .systemGreen
        case .idle, .attention, .transitioning, .success: return nil
        }
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Lead the header with a coloured ● that mirrors the menu-bar dot: red/orange while
        // recording, green while processing or just after success. Idle has no bullet. We keep
        // a reference so the transcription clock can tick the header in place (see below).
        let headerItem = header(renderedHeaderTitle(), bulletColor: headerBulletColor)
        statusHeaderItem = headerItem
        menu.addItem(headerItem)
        menu.addItem(.separator())

        // Primary action: only the one that applies. ⌃⌘R mirrors the global hotkey.
        // A red ● fronts Start so the "record" affordance reads at a glance, echoing the
        // dot the header shows once recording is live.
        if controller.canStart {
            menu.addItem(action(
                "Start Recording",
                #selector(startRecording),
                key: "r",
                mask: [.command, .control],
                bulletColor: .systemRed
            ))
        } else if controller.canStop {
            menu.addItem(action("Stop Recording", #selector(stopRecording), key: "r", mask: [.command, .control]))
        }

        // A problem promotes its fix to first-class actions.
        for item in controller.attention {
            switch item {
            case .transcriptionFailed:
                menu.addItem(action("Retry Transcription", #selector(retryTranscription)))
            case .startFailed:
                menu.addItem(action("Try Again", #selector(startRecording)))
            case .permissionMissing:
                menu.addItem(action("Open Privacy Settings…", #selector(openPrivacySettings)))
            }
            let dismiss = action("Dismiss", #selector(dismissAttentionItem(_:)))
            dismiss.representedObject = item
            menu.addItem(dismiss)
        }

        menu.addItem(.separator())

        if controller.currentFolder != nil || controller.lastFolder != nil {
            let title = controller.isRecording ? "Reveal Current Recording" : "Reveal Last Recording"
            menu.addItem(action(title, #selector(revealRecording)))
        }
        menu.addItem(action("Open Recordings Folder", #selector(openRecordingsFolder)))
        if !controller.isRecording {
            menu.addItem(action("Transcribe Pending Recordings", #selector(transcribePending)))
        }

        menu.addItem(.separator())
        menu.addItem(action("Quit Meeting2", #selector(quit), key: "q", mask: [.command]))
    }

    /// A dimmed, non-interactive status line. `isEnabled = false` (with autoenablesItems
    /// off) keeps it greyed and unhighlightable even when rebuilt live. An optional
    /// `bulletColor` prepends a coloured ●, and a leading "✓ " success mark is tinted green
    /// so a completed run reads as a positive result, not just more grey text.
    private func header(_ title: String, bulletColor: NSColor? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = headerAttributedTitle(title, bulletColor: bulletColor)
        return item
    }

    private func headerAttributedTitle(_ title: String, bulletColor: NSColor?) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        if let bulletColor {
            attributed.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: bulletColor]))
        }

        let successMark = "✓ "
        if title.hasPrefix(successMark) {
            attributed.append(NSAttributedString(
                string: successMark,
                attributes: [.foregroundColor: NSColor.systemGreen]
            ))
            attributed.append(NSAttributedString(
                string: String(title.dropFirst(successMark.count)),
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]
            ))
        } else {
            attributed.append(NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]
            ))
        }

        return attributed
    }

    /// The header text: the controller's status line, plus — while transcribing — how long
    /// it's been running. The elapsed part is deliberately kept OUT of `menuSignature`, so
    /// the clock ticks the header in place (`updateHeaderElapsedInPlace`) instead of
    /// rebuilding the whole menu every second (which would flicker the rest of the items).
    private func renderedHeaderTitle() -> String {
        var title = controller.menuStatusHeader
        if let elapsed = controller.transcribingElapsedText {
            title += "  \(elapsed)"
        }
        return title
    }

    private func updateHeaderElapsedInPlace() {
        guard controller.processingActivity == .transcribing, let item = statusHeaderItem else { return }
        let title = renderedHeaderTitle()
        guard title != item.attributedTitle?.string else { return }
        item.attributedTitle = headerAttributedTitle(title, bulletColor: headerBulletColor)
    }

    private func action(
        _ title: String,
        _ selector: Selector,
        key: String = "",
        mask: NSEvent.ModifierFlags = [],
        bulletColor: NSColor? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        if !key.isEmpty { item.keyEquivalentModifierMask = mask }
        if let bulletColor {
            // Unlike the header, this row is enabled, so keep the label in the normal
            // label colour (only the ● is tinted) and let AppKit handle highlighting.
            let attributed = NSMutableAttributedString(
                string: "● ",
                attributes: [.foregroundColor: bulletColor]
            )
            attributed.append(NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.labelColor]
            ))
            item.attributedTitle = attributed
        }
        return item
    }

    // MARK: - Menu actions (forward to the controller)

    @objc private func startRecording() { controller.startRecording() }
    @objc private func stopRecording() { controller.stopRecording() }
    @objc private func retryTranscription() { controller.retryTranscription() }
    @objc private func openPrivacySettings() { controller.openPrivacySettings() }
    @objc private func revealRecording() { controller.revealCurrentOrLastRecording() }
    @objc private func openRecordingsFolder() { controller.openRecordingsFolder() }
    @objc private func transcribePending() { controller.transcribePendingRecordings() }
    @objc private func quit() { controller.quit() }

    @objc private func dismissAttentionItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? Attention else { return }
        controller.dismissAttention(item)
    }
}
