import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var recorderManager: RecorderManager!
    private var controlWindow: NSWindow?
    private let windowState = WindowState()
    private let expandedSize = NSSize(width: 240, height: 350)
    private let collapsedSize = NSSize(width: 240, height: 86)
    private var pendingTerminate = false
    private var updatePromptedThisSession = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        recorderManager = RecorderManager()

        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            updateStatusIcon(isRecording: false)
            button.action = #selector(showControlWindow)
            button.target = self
        }

        // Observe recording state changes to update icon
        recorderManager.onRecordingStateChange = { [weak self] isRecording in
            DispatchQueue.main.async {
                self?.updateStatusIcon(isRecording: isRecording)
            }
        }
        recorderManager.onProcessingComplete = { [weak self] in
            self?.finishPendingTerminationIfNeeded()
        }

        windowState.onCollapseChange = { [weak self] collapsed in
            self?.updateWindowSize(collapsed: collapsed, animated: true)
        }

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
        let rect = NSRect(origin: .zero, size: expandedSize)
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

    private func updateWindowSize(collapsed: Bool, animated: Bool) {
        guard let window = controlWindow else { return }
        let targetSize = collapsed ? collapsedSize : expandedSize
        let frame = window.frame
        let newFrame = NSRect(
            x: frame.origin.x,
            y: frame.origin.y + frame.height - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
        window.setFrame(newFrame, display: true, animate: animated)
    }

    private func finishPendingTerminationIfNeeded() {
        guard pendingTerminate else { return }
        pendingTerminate = false
        NSApp.reply(toApplicationShouldTerminate: true)
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
