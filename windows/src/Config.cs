using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace VoiceWake;

public static class Log
{
    private static readonly object Gate = new();
    public static string? FilePath;

    public static void Write(string message)
    {
        var line = $"[{DateTime.UtcNow:yyyy-MM-ddTHH:mm:ssZ}] {message}";
        lock (Gate)
        {
            Console.WriteLine(line);
            if (FilePath != null) try { File.AppendAllText(FilePath, line + Environment.NewLine); } catch { }
        }
    }
}

public static class Text
{
    /// "Salut, Chat GPT !" -> "salutchatgpt" (même règle que la version macOS).
    public static string Normalize(string s)
    {
        var d = s.ToLowerInvariant().Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder();
        foreach (var c in d)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.NonSpacingMark) continue;
            if (char.IsLetterOrDigit(c)) sb.Append(c);
        }
        return sb.ToString();
    }
}

/// Réglages propres à Windows d'une cible (bloc "windows" du fichier de config).
public sealed class WindowsTarget
{
    /// Nom du processus sans .exe (ex. "Claude", "ChatGPT", "Codex", "Gemini").
    public string? ProcessName { get; set; }
    /// Lancement : chemin d'exe (variables %…% acceptées), "shell:AppsFolder\<AUMID>" ou "startmenu:<nom>".
    public string? Launch { get; set; }
    // Surcharges facultatives des raccourcis communs (ex. "win+h" au lieu de "ctrl+option+d").
    public string? Shortcut { get; set; }
    public string? StopShortcut { get; set; }
    public string? SubmitShortcut { get; set; }
    public string? ReadAloudShortcut { get; set; }
    public string? PauseReadShortcut { get; set; }
}

public sealed class Target
{
    public string Id { get; set; } = "";
    public string? AppName { get; set; }
    public List<string> Phrases { get; set; } = new();
    public string Shortcut { get; set; } = "";
    public string? StopShortcut { get; set; }
    public string? SubmitShortcut { get; set; }
    public bool? StopBeforeSubmit { get; set; }
    public double? SubmitDelaySeconds { get; set; }
    public string? ReadAloudShortcut { get; set; }
    public List<string>? BusyLabels { get; set; }
    public double? ReadAloudTimeoutSeconds { get; set; }
    public string? PauseReadShortcut { get; set; }
    public bool? Activate { get; set; }
    public double? LaunchDelaySeconds { get; set; }
    public WindowsTarget? Windows { get; set; }

    // Raccourcis effectifs sous Windows (surcharge "windows" sinon valeur commune).
    [JsonIgnore] public string OpenSpec => Windows?.Shortcut ?? Shortcut;
    [JsonIgnore] public string? StopSpec => Windows?.StopShortcut ?? StopShortcut;
    [JsonIgnore] public string SubmitSpec => Windows?.SubmitShortcut ?? SubmitShortcut ?? "return";
    [JsonIgnore] public string? ReadAloudSpec => Windows?.ReadAloudShortcut ?? ReadAloudShortcut;
    [JsonIgnore] public string? PauseReadSpec => Windows?.PauseReadShortcut ?? PauseReadShortcut;
    [JsonIgnore] public string ProcessName => Windows?.ProcessName ?? AppName ?? Id;
}

public sealed class ConversationSettings
{
    public double StartGraceSeconds { get; set; } = 8;
    public double IdleSecondsBeforeResume { get; set; } = 6;
    public double MaxPauseMinutes { get; set; } = 30;
}

public sealed class Config
{
    public string Locale { get; set; } = "fr-FR";
    public double CooldownSeconds { get; set; } = 5;
    public bool Debug { get; set; }
    public ConversationSettings Conversation { get; set; } = new();
    public List<string> FrontmostPhrases { get; set; } = new();
    public string? DefaultTarget { get; set; }
    public List<string>? SendPhrases { get; set; }
    public List<string>? StopPhrases { get; set; }
    public List<string>? InterruptPhrases { get; set; }
    public double? SendSilenceSeconds { get; set; }
    public double? ReviewSeconds { get; set; }
    /// Confiance minimale de la reconnaissance Windows (0–1, défaut 0,5).
    public double? MinConfidence { get; set; }
    public List<Target> Targets { get; set; } = new();

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static string DefaultPath() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "voicewake", "config.json");

    public static Config Load(string path)
    {
        var config = JsonSerializer.Deserialize<Config>(File.ReadAllText(path), Options)
                     ?? throw new InvalidDataException("Configuration vide.");
        config.Validate();
        return config;
    }

    public void Validate()
    {
        if (Targets.Count == 0) throw new InvalidDataException("Aucune cible définie.");
        var ids = new HashSet<string>();
        foreach (var t in Targets)
        {
            if (!ids.Add(t.Id)) throw new InvalidDataException($"Cible en double : {t.Id}");
            if (t.Phrases.Count == 0) throw new InvalidDataException($"{t.Id} : aucune phrase.");
            foreach (var spec in new[] { t.OpenSpec, t.StopSpec, t.SubmitSpec, t.ReadAloudSpec, t.PauseReadSpec })
                if (spec != null) Shortcut.Parse(spec); // lève une erreur lisible si invalide
        }
        if (DefaultTarget != null && !ids.Contains(DefaultTarget))
            throw new InvalidDataException($"defaultTarget inconnue : {DefaultTarget}");
    }

    public Target? FindTarget(string id) => Targets.FirstOrDefault(t => t.Id == id);

    /// Remplace le raccourci d'une cible en gardant le reste du fichier.
    public static void SaveShortcut(string spec, string targetId, string path)
    {
        Shortcut.Parse(spec);
        var root = JsonNode.Parse(File.ReadAllText(path), documentOptions: new JsonDocumentOptions
            { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true })!.AsObject();
        var target = root["targets"]!.AsArray().FirstOrDefault(n => (string?)n!["id"] == targetId)
                     ?? throw new InvalidDataException($"Cible introuvable : {targetId}");
        var win = target!["windows"] as JsonObject;
        if (win == null) { win = new JsonObject(); target["windows"] = win; }
        win["shortcut"] = spec; // surcharge Windows : ne casse pas le raccourci macOS partagé
        File.WriteAllText(path, root.ToJsonString(new JsonSerializerOptions
            { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
        Load(path);
    }
}
