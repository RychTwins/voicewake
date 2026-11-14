# VoiceWake — installation Windows : compile, installe, démarre avec la session.
# Usage (PowerShell, depuis le dossier windows) :
#   .\install.ps1            compile et installe
#   .\install.ps1 -Restart   relance seulement le service (après modification de la config)
param([switch]$Restart)
$ErrorActionPreference = 'Stop'

$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallDir = Join-Path $env:LOCALAPPDATA 'VoiceWake'
$Exe       = Join-Path $InstallDir 'voicewake.exe'
$ConfigDir = Join-Path $env:APPDATA 'voicewake'
$Config    = Join-Path $ConfigDir 'config.json'
$Log       = Join-Path $InstallDir 'voicewake.log'
$RunKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Stop-VoiceWake { Get-Process voicewake -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Milliseconds 500 }
function Start-VoiceWake { Start-Process -FilePath $Exe -ArgumentList 'run' -WindowStyle Hidden }

if ($Restart) { Stop-VoiceWake; Start-VoiceWake; Write-Host '✓ VoiceWake relancé.'; exit 0 }

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
  Write-Host 'SDK .NET 8 manquant : winget install Microsoft.DotNet.SDK.8'; exit 1
}

Write-Host '→ Compilation'
Stop-VoiceWake
New-Item -ItemType Directory -Force -Path $InstallDir, $ConfigDir | Out-Null
dotnet publish (Join-Path $Root 'VoiceWake.csproj') -c Release -o $InstallDir --nologo -v quiet
if ($LASTEXITCODE -ne 0) { Write-Host 'Échec de la compilation.'; exit 1 }

Write-Host '→ Configuration'
if (-not (Test-Path $Config)) {
  Copy-Item (Join-Path $Root '..\config.example.json') $Config
  Write-Host "  Créée : $Config"
} else { Write-Host "  Conservée : $Config" }

Write-Host '→ Démarrage automatique'
Set-ItemProperty -Path $RunKey -Name 'VoiceWake' -Value "`"$Exe`" run"
Start-VoiceWake

# Commande « voicewake » dans le terminal.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$InstallDir*") {
  [Environment]::SetEnvironmentVariable('Path', "$userPath;$InstallDir", 'User')
  Write-Host "  Ajouté au PATH : $InstallDir (rouvrir le terminal)"
}

Write-Host @"

✓ VoiceWake installé.
  1. Langue : Paramètres > Heure et langue > Langue et région > Français > Options > installer « Reconnaissance vocale ».
  2. Micro : Paramètres > Confidentialité et sécurité > Microphone > « Autoriser les applications de bureau à accéder au micro » activé.
  3. Vérifie : voicewake check     puis teste : voicewake test claude
  Config : $Config   (puis .\install.ps1 -Restart)
  Logs   : Get-Content -Wait "$Log"
"@
