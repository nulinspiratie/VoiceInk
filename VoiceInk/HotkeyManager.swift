import Foundation
import KeyboardShortcuts
import Carbon
import AppKit

extension KeyboardShortcuts.Name {
    static let toggleMiniRecorder = Self("toggleMiniRecorder")
    static let toggleMiniRecorder2 = Self("toggleMiniRecorder2")
    static let pasteLastTranscription = Self("pasteLastTranscription")
    static let pasteLastEnhancement = Self("pasteLastEnhancement")
    static let pasteLastTranscriptionAndSend = Self("pasteLastTranscriptionAndSend")
    static let pasteLastEnhancementAndSend = Self("pasteLastEnhancementAndSend")
    static let retryLastTranscription = Self("retryLastTranscription")
}

@MainActor
class HotkeyManager: ObservableObject {
    @Published var selectedHotkey1: HotkeyOption {
        didSet {
            UserDefaults.standard.set(selectedHotkey1.rawValue, forKey: "selectedHotkey1")
            setupHotkeyMonitoring()
        }
    }
    @Published var selectedHotkey2: HotkeyOption {
        didSet {
            if selectedHotkey2 == .none {
                KeyboardShortcuts.setShortcut(nil, for: .toggleMiniRecorder2)
            }
            UserDefaults.standard.set(selectedHotkey2.rawValue, forKey: "selectedHotkey2")
            setupHotkeyMonitoring()
        }
    }
    @Published var isMiddleClickToggleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMiddleClickToggleEnabled, forKey: "isMiddleClickToggleEnabled")
            setupHotkeyMonitoring()
        }
    }
    @Published var middleClickActivationDelay: Int {
        didSet {
            UserDefaults.standard.set(middleClickActivationDelay, forKey: "middleClickActivationDelay")
        }
    }
    
    private var whisperState: WhisperState
    private var miniRecorderShortcutManager: MiniRecorderShortcutManager
    
    // MARK: - Helper Properties
    private var canProcessHotkeyAction: Bool {
        whisperState.recordingState != .transcribing && whisperState.recordingState != .enhancing && whisperState.recordingState != .busy
    }
    
    // NSEvent monitoring for modifier keys
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    
    // Middle-click event monitoring
    private var middleClickMonitors: [Any?] = []
    private var middleClickTask: Task<Void, Never>?
    
    // Key state tracking
    private var currentKeyState = false
    private var keyPressStartTime: Date?
    private let briefPressThreshold = 1.7
    private let handsFreeStopSendThreshold: TimeInterval = 0.5
    private var isHandsFreeMode = false
    private var isAwaitingHandsFreeStopKeyUp = false
    private var handsFreeHoldToSendTask: Task<Void, Never>?
    private var shouldIgnoreNextHandsFreeKeyUp = false
    
    // Debounce for Fn key
    private var fnDebounceTask: Task<Void, Never>?
    private var pendingFnKeyState: Bool? = nil
    
    // Keyboard shortcut state tracking
    private var shortcutKeyPressStartTime: Date?
    private var isShortcutHandsFreeMode = false
    private var shortcutCurrentKeyState = false
    private var isAwaitingShortcutHandsFreeStopKeyUp = false
    private var shortcutHandsFreeHoldToSendTask: Task<Void, Never>?
    private var shouldIgnoreNextShortcutHandsFreeKeyUp = false
    private var lastShortcutTriggerTime: Date?
    private let shortcutCooldownInterval: TimeInterval = 0.5
    
    enum HotkeyOption: String, CaseIterable {
        case none = "none"
        case rightOption = "rightOption"
        case leftOption = "leftOption"
        case leftControl = "leftControl" 
        case rightControl = "rightControl"
        case fn = "fn"
        case rightCommand = "rightCommand"
        case rightShift = "rightShift"
        case custom = "custom"
        
        var displayName: String {
            switch self {
            case .none: return "None"
            case .rightOption: return "Right Option (⌥)"
            case .leftOption: return "Left Option (⌥)"
            case .leftControl: return "Left Control (⌃)"
            case .rightControl: return "Right Control (⌃)"
            case .fn: return "Fn"
            case .rightCommand: return "Right Command (⌘)"
            case .rightShift: return "Right Shift (⇧)"
            case .custom: return "Custom"
            }
        }
        
        var keyCode: CGKeyCode? {
            switch self {
            case .rightOption: return 0x3D
            case .leftOption: return 0x3A
            case .leftControl: return 0x3B
            case .rightControl: return 0x3E
            case .fn: return 0x3F
            case .rightCommand: return 0x36
            case .rightShift: return 0x3C
            case .custom, .none: return nil
            }
        }
        
        var isModifierKey: Bool {
            return self != .custom && self != .none
        }
    }
    
    init(whisperState: WhisperState) {
        self.selectedHotkey1 = HotkeyOption(rawValue: UserDefaults.standard.string(forKey: "selectedHotkey1") ?? "") ?? .rightCommand
        self.selectedHotkey2 = HotkeyOption(rawValue: UserDefaults.standard.string(forKey: "selectedHotkey2") ?? "") ?? .none
        
        self.isMiddleClickToggleEnabled = UserDefaults.standard.bool(forKey: "isMiddleClickToggleEnabled")
        let storedDelay = UserDefaults.standard.integer(forKey: "middleClickActivationDelay")
        self.middleClickActivationDelay = storedDelay > 0 ? storedDelay : 200
        
        self.whisperState = whisperState
        self.miniRecorderShortcutManager = MiniRecorderShortcutManager(whisperState: whisperState)

        KeyboardShortcuts.onKeyUp(for: .pasteLastTranscription) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                LastTranscriptionService.pasteLastTranscription(from: self.whisperState.modelContext)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .pasteLastEnhancement) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                LastTranscriptionService.pasteLastEnhancement(from: self.whisperState.modelContext)
            }
        }
        
        KeyboardShortcuts.onKeyUp(for: .pasteLastTranscriptionAndSend) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                LastTranscriptionService.pasteLastTranscriptionAndSend(from: self.whisperState.modelContext)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .pasteLastEnhancementAndSend) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                LastTranscriptionService.pasteLastEnhancementAndSend(from: self.whisperState.modelContext)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .retryLastTranscription) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                LastTranscriptionService.retryLastTranscription(from: self.whisperState.modelContext, whisperState: self.whisperState)
            }
        }
        
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.setupHotkeyMonitoring()
        }
    }
    
    private func setupHotkeyMonitoring() {
        removeAllMonitoring()
        
        setupModifierKeyMonitoring()
        setupCustomShortcutMonitoring()
        setupMiddleClickMonitoring()
    }
    
    private func setupModifierKeyMonitoring() {
        // Only set up if at least one hotkey is a modifier key
        guard (selectedHotkey1.isModifierKey && selectedHotkey1 != .none) || (selectedHotkey2.isModifierKey && selectedHotkey2 != .none) else { return }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return }
            Task { @MainActor in
                await self.handleModifierKeyEvent(event)
            }
        }
        
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return event }
            Task { @MainActor in
                await self.handleModifierKeyEvent(event)
            }
            return event
        }
    }
    
    private func setupMiddleClickMonitoring() {
        guard isMiddleClickToggleEnabled else { return }

        // Mouse Down
        let downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }

            self.middleClickTask?.cancel()
            self.middleClickTask = Task {
                do {
                    let delay = UInt64(self.middleClickActivationDelay) * 1_000_000 // ms to ns
                    try await Task.sleep(nanoseconds: delay)
                    
                    guard self.isMiddleClickToggleEnabled, !Task.isCancelled else { return }
                    
                    Task { @MainActor in
                        guard self.canProcessHotkeyAction else { return }
                        await self.whisperState.handleToggleMiniRecorder()
                    }
                } catch {
                    // Cancelled
                }
            }
        }

        // Mouse Up
        let upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }
            self.middleClickTask?.cancel()
        }

        middleClickMonitors = [downMonitor, upMonitor]
    }
    
    private func setupCustomShortcutMonitoring() {
        // Hotkey 1
        if selectedHotkey1 == .custom {
            KeyboardShortcuts.onKeyDown(for: .toggleMiniRecorder) { [weak self] in
                Task { @MainActor in await self?.handleCustomShortcutKeyDown() }
            }
            KeyboardShortcuts.onKeyUp(for: .toggleMiniRecorder) { [weak self] in
                Task { @MainActor in await self?.handleCustomShortcutKeyUp() }
            }
        }
        // Hotkey 2
        if selectedHotkey2 == .custom {
            KeyboardShortcuts.onKeyDown(for: .toggleMiniRecorder2) { [weak self] in
                Task { @MainActor in await self?.handleCustomShortcutKeyDown() }
            }
            KeyboardShortcuts.onKeyUp(for: .toggleMiniRecorder2) { [weak self] in
                Task { @MainActor in await self?.handleCustomShortcutKeyUp() }
            }
        }
    }
    
    private func removeAllMonitoring() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        
        for monitor in middleClickMonitors {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        middleClickMonitors = []
        middleClickTask?.cancel()
        
        resetKeyStates()
    }
    
    private func resetKeyStates() {
        currentKeyState = false
        keyPressStartTime = nil
        isHandsFreeMode = false
        isAwaitingHandsFreeStopKeyUp = false
        handsFreeHoldToSendTask?.cancel()
        handsFreeHoldToSendTask = nil
        shouldIgnoreNextHandsFreeKeyUp = false
        shortcutCurrentKeyState = false
        shortcutKeyPressStartTime = nil
        isShortcutHandsFreeMode = false
        isAwaitingShortcutHandsFreeStopKeyUp = false
        shortcutHandsFreeHoldToSendTask?.cancel()
        shortcutHandsFreeHoldToSendTask = nil
        shouldIgnoreNextShortcutHandsFreeKeyUp = false
    }
    
    private func handleModifierKeyEvent(_ event: NSEvent) async {
        let keycode = event.keyCode
        let flags = event.modifierFlags
        
        // Determine which hotkey (if any) is being triggered
        let activeHotkey: HotkeyOption?
        if selectedHotkey1.isModifierKey && selectedHotkey1.keyCode == keycode {
            activeHotkey = selectedHotkey1
        } else if selectedHotkey2.isModifierKey && selectedHotkey2.keyCode == keycode {
            activeHotkey = selectedHotkey2
        } else {
            activeHotkey = nil
        }
        
        guard let hotkey = activeHotkey else { return }
        
        var isKeyPressed = false
        
        switch hotkey {
        case .rightOption, .leftOption:
            isKeyPressed = flags.contains(.option)
        case .leftControl, .rightControl:
            isKeyPressed = flags.contains(.control)
        case .fn:
            isKeyPressed = flags.contains(.function)
            // Debounce Fn key
            pendingFnKeyState = isKeyPressed
            fnDebounceTask?.cancel()
            fnDebounceTask = Task { [pendingState = isKeyPressed] in
                try? await Task.sleep(nanoseconds: 75_000_000) // 75ms
                if pendingFnKeyState == pendingState {
                    await self.processKeyPress(isKeyPressed: pendingState)
                }
            }
            return
        case .rightCommand:
            isKeyPressed = flags.contains(.command)
        case .rightShift:
            isKeyPressed = flags.contains(.shift)
        case .custom, .none:
            return // Should not reach here
        }

        await processKeyPress(isKeyPressed: isKeyPressed)
    }
    
    private func processKeyPress(isKeyPressed: Bool) async {
        guard isKeyPressed != currentKeyState else { return }
        currentKeyState = isKeyPressed

        if isKeyPressed {
            keyPressStartTime = Date()

            if isHandsFreeMode,
               whisperState.isMiniRecorderVisible,
               whisperState.recordingState == .recording {
                isHandsFreeMode = false
                isAwaitingHandsFreeStopKeyUp = true
                handsFreeHoldToSendTask?.cancel()
                handsFreeHoldToSendTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: UInt64(self.handsFreeStopSendThreshold * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    guard self.currentKeyState, self.isAwaitingHandsFreeStopKeyUp else { return }
                    guard self.whisperState.isMiniRecorderVisible, self.whisperState.recordingState == .recording else { return }
                    guard self.canProcessHotkeyAction else { return }

                    self.isAwaitingHandsFreeStopKeyUp = false
                    self.shouldIgnoreNextHandsFreeKeyUp = true
                    self.keyPressStartTime = nil

                    self.whisperState.requestAutoSendAfterNextPaste()
                    self.whisperState.suppressNextStopSoundOnce()
                    SoundManager.shared.playStopSound()
                    await self.whisperState.toggleMiniRecorder()
                }
                return
            }

            if isHandsFreeMode {
                isHandsFreeMode = false
                guard canProcessHotkeyAction else { return }
                await whisperState.handleToggleMiniRecorder()
                return
            }

            if !whisperState.isMiniRecorderVisible {
                guard canProcessHotkeyAction else { return }
                await whisperState.handleToggleMiniRecorder()
            }
        } else {
            let now = Date()

            if shouldIgnoreNextHandsFreeKeyUp {
                shouldIgnoreNextHandsFreeKeyUp = false
                handsFreeHoldToSendTask?.cancel()
                handsFreeHoldToSendTask = nil
                keyPressStartTime = nil
                return
            }

            if isAwaitingHandsFreeStopKeyUp {
                isAwaitingHandsFreeStopKeyUp = false
                handsFreeHoldToSendTask?.cancel()
                handsFreeHoldToSendTask = nil

                if let startTime = keyPressStartTime {
                    let pressDuration = now.timeIntervalSince(startTime)
                    guard canProcessHotkeyAction else {
                        keyPressStartTime = nil
                        return
                    }

                    if pressDuration >= handsFreeStopSendThreshold {
                        whisperState.requestAutoSendAfterNextPaste()
                    }
                    await whisperState.handleToggleMiniRecorder()
                }

                keyPressStartTime = nil
                return
            }

            if let startTime = keyPressStartTime {
                let pressDuration = now.timeIntervalSince(startTime)

                if pressDuration < briefPressThreshold {
                    isHandsFreeMode = true
                } else {
                    guard canProcessHotkeyAction else { return }
                    await whisperState.handleToggleMiniRecorder()
                }
            }

            keyPressStartTime = nil
        }
    }
    
    private func handleCustomShortcutKeyDown() async {
        if let lastTrigger = lastShortcutTriggerTime,
           Date().timeIntervalSince(lastTrigger) < shortcutCooldownInterval {
            return
        }
        
        guard !shortcutCurrentKeyState else { return }
        shortcutCurrentKeyState = true
        lastShortcutTriggerTime = Date()
        shortcutKeyPressStartTime = Date()
        
        if isShortcutHandsFreeMode,
           whisperState.isMiniRecorderVisible,
           whisperState.recordingState == .recording {
            isShortcutHandsFreeMode = false
            isAwaitingShortcutHandsFreeStopKeyUp = true
            shortcutHandsFreeHoldToSendTask?.cancel()
            shortcutHandsFreeHoldToSendTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.handsFreeStopSendThreshold * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard self.shortcutCurrentKeyState, self.isAwaitingShortcutHandsFreeStopKeyUp else { return }
                guard self.whisperState.isMiniRecorderVisible, self.whisperState.recordingState == .recording else { return }
                guard self.canProcessHotkeyAction else { return }

                self.isAwaitingShortcutHandsFreeStopKeyUp = false
                self.shouldIgnoreNextShortcutHandsFreeKeyUp = true
                self.shortcutKeyPressStartTime = nil

                self.whisperState.requestAutoSendAfterNextPaste()
                self.whisperState.suppressNextStopSoundOnce()
                SoundManager.shared.playStopSound()
                await self.whisperState.toggleMiniRecorder()
            }
            return
        }

        if isShortcutHandsFreeMode {
            isShortcutHandsFreeMode = false
            guard canProcessHotkeyAction else { return }
            await whisperState.handleToggleMiniRecorder()
            return
        }
        
        if !whisperState.isMiniRecorderVisible {
            guard canProcessHotkeyAction else { return }
            await whisperState.handleToggleMiniRecorder()
        }
    }
    
    private func handleCustomShortcutKeyUp() async {
        guard shortcutCurrentKeyState else { return }
        shortcutCurrentKeyState = false
        
        let now = Date()

        if shouldIgnoreNextShortcutHandsFreeKeyUp {
            shouldIgnoreNextShortcutHandsFreeKeyUp = false
            shortcutHandsFreeHoldToSendTask?.cancel()
            shortcutHandsFreeHoldToSendTask = nil
            shortcutKeyPressStartTime = nil
            return
        }
        
        if isAwaitingShortcutHandsFreeStopKeyUp {
            isAwaitingShortcutHandsFreeStopKeyUp = false
            shortcutHandsFreeHoldToSendTask?.cancel()
            shortcutHandsFreeHoldToSendTask = nil

            if let startTime = shortcutKeyPressStartTime {
                let pressDuration = now.timeIntervalSince(startTime)
                guard canProcessHotkeyAction else {
                    shortcutKeyPressStartTime = nil
                    return
                }

                if pressDuration >= handsFreeStopSendThreshold {
                    whisperState.requestAutoSendAfterNextPaste()
                }
                await whisperState.handleToggleMiniRecorder()
            }

            shortcutKeyPressStartTime = nil
            return
        }

        if let startTime = shortcutKeyPressStartTime {
            let pressDuration = now.timeIntervalSince(startTime)
            
            if pressDuration < briefPressThreshold {
                isShortcutHandsFreeMode = true
            } else {
                guard canProcessHotkeyAction else { return }
                await whisperState.handleToggleMiniRecorder()
            }
        }
        
        shortcutKeyPressStartTime = nil
    }
    
    // Computed property for backward compatibility with UI
    var isShortcutConfigured: Bool {
        let isHotkey1Configured = (selectedHotkey1 == .custom) ? (KeyboardShortcuts.getShortcut(for: .toggleMiniRecorder) != nil) : true
        let isHotkey2Configured = (selectedHotkey2 == .custom) ? (KeyboardShortcuts.getShortcut(for: .toggleMiniRecorder2) != nil) : true
        return isHotkey1Configured && isHotkey2Configured
    }
    
    func updateShortcutStatus() {
        // Called when a custom shortcut changes
        if selectedHotkey1 == .custom || selectedHotkey2 == .custom {
            setupHotkeyMonitoring()
        }
    }
    
    deinit {
        Task { @MainActor in
            removeAllMonitoring()
        }
    }
}
