[CmdletBinding()]
param(
    [ValidateSet('Install','Prepare','Restore','Check','Switch')][string]$Mode = 'Install',
    [string]$TvAddress = '',
    [ValidateRange(1,65535)][int]$Port = 5555,
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ApolloTV-Tools'),
    [switch]$LibraryOnly
)

# This wrapper leaves upstream scripts unchanged. No VPN or route operations.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$script:HomeQuery = 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME'
$script:Launcher = 'com.gathin.tvhome'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Exe" }
}
function Read-TV([string]$Command) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $script:Python -I (Join-Path $script:Repo 'tools\tv.py') $Command 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    $value = ($output | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0 -or $value -match '(?im)^\s*(Error:|Exception|SecurityException|Failure\s*\[|/system/bin/sh:.*not found)') {
        throw "TV command failed: $Command`n$value"
    }
    return $value.Trim()
}
function Get-HomeComponent([string]$Text) {
    $lines = @($Text -split '\r?\n' | Where-Object { $_ -cmatch '^[A-Za-z_][A-Za-z0-9_.]*/[A-Za-z0-9_.$]+$' })
    if ($lines.Count -ne 1) { throw 'Home could not be identified uniquely. Select the original Home on the TV first.' }
    return $lines[0]
}
function Assert-OriginalHome([string]$Component) {
    $checked = Get-HomeComponent $Component
    $pkg = $checked.Split('/')[0]
    if ($pkg -in @('android','com.android.settings','com.android.tv.settings','com.android.provision','com.google.android.tungsten.setupwraith',$script:Launcher) -or $checked -match '(?i)FallbackHome|factory|production|testmenu') {
        throw 'The original Home is a chooser, setup screen or custom launcher. A reliable original backup is required.'
    }
}
function Assert-SameDevice($State, [string]$Identity) {
    if ($State.Schema -ne 1 -or $State.Identity -cne $Identity) { throw 'Backup does not match this TV. Restore refused.' }
    Assert-OriginalHome $State.Home
}
function Test-LauncherHome {
    $resolved = Get-HomeComponent (Read-TV $script:HomeQuery)
    $activities = Read-TV 'dumpsys activity activities'
    $active = @($activities -split '\r?\n' | Where-Object { $_ -match 'mResumedActivity|topResumedActivity|mFocusedApp' }) -join "`n"
    return ($resolved -like 'com.gathin.tvhome/*' -and $active -match 'com\.gathin\.tvhome/')
}
function Test-LauncherForeground {
    $activities = Read-TV 'dumpsys activity activities'
    $active = @($activities -split '\r?\n' | Where-Object { $_ -match 'mResumedActivity|topResumedActivity|mFocusedApp' }) -join "`n"
    return ($active -match 'com\.gathin\.tvhome/')
}
function Assert-WifiOwnerSafe([string]$Wifi) {
    if ($Wifi -notmatch 'cname=') { throw 'Cannot verify saved Wi-Fi owners. No Home packages were disabled.' }
    if ($Wifi -match 'cname=[^\s]*setupwraith') {
        throw 'Wi-Fi belongs to the setup wizard. On the TV, forget the network and reconnect through Settings before retrying. No Home packages were disabled.'
    }
}
function Get-EnabledPackages {
    $answer = Read-TV 'pm list packages -e --user 0'
    $packages = @($answer -split '\r?\n' | ForEach-Object {
        if ($_.Trim() -cmatch '^package:([A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+)$') { $Matches[1] }
    })
    if ($packages.Count -lt 5) { throw 'Incomplete package list; installation stopped.' }
    return $packages
}
function Invoke-RepoScript([string]$Name, [string[]]$Parameters) {
    Invoke-Native (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') (@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $script:Repo $Name)) + $Parameters)
}
function Invoke-LauncherInstall {
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $parameters = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $script:Repo 'launcher\build-and-install.ps1'),'-TvHost',$TvAddress,'-StockLauncher','none')
    $capture = New-Object 'System.Collections.Generic.List[string]'
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @parameters 2>&1 | ForEach-Object { $capture.Add("$_"); Write-Host "$_" }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    if ($code -ne 0) {
        # The upstream installer reports this specific error AFTER a successful
        # install when firmware retains its system Home. Other failures stop here.
        if (($capture -join "`n") -notmatch "Home resolves to '[A-Za-z0-9_./$]+', not to the new launcher") {
            throw "Launcher build/install failed ($code); see the log."
        }
        $installedPath = Read-TV 'pm path com.gathin.tvhome'
        if ($installedPath -notmatch '(?m)^package:/.+\.apk\s*$') { throw 'Launcher install could not be verified.' }
        Write-Host 'APK установлен; прошивка сохранила системный Home. Выполняется отдельная проверка переключения.'
    }
}
function Complete-HomeHandover($State, [string[]]$Packages) {
    if (Test-LauncherHome) { return }
    Assert-OriginalHome $State.Home
    $stockPackage = $State.Home.Split('/')[0]
    if ($stockPackage -cne 'com.google.android.apps.tv.launcherx') { throw 'Automatic handover is only supported for the verified Google TV Launcher package.' }
    if (@($Packages | Where-Object { $_ -like 'com.cvte.tv.launcher*' }).Count -gt 0) {
        throw 'A CVTE stock launcher is present. Automatic handover is refused for this board.'
    }
    foreach ($flag in @('FORCE_HOME','FORCE_SETUPWRAITH','TVINPUT_ALLOW','HANDLERS_ALLOW')) {
        if ([Environment]::GetEnvironmentVariable($flag)) { throw "Remove the $flag override before using the guarded handover." }
    }
    $claimants = Read-TV 'cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME'
    if ($claimants -notmatch 'com\.gathin\.tvhome/') { throw 'The replacement launcher does not declare Home on this firmware.' }
    $listPackages = @()
    $setup = 'com.google.android.tungsten.setupwraith'
    if ($Packages -contains $setup -and $claimants -match 'com\.google\.android\.tungsten\.setupwraith/') {
        Assert-WifiOwnerSafe (Read-TV 'dumpsys wifi')
        $listPackages += $setup # Wizard first: never leave its RecoveryActivity as the next Home.
    }
    if ($Packages -contains $stockPackage) { $listPackages += $stockPackage }
    if ($listPackages.Count -eq 0) { throw 'Neither known Home blocker is enabled. Further firmware diagnosis is required.' }
    Write-Host 'Для переключения Home будут отключены только эти обработчики:' -ForegroundColor Yellow
    $listPackages | ForEach-Object { Write-Host "  $_" }
    Write-Host 'Первоначальная настройка Google TV станет недоступна до отката. После переключения проверьте кнопки пульта и Chromecast; при проблемах запустите RESTORE-TV.cmd.'
    $consent = Read-Host 'Введите SWITCH для переключения или нажмите Enter для отмены'
    if ($consent -cne 'SWITCH') { throw 'Home handover cancelled.' }
    Read-TV 'am start -W -a android.intent.action.MAIN -c android.intent.category.HOME -n com.gathin.tvhome/.MainActivity' | Out-Host
    if (-not (Test-LauncherForeground)) { throw 'The replacement Home is not visible. No packages were disabled.' }
    $list = Join-Path $script:StateFolder 'home-handover.txt'
    Write-Text $list (($listPackages -join "`n") + "`n")
    # Record original package states before the first disable. The upstream tools
    # retain their Home/Wi-Fi/core/HDMI guards; no FORCE switches are set here.
    Invoke-Native $script:Python @('-I',(Join-Path $script:Repo 'tools\recovery.py'),'--save',$list)
    $marker = Join-Path $script:StateFolder 'home-handover.status'
    Write-Text $marker 'attempted'
    Invoke-RepoScript 'tools\disable.ps1' @('-TvHost',$TvAddress,'-List',$list)
    $stillEnabled = @(Get-EnabledPackages)
    if (@($listPackages | Where-Object { $stillEnabled -contains $_ }).Count -gt 0) { throw 'A Home blocker was refused or skipped. Handover will be rolled back.' }
    Read-TV 'cmd package set-home-activity --user 0 com.gathin.tvhome/.MainActivity' | Out-Host
    Read-TV 'input keyevent KEYCODE_HOME' | Out-Host
    Start-Sleep -Seconds 2
    if (-not (Test-LauncherHome)) { throw 'Home did not transfer after the guarded disable. Handover will be rolled back.' }
    Write-Text $marker 'active'
}
function Restore-Home($State) {
    Assert-OriginalHome $State.Home
    # A failed first install has no handover marker and needs only its preference
    # restored. Newer runs also restore the recorded Home blocker package states.
    $marker = if (Get-Variable StateFolder -Scope Script -ErrorAction SilentlyContinue) { Join-Path $script:StateFolder 'home-handover.status' } else { '' }
    if ($marker -and (Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $marker -Raw).Trim() -in @('attempted','active')) {
        $stockPackage = $State.Home.Split('/')[0]
        # Restore the real launcher before enabling the setup wizard, so its
        # RecoveryActivity can never become the only high-priority Home.
        Read-TV "pm enable --user 0 $stockPackage" | Out-Host
        Invoke-RepoScript 'tools\restore.ps1' @('-TvHost',$TvAddress,'-List',(Join-Path $script:StateFolder 'home-handover.txt'),'-Stock',$stockPackage)
    }
    Read-TV "cmd package set-home-activity --user 0 $($State.Home)" | Out-Host
    Read-TV 'input keyevent KEYCODE_HOME' | Out-Host
    Start-Sleep -Seconds 2
    $actual = Get-HomeComponent (Read-TV $script:HomeQuery)
    $active = Read-TV 'dumpsys activity activities'
    $pkg = $State.Home.Split('/')[0]
    $visible = @($active -split '\r?\n' | Where-Object { $_ -match 'mResumedActivity|topResumedActivity|mFocusedApp' }) -join "`n"
    if ($actual -cne $State.Home -or $visible -notmatch ([regex]::Escape($pkg) + '/')) {
        throw 'Original Home could not be verified. Keep debugging enabled and inspect the log.'
    }
    if ($marker -and (Test-Path -LiteralPath $marker)) { Write-Text $marker 'restored' }
    Write-Host 'Original Home restored. Existing applications and their data were preserved.' -ForegroundColor Green
}
function Save-OriginalState([string]$Folder, [string]$Identity) {
    $statePath = Join-Path $Folder 'original.json'
    if (Test-Path -LiteralPath $statePath) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        Assert-SameDevice $state $Identity
        return $state
    }
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    $originalHome = Get-HomeComponent (Read-TV $script:HomeQuery)
    Assert-OriginalHome $originalHome
    $queries = [ordered]@{
        'packages.txt' = 'pm list packages --user 0'
        'disabled.txt' = 'pm list packages -d --user 0'
        'getprop.txt' = 'getprop'
        'settings-global.txt' = 'settings list global'
        'settings-secure.txt' = 'settings list secure'
        'settings-system.txt' = 'settings list system'
        'home-candidates.txt' = 'cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME'
        'wifi.txt' = 'dumpsys wifi'
    }
    foreach ($name in $queries.Keys) { Write-Text (Join-Path $Folder $name) (Read-TV $queries[$name]) }
    $state = [pscustomobject]@{ Schema=1; Identity=$Identity; Home=$originalHome; Created=(Get-Date -Format o) }
    $temp = Join-Path $Folder 'original.pending.json'
    Write-Text $temp ($state | ConvertTo-Json)
    # No -Force: never overwrite the first successful original-state record.
    Move-Item -LiteralPath $temp -Destination $statePath
    return $state
}
function Save-Shot([string]$Path) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $script:Python -I (Join-Path $script:Repo 'tools\tv.py') --screenshot $Path | Out-Host; $ok = ($LASTEXITCODE -eq 0) }
    finally { $ErrorActionPreference = $old }
    if (-not $ok) { Write-Warning 'Screenshot unavailable. Check the TV screen directly; protected video may block captures.' }
}
function Get-VerifiedZip([string]$Url, [string]$Sha256, [string]$Target) {
    if ($Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $Url -notmatch '^https://') { throw 'Invalid download metadata.' }
    if ((Test-Path -LiteralPath $Target) -and (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash -ieq $Sha256) { return }
    $partial = "$Target.part"
    Write-Host "Downloading: $Url"
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $partial
    if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $Sha256) { throw 'SHA-256 mismatch. Download was not executed.' }
    Move-Item -LiteralPath $partial -Destination $Target -Force
}
function Initialize-Workspace {
    $script:Root = [IO.Path]::GetFullPath($WorkRoot)
    if ($script:Root -match '[^\x20-\x7e]') { throw 'WorkRoot must use ASCII characters for the Android build.' }
    $marker = Join-Path $script:Root 'apollo-workspace.txt'
    if ((Test-Path -LiteralPath $script:Root) -and -not (Test-Path -LiteralPath $marker)) {
        throw "Existing unmanaged folder: $script:Root. Choose a new -WorkRoot."
    }
    New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
    if (-not (Test-Path -LiteralPath $marker)) { Write-Text $marker 'ApolloTV wrapper workspace v1' }
    $script:Repo = Join-Path $script:Root 'cleanyourtv'
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'cleanyourtv'
    $ready = Join-Path $script:Root 'source-ready.txt'
    if (-not (Test-Path -LiteralPath $ready)) {
        if (-not (Test-Path -LiteralPath (Join-Path $source 'launcher\build-and-install.ps1'))) { throw 'Keep ApolloTV beside the downloaded cleanyourtv folder.' }
        & robocopy.exe $source $script:Repo /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XD .git .gradle build backup shots work | Out-Host
        if ($LASTEXITCODE -ge 8) { throw 'Could not copy the source tree.' }
        Write-Text $ready 'Local source copied; original source is unchanged.'
    }
    $script:Python = Join-Path $script:Repo 'tools\venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $script:Python)) {
        $bootstrap = $null
        $bootstrapArgs = @()
        foreach ($name in @('python.exe','python3.exe','py.exe')) {
            $candidate = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $candidate -or $candidate.Source -match '\\WindowsApps\\') { continue }
            $prefix = if ($name -eq 'py.exe') { @('-3') } else { @() }
            & $candidate.Source @prefix -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) and sys.maxsize > 2**32 else 1)' 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $bootstrap=$candidate.Source; $bootstrapArgs=$prefix; break }
        }
        if (-not $bootstrap) { throw 'Install Python 3.12 or 3.13 x64 from python.org, enable Add python.exe to PATH, and restart this script.' }
        Invoke-Native $bootstrap ($bootstrapArgs + @('-m','venv',(Join-Path $script:Repo 'tools\venv')))
        Invoke-Native $script:Python @('-m','pip','install','-r',(Join-Path $script:Repo 'tools\requirements.txt'))
    }
    Invoke-Native $script:Python @('-I','-c','import adb_shell, cryptography, rsa')
    New-Item -ItemType Directory -Path (Join-Path $script:Root 'logs') -Force | Out-Null
}
function Prepare-Toolchain {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $cache = Join-Path $script:Root 'downloads'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $jdkMarker = Join-Path $script:Root 'jdk-path.txt'
    if (Test-Path -LiteralPath $jdkMarker) { $env:JAVA_HOME = (Get-Content -LiteralPath $jdkMarker -Raw).Trim() }
    if (-not (Test-Path -LiteralPath $jdkMarker) -or -not (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME 'bin\javac.exe'))) {
        $assets = @(Invoke-RestMethod -Uri 'https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=x64&image_type=jdk&os=windows&vendor=eclipse')
        if ($assets.Count -lt 1) { throw 'Adoptium did not return a JDK package.' }
        $package = $assets[0].binary.package
        if ($package.link -notmatch '^https://github\.com/adoptium/temurin21-binaries/releases/download/') { throw 'Unexpected JDK download host.' }
        $zip = Join-Path $cache 'temurin21.zip'
        Get-VerifiedZip $package.link $package.checksum $zip
        $extract = Join-Path $script:Root ('jdk-' + [guid]::NewGuid().ToString('N'))
        Expand-Archive -LiteralPath $zip -DestinationPath $extract
        $jdk = @(Get-ChildItem -LiteralPath $extract -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\javac.exe') })
        if ($jdk.Count -ne 1) { throw 'JDK archive has an unexpected structure.' }
        $env:JAVA_HOME = $jdk[0].FullName
        Write-Text $jdkMarker $env:JAVA_HOME
    }
    $env:ANDROID_HOME = Join-Path $script:Root 'android-sdk'
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    $env:GRADLE_USER_HOME = Join-Path $script:Root 'gradle-cache'
    $env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
    $manager = Join-Path $env:ANDROID_HOME 'cmdline-tools\latest\bin\sdkmanager.bat'
    if (-not (Test-Path -LiteralPath $manager)) {
        $zip = Join-Path $cache 'android-commandline.zip'
        Get-VerifiedZip 'https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip' '90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a' $zip
        $extract = Join-Path $script:Root ('sdk-extract-' + [guid]::NewGuid().ToString('N'))
        Expand-Archive -LiteralPath $zip -DestinationPath $extract
        $parent = Join-Path $env:ANDROID_HOME 'cmdline-tools'
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Move-Item -LiteralPath (Join-Path $extract 'cmdline-tools') -Destination (Join-Path $parent 'latest')
    }
    $required = @('platforms\android-34\android.jar','build-tools\34.0.0\aapt.exe','platform-tools\adb.exe')
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $env:ANDROID_HOME $_)) })
    if ($missing.Count -gt 0) {
        Write-Host 'Android SDK license terms will be shown. Read them and answer y only if you agree.' -ForegroundColor Yellow
        Invoke-Native $manager @("--sdk_root=$env:ANDROID_HOME",'--licenses')
        Invoke-Native $manager @("--sdk_root=$env:ANDROID_HOME",'platform-tools','platforms;android-34','build-tools;34.0.0')
        foreach ($file in $required) { if (-not (Test-Path -LiteralPath (Join-Path $env:ANDROID_HOME $file))) { throw "SDK component missing: $file" } }
    }
    $sdkPath = $env:ANDROID_HOME.Replace('\','/')
    Write-Text (Join-Path $script:Repo 'launcher\local.properties') "sdk.dir=$sdkPath`n"
}
function Set-Dock([string[]]$Packages) {
    $apps = [ordered]@{
        'YouTube'='(?i)(^com\.google\.android\.youtube\.tv$|^com\.google\.android\.youtube$)'
        'VK Video'='(?i)(vkvideo|vk\.video|^com\.vk\.tv$)'
        'Rutube'='(?i)(rutube|^rtb\.mobile\.android$)'
        'Twitch'='(?i)twitch'
        'Kinopoisk'='(?i)kinopoisk'
        'Okko'='(?i)(^|\.)okko(\.|$)'
        'Wink'='(?i)(wink|rostelecom|^ru\.rt\.video\.app\.tv$)'
    }
    $dock = New-Object 'System.Collections.Generic.List[string]'
    foreach ($label in $apps.Keys) {
        $candidates = @($Packages | Where-Object { $_ -match $apps[$label] })
        if ($candidates.Count -eq 1) { $dock.Add($candidates[0]); Write-Host "$label -> $($candidates[0])" }
        else {
            Write-Host "$label : could not choose one installed package. Candidates: $($candidates -join ', ')"
            $chosen = Read-Host 'Введите точное имя установленного пакета или нажмите Enter — эту плитку можно настроить пультом позже'
            if ($chosen) {
                if ($Packages -cnotcontains $chosen -or $chosen -notmatch '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$') { throw 'Package is not in the installed-app list.' }
                $dock.Add($chosen)
            }
        }
    }
    $path = Join-Path $script:Repo 'launcher\app\src\main\res\values\config.xml'
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($path)
    $xml.SelectSingleNode('/resources/integer[@name="columns"]').InnerText = '7'
    $array = $xml.SelectSingleNode('/resources/string-array[@name="dock_apps"]')
    while ($array.HasChildNodes) { [void]$array.RemoveChild($array.FirstChild) }
    foreach ($pkg in $dock) { $item=$xml.CreateElement('item'); $item.InnerText=$pkg; [void]$array.AppendChild($item) }
    $xml.Save($path)
    $script:DockPackages = @($dock.ToArray())
    Write-Host 'Seven dock slots configured. Missing or incorrectly matched apps can be changed with Settings > Edit dock.'
}
function Apply-DockTheme {
    $themeFolder = Join-Path $script:StateFolder 'dock-theme'
    New-Item -ItemType Directory -Path $themeFolder -Force | Out-Null
    $theme = [ordered]@{ columns=7; dock_apps=@($script:DockPackages); fill_dock=$false; background='#000000' }
    Write-Text (Join-Path $themeFolder 'config.json') ($theme | ConvertTo-Json -Depth 4)
    Invoke-RepoScript 'tools\theme.ps1' @('-TvHost',$TvAddress,'-Theme',$themeFolder)
}
function Connect-TV {
    if (-not $TvAddress) {
        $localSettings = Join-Path $PSScriptRoot 'local-settings.json'
        if (Test-Path -LiteralPath $localSettings) {
            $settings = Get-Content -LiteralPath $localSettings -Raw | ConvertFrom-Json
            $TvAddress = [string]$settings.TvAddress
        }
        if (-not $TvAddress) { $TvAddress = Read-Host 'Введите IPv4-адрес телевизора из настроек сети' }
        $script:TvAddress = $TvAddress
    }
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($TvAddress, [ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Use the IPv4 address shown on your TV.' }
    $env:TV_HOST = $TvAddress
    $env:TV_PORT = "$Port"
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        $pending = $tcp.BeginConnect($TvAddress, $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(4000)) { throw 'ADB port did not answer. Check TV address and network debugging. Nothing on the TV has changed.' }
        $tcp.EndConnect($pending)
    } finally { $tcp.Close() }
    Write-Host 'Посмотрите на ТВ и подтвердите «Разрешить отладку USB?», если появится запрос.' -ForegroundColor Yellow
    $model = Read-TV 'getprop ro.product.model'
    Write-Host "Подключён телевизор: $model"
    $id = Read-TV 'settings get secure android_id'
    $serial = Read-TV 'getprop ro.serialno'
    if (($id -notmatch '^[a-fA-F0-9]{8,32}$') -and ($serial -in @('','unknown','null'))) { throw 'Cannot obtain a stable TV identity for backup and restore.' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$model|$serial|$id")) }
    finally { $sha.Dispose() }
    $script:Identity = ([BitConverter]::ToString($hash)).Replace('-','').ToLowerInvariant()
    $script:StateFolder = Join-Path $script:Root ('backups\' + $script:Identity)
}
function Finish-Session {
    Write-Host 'Проверьте пультом Home, стрелки, Back, удержание громкости, настройки, входы, видео, HDMI и трансляцию.' -ForegroundColor Yellow
    Write-Host 'Перезагрузите ТВ через меню и снова проверьте Home. Затем выключите все виды отладки, отзовите разрешения отладки и перезагрузите ТВ.'
    $answer = Read-Host 'После отключения отладки введите CHECK для проверки порта или нажмите Enter, чтобы закончить позже'
    if ($answer -ieq 'CHECK') {
        & $script:Python -I (Join-Path $script:Repo 'tools\adb-closed.py') $TvAddress "$Port" | Out-Host
        Write-Host 'A timeout alone is not proof: also confirm the debugging switches are OFF on the TV.'
    }
}

if ($LibraryOnly) { return }
$exitCode = 0
$transcript = $false
$changed = $false
$state = $null
$mutex = $null
$locked = $false
try {
    $mutex = New-Object Threading.Mutex($false, 'Local\ApolloTVSetup')
    $locked = $mutex.WaitOne(0)
    if (-not $locked) { throw 'Another ApolloTV script is already running.' }
    Initialize-Workspace
    $log = Join-Path $script:Root ('logs\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $Mode + '.txt')
    Start-Transcript -LiteralPath $log | Out-Null
    $transcript = $true
    Write-Host "ApolloTV - $Mode. Workspace: $script:Root"
    if ($Mode -eq 'Prepare') {
        Prepare-Toolchain
        Push-Location (Join-Path $script:Repo 'launcher')
        try { Invoke-Native '.\gradlew.bat' @('--no-daemon',':app:dependencies','--configuration','releaseRuntimeClasspath') }
        finally { Pop-Location }
        Write-Host 'Toolchain prepared. Run INSTALL-TV.cmd when the TV is reachable. The first build may download additional dependencies.' -ForegroundColor Green
    } else {
        Connect-TV
        if ($Mode -eq 'Check') {
            Write-Host (Read-TV 'getprop ro.build.version.release')
            Write-Host (Read-TV $script:HomeQuery)
            Write-Host 'Connection check passed. No TV settings changed.' -ForegroundColor Green
        } elseif ($Mode -eq 'Restore') {
            $statePath = Join-Path $script:StateFolder 'original.json'
            if (-not (Test-Path -LiteralPath $statePath)) { throw 'No original backup exists for this TV. Restore refused.' }
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            Assert-SameDevice $state $script:Identity
            Restore-Home $state
            Finish-Session
        } else {
            $sdk = Read-TV 'getprop ro.build.version.sdk'
            if ($sdk -notmatch '^\d+$' -or [int]$sdk -lt 26) { throw 'This launcher requires Android SDK 26 or newer.' }
            $userId = Read-TV 'am get-current-user'
            if ($userId -ne '0') { throw 'Switch the TV to its main owner profile (user 0) and retry.' }
            $state = Save-OriginalState $script:StateFolder $script:Identity
            Write-Host "Original backup: $script:StateFolder"
            Save-Shot (Join-Path $script:StateFolder 'before.png')
            $packages = @(Get-EnabledPackages)
            Set-Dock @($packages)
            $changed = $true  # Even a partially failed install must restore the saved Home preference.
            if ($Mode -eq 'Switch') {
                $installedPath = Read-TV 'pm path com.gathin.tvhome'
                if ($installedPath -notmatch '(?m)^package:/.+\.apk\s*$') { throw 'CleanYourTV is not installed. Run INSTALL-TV.cmd first.' }
                Write-Host 'Исправление уже установленного Home без повторной сборки APK.'
            } else {
                Prepare-Toolchain
                Write-Host 'Building and installing the launcher before changing system Home handlers.'
                Invoke-LauncherInstall
            }
            Complete-HomeHandover $state @($packages)
            Apply-DockTheme
            Read-TV 'input keyevent KEYCODE_HOME' | Out-Host
            Start-Sleep -Seconds 2
            if (-not (Test-LauncherHome)) { throw 'The firmware did not give Home to the new launcher.' }
            Save-Shot (Join-Path $script:StateFolder 'after.png')
            Write-Host 'Нажмите настоящую кнопку Home на пульте и проверьте, что появился новый экран.'
            $answer = Read-Host 'Новый экран появился? Введите YES. Любой другой ответ вернёт прежний Home'
            if ($answer -ine 'YES') { throw 'New Home was not confirmed with the remote.' }
            if (-not (Test-LauncherHome)) { throw 'Home switched away from the new launcher after the real button press.' }
            Write-Host 'Новый Home установлен и проверен. Пользовательские приложения сохранены.' -ForegroundColor Green
            Write-Host 'Ряд: YouTube, VK Видео, Rutube, Twitch, Кинопоиск, Okko, Wink. Для исправления плиток удерживайте OK на Settings → Edit dock.'
            Finish-Session
        }
    }
} catch {
    $exitCode = 1
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($changed -and $null -ne $state) {
        Write-Host 'Trying to restore the original Home...'
        try { Restore-Home $state }
        catch { Write-Host "Automatic restore could not be verified: $($_.Exception.Message). Keep debugging enabled and run RESTORE-TV.cmd when connected." -ForegroundColor Red }
    }
} finally {
    if ($transcript) { Stop-Transcript | Out-Null; Write-Host "Log: $log" }
    if ($locked) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
exit $exitCode
