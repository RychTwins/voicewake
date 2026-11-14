# VoiceWake — désinstallation Windows.
#   .\uninstall.ps1          garde la configuration
#   .\uninstall.ps1 -Purge   supprime aussi la configuration
param([switch]$Purge)
$InstallDir = Join-Path $env:LOCALAPPDATA 'VoiceWake'
$ConfigDir  = Join-Path $env:APPDATA 'voicewake'

Get-Process voicewake -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'VoiceWake' -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
[Environment]::SetEnvironmentVariable('Path', (($userPath -split ';') | Where-Object { $_ -and $_ -ne $InstallDir }) -join ';', 'User')

if ($Purge) { Remove-Item -Recurse -Force $ConfigDir -ErrorAction SilentlyContinue; Write-Host '✓ VoiceWake et sa configuration supprimés.' }
else { Write-Host "✓ VoiceWake supprimé (configuration conservée : $ConfigDir)." }
