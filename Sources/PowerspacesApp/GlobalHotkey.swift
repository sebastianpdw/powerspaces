// Powerspaces
// Copyright © 2026 Sebastian Panman de Wit
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Carbon.HIToolbox

/// A single system-wide keyboard shortcut, backed by Carbon's `RegisterEventHotKey`.
///
/// Carbon hotkeys are registered with the window server and fire even when
/// Powerspaces isn't the front app — and, unlike a `CGEventTap`, they need **no
/// Accessibility permission**, so the launcher shortcut works the moment it's
/// chosen. Call `apply(keyCode:modifiers:)` to set the combo, or with `nil` to
/// clear it; the previous registration is always torn down first.
///
/// The Carbon event handler is a C callback that can't capture `self`, so the
/// fire-action is looked up from a small static table keyed by this hotkey's id.
@MainActor
final class GlobalHotkey {
    /// 'PSPS' — a four-char signature so our hotkey ids don't collide with others.
    private static let signature: OSType = 0x5053_5053
    /// Per-instance id, and the table the (context-free) C handler dispatches through.
    private static var nextID: UInt32 = 1
    private static var actions: [UInt32: () -> Void] = [:]
    private static var sharedHandler: EventHandlerRef?

    private let id: UInt32
    private let onFire: () -> Void
    private var hotKeyRef: EventHotKeyRef?

    init(onFire: @escaping () -> Void) {
        self.onFire = onFire
        self.id = GlobalHotkey.nextID
        GlobalHotkey.nextID += 1
    }

    /// Register (or, with `keyCode == nil`, clear) the shortcut. `modifiers` are
    /// Carbon modifier masks (`cmdKey`, `optionKey`, …). Idempotent: re-applying
    /// the same combo just re-registers it after tearing down the old one.
    func apply(keyCode: UInt32?, modifiers: UInt32) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        guard let keyCode else { GlobalHotkey.actions[id] = nil; return }
        GlobalHotkey.installSharedHandler()
        GlobalHotkey.actions[id] = onFire
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: GlobalHotkey.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { hotKeyRef = ref } else { GlobalHotkey.actions[id] = nil }
    }

    /// Install the one process-wide handler that routes every hot-key press to the
    /// matching action. The handler runs on the main run loop, so it's already on
    /// the main actor when it fires.
    private static func installSharedHandler() {
        guard sharedHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var pressedID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressedID)
            MainActor.assumeIsolated { GlobalHotkey.actions[pressedID.id]?() }
            return noErr
        }, 1, &spec, nil, &sharedHandler)
    }
}
