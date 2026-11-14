import CoreAudio

/// Sait si une application utilise un micro (n'importe lequel).
enum MicMonitor {
    static func isAnyInputInUse() -> Bool {
        inputDevices().contains { isRunningSomewhere($0) }
    }

    /// Un autre processus que VoiceWake capte-t-il le micro ? (macOS 14+, sinon repli sur isAnyInputInUse.)
    static func isInputInUseByOtherProcess() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return isAnyInputInUse() }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return isAnyInputInUse() }
        let me = getpid()
        return ids.contains { id in
            processValue(id, kAudioProcessPropertyPID, as: pid_t.self) != me &&
            processValue(id, kAudioProcessPropertyIsRunningInput, as: UInt32.self) ?? 0 != 0
        }
    }

    /// Une app dont le bundle ID commence par l'un des préfixes joue-t-elle du son ? (lecture à voix haute, mode vocal)
    static func isOutputRunning(bundlePrefixes: [String]) -> Bool { outputtingPrefix(bundlePrefixes) != nil }

    /// Le préfixe (bundle ID de la cible) de l'app qui joue du son, ou nil.
    static func outputtingPrefix(_ bundlePrefixes: [String]) -> String? {
        guard !bundlePrefixes.isEmpty else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids where processValue(id, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0 != 0 {
            let bundle = bundleID(of: id) ?? ""
            if let p = bundlePrefixes.first(where: { bundle.hasPrefix($0) }) { return p }
        }
        return nil
    }

    private static func bundleID(of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func processValue<T: FixedWidthInteger>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, as: T.Type) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func inputDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput)
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isRunningSomewhere(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running) == noErr && running != 0
    }
}
