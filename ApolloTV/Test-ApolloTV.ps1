$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ApolloTV.ps1') -LibraryOnly -TvAddress '192.0.2.20'
$count = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:count++
}
function Must-Fail([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert $failed $Message
}
$tokens = $null
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'ApolloTV.ps1'), [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'PowerShell syntax'
Assert ((Get-HomeComponent 'com.google.android.apps.tv.launcherx/.HomeActivity') -ceq 'com.google.android.apps.tv.launcherx/.HomeActivity') 'Valid Home component'
Must-Fail { Get-HomeComponent 'com.example/.Home;reboot' } 'Reject shell injection'
Must-Fail { Get-HomeComponent "com.example/.A`ncom.example/.B" } 'Reject ambiguous Home'
foreach ($component in @('android/.ResolverActivity','com.google.android.tungsten.setupwraith/.RecoveryActivity','com.android.tv.settings/.FallbackHome','com.gathin.tvhome/.MainActivity','com.vendor.factory/.Main')) {
    Must-Fail { Assert-OriginalHome $component } "Reject unsafe original Home: $component"
}
$state = [pscustomobject]@{ Schema=1; Identity='device-one'; Home='com.google.android.apps.tv.launcherx/.HomeActivity' }
Assert-SameDevice $state 'device-one'
Must-Fail { Assert-SameDevice $state 'device-two' } 'Reject restore on another device'

# A fake TV models a firmware which reports successful Home resolution while
# setupwraith, rather than the launcher, is actually foreground.
$script:fakeResolver = 'com.gathin.tvhome/.MainActivity'
$script:fakeFocus = 'com.google.android.tungsten.setupwraith/.RecoveryActivity'
$script:calls = New-Object 'System.Collections.Generic.List[string]'
function Read-TV([string]$Command) {
    $script:calls.Add($Command)
    if ($Command -eq $script:HomeQuery) { return $script:fakeResolver }
    if ($Command -eq 'dumpsys activity activities') { return "mResumedActivity: ActivityRecord{abc u0 $script:fakeFocus t2}" }
    if ($Command -like 'cmd package set-home-activity --user 0 *') {
        $script:fakeResolver = $Command.Substring('cmd package set-home-activity --user 0 '.Length)
        return 'Success'
    }
    if ($Command -eq 'input keyevent KEYCODE_HOME') { $script:fakeFocus = $script:fakeResolver; return '' }
    if ($Command -eq 'pm list packages --user 0') { return "package:android`npackage:com.google.android.apps.tv.launcherx" }
    return 'sample read-only device state'
}
Assert (-not (Test-LauncherHome)) 'Reject resolver-only false success'
$script:fakeFocus = 'com.gathin.tvhome/.MainActivity'
Assert (Test-LauncherHome) 'Accept foreground plus resolver'
Restore-Home $state
Assert ($script:fakeResolver -ceq $state.Home -and $script:fakeFocus -ceq $state.Home) 'Restore reassigns and verifies original Home'
Assert (@($script:calls | Where-Object { $_ -match 'pm (disable|uninstall|clear)' }).Count -eq 0) 'Restore does not disable, uninstall or erase apps'

# Keep test outputs in the task workspace; retain them rather than deleting paths.
$testRoot = Join-Path $PSScriptRoot ('test-results\' + [guid]::NewGuid().ToString('N'))
$script:fakeResolver = $state.Home
$first = Save-OriginalState $testRoot 'device-one'
$bytes = [IO.File]::ReadAllText((Join-Path $testRoot 'original.json'))
$script:fakeResolver = 'com.gathin.tvhome/.MainActivity'
$second = Save-OriginalState $testRoot 'device-one'
Assert ($second.Home -ceq $state.Home) 'Rerun preserves original Home after installation'
Assert ([IO.File]::ReadAllText((Join-Path $testRoot 'original.json')) -ceq $bytes) 'Original record not rewritten'
Must-Fail { Save-OriginalState $testRoot 'device-two' } 'Refuse mismatched backup reuse'
Assert ((Get-ChildItem -LiteralPath $testRoot -File).Count -ge 9) 'Backup includes package/settings files'

# Real file transformation: only the copied XML is changed, using installed IDs.
$script:Repo = Join-Path $testRoot 'repo'
$xmlDir = Join-Path $script:Repo 'launcher\app\src\main\res\values'
New-Item -ItemType Directory -Path $xmlDir -Force | Out-Null
$xmlPath = Join-Path $xmlDir 'config.xml'
Write-Text $xmlPath '<resources><integer name="columns">4</integer><string-array name="dock_apps"><item>old.app</item></string-array></resources>'
$installed = @('com.google.android.youtube.tv','com.vk.tv','rtb.mobile.android','tv.twitch.android.app','ru.kinopoisk.tv','tv.okko.androidtv','ru.rt.video.app.tv')
Set-Dock $installed
[xml]$actual = Get-Content -LiteralPath $xmlPath -Raw
Assert ($actual.SelectSingleNode('/resources/integer[@name="columns"]').InnerText -eq '7') 'Seven dock slots'
$actualApps = @($actual.SelectNodes('/resources/string-array[@name="dock_apps"]/item') | ForEach-Object { $_.InnerText })
Assert (($actualApps -join ',') -ceq ($installed -join ',')) 'Requested dock order'

Must-Fail { Assert-WifiOwnerSafe 'no saved-network information' } 'Refuse an unknown Wi-Fi owner'
Must-Fail { Assert-WifiOwnerSafe 'cname=com.google.android.tungsten.setupwraith:10123' } 'Refuse a setup-owned network'
Assert-WifiOwnerSafe 'cname=android.uid.system:1000'
Assert $true 'Allow system-owned Wi-Fi'

# Exercise guarded handover and recovery using the real control flow and fake TV.
$script:StateFolder = $testRoot
$script:Python = 'fake-python.exe'
$script:fakeResolver = $state.Home
$script:fakeFocus = $state.Home
$script:fakePackages = @($installed) + @('android','com.android.settings','com.google.android.apps.tv.launcherx','com.google.android.tungsten.setupwraith')
$script:repoCalls = New-Object 'System.Collections.Generic.List[string]'
$script:readAnswer = 'SWITCH'
$script:refuseDisable = $false
function Read-Host { return $script:readAnswer }
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    Assert ($Arguments -contains '--save') 'Upstream recovery record saved before disable'
    $script:repoCalls.Add('record')
}
function Invoke-RepoScript([string]$Name, [string[]]$Parameters) {
    $script:repoCalls.Add($Name)
    if ($Name -eq 'tools\disable.ps1' -and -not $script:refuseDisable) {
        $script:fakePackages = @($script:fakePackages | Where-Object { $_ -notin @('com.google.android.apps.tv.launcherx','com.google.android.tungsten.setupwraith') })
    }
    if ($Name -eq 'tools\restore.ps1') {
        $script:fakePackages += @('com.google.android.apps.tv.launcherx','com.google.android.tungsten.setupwraith')
    }
}
function Read-TV([string]$Command) {
    $script:calls.Add($Command)
    if ($Command -eq $script:HomeQuery) { return $script:fakeResolver }
    if ($Command -eq 'dumpsys activity activities') { return "mResumedActivity: ActivityRecord{abc u0 $script:fakeFocus t2}" }
    if ($Command -eq 'dumpsys wifi') { return 'cname=android.uid.system:1000' }
    if ($Command -eq 'pm path com.gathin.tvhome') { return 'package:/data/app/com.gathin.tvhome/base.apk' }
    if ($Command -like 'cmd package query-activities*') { return "com.gathin.tvhome/.MainActivity`ncom.google.android.tungsten.setupwraith/.RecoveryActivity" }
    if ($Command -eq 'pm list packages -e --user 0') { return ($script:fakePackages | ForEach-Object { "package:$_" }) -join "`n" }
    if ($Command -like 'am start -W*com.gathin.tvhome/.MainActivity') { $script:fakeFocus='com.gathin.tvhome/.MainActivity'; return 'Status: ok' }
    if ($Command -like 'cmd package set-home-activity --user 0 *') {
        $script:fakeResolver = $Command.Substring('cmd package set-home-activity --user 0 '.Length)
        return 'Success'
    }
    if ($Command -eq 'input keyevent KEYCODE_HOME') { $script:fakeFocus = $script:fakeResolver; return '' }
    if ($Command -eq 'pm enable --user 0 com.google.android.apps.tv.launcherx') { $script:fakePackages += 'com.google.android.apps.tv.launcherx'; return 'enabled' }
    throw "Unexpected fake command: $Command"
}
Must-Fail { Complete-HomeHandover $state @($script:fakePackages + 'com.cvte.tv.launcher.Main') } 'Protect CVTE stock launchers'
$script:readAnswer = ''
Must-Fail { Complete-HomeHandover $state $script:fakePackages } 'Cancellation prevents package changes'
Assert ($script:repoCalls.Count -eq 0) 'No disable on cancellation'
$script:readAnswer = 'SWITCH'
Complete-HomeHandover $state $script:fakePackages
Assert (Test-LauncherHome) 'Guarded handover reaches real launcher foreground'
$handoverList = @(Get-Content -LiteralPath (Join-Path $testRoot 'home-handover.txt'))
Assert (($handoverList -join ',') -eq 'com.google.android.tungsten.setupwraith,com.google.android.apps.tv.launcherx') 'Disable wizard before launcher; touch only two packages'
Assert (($script:repoCalls -join ',') -eq 'record,tools\disable.ps1') 'Record before disable through upstream tools'
Restore-Home $state
Assert ($script:fakeResolver -eq $state.Home) 'Rollback restores original Home after package handover'
Assert ($script:fakePackages -contains 'com.google.android.tungsten.setupwraith') 'Rollback restores setup wizard'
Assert ((Get-Content -LiteralPath (Join-Path $testRoot 'home-handover.status') -Raw).Trim() -eq 'restored') 'Rollback marker recorded'

$script:refuseDisable = $true
Must-Fail { Complete-HomeHandover $state $script:fakePackages } 'Stop if firmware refuses package disable'
Restore-Home $state
Assert ($script:fakeResolver -eq $state.Home) 'Refused disable remains recoverable'

# Reproduce the exact upstream post-install error from the user's log in a
# harmless child PowerShell process. Only that specific handover failure may
# proceed; a failed APK installation must still stop.
$fakeInstaller = Join-Path $script:Repo 'launcher\build-and-install.ps1'
Write-Text $fakeInstaller 'param($TvHost,$StockLauncher); Write-Output "Home resolves to ''com.google.android.apps.tv.launcherx/.home.HomeActivity'', not to the new launcher"; exit 1'
Invoke-LauncherInstall
Assert $true 'Recognize successful APK install followed by the reported Home-resolution failure'
Write-Text $fakeInstaller 'param($TvHost,$StockLauncher); Write-Output "Failure [INSTALL_FAILED_VERIFICATION_FAILURE]"; exit 1'
Must-Fail { Invoke-LauncherInstall } 'Do not treat an APK verification failure as successful installation'

# Wallpaper conversion uses a separate JPEG copy and retains the source.
Add-Type -AssemblyName System.Drawing
$wallSource = Join-Path $testRoot 'source wallpaper.png'
$sourceImage = New-Object Drawing.Bitmap(2400,1350)
try { $sourceImage.Save($wallSource, [Drawing.Imaging.ImageFormat]::Png) } finally { $sourceImage.Dispose() }
$wallTarget = Join-Path $testRoot 'wallpaper.jpg'
Convert-Wallpaper $wallSource $wallTarget
$converted = [Drawing.Image]::FromFile($wallTarget)
try {
    Assert ($converted.Width -eq 1920 -and $converted.Height -eq 1080) 'Resize large wallpaper for TV'
    Assert ($converted.RawFormat.Guid -eq [Drawing.Imaging.ImageFormat]::Jpeg.Guid) 'Output is a real JPEG'
} finally { $converted.Dispose() }
Assert (Test-Path -LiteralPath $wallSource) 'Retain original wallpaper file'
$invalidImage = Join-Path $testRoot 'invalid.txt'
Write-Text $invalidImage 'not an image'
Must-Fail { Convert-Wallpaper $invalidImage (Join-Path $testRoot 'invalid.jpg') } 'Reject unsupported wallpaper file'
$themeFixture = [pscustomobject]@{dock_apps=@('app.one','app.two'); columns=6; wallpaper=$false; show_clock=$false}
$withWallpaper = Set-WallpaperOptions $themeFixture $true 35
Assert ($withWallpaper.wallpaper -eq $true -and $withWallpaper.wallpaper_dim -eq 35) 'Enable chosen wallpaper and dimming'
Assert (($withWallpaper.dock_apps -join ',') -eq 'app.one,app.two' -and $withWallpaper.show_clock -eq $false) 'Keep unrelated theme settings'
$withoutWallpaper = Set-WallpaperOptions $withWallpaper $false 0
Assert ($withoutWallpaper.wallpaper -eq $false -and $withoutWallpaper.columns -eq 6) 'Reset wallpaper without resetting columns'
$cachedTheme = Join-Path $testRoot 'previous-theme'
New-Item -ItemType Directory -Path $cachedTheme -Force | Out-Null
Write-Text (Join-Path $cachedTheme 'config.json') ((Set-WallpaperOptions $themeFixture $true 35) | ConvertTo-Json -Depth 10)
Copy-Item -LiteralPath $wallTarget -Destination (Join-Path $cachedTheme 'wallpaper.jpg')
Write-Text (Join-Path $testRoot 'last-theme.txt') $cachedTheme
Apply-DockTheme
$reapplied = Get-LocalThemeFolder
$reappliedConfig = Get-Content -LiteralPath (Join-Path $reapplied 'config.json') -Raw | ConvertFrom-Json
Assert ($reappliedConfig.wallpaper -eq $true -and $reappliedConfig.columns -eq 7) 'Keep wallpaper when reapplying dock'
Assert ((Get-FileHash -LiteralPath (Join-Path $reapplied 'wallpaper.jpg')).Hash -eq (Get-FileHash -LiteralPath $wallTarget).Hash) 'Keep cached wallpaper asset on Home fix'
Write-Text (Join-Path $testRoot 'last-theme.txt') (Split-Path -Parent $testRoot)
Must-Fail { Get-LocalThemeFolder } 'Reject theme marker outside device backup folder'
Write-Host "PASS: $count checks. No network requests or real-TV operations were performed."
