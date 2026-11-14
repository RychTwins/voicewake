namespace VoiceWake;

/// Ouvre l'app, clique son micro, coupe, envoie, lance la lecture (équivalent de ShortcutTrigger.swift).
/// Toutes les méthodes sont bloquantes : appelées depuis la file série du Coordinator.
public sealed class Trigger
{
    private int readGeneration;

    /// Ouvre l'application si besoin puis envoie son raccourci d'ouverture du micro.
    public void Fire(Target t)
    {
        Interlocked.Increment(ref readGeneration); // nouvelle demande : annule une lecture en attente
        if (Apps.IsRunning(t))
        {
            if (t.Activate ?? true) Apps.Activate(t);
            Thread.Sleep(300);
            Send(t, t.OpenSpec, patience: 3);
            return;
        }
        Log.Write($"{t.Id} : lancement de l'application.");
        if (!Apps.Launch(t)) { Log.Write($"{t.Id} : application introuvable ({t.ProcessName})."); return; }
        Thread.Sleep(TimeSpan.FromSeconds(t.LaunchDelaySeconds ?? 3));
        if (t.Activate ?? true) Apps.Activate(t);
        Send(t, t.OpenSpec, patience: 20); // interface parfois lente à apparaître au premier lancement
    }

    public void StopDictation(Target t)
    {
        Apps.Activate(t);
        Thread.Sleep(200);
        Send(t, t.StopSpec ?? t.OpenSpec);
    }

    public void Submit(Target t, bool stopFirst)
    {
        Apps.Activate(t);
        Thread.Sleep(300);
        if (stopFirst && (t.StopBeforeSubmit ?? true))
        {
            Send(t, t.StopSpec ?? t.OpenSpec);
            Thread.Sleep(TimeSpan.FromSeconds(t.SubmitDelaySeconds ?? 1.5));
        }
        Send(t, t.SubmitSpec);
    }

    /// Met la lecture à voix haute en pause, puis rouvre le micro.
    public void InterruptAndDictate(Target t)
    {
        if (t.PauseReadSpec is string pause) { Send(t, pause); Thread.Sleep(500); }
        Fire(t);
    }

    /// `patience` : durée max (s) de recherche d'un bouton.
    public void Send(Target t, string spec, double patience = 3)
    {
        var s = Shortcut.Parse(spec);
        if (s.Buttons.Count == 0)
        {
            ShortcutPlayer.Play(s);
            Log.Write($"Raccourci envoyé : {s.Spec}");
            return;
        }
        var deadline = DateTime.UtcNow.AddSeconds(patience);
        do
        {
            if (Buttons.Press(t, s.Buttons) is string name) { Log.Write($"Bouton cliqué : « {name} »"); return; }
            Thread.Sleep(500);
        } while (DateTime.UtcNow < deadline);
        Log.Write($"{t.Id} : bouton introuvable ({string.Join(" | ", s.Buttons)}).");
    }

    /// Attend la fin de la réponse, puis clique le dernier bouton de lecture à voix haute.
    /// Fin = libellés « en cours » (busyLabels) disparus, ou nouveau bouton de lecture, stable 2 s.
    public void ReadAloudWhenDone(Target t)
    {
        if (t.ReadAloudSpec is not string spec) return;
        var labels = Shortcut.Parse(spec).Buttons;
        if (labels.Count == 0 || !Apps.IsRunning(t)) return;
        var gen = Interlocked.Increment(ref readGeneration);
        var busy = t.BusyLabels ?? new List<string>();
        var timeout = TimeSpan.FromSeconds(t.ReadAloudTimeoutSeconds ?? 600);
        var initial = Buttons.All(t, labels).Count;
        Log.Write($"{t.Id} : lecture à voix haute à la fin de la réponse.");
        Task.Run(() =>
        {
            var start = DateTime.UtcNow;
            bool sawBusy = false; int stable = 0;
            while (DateTime.UtcNow - start < timeout)
            {
                Thread.Sleep(1000);
                if (gen != Volatile.Read(ref readGeneration) || !Apps.IsRunning(t)) return;
                if (busy.Count > 0 && Buttons.All(t, busy, anyRole: true).Count > 0) { sawBusy = true; stable = 0; continue; }
                var grew = Buttons.All(t, labels).Count > initial;
                stable = (sawBusy || grew) ? stable + 1 : 0;
                if (stable < 2) continue;
                var ok = Buttons.Press(t, labels, last: true) != null;
                Log.Write(ok ? $"{t.Id} : lecture à voix haute lancée." : $"{t.Id} : bouton de lecture introuvable.");
                return;
            }
            Log.Write($"{t.Id} : réponse trop longue, lecture non lancée.");
        });
    }
}
