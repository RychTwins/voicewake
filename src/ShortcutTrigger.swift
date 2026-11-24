import AppKit
import ApplicationServices

final class ShortcutTrigger {
    private(set) var externalDictationWindow: DictationWindow?
    private(set) var nativeDictationWindow: DictationWindow?

    struct ReadBaseline {
        let buttons: [AXUIElement]
        let busy: Bool
        let codexReply: AXUIElement?
    }

    struct DictationWindow {
        let app: NSRunningApplication
        let element: AXUIElement
        let target: Target
        var conversation: ConversationGuard<AXButtonPresser.ConversationIdentity>? = nil

        var isFocused: Bool {
            AXButtonPresser.isFrontmost(app) &&
                AXButtonPresser.currentWindow(in: app).map { CFEqual($0, element) } == true
        }

        var isSameConversation: Bool {
            guard let conversation else { return false }
            let current = isFocused ? AXButtonPresser.conversationIdentity(in: element, target: target) : nil
            return conversation.check(current)
        }

        var allowsAction: Bool { conversation == nil ? isFocused : isSameConversation }

        /// Vrai quand le tour est perdu pour de bon : chat ou fenêtre changé depuis plus de 2 s (un écart bref,
        /// le temps que l'app passe au premier plan, ne compte pas).
        var isLost: Bool {
            guard let conversation else { return !isFocused }
            _ = isSameConversation
            return conversation.isCancelled
        }

        var lossDetail: String {
            "premier plan : \(isFocused ? "oui" : "non"), repère : \(conversation?.lastMismatch ?? "aucun")"
        }
    }

    static func dictationWindow(for target: Target) -> DictationWindow? {
        guard let app = runningApp(for: target) else { return nil }
        AXButtonPresser.enableAccessibility(app)
        guard AXButtonPresser.isFrontmost(app),
              let window = AXButtonPresser.currentWindow(in: app) else { return nil }
        let identity = AXButtonPresser.conversationIdentity(in: window, target: target)
        let conversation = identity.map(ConversationGuard.init)
        conversation?.isUnknown = { $0 == .route("page:") }
        conversation?.grace = 2
        conversation?.succeeds = { old, new in
            // Repère provisoire (chat neuf) → vrai repère, une seule fois ; jamais d'un vrai chat à un autre.
            guard case .route(let before) = old, before.hasPrefix("page:") else { return false }
            if case .route(let after) = new { return !after.hasPrefix("page:") }
            return true
        }
        return DictationWindow(app: app, element: window, target: target, conversation: conversation)
    }

