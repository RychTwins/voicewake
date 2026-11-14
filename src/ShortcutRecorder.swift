import CoreGraphics
import Foundation

private func recorderCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<ShortcutRecorder>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}

/// Écoute le clavier et en déduit le raccourci que l'utilisateur vient de taper.
final class ShortcutRecorder {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held: [CGKeyCode] = []
    private var peak: [CGKeyCode] = []
    private var usedWithKey = false
    private var lastTap: (spec: String, at: Date)?
    private var pending: DispatchWorkItem?
    private var completion: ((String?) -> Void)?

    /// false si l'autorisation « Surveillance de l'entrée » manque.
    func start(timeout: TimeInterval, completion: @escaping (String?) -> Void) -> Bool {
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
            return false
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: recorderCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        self.completion = completion
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0, !KeyMap.isModifier(code) else { return }
            usedWithKey = true
            finish(KeyMap.comboName(modifiers: held, main: code))

        case .flagsChanged:
            if code == KeyMap.capsLock { registerTap("capslock"); return }
            guard KeyMap.isModifier(code) else { return }
            if let i = held.firstIndex(of: code) {
                held.remove(at: i)
                if held.isEmpty {
                    if !usedWithKey { registerTap(KeyMap.comboName(modifiers: peak, main: nil)) }
                    usedWithKey = false
                    peak = []
                }
            } else {
                pending?.cancel()
                held.append(code)
                if !peak.contains(code) { peak.append(code) }
            }

        default:
            break
        }
    }

    /// Appui seul sur une ou plusieurs touches de modification : simple ou double ?
    private func registerTap(_ spec: String) {
        pending?.cancel()
        if let last = lastTap, last.spec == spec, Date().timeIntervalSince(last.at) < 0.45 {
            finish("double \(spec)")
            return
        }
        lastTap = (spec, Date())
        let work = DispatchWorkItem { [weak self] in self?.finish(spec) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func finish(_ spec: String?) {
        guard let completion else { return }
        self.completion = nil
        pending?.cancel()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        completion(spec)
    }
}
