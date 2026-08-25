import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ScreenCaptureKit

extension Notification.Name {
    static let beginHoverScreenshot = Notification.Name("GSD.beginHoverScreenshot")
}

/// Captures a screen region without requiring the pointer to move. The captured
/// image only lives in memory until it is copied or discarded.
final class HoverScreenshotController {
    private let selectionHotKeys = HotKeyManager()
    private let previewHotKeys = HotKeyManager()

    private var selectionWindow: NSPanel?
    private var previewWindow: NSPanel?
    private var selectionView: CaptureSelectionView?
    private var selectedScreen: NSScreen?
    private var selectionRect = NSRect.zero
    private var frozenImage: CGImage?
    private var selectionTokens: [UInt32] = []
    private var previewTokens: [UInt32] = []
    private var pendingImage: NSImage?
    private var discardTask: DispatchWorkItem?
    private var presetIndex = 1

    private let presets = [
        NSSize(width: 360, height: 240),
        NSSize(width: 640, height: 400),
        NSSize(width: 960, height: 640),
    ]

    func beginCapture() {
        dispatchPrecondition(condition: .onQueue(.main))

        if selectionWindow != nil {
            cancelSelection()
            return
        }

        discardPreview()

        guard hasScreenCapturePermission() else { return }
        freezeScreen()
    }

    private func hasScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if CGRequestScreenCaptureAccess() { return true }

        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Needed"
        alert.informativeText =
            "Allow GSD in System Settings > Privacy & Security > Screen Recording, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
        {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    // MARK: Selection

    private func freezeScreen() {
        let pointer = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
                ?? NSScreen.main
        else { return }

        capture(rect: screen.frame, on: screen) { [weak self] image in
            guard let self else { return }
            guard let image else {
                NSSound.beep()
                return
            }
            self.showSelection(on: screen, pointer: pointer, frozenImage: image)
        }
    }

    private func showSelection(on screen: NSScreen, pointer: NSPoint, frozenImage: CGImage) {
        selectedScreen = screen
        self.frozenImage = frozenImage
        presetIndex = min(presetIndex, presets.count - 1)
        selectionRect = rectCentered(at: pointer, size: presets[presetIndex], in: screen.frame)

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]

        let displayImage = NSImage(cgImage: frozenImage, size: screen.frame.size)
        let overlay = CaptureSelectionView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            frozenImage: displayImage
        )
        overlay.selectionRect = localSelectionRect(for: screen)
        overlay.onSelectionChanged = { [weak self] localRect in
            self?.setSelection(localRect: localRect, on: screen)
        }
        overlay.onSelectionCompleted = { [weak self] localRect in
            guard let self else { return }
            self.setSelection(localRect: localRect, on: screen)
            self.captureSelection()
        }
        panel.contentView = overlay

