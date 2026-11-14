using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Automation;

namespace VoiceWake;

/// Trouver, lancer et mettre au premier plan l'application d'une cible.
public static class Apps
{
    public static Process[] Processes(Target t) =>
        Process.GetProcessesByName(t.ProcessName).Where(p => { try { return !p.HasExited; } catch { return false; } }).ToArray();

    /// Processus qui possède une fenêtre principale visible (Electron : plusieurs processus du même nom).
    public static Process? MainProcess(Target t) =>
        Processes(t).FirstOrDefault(p => p.MainWindowHandle != IntPtr.Zero);

    public static bool IsRunning(Target t) => Processes(t).Length > 0;

    public static bool IsInstalled(Target t) => IsRunning(t) || ResolveLaunch(t) != null;

    /// Commande de lancement : exe, shell:AppsFolder\AUMID, ou recherche dans le menu Démarrer.
    public static string? ResolveLaunch(Target t)
    {
        var launch = t.Windows?.Launch ?? $"startmenu:{t.AppName ?? t.ProcessName}";
        if (launch.StartsWith("startmenu:", StringComparison.OrdinalIgnoreCase))
        {
            var aumid = StartMenuAppId(launch[10..]);
            return aumid == null ? null : $@"shell:AppsFolder\{aumid}";
        }
        if (launch.StartsWith("shell:", StringComparison.OrdinalIgnoreCase)) return launch;
        var path = Environment.ExpandEnvironmentVariables(launch);
        return File.Exists(path) ? path : null;
    }

    private static readonly Dictionary<string, string?> AppIdCache = new();

    /// AppID d'une entrée du menu Démarrer (Get-StartApps), ex. "Claude" → "Claude_pzs8sxrjxfjjc!Claude".
    private static string? StartMenuAppId(string name)
    {
        lock (AppIdCache)
        {
            if (AppIdCache.TryGetValue(name, out var cached)) return cached;
            string? id = null;
            try
            {
                var psi = new ProcessStartInfo("powershell.exe",
                    "-NoProfile -NonInteractive -Command \"Get-StartApps | ForEach-Object { $_.Name + [char]9 + $_.AppID }\"")
                { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
                using var p = Process.Start(psi)!;
                var lines = p.StandardOutput.ReadToEnd().Split('\n', StringSplitOptions.RemoveEmptyEntries);
                p.WaitForExit(10000);
                var entries = lines.Select(l => l.TrimEnd('\r').Split('\t')).Where(a => a.Length == 2).ToList();
                id = (entries.FirstOrDefault(a => a[0].Equals(name, StringComparison.OrdinalIgnoreCase))
                      ?? entries.FirstOrDefault(a => a[0].StartsWith(name, StringComparison.OrdinalIgnoreCase)))?[1];
            }
            catch (Exception e) { Log.Write($"Menu Démarrer illisible : {e.Message}"); }
            AppIdCache[name] = id;
            return id;
        }
    }

    public static bool Launch(Target t)
    {
        var cmd = ResolveLaunch(t);
        if (cmd == null) return false;
        try
        {
            if (cmd.StartsWith("shell:", StringComparison.OrdinalIgnoreCase))
                Process.Start(new ProcessStartInfo("explorer.exe", cmd) { UseShellExecute = true });
            else
                Process.Start(new ProcessStartInfo(cmd) { UseShellExecute = true });
            return true;
        }
        catch (Exception e) { Log.Write($"{t.Id} : lancement impossible : {e.Message}"); return false; }
    }

    /// Met la fenêtre au premier plan (contourne la restriction de SetForegroundWindow avec un appui Alt).
    public static void Activate(Target t)
    {
        var p = MainProcess(t);
        if (p == null) return;
        var hwnd = p.MainWindowHandle;
        if (IsIconic(hwnd)) ShowWindow(hwnd, 9); // SW_RESTORE
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
        SetForegroundWindow(hwnd);
    }

    /// Cible dont l'application est au premier plan.
    public static Target? Frontmost(Config config)
    {
        var hwnd = GetForegroundWindow();
        GetWindowThreadProcessId(hwnd, out var pid);
        try
        {
            var name = Process.GetProcessById((int)pid).ProcessName;
            return config.Targets.FirstOrDefault(t => t.ProcessName.Equals(name, StringComparison.OrdinalIgnoreCase));
        }
        catch { return null; }
    }

    /// Fenêtres de premier niveau (UI Automation) de tous les processus de la cible.
    public static List<AutomationElement> Windows(Target t)
    {
        var pids = Processes(t).Select(p => p.Id).ToHashSet();
        var result = new List<AutomationElement>();
        var windows = AutomationElement.RootElement.FindAll(TreeScope.Children, Condition.TrueCondition);
        foreach (AutomationElement w in windows)
        {
            try { if (pids.Contains(w.Current.ProcessId)) result.Add(w); } catch { }
        }
        // La fenêtre au premier plan en premier.
        var fg = GetForegroundWindow();
        return result.OrderByDescending(w => { try { return w.Current.NativeWindowHandle == fg.ToInt32(); } catch { return false; } }).ToList();
    }

    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}

/// Clique un bouton par son nom exact (UI Automation), comme AXButtonPresser sur macOS.
public static class Buttons
{
    private static readonly Condition Clickable = new OrCondition(
        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.CheckBox),
        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.SplitButton),
        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.RadioButton));

    /// Tous les éléments dont le nom exact est dans `labels`, dans l'ordre de l'arbre.
    public static List<AutomationElement> All(Target t, IEnumerable<string> labels, bool anyRole = false)
    {
        var wanted = labels.Select(l => l.Trim().ToLowerInvariant()).ToHashSet();
        var found = new List<AutomationElement>();
        foreach (var w in Apps.Windows(t))
        {
            try
            {
                var all = w.FindAll(TreeScope.Descendants, anyRole ? Condition.TrueCondition : Clickable);
                foreach (AutomationElement e in all)
                {
                    string name;
                    try { name = e.Current.Name ?? ""; } catch { continue; }
                    if (wanted.Contains(name.Trim().ToLowerInvariant())) found.Add(e);
                }
            }
            catch (ElementNotAvailableException) { }
        }
        return found;
    }

    /// Presse le premier (ou le dernier) bouton trouvé. Renvoie son nom, ou null.
    public static string? Press(Target t, IEnumerable<string> labels, bool last = false)
    {
        var list = All(t, labels);
        if (last) list.Reverse();
        foreach (var e in list)
            if (Invoke(e)) { try { return e.Current.Name; } catch { return "?"; } }
        return null;
    }

    private static bool Invoke(AutomationElement e)
    {
        try
        {
            if (e.TryGetCurrentPattern(InvokePattern.Pattern, out var inv)) { ((InvokePattern)inv).Invoke(); return true; }
            if (e.TryGetCurrentPattern(TogglePattern.Pattern, out var tog)) { ((TogglePattern)tog).Toggle(); return true; }
            if (e.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var sel)) { ((SelectionItemPattern)sel).Select(); return true; }
        }
        catch (Exception ex) { Log.Write($"Clic impossible : {ex.Message}"); }
        return false;
    }
}
