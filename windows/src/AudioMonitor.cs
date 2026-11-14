using System.Diagnostics;
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace VoiceWake;

/// Équivalent de MicMonitor (macOS) : qui utilise le micro, qui joue du son.
public static class AudioMonitor
{
    private const string MicKey = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    /// Une autre application que VoiceWake capte-t-elle le micro ?
    /// Windows note dans le registre le début et la fin de chaque utilisation : fin = 0 → en cours.
    public static bool IsMicInUseByOtherApp()
    {
        var self = Environment.ProcessPath?.Replace('\\', '#') ?? "";
        using var root = Registry.CurrentUser.OpenSubKey(MicKey);
        if (root == null) return false;
        foreach (var name in root.GetSubKeyNames())
        {
            using var key = root.OpenSubKey(name);
            if (key == null) continue;
            if (name == "NonPackaged")
            {
                foreach (var exe in key.GetSubKeyNames())
                {
                    if (exe.Equals(self, StringComparison.OrdinalIgnoreCase)) continue;
                    using var k = key.OpenSubKey(exe);
                    if (InUse(k)) return true;
                }
            }
            else if (InUse(key)) return true;
        }
        return false;
    }

    private static bool InUse(RegistryKey? k)
    {
        if (k == null) return false;
        var start = k.GetValue("LastUsedTimeStart") as long? ?? 0;
        var stop = k.GetValue("LastUsedTimeStop") as long? ?? 0;
        return start != 0 && stop == 0;
    }

    /// Nom de processus (cible) qui joue du son en ce moment, ou null.
    public static string? OutputtingProcess(IEnumerable<string> processNames)
    {
        var wanted = processNames.Select(n => n.ToLowerInvariant()).ToHashSet();
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
            {
                var sessions = device.AudioSessionManager.Sessions;
                for (int i = 0; i < sessions.Count; i++)
                {
                    var s = sessions[i];
                    if (s.State != AudioSessionState.AudioSessionStateActive) continue;
                    string name;
                    try { name = Process.GetProcessById((int)s.GetProcessID).ProcessName.ToLowerInvariant(); }
                    catch { continue; }
                    if (wanted.Contains(name)) return name;
                }
            }
        }
        catch (Exception e) { Log.Write($"Sessions audio illisibles : {e.Message}"); }
        return null;
    }
}
