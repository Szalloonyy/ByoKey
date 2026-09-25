//
//  HotKeyCenter.swift
//  RecallDrop (macOS)
//
//  System-wide keyboard shortcuts via Carbon's RegisterEventHotKey. Unlike
//  global NSEvent monitors this needs no Accessibility permission and works
//  in the App Sandbox.
//

import AppKit
import Carbon.HIToolbox

/// A key plus Carbon modifier flags.
struct HotKeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Converts an AppKit key event; nil when neither ⌘ nor ⌃ is held
    /// (macOS does not allow global shortcuts that use only ⌥ or ⌥⇧).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        guard carbon & UInt32(cmdKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon)
    }

    @MainActor
    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.keyName(for: keyCode)
    }

    /// The key's label: special keys by symbol, character keys as the current
    /// keyboard layout prints them (Z and Y swap on a German keyboard).
    @MainActor
    static func keyName(for keyCode: UInt32) -> String {
        if let special = specialKeyNames[Int(keyCode)] { return special }
        if let typed = layoutCharacter(for: keyCode) { return typed }
        return usLayoutNames[Int(keyCode)] ?? "Key \(keyCode)"
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]

    /// Fallback labels for character keys (ANSI US layout).
    private static let usLayoutNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`"
    ]

    /// What the key types in the current (ASCII-capable) keyboard layout.
    @MainActor
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length).uppercased()
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

enum HotKeyAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case captureScreen
    case captureClipboard
    case quickNote
    case toggleDropShelf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureScreen: "Capture Screen Region"
        case .captureClipboard: "Capture Clipboard"
        case .quickNote: "Quick Note"
        case .toggleDropShelf: "Show/Hide Drop Shelf"
        }
    }

    var defaultCombo: HotKeyCombo {
        let modifiers = HotKeyCombo.controlOptionCommand
        switch self {
        case .captureScreen: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: modifiers)
        case .captureClipboard: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: modifiers)
        case .quickNote: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_N), modifiers: modifiers)
        case .toggleDropShelf: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: modifiers)
        }
    }
}

/// The user's shortcut choices; a missing entry means "default", an explicit nil means "off".
struct HotKeyBindings: Codable, Equatable, Sendable {
    var combos: [String: HotKeyCombo?] = [:]

    func combo(for action: HotKeyAction) -> HotKeyCombo? {
        if let entry = combos[action.rawValue] { return entry }
        return action.defaultCombo
    }

    mutating func set(_ combo: HotKeyCombo?, for action: HotKeyAction) {
        combos[action.rawValue] = .some(combo)
    }

    var active: [HotKeyAction: HotKeyCombo] {
        var result: [HotKeyAction: HotKeyCombo] = [:]
        for action in HotKeyAction.allCases {
            if let combo = combo(for: action) { result[action] = combo }
        }
        return result
    }

    @MainActor
    static func load(from settings: SettingsStore) -> HotKeyBindings {
        guard let data = settings.hotKeysData,
              let bindings = try? JSONDecoder().decode(HotKeyBindings.self, from: data) else { return HotKeyBindings() }
        return bindings
    }

    @MainActor
    func save(to settings: SettingsStore) {
        settings.hotKeysData = try? JSONEncoder().encode(self)
    }

    /// Another action that already uses `combo`, if any.
    func action(using combo: HotKeyCombo, except action: HotKeyAction) -> HotKeyAction? {
        HotKeyAction.allCases.first { $0 != action && self.combo(for: $0) == combo }
    }
}

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// Invoked on the main thread when a registered shortcut is pressed.
    var onAction: ((HotKeyAction) -> Void)?
    /// Actions whose shortcut could not be registered (taken by another app,
    /// or used twice).
    private(set) var conflicts: Set<HotKeyAction> = []
    private var appliedBindings = HotKeyBindings()
    private var isSuspended = false

    private var handlerRef: EventHandlerRef?
    private var registered: [UInt32: (ref: EventHotKeyRef, action: HotKeyAction)] = [:]
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x5244_4B59 // "RDKY"

    func apply(_ bindings: HotKeyBindings) {
        appliedBindings = bindings
        guard !isSuspended else { return }
        installHandlerIfNeeded()
        unregisterAll()
        conflicts = []
        var used: Set<HotKeyCombo> = []
        // A fixed order, so the same action wins every time if two share a combination.
        for action in HotKeyAction.allCases {
            guard let combo = bindings.combo(for: action) else { continue }
            guard used.insert(combo).inserted else {
                conflicts.insert(action)
                continue
            }
            register(combo, for: action)
        }
    }

    /// Lets the shortcut recorder receive combinations that are registered
    /// as global shortcuts; `resume()` registers them again.
    func suspend() {
        isSuspended = true
        unregisterAll()
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        apply(appliedBindings)
    }

    func unregisterAll() {
        for entry in registered.values {
            UnregisterEventHotKey(entry.ref)
        }
        registered.removeAll()
    }

    private func register(_ combo: HotKeyCombo, for action: HotKeyAction) {
        let identifier = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        // Exclusive: fails when another app already owns the combination.
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &reference)
        if status == noErr, let reference {
            registered[identifier] = (reference, action)
        } else {
            conflicts.insert(action)
        }
    }

    fileprivate func handleHotKey(id: UInt32) {
        guard let action = registered[id]?.action else { return }
        onAction?(action)
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                let identifier = hotKeyID.id
                // Carbon delivers application events on the main thread.
                MainActor.assumeIsolated {
                    center.handleHotKey(id: identifier)
                }
                return noErr
            },
            1,
            &eventType,
            context,
            &handlerRef
        )
    }
}
