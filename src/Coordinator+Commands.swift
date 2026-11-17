import AppKit
import AVFoundation

extension Coordinator {
    // MARK: Commandes universelles

    /// Libellé lu dans l'app : journalisé seulement en mode debug (un bouton peut porter un titre de conversation).
    func label(_ title: String) -> String { config.debug ? " « \(title) »" : "" }

    func runUniversal(_ kind: Universal.Kind, _ query: [String], in app: NSRunningApplication) {
        let name = app.localizedName ?? "app"
        DispatchQueue.global().async { [weak self] in
            let action = Universal.find(kind, query, in: app)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let action else {
                    Feedback.play(.failed)
                    Bilan.record(.universal, (kind == .menu ? "menu " : "clique sur ") + (self.config.debug ? query.joined(separator: " ") : "rien ne correspond"))
                    return log("Commande universelle → \(name) : rien ne correspond\(self.config.debug ? " à « \(query.joined(separator: " ")) »" : "").")
                }
                if self.config.dryRun == true { return log("[essai] → \(kind == .menu ? "menu" : "bouton")\(self.label(action.title)) dans \(name)") }
                if action.dangerous { return self.askConfirmation(action, in: name) }
                self.performUniversal(action, in: name)
            }
        }
    }

    // MARK: « Écris … »

    func writeText(_ typed: String) {
        guard !typed.isEmpty else { Feedback.play(.failed); return log("Écris : texte vide.") }
        guard let app = Universal.frontApp(), let bid = app.bundleIdentifier, Universal.allowedApps(config).contains(bid) else {
            Feedback.play(.failed)
            Bilan.record(.write, "app non autorisée")
            return log("Écris : app au premier plan non autorisée (ajouter son identifiant à universalApps).")
        }
        let name = app.localizedName ?? bid
        if config.dryRun == true { return log("[essai] → écris dans \(name)\(said(typed))") }
        DispatchQueue.global().async { [weak self] in
            // Seulement le champ qui a déjà le focus : le texte ne part jamais dans un autre champ.
            var ok = false
            if let field = AXButtonPresser.focusedTextField(in: app) {
                ok = TextTyper.type(typed, to: app.processIdentifier, while: {
                    AXButtonPresser.isFrontmost(app) && AXButtonPresser.focusedTextField(in: app).map { CFEqual($0, field) } == true
                })
            }
            DispatchQueue.main.async {
                guard let self else { return }
                Feedback.play(ok ? .understood : .failed)
                if !ok { Bilan.record(.write, "aucun champ de saisie actif") }
                log("Écris → \(name) : \(ok ? "\(typed.count) caractères tapés" : "aucun champ de saisie actif")\(self.said(typed)).")
            }
        }
    }

    // MARK: Commandes du Mac

    func systemCommand(_ text: String) -> SystemCommand? {
        guard config.jarvisEnabled, config.systemCommands ?? true else { return nil }
        return SystemCommands.match(text, apps: SystemCommands.installedApps(), running: SystemCommands.runningApps() + SystemCommands.targetApps(config),
                                    front: Universal.frontApp()?.bundleIdentifier)
    }

    func runSystem(_ sys: SystemCommand) {
        let what: String
        switch sys {
        case let .launch(p), let .activate(p): what = "ouvrir \(SystemCommands.appName(p))"
        case let .quit(id): what = "quitter \(SystemCommands.appName(id))"
        case let .hide(id): what = "cacher \(SystemCommands.appName(id))"
        default: what = "\(sys)"
        }
        if config.dryRun == true { return log("[essai] → Mac : \(what)") }
        let run = {
            let ok = SystemCommands.perform(sys)
            Feedback.play(ok ? .understood : .failed)
            if !ok { Bilan.record(.system, "\(sys)".split(separator: "(").first.map(String.init) ?? "mac") }
            log("Mac : \(what) \(ok ? "fait" : "impossible").")
        }
        if sys.dangerous {
            log("Confirmation demandée → Mac : \(what).")
            return askConfirmation(what, run: run)
        }
        run()
    }

    // MARK: Finder et Réglages Système

    func macCommand(_ text: String) -> MacCommand? {
        guard config.jarvisEnabled, config.systemCommands ?? true else { return nil }
        if let s = SettingsCommands.match(text) { return .settings(s) }
        // « Joue la musique », « musique suivante » : touches multimédia (commandes du Mac), pas une recherche.
        if !SystemCommands.fixedPhrases.contains(normalize(text)),
           let m = MediaCommands.match(text, front: Universal.frontApp()?.bundleIdentifier) { return .media(m) }
        if let b = BrowserCommands.match(text, front: Universal.frontApp()?.bundleIdentifier) { return .browser(b) }
        guard let f = FinderCommands.match(text) else { return nil }
        // Sélection du Finder : seulement Finder au premier plan (« supprime » ailleurs ne vise jamais un fichier).
        if f.needsFinderFront, Universal.frontApp()?.bundleIdentifier != "com.apple.finder" { return nil }
        return .finder(f)
    }

    func runMac(_ mac: MacCommand) {
        let title: String, dangerous: Bool
        switch mac {
        case let .finder(f): (title, dangerous) = (f.title, f.dangerous)
        case let .settings(c): (title, dangerous) = (c.title, c.dangerous)
        case let .media(m): (title, dangerous) = (m.title, false)
        case let .browser(b): (title, dangerous) = (b.title, false)
        }
        let front = Universal.frontApp()
        if config.dryRun == true { return log("[essai] → \(title)") }
        let config = self.config
        let run = { [weak self] in
            DispatchQueue.global().async {
                let result: (ok: Bool, detail: String)
                var say: String?
                switch mac {
                case let .finder(f): result = FinderCommands.perform(f, config: config)
                case let .settings(c): let ok = SettingsCommands.perform(c); result = (ok, ok ? "fait" : "impossible")
                case let .media(m): let r = MediaCommands.perform(m); say = r.say; result = (r.ok, r.ok ? "fait" : "impossible")
                case let .browser(b):
                    // Raccourcis : le même navigateur doit être encore devant.
                    let ok = (!b.needsBrowserFront || front.map(AXButtonPresser.isFrontmost) == true) && BrowserCommands.perform(b, front: front)
                    result = (ok, ok ? "fait" : "impossible")
                }
                DispatchQueue.main.async {
                    if let say { self?.speak(say) } // titre en cours, ou raison de l'échec
                    Feedback.play(result.ok ? .understood : .failed)
                    if !result.ok { Bilan.record(.system, "\(title) \(result.detail)") }
                    log("Mac : \(title) → \(result.detail)\(config.debug && say != nil ? " (« \(say!) »)" : "").")
                }
            }
        }
        if dangerous {
            log("Confirmation demandée → \(title).")
            return askConfirmation(title, run: run)
        }
        run()
    }
}
