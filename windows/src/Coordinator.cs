using System.Collections.Concurrent;

namespace VoiceWake;

/// Veille → micro de l'app → « ok arrête » / « ok envoie » → lecture à voix haute → veille.
/// Toute la logique tourne sur une seule file série : pas de verrous.
public sealed class Coordinator
{
    private readonly Config config;
    private readonly Listener listener;
    private readonly Trigger trigger = new();
    private readonly BlockingCollection<Action> queue = new();

    private DateTime lastWake = DateTime.MinValue;
    private Target? active;          // cible en cours de dictée
    private bool recording;          // micro de l'app ouvert (false après « ok arrête »)
    private DateTime? reviewUntil;   // après « ok arrête » : attente de « ok envoie »
    private System.Threading.Timer? pauseTimer;
    private CancellationTokenSource? pendingCommand;
    private int pauseGen;            // invalide les ticks d'une pause terminée

    public Coordinator(Config config)
    {
        this.config = config;
        listener = new Listener(config);
        listener.Heard += (tag, text, conf) => queue.Add(() => Handle(tag, text, conf));
        new Thread(() => { foreach (var a in queue.GetConsumingEnumerable()) Safe(a); })
            { IsBackground = true, Name = "voicewake" }.Start();
    }

    public async Task StartAsync()
    {
        await listener.StartAsync();
        Log.Write($"VoiceWake prêt. Cibles : {string.Join(", ", config.Targets.Select(t => t.Id))}.");
    }

    private static void Safe(Action a)
    {
        try { a(); } catch (Exception e) { Log.Write($"Erreur : {e.Message}"); }
    }

    private void Handle(string tag, string text, double confidence)
    {
        if (confidence < (config.MinConfidence ?? 0.5)) return;

        // En pleine dictée : seules les commandes d'envoi / d'arrêt comptent.
        if (active is Target current)
        {
            if (tag == Listener.Send || (tag == Listener.Stop && recording)) ScheduleCommand(tag, text, current);
            return;
        }

        // Un assistant parle (lecture à voix haute) : seule une phrase d'interruption compte.
        var speaking = AudioMonitor.OutputtingProcess(config.Targets.Select(t => t.ProcessName));
        if (tag == Listener.Interrupt)
        {
            if (speaking == null) return;
            var t = config.Targets.First(x => x.ProcessName.Equals(speaking, StringComparison.OrdinalIgnoreCase));
            lastWake = DateTime.UtcNow;
            Log.Write($"Interruption de la lecture → {t.Id} (« {text} »).");
            trigger.InterruptAndDictate(t);
            StartPause(t);
            return;
        }
        if (speaking != null)
        {
            if (config.Debug) Log.Write($"Phrase ignorée : un assistant parle (« {text} »).");
            return;
        }

        Target? target = tag == Listener.Front
            ? Apps.Frontmost(config) ?? (config.DefaultTarget is string d ? config.FindTarget(d) : null)
            : tag.StartsWith(Listener.WakePrefix) ? config.FindTarget(tag[Listener.WakePrefix.Length..]) : null;
        if (target == null) return;
        if ((DateTime.UtcNow - lastWake).TotalSeconds < config.CooldownSeconds) return;
        lastWake = DateTime.UtcNow;
        Log.Write($"Phrase détectée → {target.Id} (« {text} »).");
        trigger.Fire(target);
        StartPause(target);
    }

    /// Commande dite, puis silence (sendSilenceSeconds) : on agit, sauf si une autre phrase suit.
    private void ScheduleCommand(string tag, string text, Target t)
    {
        pendingCommand?.Cancel();
        var cts = pendingCommand = new CancellationTokenSource();
        var delay = TimeSpan.FromSeconds(config.SendSilenceSeconds ?? 1.2);
        Task.Delay(delay, cts.Token).ContinueWith(task =>
        {
            if (task.IsCanceled) return;
            queue.Add(() =>
            {
                if (cts.IsCancellationRequested || active?.Id != t.Id) return;
                if (tag == Listener.Stop)
                {
                    Log.Write($"Phrase d'arrêt détectée → {t.Id} (« {text} »). En attente de « ok envoie ».");
                    recording = false;
                    reviewUntil = DateTime.UtcNow.AddSeconds(config.ReviewSeconds ?? 180);
                    trigger.StopDictation(t);
                    return;
                }
                Log.Write($"Phrase d'envoi détectée → {t.Id} (« {text} »).");
                var stopFirst = recording;
                EndPause();
                trigger.Submit(t, stopFirst);
                Log.Write("Reprise de la veille (message envoyé).");
                trigger.ReadAloudWhenDone(t);
            });
        });
    }

    /// Reste en pause tant qu'une autre application utilise le micro.
    /// Avec l'envoi vocal, VoiceWake continue d'écouter (micro partagé sous Windows).
    private void StartPause(Target t)
    {
        var listening = (config.SendPhrases?.Count ?? 0) > 0;
        var c = config.Conversation;
        var started = DateTime.UtcNow;
        var lastActive = started;
        var sawConversation = false;
        Log.Write($"Pause pendant la conversation{(listening ? " (envoi vocal actif)" : "")}.");
        if (listening) { active = t; recording = true; reviewUntil = null; }

        pauseTimer?.Dispose();
        var gen = ++pauseGen;
        pauseTimer = new System.Threading.Timer(_ => queue.Add(() =>
        {
            if (gen != pauseGen) return;
            var now = DateTime.UtcNow;
            var elapsed = (now - started).TotalSeconds;
            if (AudioMonitor.IsMicInUseByOtherApp())
            {
                lastActive = now;
                if (!sawConversation) { sawConversation = true; Log.Write("Conversation en cours."); }
            }
            var idle = (now - lastActive).TotalSeconds;
            string? reason =
                elapsed >= c.MaxPauseMinutes * 60 ? "durée maximale atteinte" :
                reviewUntil is DateTime until ? (now >= until ? "pas de « ok envoie » après relecture" : null) :
                elapsed >= c.StartGraceSeconds && idle >= c.IdleSecondsBeforeResume
                    ? (sawConversation ? "conversation terminée" : "aucune conversation détectée") : null;
            if (reason == null) return;
            EndPause();
            Log.Write($"Reprise de la veille ({reason}).");
        }), null, 1000, 1000);
    }

    private void EndPause()
    {
        pauseGen++;
        pauseTimer?.Dispose();
        pauseTimer = null;
        pendingCommand?.Cancel();
        active = null;
        recording = false;
        reviewUntil = null;
    }
}
