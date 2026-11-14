using System.Runtime.InteropServices;

namespace VoiceWake;

public static class Program
{
    private const string Usage = """
        Usage : voicewake [commande] [--config chemin]
          run            écoute en continu (défaut, lancé au démarrage de Windows)
          check          vérifie la configuration, les applications et la langue
          test <cible>   ouvre l'app et envoie son raccourci dans 3 s (sans micro)
          set <cible> "raccourci"   ex. "win+h", "ctrl+shift+v", "button:Dicter"
          route "texte"  montre quelle cible une phrase déclencherait
        """;

    public static int Main(string[] argv)
    {
        AttachConsole(-1); // affiche la sortie dans le terminal qui a lancé la commande
        var args = argv.ToList();
        var configPath = Config.DefaultPath();
        var i = args.IndexOf("--config");
        if (i >= 0 && i + 1 < args.Count) { configPath = args[i + 1]; args.RemoveRange(i, 2); }
        var command = args.FirstOrDefault() ?? "run";

        Config config;
        try { config = Config.Load(configPath); }
        catch (Exception e) { Log.Write($"Configuration invalide ({configPath}) : {e.Message}"); return 1; }

        Target? RequireTarget()
        {
            var t = args.Count >= 2 ? config.FindTarget(args[1]) : null;
            if (t == null) Console.WriteLine($"Cibles : {string.Join(", ", config.Targets.Select(x => x.Id))}");
            return t;
        }

        switch (command)
        {
            case "run":
                using (var mutex = new Mutex(true, @"Local\io.github.voicewake", out var first))
                {
                    if (!first) { Console.WriteLine("VoiceWake tourne déjà."); return 0; }
                    var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VoiceWake");
                    Directory.CreateDirectory(dir);
                    Log.FilePath = Path.Combine(dir, "voicewake.log");
                    try
                    {
                        var coordinator = new Coordinator(config);
                        coordinator.StartAsync().GetAwaiter().GetResult();
                        Thread.Sleep(Timeout.Infinite);
                    }
                    catch (Exception e) { Log.Write(e.Message); return 1; }
                }
                return 0;

            case "check":
                Console.WriteLine($"Configuration OK : {configPath}");
                foreach (var t in config.Targets)
                {
                    Console.WriteLine($"- {t.Id} : « {t.OpenSpec} » | processus : {t.ProcessName} | installée : {(Apps.IsInstalled(t) ? "oui" : "NON")} | ouverte : {(Apps.IsRunning(t) ? "oui" : "non")}");
                    Console.WriteLine($"    phrases : {string.Join(", ", t.Phrases)}");
                }
                Console.WriteLine($"- premier plan : {string.Join(", ", config.FrontmostPhrases)} → défaut : {config.DefaultTarget ?? "aucun"}");
                Console.WriteLine($"- envoi vocal : {((config.SendPhrases?.Count ?? 0) == 0 ? "désactivé" : string.Join(", ", config.SendPhrases!))}");
                Console.WriteLine($"Reconnaissance vocale {config.Locale} : {(Listener.IsLanguageSupported(config.Locale) ? "OK" : "NON (installer la langue avec la reconnaissance vocale)")}");
                return 0;

            case "test":
            {
                var t = RequireTarget();
                if (t == null) return 1;
                Console.WriteLine($"Raccourci de {t.Id} (« {t.OpenSpec} ») dans 3 s…");
                Thread.Sleep(3000);
                new Trigger().Fire(t);
                return 0;
            }

            case "set":
            {
                var t = RequireTarget();
                if (t == null || args.Count < 3) { Console.WriteLine(Usage); return 1; }
                try
                {
                    var spec = string.Join(" ", args.Skip(2));
                    Config.SaveShortcut(spec, t.Id, configPath);
                    Console.WriteLine($"✓ {t.Id} → « {spec} » enregistré (bloc \"windows\"). Relance : .\\install.ps1 -Restart");
                    return 0;
                }
                catch (Exception e) { Console.WriteLine($"Échec : {e.Message}"); return 1; }
            }

            case "route":
            {
                var n = Text.Normalize(string.Join(" ", args.Skip(1)));
                bool Has(IEnumerable<string>? list) => list?.Any(p => Text.Normalize(p) == n) == true;
                var hit = config.Targets.FirstOrDefault(t => Has(t.Phrases));
                Console.WriteLine(hit != null ? $"→ {hit.Id}" :
                    Has(config.FrontmostPhrases) ? "→ application au premier plan" :
                    Has(config.SendPhrases) ? "→ phrase d'envoi (pendant une dictée)" :
                    Has(config.StopPhrases) ? "→ phrase d'arrêt du micro (pendant une dictée)" :
                    Has(config.InterruptPhrases) ? "→ interruption de la lecture" : "→ aucune cible");
                Console.WriteLine("(Windows reconnaît uniquement les phrases exactes de la config, dites seules.)");
                return 0;
            }

            default:
                Console.WriteLine(Usage);
                return command is "help" or "--help" ? 0 : 1;
        }
    }

    [DllImport("kernel32.dll")] private static extern bool AttachConsole(int dwProcessId);
}