    /// Attend qu'une app tout juste lancée affiche sa fenêtre (essais toutes les 0,5 s). Les apps Electron
    /// n'exposent leur arbre d'accessibilité qu'une fois l'option activée : on la réactive à chaque essai.
    static func waitForWindow(_ app: NSRunningApplication, activate: Bool, remaining: Int, _ done: @escaping (Bool) -> Void) {
        AXButtonPresser.enableAccessibility(app)
        if app.isTerminated { return done(false) }
        if app.isFinishedLaunching, AXButtonPresser.currentWindow(in: app) != nil, !activate || AXButtonPresser.isFrontmost(app) {
            return done(true)
        }
        if activate, app.isFinishedLaunching, !AXButtonPresser.isFrontmost(app) { app.activate() }
        guard remaining > 0 else { return done(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitForWindow(app, activate: activate, remaining: remaining - 1, done) }
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
        nativeDictationWindow = nil

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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if AXButtonPresser.isFrontmost(app) { self.startNativeDictation(t, in: app, patience: 3, completion) }
                    else { self.send(t, completion) }
                }
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
                    else { self.startNativeDictation(t, in: app, patience: 5, completion) }
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
            DispatchQueue.main.async {
                guard let app else {
                    log("\(t.id) : lancement impossible : \(error?.localizedDescription ?? "application indisponible")")
                    completion?(false)
                    return
                }
                // Premier lancement après un redémarrage : l'app peut mettre bien plus de 20 s à afficher
                // sa fenêtre. On attend la fenêtre (60 s max), puis le délai de mise en place.
                Self.waitForWindow(app, activate: activate, remaining: 120) { ready in
                    if !ready { log("\(t.id) : fenêtre toujours absente après 60 s, dernier essai.") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (t.launchDelaySeconds ?? 3)) {
                        if let external { self.startExternalDictation(external, for: t, in: app, completion) }
                        else if activate { self.startNativeDictation(t, in: app, patience: 30, completion) }
                        else { self.send(t, patience: 30, completion) }
                    }
                }
            }
        }
    }

    private func startNativeDictation(_ target: Target, in app: NSRunningApplication, patience: Double,
                                      _ completion: ((Bool) -> Void)?) {
        let window = Self.dictationWindow(for: target)
        send(target, patience: patience, in: window, foregroundApp: app) { started in
            if started { self.nativeDictationWindow = window }
            completion?(started)
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
        let window = DictationWindow(app: app, element: element, target: target)
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
        if external.typedByVoiceWake == true {
            // VoiceWake écoute lui-même : le champ a le focus, rien d'autre à lancer.
            let identity = AXButtonPresser.conversationIdentity(in: element, target: target)
            externalDictationWindow = DictationWindow(app: app, element: element, target: target,
                                                      conversation: identity.map(ConversationGuard.init))
            log("\(target.id) : dictée par VoiceWake (texte tapé à l'envoi).")
            completion?(true)
            return
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
    func submit(_ t: Target, in window: DictationWindow?, stopFirst: Bool, automatic: Bool = false,
                completion: @escaping (Bool) -> Void) {
        guard let window, automatic ? window.isSameConversation : window.allowsAction else {
            log("\(t.id) : envoi annulé, chat ou fenêtre de dictée changé.")
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
                self.send(submitTarget, patience: 6, in: window, retryInterval: 0.15,
                          uniqueSend: automatic, completion)
            }
        }
        if stopFirst && (t.stopBeforeSubmit ?? true) {
            stopDictation(t, in: window, recoverFocus: false) { stopped in
                if stopped { finish() } else { completion(false) }
            }
        } else {
            finish()
        }
    }

    /// Appelé quand une lecture lancée par VoiceWake se termine d'elle-même (ni pause ni interruption).
    var onReadingFinished: ((Target, DictationWindow) -> Void)?
    var onReadText: ((Target, DictationWindow, String) -> Bool)?

    func reopenDictation(_ target: Target, in window: DictationWindow, completion: @escaping (Bool) -> Void) {
        guard window.isSameConversation else { return completion(false) }
        if !target.shortcut.buttons.isEmpty {
            let stop = target.stopShortcut?.buttons ?? []
            if !stop.isEmpty, stop != target.shortcut.buttons,
               !AXButtonPresser.all(stop, in: window.app, window: window.element).isEmpty {
                return completion(false)
            }
        } else if MicMonitor.isInputRunning(pid: window.app.processIdentifier, bundle: target.bundleID) == true {
            return completion(false)
        }
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

    /// Clique le dernier bouton de lecture. Si ce bouton ouvre un menu (Gemini : « Autres actions » puis « Écouter »),
    /// l'appui ne rend la main qu'après ~1,5 s, menu ouvert : l'option est donc choisie en parallèle, dès qu'elle
    /// apparaît, pour que le menu ne reste visible qu'un instant.
    private static func pressReadAloud(_ t: Target, _ labels: [String], in app: NSRunningApplication,
                                       window: AXUIElement, while allowed: @escaping () -> Bool = { true }) -> Bool {
        guard let item = t.readAloudMenuItem else { return AXButtonPresser.pressLast(labels, in: app, window: window, while: allowed) }
        DispatchQueue.global().async { _ = AXButtonPresser.pressLast(labels, in: app, window: window, while: allowed) }
        return AXButtonPresser.pressMenuItemSoon(item, in: app, within: 3, while: allowed)
    }

    /// « Fais la lecture » : clique tout de suite le dernier bouton de lecture à voix haute de l'assistant.
    func readAloudNow(_ t: Target, completion: @escaping (Bool) -> Void) {
        guard let labels = t.readAloudShortcut?.buttons, !labels.isEmpty, let app = Self.runningApp(for: t),
              let window = AXButtonPresser.currentWindow(in: app) else { return completion(false) }
        readGeneration += 1
        let gen = readGeneration
        pausedReading = nil
        if t.bundleID == "com.openai.codex" {
            guard let origin = Self.dictationWindow(for: t), origin.isSameConversation else { return completion(false) }
            DispatchQueue.global().async {
                let text = AXButtonPresser.codexReply(in: origin.element)?.text
                DispatchQueue.main.async {
                    guard gen == self.readGeneration, origin.isSameConversation, let text else { return completion(false) }
                    completion(self.onReadText?(t, origin, text) == true)
                }
            }
            return
        }
        DispatchQueue.global().async {
            let ok = Self.pressReadAloud(t, labels, in: app, window: window)
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
                let pauseVisible = !pauseLabels.isEmpty && !AXButtonPresser.all(pauseLabels, in: app, window: origin?.element).isEmpty
                let playing = pauseVisible || ((pauseLabels.isEmpty || bundle == "com.openai.codex") &&
                    !bundle.isEmpty && MicMonitor.isOutputRunning(bundlePrefixes: [bundle]))
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
                                if origin.isSameConversation { self.onReadingFinished?(t, origin) }
                            }
                        }
                    }
                    return done
                }
                if stop { return }
                _ = origin?.isSameConversation
            }
        }
    }

    /// Repère la réponse visible avant l'envoi pour éviter de lire une ancienne réponse.
    func readAloudBaseline(_ t: Target, in window: DictationWindow?) -> ReadBaseline? {
        guard let labels = t.readAloudShortcut?.buttons, !labels.isEmpty, let window, window.allowsAction else { return nil }
        let busy = readBusyLabels(t)
        return ReadBaseline(
            buttons: t.bundleID == "com.openai.codex" ? [] : AXButtonPresser.all(labels, in: window.app, window: window.element),
            busy: !busy.isEmpty && !AXButtonPresser.all(busy, in: window.app, window: window.element, anyRole: true).isEmpty,
            codexReply: t.bundleID == "com.openai.codex" ? AXButtonPresser.codexReplyHeading(in: window.element) : nil
        )
    }

    private func readBusyLabels(_ target: Target) -> [String] {
        let configured = target.busyLabels ?? []
        if target.bundleID == "com.openai.codex" {
            return configured + ["Arrêter", "Stop", "Arrêter la génération", "Stop generating"]
        }
        return configured
    }

    /// Assistant sans lecture à voix haute (extension d'éditeur, ChatGPT) : la réponse est considérée finie
    /// quand le texte de la fenêtre a changé puis n'a plus bougé pendant 6 s, sans indicateur « en cours ».
    func whenAnswerDone(_ t: Target, in window: DictationWindow?, completion: @escaping () -> Void) {
        guard let window, window.isSameConversation else { return }
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
                if window.isLost { return log("\(t.id) : attente annulée, chat changé (\(window.lossDetail)).") }
                guard window.isSameConversation else { continue }
                let text = AXButtonPresser.windowTexts(in: app, window: window.element).joined(separator: "\n")
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
              let window, window.allowsAction, let baseline else { return }
        let app = window.app
        readGeneration += 1
        let gen = readGeneration
        let busy = readBusyLabels(t)
        let isCodex = t.bundleID == "com.openai.codex"
        let timeout = t.readAloudTimeoutSeconds ?? 600
        log("\(t.id) : lecture à voix haute à la fin de la réponse.")
        DispatchQueue.global().async {
            let start = Date()
            var sawBusy = baseline.busy
            var stable = 0
            var lastReply: String?
            var stableReply = 0
            while Date().timeIntervalSince(start) < timeout {
                usleep(500_000)
                guard DispatchQueue.main.sync(execute: { gen == self.readGeneration }) else { return }
                if window.isLost {
                    log("\(t.id) : lecture automatique annulée, chat ou fenêtre changé (\(window.lossDetail)).")
                    return
                }
                guard window.allowsAction else { continue }
                let isBusy = !busy.isEmpty && !AXButtonPresser.all(busy, in: app, window: window.element, anyRole: true).isEmpty
                if isBusy {
                    sawBusy = true
                    stable = 0
                    stableReply = 0
                    lastReply = nil
                    continue
                }
                // Le bouton Codex requiert le focus clavier. Lire la nouvelle réponse terminée sans agir sur l'interface.
                if isCodex {
                    let reply = AXButtonPresser.codexReply(in: window.element)
                    let freshReply = reply.flatMap { item in
                        baseline.codexReply.map { CFEqual($0, item.heading) } == true ? nil : item.text
                    }
                    stableReply = freshReply != nil && freshReply == lastReply ? stableReply + 1 : 0
                    lastReply = freshReply
                    guard stableReply >= 8, let freshReply else { continue }
                    DispatchQueue.main.async {
                        guard gen == self.readGeneration, window.isSameConversation else { return }
                        _ = self.onReadText?(t, window, freshReply)
                    }
                    return
                }
                let buttons = AXButtonPresser.all(labels, in: app, window: window.element)
                let newest = buttons.last
                let newButton = newest.map { latest in !baseline.buttons.contains(where: { CFEqual($0, latest) }) } ?? false
                stable = (newButton || (sawBusy && newest != nil)) ? stable + 1 : 0
                if stable >= 4 {
                    guard DispatchQueue.main.sync(execute: { gen == self.readGeneration }) else { return }
                    let ok = Self.pressReadAloud(t, labels, in: app, window: window.element, while: { window.allowsAction })
                    DispatchQueue.main.async {
                        guard gen == self.readGeneration, window.allowsAction else { return }
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
        _ t: Target, in window: DictationWindow?, external: ExternalDictation? = nil, recoverFocus: Bool = true,
        completion: @escaping (Bool) -> Void
    ) {
        guard let window, window.allowsAction else {
            // La fenêtre de dictée n'est plus devant (autre app, autre fenêtre) : si le micro de l'app est
            // réellement ouvert, on la remet au premier plan et on coupe ce micro-là. Sans micro ouvert, rien :
            // le raccourci risquerait d'ouvrir une nouvelle dictée au lieu d'en fermer une.
            if recoverFocus, external == nil, let app = Self.runningApp(for: t),
               MicMonitor.isInputRunning(pid: app.processIdentifier, bundle: t.bundleID) == true {
                log("\(t.id) : fenêtre de dictée changée, micro encore ouvert : remise au premier plan pour l'arrêter.")
                Self.bringToFront(app, target: t) { active in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard active, var fresh = Self.dictationWindow(for: t) else {
                            log("\(t.id) : arrêt annulé, fenêtre de dictée indisponible.")
                            return completion(false)
                        }
                        fresh.conversation = nil // nouvelle référence : seule la fenêtre au premier plan compte
                        guard fresh.isFocused else { return completion(false) } // jamais de deuxième tentative
                        self.stopDictation(t, in: fresh, external: nil, completion: completion)
                    }
                }
                return
            }
            log("\(t.id) : arrêt annulé, fenêtre de dictée indisponible.")
            completion(false)
            return
        }
        var stopTarget = t
        if let external {
            if external.typedByVoiceWake == true { completion(true); return } // rien à arrêter : VoiceWake écoute
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
                        guard window.allowsAction else { break }
                        closed = MicMonitor.isInputRunning(pid: window.app.processIdentifier, bundle: t.bundleID) == false
                        if !closed { usleep(100_000) }
                    } while !closed && ProcessInfo.processInfo.systemUptime < deadline
                    let confirmed = closed
                    DispatchQueue.main.async {
                        if !confirmed { log("\(t.id) : fermeture du micro non confirmée.") }
                        completion(confirmed && window.allowsAction)
                    }
                }
                return
            }
            let open = t.shortcut.buttons
            if !stopped, external == nil, !open.isEmpty, window.allowsAction,
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
        retryInterval: Double = 0.5, uniqueSend: Bool = false, _ completion: ((Bool) -> Void)?
    ) {
        let s = t.shortcut
        let allowed = {
            AXIsProcessTrusted() && (uniqueSend ? window?.isSameConversation == true :
                (window?.allowsAction ?? foregroundApp.map(AXButtonPresser.isFrontmost) ?? true))
        }
        guard allowed() else {
            log("\(t.id) : action ignorée, fenêtre de dictée inactive ou accès refusé.")
            completion?(false)
            return
        }
        if s.buttons.isEmpty {
            if uniqueSend {
                completion?(false)
                return
            }
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
                    if uniqueSend, let window {
                        if AXButtonPresser.pressUniqueSend(s.buttons, in: app, window: window.element, while: allowed) {
                            pressed = s.buttons.joined(separator: " | ")
                        }
                    } else {
                        pressed = AXButtonPresser.press(s.buttons, in: app, window: window?.element, while: allowed)
                    }
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