        selectionWindow = panel
        selectionView = overlay
        registerSelectionHotKeys()
        panel.orderFrontRegardless()
    }

    private func registerSelectionHotKeys() {
        registerSelectionKey(UInt32(kVK_Return), modifiers: 0) { [weak self] in
            self?.captureSelection()
        }
        registerSelectionKey(UInt32(kVK_ANSI_KeypadEnter), modifiers: 0) { [weak self] in
            self?.captureSelection()
        }
        registerSelectionKey(UInt32(kVK_Escape), modifiers: 0) { [weak self] in
            self?.cancelSelection()
        }
        registerSelectionKey(UInt32(kVK_Space), modifiers: 0) { [weak self] in
            self?.cyclePreset()
        }

        registerArrowKeys(modifiers: 0, step: 12)
        registerArrowKeys(modifiers: UInt32(optionKey), step: 1)

        registerSelectionKey(UInt32(kVK_LeftArrow), modifiers: UInt32(shiftKey)) {
            [weak self] in self?.resizeSelection(width: -24, height: 0)
        }
        registerSelectionKey(UInt32(kVK_RightArrow), modifiers: UInt32(shiftKey)) {
            [weak self] in self?.resizeSelection(width: 24, height: 0)
        }
        registerSelectionKey(UInt32(kVK_UpArrow), modifiers: UInt32(shiftKey)) {
            [weak self] in self?.resizeSelection(width: 0, height: 24)
        }
        registerSelectionKey(UInt32(kVK_DownArrow), modifiers: UInt32(shiftKey)) {
            [weak self] in self?.resizeSelection(width: 0, height: -24)
        }
    }

    private func registerArrowKeys(modifiers: UInt32, step: CGFloat) {
        registerSelectionKey(UInt32(kVK_LeftArrow), modifiers: modifiers) { [weak self] in
            self?.moveSelection(dx: -step, dy: 0)
        }
        registerSelectionKey(UInt32(kVK_RightArrow), modifiers: modifiers) { [weak self] in
            self?.moveSelection(dx: step, dy: 0)
        }
        registerSelectionKey(UInt32(kVK_UpArrow), modifiers: modifiers) { [weak self] in
            self?.moveSelection(dx: 0, dy: step)
        }
        registerSelectionKey(UInt32(kVK_DownArrow), modifiers: modifiers) { [weak self] in
            self?.moveSelection(dx: 0, dy: -step)
        }
    }

    private func registerSelectionKey(
        _ keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping () -> Void
    ) {
        if let token = selectionHotKeys.register(
            keyCode: keyCode,
            modifiers: modifiers,
            handler: handler
        ) {
            selectionTokens.append(token)
        }
    }

    private func moveSelection(dx: CGFloat, dy: CGFloat) {
        guard let screen = selectedScreen else { return }
        selectionRect.origin.x += dx
        selectionRect.origin.y += dy
        selectionRect = clamped(selectionRect, to: screen.frame)
        refreshSelectionOverlay()
    }

    private func resizeSelection(width: CGFloat, height: CGFloat) {
        guard let screen = selectedScreen else { return }

        let center = NSPoint(x: selectionRect.midX, y: selectionRect.midY)
        let maximum = screen.frame.insetBy(dx: 16, dy: 16).size
        let newSize = NSSize(
            width: min(max(selectionRect.width + width, 120), maximum.width),
            height: min(max(selectionRect.height + height, 80), maximum.height)
        )
        selectionRect = rectCentered(at: center, size: newSize, in: screen.frame)
        refreshSelectionOverlay()
    }

    private func cyclePreset() {
        guard let screen = selectedScreen else { return }
        presetIndex = (presetIndex + 1) % (presets.count + 1)

        let size: NSSize
        if presetIndex == presets.count {
            size = screen.frame.insetBy(dx: 16, dy: 16).size
        } else {
            size = presets[presetIndex]
        }
        selectionRect = rectCentered(
            at: NSPoint(x: selectionRect.midX, y: selectionRect.midY),
            size: size,
            in: screen.frame
        )
        refreshSelectionOverlay()
    }

    private func refreshSelectionOverlay() {
        guard let screen = selectedScreen else { return }
        selectionView?.selectionRect = localSelectionRect(for: screen)
        selectionView?.needsDisplay = true
    }

    private func captureSelection() {
        guard
            selectionWindow != nil,
            let screen = selectedScreen,
            let frozenImage
        else { return }

        let localRect = localSelectionRect(for: screen).intersection(
            NSRect(origin: .zero, size: screen.frame.size)
        )
        guard localRect.width >= 4, localRect.height >= 4 else { return }

        let scaleX = CGFloat(frozenImage.width) / screen.frame.width
        let scaleY = CGFloat(frozenImage.height) / screen.frame.height
        let pixelRect = CGRect(
            x: localRect.minX * scaleX,
            y: (screen.frame.height - localRect.maxY) * scaleY,
            width: localRect.width * scaleX,
            height: localRect.height * scaleY
        ).integral

        guard let croppedImage = frozenImage.cropping(to: pixelRect) else {
            NSSound.beep()
            return
        }

        let outputSize = localRect.size
        closeSelectionOverlay()
        let image = NSImage(cgImage: croppedImage, size: outputSize)
        showPreview(for: image, on: screen)
    }

    private func capture(
        rect: NSRect,
        on screen: NSScreen?,
        completion: @escaping (CGImage?) -> Void
    ) {
        if #available(macOS 14.0, *), let screen {
            captureWithScreenCaptureKit(rect: rect, on: screen) { [weak self] image in
                // Keep a legacy fallback for unusual display configurations and
                // for systems upgrading from the macOS 13 implementation.
                completion(image ?? self?.captureWithCoreGraphics(rect: rect))
            }
        } else {
            completion(captureWithCoreGraphics(rect: rect))
        }
    }

    @available(macOS 14.0, *)
    private func captureWithScreenCaptureKit(
        rect: NSRect,
        on screen: NSScreen,
        completion: @escaping (CGImage?) -> Void
    ) {
        guard
            let displayNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        else {
            completion(nil)
            return
        }

        let screenFrame = screen.frame
        let scale = screen.backingScaleFactor

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                guard
                    let display = content.displays.first(where: {
                        $0.displayID == CGDirectDisplayID(displayNumber.uint32Value)
                    })
                else {
                    await MainActor.run { completion(nil) }
                    return
                }

                let sourceRect = CGRect(
                    x: rect.minX - screenFrame.minX,
                    y: screenFrame.maxY - rect.maxY,
                    width: rect.width,
                    height: rect.height
                )
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = sourceRect
                configuration.width = Int(rect.width * scale)
                configuration.height = Int(rect.height * scale)
                configuration.showsCursor = true

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                await MainActor.run { completion(image) }
            } catch {
                await MainActor.run { completion(nil) }
            }
        }
    }

    private func captureWithCoreGraphics(rect: NSRect) -> CGImage? {
        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        let quartzRect = CGRect(
            x: rect.minX,
            y: mainDisplayHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )

        return CGWindowListCreateImage(
            quartzRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        )
    }

    private func cancelSelection() {
        closeSelectionOverlay()
    }

    private func closeSelectionOverlay() {
        selectionWindow?.orderOut(nil)
        selectionWindow = nil
        selectionView = nil
        selectedScreen = nil
        frozenImage = nil
        for token in selectionTokens {
            selectionHotKeys.unregister(token)
        }
        selectionTokens.removeAll()
    }

    // MARK: Ephemeral preview

    private func showPreview(for image: NSImage, on screen: NSScreen?) {
        discardPreview()
        pendingImage = image

        let imageRatio = max(image.size.width / max(image.size.height, 1), 0.25)
        let contentWidth: CGFloat = 440
        let imageHeight = min(max(contentWidth / imageRatio, 180), 360)
        let contentSize = NSSize(width: contentWidth, height: imageHeight + 72)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = CapturePreviewView(frame: NSRect(origin: .zero, size: contentSize), image: image)

        if let screen {
            let origin = NSPoint(
                x: screen.visibleFrame.midX - contentSize.width / 2,
                y: screen.visibleFrame.maxY - contentSize.height - 24
            )
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }

        previewWindow = panel
        registerPreviewHotKeys()
        panel.orderFrontRegardless()

        let task = DispatchWorkItem { [weak self] in
            self?.discardPreview()
        }
        discardTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: task)
    }

    private func registerPreviewHotKeys() {
        registerPreviewKey(UInt32(kVK_Return)) { [weak self] in
            self?.copyPreview()
        }
        registerPreviewKey(UInt32(kVK_ANSI_KeypadEnter)) { [weak self] in
            self?.copyPreview()
        }
        registerPreviewKey(UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey)) { [weak self] in
            self?.copyPreview()
        }
        registerPreviewKey(UInt32(kVK_Escape)) { [weak self] in
            self?.discardPreview()
        }
    }

    private func registerPreviewKey(
        _ keyCode: UInt32,
        modifiers: UInt32 = 0,
        handler: @escaping () -> Void
    ) {
        if let token = previewHotKeys.register(
            keyCode: keyCode,
            modifiers: modifiers,
            handler: handler
        ) {
            previewTokens.append(token)
        }
    }

    private func copyPreview() {
        guard let image = pendingImage, let data = image.tiffRepresentation else {
            discardPreview()
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .tiff)
        discardPreview()
        NSSound(named: "Tink")?.play()
    }

    private func discardPreview() {
        discardTask?.cancel()
        discardTask = nil
        previewWindow?.orderOut(nil)
        previewWindow = nil
        pendingImage = nil
        for token in previewTokens {
            previewHotKeys.unregister(token)
        }
        previewTokens.removeAll()
    }

    // MARK: Geometry

    private func localSelectionRect(for screen: NSScreen) -> NSRect {
        NSRect(
            x: selectionRect.minX - screen.frame.minX,
            y: selectionRect.minY - screen.frame.minY,
            width: selectionRect.width,
            height: selectionRect.height
        )
    }

    private func setSelection(localRect: NSRect, on screen: NSScreen) {
        selectionRect = NSRect(
            x: localRect.minX + screen.frame.minX,
            y: localRect.minY + screen.frame.minY,
            width: localRect.width,
            height: localRect.height
        )
    }

    private func rectCentered(at point: NSPoint, size: NSSize, in bounds: NSRect) -> NSRect {
        let available = bounds.insetBy(dx: 16, dy: 16)
        let fittedSize = NSSize(
            width: min(max(size.width, 120), available.width),
            height: min(max(size.height, 80), available.height)
        )
        let rect = NSRect(
            x: point.x - fittedSize.width / 2,
            y: point.y - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
        return clamped(rect, to: bounds)
    }

    private func clamped(_ rect: NSRect, to bounds: NSRect) -> NSRect {
        let available = bounds.insetBy(dx: 16, dy: 16)
        var result = rect
        result.size.width = min(result.width, available.width)
        result.size.height = min(result.height, available.height)
        result.origin.x = min(max(result.minX, available.minX), available.maxX - result.width)
        result.origin.y = min(max(result.minY, available.minY), available.maxY - result.height)
        return result
    }
}

