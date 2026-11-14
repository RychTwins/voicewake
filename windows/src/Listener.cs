using Windows.Globalization;
using Windows.Media.SpeechRecognition;

namespace VoiceWake;

/// Écoute le micro en continu et ne reconnaît que les phrases de la config (liste fermée, hors ligne).
/// Chaque phrase est reconnue comme un énoncé à part : il faut une petite pause avant et après,
/// ce qui évite naturellement les déclenchements en pleine phrase.
public sealed class Listener
{
    public const string Front = "front", Send = "send", Stop = "stop", Interrupt = "interrupt", WakePrefix = "wake:";

    /// (tag, texte reconnu, confiance 0–1)
    public event Action<string, string, double>? Heard;

    private readonly Config config;
    private SpeechRecognizer? recognizer;
    private volatile bool running;

    public Listener(Config config) => this.config = config;

    public static bool IsLanguageSupported(string locale) =>
        SpeechRecognizer.SupportedGrammarLanguages.Any(l => l.LanguageTag.Equals(locale, StringComparison.OrdinalIgnoreCase));

    public async Task StartAsync()
    {
        if (!IsLanguageSupported(config.Locale))
            throw new InvalidOperationException(
                $"Langue {config.Locale} non installée pour la reconnaissance vocale : Paramètres > Heure et langue > Langue et région > Français > Options > Reconnaissance vocale.");

        recognizer = new SpeechRecognizer(new Language(config.Locale));
        foreach (var t in config.Targets)
            Add(t.Phrases, WakePrefix + t.Id);
        Add(config.FrontmostPhrases, Front);
        Add(config.SendPhrases, Send);
        Add(config.StopPhrases, Stop);
        Add(config.InterruptPhrases, Interrupt);

        var compiled = await recognizer.CompileConstraintsAsync();
        if (compiled.Status != SpeechRecognitionResultStatus.Success)
            throw new InvalidOperationException($"Phrases non compilées : {compiled.Status}");

        var session = recognizer.ContinuousRecognitionSession;
        session.AutoStopSilenceTimeout = TimeSpan.FromHours(12);
        session.ResultGenerated += (_, e) =>
        {
            var r = e.Result;
            if (config.Debug) Log.Write($"… {r.Text} ({r.Constraint?.Tag}, {r.RawConfidence:0.00})");
            if (r.Status != SpeechRecognitionResultStatus.Success || r.Confidence == SpeechRecognitionConfidence.Rejected) return;
            if (r.Constraint?.Tag is string tag) Heard?.Invoke(tag, r.Text, r.RawConfidence);
        };
        // La session s'arrête parfois (veille, changement de micro, délai) : on la relance.
        session.Completed += async (_, e) =>
        {
            if (!running) return;
            Log.Write($"Écoute interrompue ({e.Status}), redémarrage.");
            await Task.Delay(2000);
            try { await session.StartAsync(); } catch (Exception ex) { Log.Write($"Redémarrage impossible : {ex.Message}"); }
        };

        running = true;
        await session.StartAsync();
        Log.Write($"En écoute ({config.Locale}).");
    }

    private void Add(IEnumerable<string>? phrases, string tag)
    {
        var list = phrases?.Where(p => !string.IsNullOrWhiteSpace(p)).Distinct().ToList();
        if (list == null || list.Count == 0) return;
        recognizer!.Constraints.Add(new SpeechRecognitionListConstraint(list, tag));
    }
}
