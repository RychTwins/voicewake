using System.Runtime.InteropServices;

namespace VoiceWake;

/// Raccourci décrit en texte, même syntaxe que sur macOS :
///   "ctrl+shift+v", "win+h", "double alt", "hold 1.5 ctrl", "ctrl+k then v", "keycode:0x14",
///   "button:Libellé exact|Autre libellé" (clic UI Automation).
/// Sous Windows : option/alt = Alt, cmd/command/win = Windows, fn n'existe pas.
public sealed class Shortcut
{
    public string Spec { get; }
    public List<Step> Steps { get; } = new();
    public List<string> Buttons { get; } = new();

    public sealed record Combo(List<ushort> Modifiers, ushort? Main);
    public sealed record Step(Combo Combo, int Times, double? HoldSeconds);

    private Shortcut(string spec) => Spec = spec;

    public static Shortcut Parse(string spec)
    {
        var trimmed = spec.Trim();
        if (trimmed.Length == 0) throw new InvalidDataException("Raccourci vide.");
        var s = new Shortcut(trimmed);
        if (trimmed.StartsWith("button:", StringComparison.OrdinalIgnoreCase))
        {
            s.Buttons.AddRange(trimmed[7..].Split('|').Select(x => x.Trim()).Where(x => x.Length > 0));
            if (s.Buttons.Count == 0) throw new InvalidDataException($"Bouton sans libellé : {trimmed}");
            return s;
        }
        foreach (var part in trimmed.Split(" then ", StringSplitOptions.RemoveEmptyEntries))
            s.Steps.Add(ParseStep(part, trimmed));
        return s;
    }

    private static Step ParseStep(string raw, string spec)
    {
        var tokens = raw.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        int times = 1; double? hold = null;
        switch (tokens.FirstOrDefault()?.ToLowerInvariant())
        {
            case "double" or "2x": times = 2; tokens.RemoveAt(0); break;
            case "triple" or "3x": times = 3; tokens.RemoveAt(0); break;
            case "hold":
                tokens.RemoveAt(0);
                if (tokens.Count > 0 && double.TryParse(tokens[0].Replace(',', '.'),
                        System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var sec))
                { hold = sec; tokens.RemoveAt(0); }
                else hold = 1;
                break;
        }
        var names = string.Concat(tokens).Split('+', StringSplitOptions.RemoveEmptyEntries);
        if (names.Length == 0) throw new InvalidDataException($"Raccourci incomplet : {spec}");
        var mods = new List<ushort>(); ushort? main = null;
        foreach (var n in names)
        {
            var (vk, isMod) = KeyMap.Key(n) ?? throw new InvalidDataException($"Touche inconnue « {n} » dans « {spec} »");
            if (isMod) mods.Add(vk);
            else if (main == null) main = vk;
            else throw new InvalidDataException($"Une seule touche principale par étape : {spec}");
        }
        return new Step(new Combo(mods, main), times, hold);
    }
}

public static class KeyMap
{
    private static readonly Dictionary<string, ushort> Modifiers = new()
    {
        ["ctrl"] = 0xA2, ["control"] = 0xA2, ["lctrl"] = 0xA2, ["rctrl"] = 0xA3, ["rcontrol"] = 0xA3,
        ["alt"] = 0xA4, ["option"] = 0xA4, ["opt"] = 0xA4, ["lalt"] = 0xA4, ["ralt"] = 0xA5, ["roption"] = 0xA5,
        ["shift"] = 0xA0, ["maj"] = 0xA0, ["lshift"] = 0xA0, ["rshift"] = 0xA1,
        ["win"] = 0x5B, ["cmd"] = 0x5B, ["command"] = 0x5B, ["lwin"] = 0x5B, ["rwin"] = 0x5C, ["rcmd"] = 0x5C,
    };

    private static readonly Dictionary<string, ushort> Specials = new()
    {
        ["space"] = 0x20, ["espace"] = 0x20, ["return"] = 0x0D, ["enter"] = 0x0D, ["entree"] = 0x0D,
        ["tab"] = 0x09, ["escape"] = 0x1B, ["esc"] = 0x1B, ["delete"] = 0x08, ["backspace"] = 0x08,
        ["forwarddelete"] = 0x2E, ["suppr"] = 0x2E, ["up"] = 0x26, ["down"] = 0x28, ["left"] = 0x25, ["right"] = 0x27,
        ["home"] = 0x24, ["end"] = 0x23, ["pageup"] = 0x21, ["pagedown"] = 0x22,
        ["capslock"] = 0x14, ["caps"] = 0x14, ["verrmaj"] = 0x14,
    };

    public static bool IsModifier(ushort vk) => Modifiers.ContainsValue(vk);

    public static (ushort vk, bool isModifier)? Key(string raw)
    {
        var name = raw.Trim().ToLowerInvariant();
        if (name.StartsWith("keycode:"))
        {
            var v = name[8..];
            ushort code = v.StartsWith("0x") ? Convert.ToUInt16(v[2..], 16) : ushort.Parse(v);
            return (code, IsModifier(code));
        }
        if (Modifiers.TryGetValue(name, out var m)) return (m, true);
        if (Specials.TryGetValue(name, out var s)) return (s, false);
        if (name.Length > 1 && name[0] == 'f' && int.TryParse(name[1..], out var f) && f is >= 1 and <= 24)
            return ((ushort)(0x70 + f - 1), false);
        if (name.Length == 1)
        {
            // Selon la disposition active (AZERTY, QWERTY…).
            short r = VkKeyScanEx(name[0], GetKeyboardLayout(0));
            if (r != -1) return ((ushort)(r & 0xFF), false);
        }
        return null;
    }

    [DllImport("user32.dll")] private static extern short VkKeyScanEx(char ch, IntPtr dwhkl);
    [DllImport("user32.dll")] private static extern IntPtr GetKeyboardLayout(uint idThread);
}

/// Rejoue un raccourci clavier avec SendInput.
public static class ShortcutPlayer
{
    public static void Play(Shortcut s)
    {
        for (int i = 0; i < s.Steps.Count; i++)
        {
            if (i > 0) Thread.Sleep(150);
            var step = s.Steps[i];
            if (step.HoldSeconds is double hold) { Down(step.Combo); Thread.Sleep((int)(hold * 1000)); Up(step.Combo); continue; }
            for (int t = 0; t < step.Times; t++)
            {
                if (t > 0) Thread.Sleep(100);
                Down(step.Combo); Thread.Sleep(30); Up(step.Combo);
            }
        }
    }

    private static void Down(Shortcut.Combo c)
    {
        foreach (var m in c.Modifiers) { Key(m, false); Thread.Sleep(20); }
        if (c.Main is ushort k) Key(k, false);
    }

    private static void Up(Shortcut.Combo c)
    {
        if (c.Main is ushort k) Key(k, true);
        for (int i = c.Modifiers.Count - 1; i >= 0; i--) { Thread.Sleep(20); Key(c.Modifiers[i], true); }
    }

    private static void Key(ushort vk, bool up)
    {
        var input = new INPUT
        {
            type = 1, // INPUT_KEYBOARD
            U = new InputUnion { ki = new KEYBDINPUT { wVk = vk, dwFlags = (up ? 0x0002u : 0) | (IsExtended(vk) ? 0x0001u : 0) } },
        };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    private static bool IsExtended(ushort vk) =>
        vk is 0x21 or 0x22 or 0x23 or 0x24 or 0x25 or 0x26 or 0x27 or 0x28 or 0x2E or 0x5B or 0x5C or 0xA3 or 0xA5;

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public InputUnion U; }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
}
