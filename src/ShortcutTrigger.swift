import AppKit
import ApplicationServices

final class ShortcutTrigger {
    private(set) var externalDictationWindow: DictationWindow?

    struct ReadBaseline {
        let buttons: [AXUIElement]
        let busy: Bool
    }

    struct DictationWindow {
        let app: NSRunningApplication
        let element: AXUIElement

        var isFocused: Bool {
            AXButtonPresser.isFrontmost(app) &&
                AXButtonPresser.currentWindow(in: app).map { CFEqual($0, element) } == true
        }
    }

    static func dictationWindow(for target: Target) -> DictationWindow? {
        guard let app = runningApp(for: target), AXButtonPresser.isFrontmost(app),
              let window = AXButtonPresser.currentWindow(in: app) else { return nil }
        return DictationWindow(app: app, element: window)
    }

    static func checkAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let ok = AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
        if !ok { log("Autoriser VoiceWake : Réglages Système > Confidentialité et sécurité > Accessibilité.") }
        return ok
    }

    /// La vraie application de la cible : bundle ID exact d'abord, puis le nom,
    /// uniquement parmi les apps normales (icône dans le Dock). Évite les extensions et assistants
    /// qui portent le même nom (ex. « Gemini » = extension Finder de Gemini).
    static func runningApp(for t: Target) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let b = t.bundleID, let app = apps.first(where: { $0.bundleIdentifier == b }) { return app }
        return apps.first { matches($0, t) }
    }

    static func matches(_ app: NSRunningApplication, _ t: Target) -> Bool {
        guard app.activationPolicy == .regular else { return false }
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
    func fire(_ t: Target, external: ExternalDictation? = nil, completion: ((Bool) -> Void)? = nil) {
        guard AXIsProcessTrusted() else {
            log("Accessibilité non accordée : raccourci ignoré.")
            completion?(false)
            return
        }
        let activate = external != nil || (t.activate ?? true)
        readGeneration += 1 // nouvelle demande : annule une lecture en attente
        reading = nil
        pausedReading = nil
        externalDictationWindow = nil

        // Une cible temporaire d'éditeur garde le champ qui a déjà le focus.
        if let external, t.phrases.isEmpty {
            guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == t.bundleID else {
                completion?(false)
                return
            }
            startExternalDictation(external, for: t, in: app, completion)
            return
        }

        if let app = Self.runningApp(for: t) {
            guard activate else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.send(t, completion) }
                return
            }
            // L'app doit être réellement au premier plan (fenêtre affichée) avant le clic.
            Self.bringToFront(app, target: t) { active in
                guard active else {
                    log("\(t.id) : impossible de mettre l'app au premier plan.")
                    completion?(false)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let external { self.startExternalDictation(external, for: t, in: app, completion) }
                    else { self.send(t, patience: 5, foregroundApp: app, completion) }
                }
            }
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
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, error in
            DispatchQueue.main.asyncAfter(deadline: .now() + (t.launchDelaySeconds ?? 3)) {
                guard let app else {
                    log("\(t.id) : lancement impossible : \(error?.localizedDescription ?? "application indisponible")")
                    completion?(false)
                    return
                }
                if let external { self.startExternalDictation(external, for: t, in: app, completion) }
                else { self.send(t, patience: 20, foregroundApp: activate ? app : nil, completion) }
            }
        }
    }

    private func startExternalDictation(
        _ external: ExternalDictation, for target: Target, in app: NSRunningApplication,
        _ completion: ((Bool) -> Void)?
    ) {
        guard AXButtonPresser.isFrontmost(app), let element = AXButtonPresser.focusedWindow(in: app) else {
            log("\(target.id) : fenêtre de dictée indisponible.")
            completion?(false)
            return
        }
        let window = DictationWindow(app: app, element: element)
        let focused = AXButtonPresser.focusedTextField(in: app)
        let field: AXUIElement?
        if let labels = target.dictationFieldLabels, !labels.isEmpty {
            field = AXButtonPresser.textField(in: element, labeled: labels)
        } else {
            field = focused
        }
        guard let field, window.isFocused,
              focused.map({ CFEqual($0, field) }) == true || AXButtonPresser.focus(field) else {
            log("\(target.id) : champ de saisie indisponible pour la dictée externe.")
            completion?(false)
            return
        }
        let allowed = {
            AXIsProcessTrusted() && window.isFocused &&
                AXButtonPresser.focusedTextField(in: app).map { CFEqual($0, field) } == true
        }
        if external.useMacOSDictationMenu == true {
            let started = AXButtonPresser.startMacOSDictation(in: app, while: allowed)
            if started { externalDictationWindow = window }
            log(started ? "\(target.id) : commande Dictée macOS activée." :
                "\(target.id) : commande Dictée macOS indisponible ou champ inactif.")
            completion?(started)
            return
        }
        ShortcutPlayer.play(external.shortcut, while: allowed) { played in
            if played { self.externalDictationWindow = window }
            log(played ? "\(target.id) : raccourci de dictée externe envoyé." : "\(target.id) : dictée externe annulée, champ inactif.")
            completion?(played)
        }
    }

    /// Envoi vocal : coupe le micro de l'app (en rejouant son raccourci), attend le texte, puis envoie.
    func submit(_ t: Target, in window: DictationWindow?, stopFirst: Bool, completion: @escaping (Bool) -> Void) {
        guard let window, window.isFocused else {
            log("\(t.id) : envoi annulé, fenêtre de dictée indisponible.")
            completion(false)
            return
        }
        var submitTarget = t
        submitTarget.shortcut = t.submitShortcut ?? (try! Shortcut(spec: "return"))
        let finish = {
            // Pour un bouton, l'état actif du composeur remplace l'attente fixe.
            let usesKeys = submitTarget.shortcut.buttons.isEmpty
            let delay = stopFirst && usesKeys ? (t.submitDelaySeconds ?? 1.5) : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.send(submitTarget, patience: 6, in: window, retryInterval: 0.15, completion)
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

    /// Appelé quand une lecture lancée par VoiceWake se termine d'elle-même (ni pause ni interruption).
    var onReadingFinished: ((Target, DictationWindow) -> Void)?

    func reopenDictation(_ target: Target, in window: DictationWindow, completion: @escaping (Bool) -> Void) {
        send(target, in: window, systemShortcut: true, completion)
    }
    private var readGeneration = 0
    /// Lecture à voix haute lancée par VoiceWake (cible et date), effacée à la demande suivante.
    private(set) var reading: (target: Target, since: Date)?
    /// Lecture mise en pause à la voix (« arrête la lecture »), reprenable 10 min.
    private(set) var pausedReading: (target: Target, since: Date)?

    func pausedTarget() -> Target? {
        guard let p = pausedReading, Date().timeIntervalSince(p.since) < 600 else { return nil }
        return p.target
    }

    /// « Arrête la lecture » : pause seulement.
    func pauseReading(_ t: Target) {
        guard let pause = t.pauseReadShortcut else { return log("\(t.id) : pas de bouton de pause configuré.") }
        var pauseTarget = t
        pauseTarget.shortcut = pause
        reading = nil
        pausedReading = (t, Date())
        send(pauseTarget) { ok in if !ok { log("\(t.id) : pause de la lecture non effectuée.") } }
    }

    /// « Reprends la lecture » : reprise là où elle s'était arrêtée.
    func resumeReading(_ t: Target) {
        guard let resume = t.resumeReadShortcut, let app = Self.runningApp(for: t) else {
            // Pas de reprise dans l'app (Codex : arrêt seulement) : on relance la lecture de la dernière réponse.
            guard t.readAloudShortcut != nil else { return log("\(t.id) : pas de bouton de reprise configuré.") }
            return readAloudNow(t) { ok in
                log(ok ? "\(t.id) : lecture relancée depuis le début." : "\(t.id) : reprise de la lecture non effectuée.")
            }
        }
        var resumeTarget = t
        resumeTarget.shortcut = resume
        pausedReading = nil
        send(resumeTarget) { ok in
            if ok { self.startReading(t, app: app) } else { log("\(t.id) : reprise de la lecture non effectuée.") }
        }
    }

    /// « Fais la lecture » : clique tout de suite le dernier bouton de lecture à voix haute de l'assistant.
    func readAloudNow(_ t: Target, completion: @escaping (Bool) -> Void) {
        guard let labels = t.readAloudShortcut?.buttons, !labels.isEmpty, let app = Self.runningApp(for: t),
              let window = AXButtonPresser.currentWindow(in: app) else { return completion(false) }
        readGeneration += 1
        let gen = readGeneration
        pausedReading = nil
        DispatchQueue.global().async {
            var ok = AXButtonPresser.pressLast(labels, in: app, window: window)
            if let item = t.readAloudMenuItem {
                usleep(500_000)
                ok = AXButtonPresser.pressMenuItem(item, in: app)
            }
            DispatchQueue.main.async {
                guard gen == self.readGeneration else { return }
                if ok { self.startReading(t, app: app) }
                completion(ok)
            }
        }
    }

    /// Cible dont VoiceWake a lancé la lecture il y a moins de `within` secondes.
    func readingTarget(within seconds: TimeInterval = 900) -> Target? {
        guard let r = reading, Date().timeIntervalSince(r.since) < seconds else { return nil }
        return r.target
    }

    /// Lecture lancée : surveille le son de l'app et ne considère la lecture finie qu'après
    /// 3 s de silence continu (les pauses entre phrases ne lèvent pas la protection).
    private func startReading(_ t: Target, app: NSRunningApplication, in window: DictationWindow? = nil) {
        reading = (t, Date())
        let origin = window ?? Self.dictationWindow(for: t)
        let gen = readGeneration
        let bundle = t.bundleID ?? app.bundleIdentifier ?? ""
        DispatchQueue.global().async {
            var silentSince: Date?
            var heardPlayback = false
            let startedAt = ProcessInfo.processInfo.systemUptime
            while true {
                usleep(500_000)
                // Signal le plus fiable : le bouton de pause, visible seulement pendant la lecture (Claude).
                // Sinon, le son de l'app.
                let pauseLabels = t.pauseReadShortcut?.buttons ?? []
                let playing = !pauseLabels.isEmpty
                    ? !AXButtonPresser.all(pauseLabels, in: app, window: origin?.element).isEmpty
                    : (!bundle.isEmpty && MicMonitor.isOutputRunning(bundlePrefixes: [bundle]))
                var done = false
                if playing {
                    heardPlayback = true
                    silentSince = nil
                } else if !heardPlayback {
                    done = ProcessInfo.processInfo.systemUptime - startedAt >= 15
                } else if let s = silentSince {
                    done = Date().timeIntervalSince(s) >= 3
                } else { silentSince = Date() }
                let stop: Bool = DispatchQueue.main.sync {
                    guard gen == self.readGeneration, self.reading != nil else { return true }
                    if done {
                        self.reading = nil
                        log(heardPlayback ? "\(t.id) : lecture terminée." : "\(t.id) : lecture non confirmée.")
                        if heardPlayback, let origin {
                            DispatchQueue.main.async {
                                guard gen == self.readGeneration else { return }
                                self.onReadingFinished?(t, origin)
                            }
                        }
                    }
                    return done
                }
                if stop { return }
            }
        }
    }

    /// Attend la fin de la réponse, puis clique le dernier bouton de lecture à voix haute.
    /// Fin = indicateur « en cours » (busyLabels) disparu, ou nouveau bouton de lecture, stable 2 s.
    func readAloudBaseline(_ t: Target, in window: DictationWindow?) -> ReadBaseline? {
        guard let labels = t.readAloudShortcut?.buttons, !labels.isEmpty, let window, window.isFocused else { return nil }
        let busy = readBusyLabels(t)
        return ReadBaseline(
            buttons: AXButtonPresser.all(labels, in: window.app, window: window.element),
            busy: !busy.isEmpty && !AXButtonPresser.all(busy, in: window.app, window: window.element, anyRole: true).isEmpty
        )
    }

    private func readBusyLabels(_ target: Target) -> [String] {
        target.busyLabels ?? (target.bundleID == "com.openai.codex" ? ["Arrêter", "Stop"] : [])
    }

    /// Assistant sans lecture à voix haute (extension d'éditeur, ChatGPT) : la réponse est considérée finie
    /// quand le texte de la fenêtre a changé puis n'a plus bougé pendant 6 s, sans indicateur « en cours ».
    func whenAnswerDone(_ t: Target, in window: DictationWindow?, completion: @escaping () -> Void) {
        guard let window, window.isFocused else { return }
        let app = window.app
        readGeneration += 1
        let gen = readGeneration
        let busy = readBusyLabels(t)
        let timeout = t.readAloudTimeoutSeconds ?? 600
        log("\(t.id) : attente de la fin de la réponse.")
        DispatchQueue.global().async {
            let start = Date()
            var last: String?
            var changed = false
            var stableSince = Date()
            while Date().timeIntervalSince(start) < timeout {
                usleep(1_500_000)
                guard DispatchQueue.main.sync(execute: { gen == self.readGeneration }) else { return }
                guard window.isFocused else { return log("\(t.id) : attente annulée, fenêtre changée.") }
                let text = AXButtonPresser.windowTexts(in: app).joined(separator: "\n")
                if text != last {
                    if last != nil { changed = true }
                    last = text
                    stableSince = Date()
                    continue
                }
                if !busy.isEmpty, !AXButtonPresser.all(busy, in: app, window: window.element, anyRole: true).isEmpty {
                    stableSince = Date()
                    continue
                }
                guard changed, Date().timeIntervalSince(stableSince) >= 6 else { continue }
                DispatchQueue.main.async {
                    guard gen == self.readGeneration else { return }
                    log("\(t.id) : réponse terminée.")
                    completion()
                }
                return
            }
        }
    }

    func readAloudWhenDone(_ t: Target, in window: DictationWindow?, baseline: ReadBaseline?) {
        guard let labels = t.readAloudShortcut?.buttons, !labels.isEmpty,
              let window, window.isFocused, let baseline else { return }
        let app = window.app
        readGeneration += 1
        let gen = readGeneration
        let busy = readBusyLabels(t)
        let timeout = t.readAloudTimeoutSeconds ?? 600
        log("\(t.id) : lecture à voix haute à la fin de la réponse.")
        DispatchQueue.global().async {
            let start = Date()
            var sawBusy = baseline.busy
            var stable = 0
            while Date().timeIntervalSince(start) < timeout {
                usleep(500_000)
                guard DispatchQueue.main.sync(execute: { gen == self.readGeneration }) else { return }
                guard window.isFocused else {
                    log("\(t.id) : lecture automatique annulée, fenêtre changée.")
                    return
                }
                let isBusy = !busy.isEmpty && !AXButtonPresser.all(busy, in: app, window: window.element, anyRole: true).isEmpty
                if isBusy { sawBusy = true; stable = 0; continue }
                let buttons = AXButtonPresser.all(labels, in: app, window: window.element)
                let newest = buttons.last
                let newButton = newest.map { latest in !baseline.buttons.contains(where: { CFEqual($0, latest) }) } ?? false
                stable = (newButton || (sawBusy && newest != nil)) ? stable + 1 : 0
                if stable >= 4 {
                    guard DispatchQueue.main.sync(execute: { gen == self.readGeneration }) else { return }
                    var ok = AXButtonPresser.pressLast(labels, in: app, window: window.element)
                    if let item = t.readAloudMenuItem {
                        // Le bouton ouvre un menu (certaines apps signalent un échec alors que le menu s'ouvre).
                        usleep(500_000)
                        guard window.isFocused, DispatchQueue.main.sync(execute: { gen == self.readGeneration }) else { return }
                        ok = AXButtonPresser.pressMenuItem(item, in: app)
                    }
                    DispatchQueue.main.async {
                        guard gen == self.readGeneration, window.isFocused else { return }
                        if ok { self.startReading(t, app: app, in: window) }
                        log(ok ? "\(t.id) : lecture à voix haute lancée." : "\(t.id) : bouton de lecture introuvable.")
                    }
                    return
                }
            }
            DispatchQueue.main.async { log("\(t.id) : réponse trop longue, lecture non lancée.") }
        }
    }

    /// Met la lecture à voix haute en pause (pauseReadShortcut), puis rouvre le micro de l'app.
    func interruptAndDictate(_ t: Target, external: ExternalDictation? = nil, completion: ((Bool) -> Void)? = nil) {
        guard let pause = t.pauseReadShortcut else { return fire(t, external: external, completion: completion) }
        var pauseTarget = t
        pauseTarget.shortcut = pause
        send(pauseTarget) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.fire(t, external: external, completion: completion) }
        }
    }

    /// Coupe le micro de l'app (stopShortcut, sinon le raccourci d'ouverture).
    func stopDictation(
        _ t: Target, in window: DictationWindow?, external: ExternalDictation? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        guard let window, window.isFocused else {
            log("\(t.id) : arrêt annulé, fenêtre de dictée indisponible.")
            completion(false)
            return
        }
        var stopTarget = t
        if let external {
            guard let stop = external.stopShortcut else { completion(false); return }
            stopTarget.shortcut = stop
        } else {
            stopTarget.shortcut = t.stopShortcut ?? t.shortcut
        }
        // Le raccourci de la Dictée macOS doit passer par le système.
        let usesOpeningShortcut = stopTarget.shortcut.spec == t.shortcut.spec
        let verifyMicrophone = external == nil && t.bundleID == "com.openai.codex" &&
            MicMonitor.isInputRunning(pid: window.app.processIdentifier, bundle: t.bundleID) == true
        send(stopTarget, in: window, systemShortcut: external != nil || usesOpeningShortcut) { stopped in
            if stopped && verifyMicrophone {
                DispatchQueue.global().async {
                    let deadline = ProcessInfo.processInfo.systemUptime + 4
                    var closed = false
                    repeat {
                        guard window.isFocused else { break }
                        closed = MicMonitor.isInputRunning(pid: window.app.processIdentifier, bundle: t.bundleID) == false
                        if !closed { usleep(100_000) }
                    } while !closed && ProcessInfo.processInfo.systemUptime < deadline
                    let confirmed = closed
                    DispatchQueue.main.async {
                        if !confirmed { log("\(t.id) : fermeture du micro non confirmée.") }
                        completion(confirmed && window.isFocused)
                    }
                }
                return
            }
            let open = t.shortcut.buttons
            if !stopped, external == nil, !open.isEmpty, window.isFocused,
               !AXButtonPresser.all(open, in: window.app, window: window.element).isEmpty {
                log("\(t.id) : micro déjà fermé par l'application.")
                completion(true)
            } else {
                completion(stopped)
            }
        }
    }

    /// Met l'app au premier plan et attend qu'elle le soit (3 s max).
    /// Depuis macOS 14, `activate()` appelé par une app en arrière-plan peut être refusé :
    /// on passe alors par LaunchServices (comme un clic dans le Dock), qui affiche aussi une app masquée.
    static func bringToFront(_ app: NSRunningApplication, target t: Target, completion: @escaping (Bool) -> Void) {
        if AXButtonPresser.isFrontmost(app) { return completion(true) }
        app.unhide()
        activate(app)
        // Accessibilité : accepté même depuis un service en arrière-plan (activate() peut être refusé).
        let el = AXUIElementCreateApplication(app.processIdentifier)
        let unhidden = AXUIElementSetAttributeValue(el, kAXHiddenAttribute as CFString, kCFBooleanFalse)
        let front = AXUIElementSetAttributeValue(el, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        log("\(t.id) : mise au premier plan (AX masquage \(unhidden.rawValue), premier plan \(front.rawValue)).")
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &windows) == .success,
           let first = (windows as? [AXUIElement])?.first {
            AXUIElementSetAttributeValue(first, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(first, kAXRaiseAction as CFString)
        }
        // Jusqu'à 5 s. Si l'activation directe est refusée, on repasse par LaunchServices
        // (comme un clic dans le Dock) après 0,75 s, puis une seconde fois après 3 s.
        func poll(_ remaining: Int) {
            if AXButtonPresser.isFrontmost(app) { return completion(true) }
            if remaining <= 0 { return completion(false) }
            if remaining == 17 || remaining == 8, let url = app.bundleURL ?? appURL(for: t) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
                AXUIElementSetAttributeValue(el, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll(remaining - 1) }
        }
        poll(20)
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
        systemShortcut: Bool = false, foregroundApp: NSRunningApplication? = nil,
        retryInterval: Double = 0.5, _ completion: ((Bool) -> Void)?
    ) {
        let s = t.shortcut
        let allowed = { AXIsProcessTrusted() && (window?.isFocused ?? foregroundApp.map(AXButtonPresser.isFrontmost) ?? true) }
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
            for attempt in 0..<max(1, Int(ceil(patience / retryInterval))) where pressed == nil {
                if attempt > 0 { usleep(UInt32(retryInterval * 1_000_000)) }
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
