import AppKit
import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var recorderManager: RecorderManager!
    private var controlWindow: NSWindow?
    private let windowState = WindowState()
    private let mainWidth: CGFloat = 240
    private let transcriptWidth: CGFloat = 281 // 280 + 1 for divider
    private let expandedHeight: CGFloat = 400
    private let recordingHeight: CGFloat = 76 // header + compact controls row
    private let recordingExpandedHeight: CGFloat = 140 // slightly taller when transcript panel open
    private let collapsedHeight: CGFloat = 86
    private var pendingTerminate = false
    private var updatePromptedThisSession = false
    private var cancellables = Set<AnyCancellable>()
    private var resizeWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        recorderManager = RecorderManager()

        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            updateStatusIcon(isRecording: false)
            button.action = #selector(showControlWindow)
            button.target = self
        }

        // Observe recording state changes to update icon and resize
        recorderManager.onRecordingStateChange = { [weak self] isRecording in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateStatusIcon(isRecording: isRecording)
                // Don't auto-show transcript panel — user controls it via expand button
                self.recalculateWindowSize(animated: true)
            }
        }
        recorderManager.onProcessingComplete = { [weak self] in
            guard let self else { return }
            self.finishPendingTerminationIfNeeded()
        }

        // Show transcript panel when post-recording transcription starts
        recorderManager.transcriptionManager.$isTranscribing
            .removeDuplicates()
            .sink { [weak self] isTranscribing in
                guard let self else { return }
                if isTranscribing && self.recorderManager.transcriptionManager.mode == .postRecording {
                    self.recorderManager.transcriptionManager.showPanel = true
                }
                DispatchQueue.main.async {
                    self.recalculateWindowSize(animated: true)
                }
            }
            .store(in: &cancellables)

        // Observe showPanel changes — user-initiated, skip debounce
        recorderManager.transcriptionManager.$showPanel
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.performResize(animated: true)
            }
            .store(in: &cancellables)

        // Observe mode changes — right panel visibility depends on mode
        recorderManager.transcriptionManager.$mode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recalculateWindowSize(animated: true)
            }
            .store(in: &cancellables)

        windowState.onCollapseChange = { [weak self] _ in
            // Collapse is user-initiated — skip debounce for instant response
            self?.performResize(animated: true)
        }

        setupEditMenu()
        setupControlWindow()

        checkForUpdatesOnLaunch()

        // Show the control window on launch after the status item is ready.
        DispatchQueue.main.async {
            self.showControlWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorderManager.isRecording {
            pendingTerminate = true
            recorderManager.stopRecording()
            return .terminateLater
        }

        if recorderManager.isProcessing {
            pendingTerminate = true
            return .terminateLater
        }

        return .terminateNow
    }

    private func updateStatusIcon(isRecording: Bool) {
        guard let button = statusItem.button else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let symbolName = isRecording ? "record.circle.fill" : "record.circle"
        let description = isRecording ? "Recording" : "OpenRec"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image?.withSymbolConfiguration(config)
        button.contentTintColor = isRecording ? .systemRed : nil
    }

    @objc private func showControlWindow() {
        guard let window = controlWindow else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupControlWindow() {
        let size = NSSize(width: mainWidth, height: expandedHeight)
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenRec"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        // Hide from screen sharing and screen recording
        window.sharingType = .none

        window.contentView = NSHostingView(
            rootView: FloatingPanelView(
                recorderManager: recorderManager,
                windowState: windowState
            )
        )

        configureTrafficLights(for: window)

        window.center()
        controlWindow = window
    }

    /// Single method that computes window size from all relevant state.
    /// Debounced so rapid-fire observer callbacks coalesce into one smooth resize.
    private func recalculateWindowSize(animated: Bool) {
        resizeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performResize(animated: animated)
        }
        resizeWorkItem = item
        if animated {
            // Tiny delay to coalesce multiple state changes into one animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: item)
        } else {
            DispatchQueue.main.async(execute: item)
        }
    }

    private func performResize(animated: Bool) {
        guard let window = controlWindow else { return }
        let collapsed = windowState.isCollapsed

        let (targetWidth, targetHeight) = MainActor.assumeIsolated { () -> (CGFloat, CGFloat) in
            let tm = recorderManager.transcriptionManager
            let isRecording = recorderManager.isRecording

            // Right panel: during recording, user-controlled; otherwise auto when mode != .off
            let showingRightPanel = !collapsed && tm.mode != .off && (isRecording ? tm.showPanel : true)

            // Tips show independently of right panel during recording
            let showingTips: Bool = {
                if collapsed { return false }
                if !tm.hasOpenRouterKey { return false }
                if isRecording && tm.mode == .live && tm.hasAPIKey { return true }
                if tm.isTranscribing { return true }
                if tm.showPanel && !tm.committedSegments.isEmpty { return true }
                return false
            }()

            let currentTipsHeight: CGFloat
            if showingTips {
                currentTipsHeight = isRecording ? 201 : 141 // content + 1px divider
            } else {
                currentTipsHeight = 0
            }

            let baseHeight: CGFloat
            if isRecording {
                baseHeight = showingRightPanel ? recordingExpandedHeight : recordingHeight
            } else {
                baseHeight = expandedHeight
            }
            let w = mainWidth + (showingRightPanel ? transcriptWidth : 0)
            let h = collapsed ? collapsedHeight : baseHeight + currentTipsHeight
            return (w, h)
        }

        let frame = window.frame
        let newFrame = NSRect(
            x: frame.origin.x,
            y: frame.origin.y + frame.height - targetHeight,
            width: targetWidth,
            height: targetHeight
        )

        // Skip if already at target size
        guard !frame.equalTo(newFrame) else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
                window.animator().setFrame(newFrame, display: true)
            }
        } else {
            window.setFrame(newFrame, display: true)
        }
    }

    private func finishPendingTerminationIfNeeded() {
        guard pendingTerminate else { return }
        pendingTerminate = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func setupEditMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit OpenRec", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func configureTrafficLights(for window: NSWindow) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for buttonType in buttons {
            window.standardWindowButton(buttonType)?.isHidden = true
        }
    }

    private func checkForUpdatesOnLaunch() {
        guard let currentVersion = Bundle.main.shortVersionString else { return }

        UpdateManager.checkForUpdate(currentVersion: currentVersion) { [weak self] info in
            guard let self else { return }
            guard let info else { return }

            UpdateManager.downloadUpdate(from: info) { [weak self] localURL in
                guard let self else { return }
                guard let localURL else { return }

                DispatchQueue.main.async {
                    self.presentUpdateAlertIfNeeded(downloadURL: localURL, tag: info.tag)
                }
            }
        }
    }

    private func presentUpdateAlertIfNeeded(downloadURL: URL, tag: String) {
        guard !updatePromptedThisSession else { return }
        updatePromptedThisSession = true

        let versionLabel = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

        let alert = NSAlert()
        alert.messageText = "New version available"
        alert.informativeText = "OpenRec \(versionLabel) has been downloaded and is ready to install."
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Skip")
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(downloadURL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }
    }
}
