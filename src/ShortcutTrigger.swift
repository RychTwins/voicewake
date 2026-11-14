import AppKit
import ApplicationServices

final class ShortcutTrigger {
    struct DictationWindow {
        let app: NSRunningApplication
        let element: AXUIElement

        var isFocused: Bool {
            app.isActive && AXButtonPresser.focusedWindow(in: app).map { CFEqual($0, element) } == true
        }
    }

    static func dictationWindow(for target: Target) -> DictationWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication, matches(app, target),
              let window = AXButtonPresser.focusedWindow(in: app) else { return nil }
        return DictationWindow(app: app, element: window)
    }

    static func checkAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let ok = AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
        if !ok { log("Autoriser VoiceWake : Réglages Système > Confidentialité et sécurité > Accessibilité.") }
        return ok
    }

    static func runningApp(for t: Target) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { matches($0, t) }
    }

    static func matches(_ app: NSRunningApplication, _ t: Target) -> Bool {
        if let b = t.bundleID, app.bundleIdentifier == b { return true }
        if let n = t.appName, app.localizedName?.caseInsensitiveCompare(n) == .orderedSame { return true }
        return false
    }

    static func appURL(for t: Target) -> URL? {
        if let b = t.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            return url
        }
        guard let n = t.appName else { return nil }
        let fm = FileManager.default
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let path = "\(dir)/\(n).app"
            if fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Ouvre l'application si besoin, puis envoie son raccourci vocal.
    func fire(_ t: Target, completion: ((Bool) -> Void)? = nil) {
        guard AXIsProcessTrusted() else {
            log("Accessibilité non accordée : raccourci ignoré.")
            completion?(false)
            return
        }
        let activate = t.activate ?? true
        readGeneration += 1 // nouvelle demande : annule une lecture en attente
        reading = nil

        if let app = Self.runningApp(for: t) {
            if activate { Self.activate(app) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.send(t, completion) }
            return
        }

        guard let url = Self.appURL(for: t) else {
            log("\(t.id) : application introuvable (\(t.appName ?? t.bundleID ?? "?")).")
            completion?(false)
            return
        }
        log("\(t.id) : lancement de l'application.")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = activate
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            if let error { log("\(t.id) : lancement impossible : \(error.localizedDescription)") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (t.launchDelaySeconds ?? 3)) {
            // App tout juste lancée : son interface peut mettre du temps à apparaître.
            self.send(t, patience: 20, completion)
        }
    }

    /// Envoi vocal : coupe le micro de l'app (en rejouant son raccourci), attend le texte, puis envoie.
    func submit(_ t: Target, in window: DictationWindow?, stopFirst: Bool, completion: @escaping (Bool) -> Void) {
        guard let window else { completion(false); return }
        var submitTarget = t
        submitTarget.shortcut = t.submitShortcut ?? (try! Shortcut(spec: "return"))
        let finish = {
            DispatchQueue.main.asyncAfter(deadline: .now() + (stopFirst ? (t.submitDelaySeconds ?? 1.5) : 0)) {
                self.send(submitTarget, in: window, completion)
            }
        }
        if stopFirst && (t.stopBeforeSubmit ?? true) {
            stopDictation(t, in: window) { stopped in
                if stopped { finish() } else { completion(false) }
            }
        } else {
            finish()
        }
    }

    private var readGeneration = 0
    /// Lecture à voix haute lancée par VoiceWake (cible et date), effacée à la demande suivante.
    private(set) var reading: (target: Target, since: Date)?

    /// Cible dont VoiceWake a lancé la lecture il y a moins de `within` secondes.
    func readingTarget(within seconds: TimeInterval = 900) -> Target? {
        guard let r = reading, Date().timeIntervalSince(r.since) < seconds else { return nil }
        return r.target
    }

    /// Lecture lancée : surveille le son de l'app et ne considère la lecture finie qu'après
    /// 3 s de silence continu (les pauses entre phrases ne lèvent pas la protection).
    private func startReading(_ t: Target, app: NSRunningApplication) {
        reading = (t, Date())
        let gen = readGeneration
        let bundle = t.bundleID ?? app.bundleIdentifier ?? ""
        DispatchQueue.global().async {
            var silentSince: Date?
            while true {
                usleep(500_000)
                // Signal le plus fiable : le bouton de pause, visible seulement pendant la lecture (Claude).
                // Sinon, le son de l'app.
                let pauseLabels = t.pauseReadShortcut?.buttons ?? []
                let playing = !pauseLabels.isEmpty
                    ? !AXButtonPresser.all(pauseLabels, in: app).isEmpty
                    : (!bundle.isEmpty && MicMonitor.isOutputRunning(bundlePrefixes: [bundle]))
                var done = false
                if playing { silentSince = nil }
                else if let s = silentSince { done = Date().timeIntervalSince(s) >= 3 }
                else { silentSince = Date() }
                let stop: Bool = DispatchQueue.main.sync {
                    guard gen == self.readGeneration, self.reading != nil else { return true }
                    if done { self.reading = nil; log("\(t.id) : lecture terminée.") }
                    return done
                }
                if stop { return }
            }
        }
    }

    /// Attend la fin de la réponse, puis clique le dernier bouton de lecture à voix haute.
    /// Fin = indicateur « en cours » (busyLabels) disparu, ou nouveau bouton de lecture, stable 2 s.
    func readAloudWhenDone(_ t: Target) {
        guard let labels = t.readAloudShortcut?.buttons, !labels.isEmpty,
              let app = Self.runningApp(for: t) else { return }
        readGeneration += 1
        let gen = readGeneration
        let busy = t.busyLabels ?? []
        let timeout = t.readAloudTimeoutSeconds ?? 600
        let initial = AXButtonPresser.all(labels, in: app).count
        log("\(t.id) : lecture à voix haute à la fin de la réponse.")
        DispatchQueue.global().async {
            let start = Date()
            var sawBusy = false
            var stable = 0
            while Date().timeIntervalSince(start) < timeout {
                usleep(1_000_000)
                guard gen == self.readGeneration, !app.isTerminated else { return }
                let isBusy = !busy.isEmpty && !AXButtonPresser.all(busy, in: app, anyRole: true).isEmpty
                if isBusy { sawBusy = true; stable = 0; continue }
                let grew = AXButtonPresser.all(labels, in: app).count > initial
                stable = (sawBusy || grew) ? stable + 1 : 0
                if stable >= 2 {
                    let ok = AXButtonPresser.pressLast(labels, in: app)
                    DispatchQueue.main.async {
                        if ok { self.startReading(t, app: app) }
                        log(ok ? "\(t.id) : lecture à voix haute lancée." : "\(t.id) : bouton de lecture introuvable.")
                    }
                    return
                }
            }
            DispatchQueue.main.async { log("\(t.id) : réponse trop longue, lecture non lancée.") }
        }
    }

    /// Met la lecture à voix haute en pause (pauseReadShortcut), puis rouvre le micro de l'app.
    func interruptAndDictate(_ t: Target, completion: ((Bool) -> Void)? = nil) {
        guard let pause = t.pauseReadShortcut else { return fire(t, completion: completion) }
        var pauseTarget = t
        pauseTarget.shortcut = pause
        send(pauseTarget) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.fire(t, completion: completion) }
        }
    }

    /// Coupe le micro de l'app (stopShortcut, sinon le raccourci d'ouverture).
    func stopDictation(_ t: Target, in window: DictationWindow?, completion: @escaping (Bool) -> Void) {
        guard let window else { completion(false); return }
        var stopTarget = t
        stopTarget.shortcut = t.stopShortcut ?? t.shortcut
        // Le raccourci de la Dictée macOS doit passer par le système.
        let usesOpeningShortcut = stopTarget.shortcut.spec == t.shortcut.spec
        send(stopTarget, in: window, systemShortcut: usesOpeningShortcut, completion)
    }

    private static func activate(_ app: NSRunningApplication) {
        if #available(macOS 14, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// `patience` : durée max (s) de recherche du bouton.
    private func send(
        _ t: Target, patience: Double = 3, in window: DictationWindow? = nil,
        systemShortcut: Bool = false, _ completion: ((Bool) -> Void)?
    ) {
        let s = t.shortcut
        let allowed = { AXIsProcessTrusted() && (window?.isFocused ?? true) }
        guard allowed() else {
            log("\(t.id) : action ignorée, fenêtre de dictée inactive ou accès refusé.")
            completion?(false)
            return
        }
        if s.buttons.isEmpty {
            ShortcutPlayer.play(s, to: systemShortcut ? nil : window?.app.processIdentifier, while: allowed) { played in
                log(played ? "Raccourci envoyé : \(s.spec)" : "\(t.id) : raccourci interrompu.")
                completion?(played)
            }
            return
        }
        DispatchQueue.global().async {
            var pressed: String?
            // L'application vient peut-être de s'ouvrir : essais toutes les 0,5 s.
            for attempt in 0..<max(1, Int(patience * 2)) where pressed == nil {
                if attempt > 0 { usleep(500_000) }
                guard allowed() else { break }
                if let app = window?.app ?? Self.runningApp(for: t) {
                    pressed = AXButtonPresser.press(s.buttons, in: app, window: window?.element)
                }
            }
            DispatchQueue.main.async {
                if let pressed { log("Bouton cliqué : « \(pressed) »") }
                else { log("\(t.id) : bouton introuvable (\(s.buttons.joined(separator: " | "))).") }
                completion?(pressed != nil)
            }
        }
    }
}