private final class CaptureSelectionView: NSView {
    var selectionRect = NSRect.zero
    var onSelectionChanged: ((NSRect) -> Void)?
    var onSelectionCompleted: ((NSRect) -> Void)?

    private let frozenImage: NSImage
    private var dragStart: NSPoint?
    private var selectionBeforeDrag = NSRect.zero

    init(frame frameRect: NSRect, frozenImage: NSImage) {
        self.frozenImage = frozenImage
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        dragStart = point
        selectionBeforeDrag = selectionRect
        selectionRect = NSRect(origin: point, size: .zero)
        onSelectionChanged?(selectionRect)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        selectionRect = NSRect(
            x: min(dragStart.x, point.x),
            y: min(dragStart.y, point.y),
            width: abs(point.x - dragStart.x),
            height: abs(point.y - dragStart.y)
        )
        onSelectionChanged?(selectionRect)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        mouseDragged(with: event)
        dragStart = nil

        guard selectionRect.width >= 4, selectionRect.height >= 4 else {
            selectionRect = selectionBeforeDrag
            onSelectionChanged?(selectionRect)
            needsDisplay = true
            return
        }

        onSelectionCompleted?(selectionRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        frozenImage.draw(
            in: bounds,
            from: NSRect(origin: .zero, size: frozenImage.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(selectionRect)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.42).setFill()
        shade.fill()

        let outline = NSBezierPath(roundedRect: selectionRect, xRadius: 5, yRadius: 5)
        outline.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        outline.stroke()

        drawInstructions()
    }

    private func drawInstructions() {
        let text = "Drag to capture   Esc cancel   Arrows move   ⇧ resize   Space size"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let bubbleSize = NSSize(width: textSize.width + 24, height: 34)
        let proposedX = selectionRect.midX - bubbleSize.width / 2
        let x = min(max(proposedX, bounds.minX + 12), bounds.maxX - bubbleSize.width - 12)
        let below = selectionRect.minY - bubbleSize.height - 10
        let y = below >= bounds.minY + 12
            ? below
            : min(selectionRect.maxY + 10, bounds.maxY - bubbleSize.height - 12)
        let bubbleRect = NSRect(origin: NSPoint(x: x, y: y), size: bubbleSize)

        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: bubbleRect, xRadius: 9, yRadius: 9).fill()
        text.draw(
            at: NSPoint(x: bubbleRect.minX + 12, y: bubbleRect.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }

    private func clampedPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}

private final class CapturePreviewView: NSView {
    private let image: NSImage

    init(frame frameRect: NSRect, image: NSImage) {
        self.image = image
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()

        let imageBounds = NSRect(x: 12, y: 60, width: bounds.width - 24, height: bounds.height - 72)
        let target = aspectFit(image.size, in: imageBounds)
        image.draw(
            in: target,
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: target, xRadius: 5, yRadius: 5)
        border.lineWidth = 1
        border.stroke()

        let title = "Ephemeral screenshot"
        title.draw(
            at: NSPoint(x: 16, y: 34),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
        )

        let detail = "Return or ⌘C to copy • Esc to discard • Auto-discards in 20 seconds"
        detail.draw(
            at: NSPoint(x: 16, y: 15),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    private func aspectFit(_ size: NSSize, in bounds: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let result = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(
            x: bounds.midX - result.width / 2,
            y: bounds.midY - result.height / 2,
            width: result.width,
            height: result.height
        )
    }
}
