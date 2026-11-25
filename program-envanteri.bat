@echo off
chcp 65001 >nul
setlocal
title Program ve Eklenti Envanteri
set "BAT_PATH=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$raw = [System.IO.File]::ReadAllText($env:BAT_PATH, [System.Text.Encoding]::UTF8); $m = '#PS_' + 'START'; $i = $raw.IndexOf($m); if ($i -ge 0) { Invoke-Expression $raw.Substring($i + $m.Length) }"
if not "%ENVANTER_NO_PAUSE%"=="1" (
  echo.
  pause
)
exit /b
#PS_START
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue } catch {}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$items = New-Object 'System.Collections.Generic.List[object]'

function Add-Item {
    param(
        [string]$Kategori,
        [string]$UstProgram = '-',
        [string]$Ad,
        [string]$Surum = '-',
        [string]$Yayinci = '-',
        [string]$KurulumTarihi = '-',
        [string]$Konum = '-',
        [string]$Not = '-'
    )
    if ([string]::IsNullOrWhiteSpace($Ad)) { return }
    $items.Add([PSCustomObject]@{
        Kategori      = $Kategori.Trim()
        UstProgram    = if ([string]::IsNullOrWhiteSpace($UstProgram)) { '-' } else { $UstProgram.Trim() }
        Ad            = $Ad.Trim()
        Surum         = if ([string]::IsNullOrWhiteSpace($Surum)) { '-' } else { $Surum.Trim() }
        Yayinci       = if ([string]::IsNullOrWhiteSpace($Yayinci)) { '-' } else { $Yayinci.Trim() }
        KurulumTarihi = if ([string]::IsNullOrWhiteSpace($KurulumTarihi)) { '-' } else { $KurulumTarihi.Trim() }
        Konum         = if ([string]::IsNullOrWhiteSpace($Konum)) { '-' } else { $Konum.Trim() }
        Not           = if ([string]::IsNullOrWhiteSpace($Not)) { '-' } else { $Not.Trim() }
    })
}

function As-Array {
    param($Obj)
    if ($null -eq $Obj) { return ,@() }
    if ($Obj -is [System.Array]) { return ,$Obj }
    return ,@($Obj)
}

function Format-RegDate {
    param([string]$d)
    if (-not $d) { return '-' }
    $d = $d.Trim()
    if ($d -match '^(\d{4})(\d{2})(\d{2})$') {
        $mo = [int]$Matches[2]; $dy = [int]$Matches[3]
        if ($mo -ge 1 -and $mo -le 12 -and $dy -ge 1 -and $dy -le 31) {
            return "$($Matches[1])-$($Matches[2])-$($Matches[3])"
        }
        return '-'
    }
    if ($d -match '^\d{10}$') {
        try {
            $epoch = [DateTimeOffset]::FromUnixTimeSeconds([long]$d).ToLocalTime()
            if ($epoch.Year -ge 2000 -and $epoch.Year -le 2100) { return $epoch.ToString('yyyy-MM-dd') }
        } catch {}
    }
    return $d
}

function Get-FileVer {
    param([string]$Path)
    if (-not $Path) { return $null }
    $p = $Path.Trim().Trim('"')
    if ($p -match '^file:///(.+)$') { $p = [System.Uri]::UnescapeDataString($Matches[1]) -replace '/', '\' }
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    try {
        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($p)
        $ver = if ($vi.ProductVersion -and $vi.ProductVersion.Trim()) { $vi.ProductVersion.Trim() }
               elseif ($vi.FileVersion -and $vi.FileVersion.Trim()) { $vi.FileVersion.Trim() }
               else { $null }
        $pub = if ($vi.CompanyName -and $vi.CompanyName.Trim()) { $vi.CompanyName.Trim() } else { $null }
        return @{ Version = $ver; Publisher = $pub; Path = $p }
    } catch { return $null }
}

function Resolve-ClsidInfo {
    param([string]$Guid)
    if (-not $Guid) { return @{ Version = '-'; Path = '-'; Publisher = '-' } }
    $g = $Guid.Trim()
    if (-not $g.StartsWith('{')) { $g = "{$g}" }
    $paths = @(
        "Registry::HKEY_CLASSES_ROOT\CLSID\$g\InprocServer32",
        "Registry::HKEY_CLASSES_ROOT\WOW6432Node\CLSID\$g\InprocServer32",
        "Registry::HKEY_CLASSES_ROOT\CLSID\$g\LocalServer32"
    )
    foreach ($rp in $paths) {
        try {
            if (-not (Test-Path -LiteralPath $rp)) { continue }
            $k = Get-Item -LiteralPath $rp -ErrorAction Stop
            $asm = [string]$k.GetValue('Assembly')
            $cb  = [string]$k.GetValue('CodeBase')
            $def = [string]$k.GetValue('')
            $ver = '-'; $filePath = '-'; $pub = '-'

            if ($asm -and $asm -match 'Version=([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)') {
                $ver = $Matches[1]
            }
            $cand = $null
            if ($cb) { $cand = $cb }
            elseif ($def -and ($def -notmatch '(?i)mscoree\.dll')) {
                if ($def -match '^"([^"]+)"') { $cand = $Matches[1] } else { $cand = ($def -split '\s+/')[0] }
            }
            if ($cand) {
                $fv = Get-FileVer $cand
                if ($fv) {
                    $filePath = $fv.Path
                    if ($ver -eq '-' -and $fv.Version) { $ver = $fv.Version }
                    if ($fv.Publisher) { $pub = $fv.Publisher }
                } else {
                    $filePath = $cand
                }
            }
            return @{ Version = $ver; Path = $filePath; Publisher = $pub }
        } catch {}
    }
    return @{ Version = '-'; Path = '-'; Publisher = '-' }
}

function Invoke-FastCmd {
    param(
        [string]$FileName,
        [string]$Arguments = '',
        [int]$TimeoutMs = 3500
    )
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FileName
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        if (-not $p.Start()) { return $null }
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch {}
            return $null
        }
        $out = $outTask.GetAwaiter().GetResult()
        $err = $errTask.GetAwaiter().GetResult()
        $combined = if ($out.Trim()) { $out.Trim() } else { $err.Trim() }
        return $combined
    } catch { return $null }
}

function HtmlEnc {
    param([string]$s)
    if ($null -eq $s) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($s)
}

function CsvEsc {
    param([string]$s)
    if ($null -eq $s) { return '' }
    $t = $s -replace "`r`n", ' ' -replace "`n", ' ' -replace "`r", ' '
    if ($t -match '[;"\r\n]') { return '"' + ($t -replace '"', '""') + '"' }
    return $t
}

# --- Sistem Bilgisi ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$os = Get-CimInstance Win32_OperatingSystem
$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
$cs = Get-CimInstance Win32_ComputerSystem
$ramGb = if ($cs.TotalPhysicalMemory) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) } else { 0 }
$cvKey = Get-Item 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$winDispVer = [string]$cvKey.GetValue('DisplayVersion')
if (-not $winDispVer) { $winDispVer = [string]$cvKey.GetValue('ReleaseId') }
$winBuild = [string]$cvKey.GetValue('CurrentBuildNumber')
$winUbr = [string]$cvKey.GetValue('UBR')
$winFull = "$($os.Caption) $winDispVer (Build $winBuild.$winUbr)".Trim()
$pcName = $env:COMPUTERNAME
$curUser = $env:USERNAME
$nowStr = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')

# Tarama yapilacak kullanici profilleri (yonetici ise tum profiller, degilse mevcut kullanici)
$profileList = New-Object 'System.Collections.Generic.List[object]'
$profileList.Add(@{ Name = $curUser; Path = $env:USERPROFILE; Current = $true })
if ($isAdmin) {
    Get-ChildItem 'C:\Users' -Directory | Where-Object {
        $_.Name -notin @($curUser, 'Public', 'Default', 'Default User', 'All Users', 'defaultuser0') -and
        -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } | ForEach-Object {
        $profileList.Add(@{ Name = $_.Name; Path = $_.FullName; Current = $false })
    }
}

Write-Host ''
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host '   PROGRAM VE EKLENTI ENVANTERI' -ForegroundColor Yellow
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host "Bilgisayar : $pcName ($winFull)"
Write-Host "Kullanici  : $curUser | Yonetici: $(if ($isAdmin) {'Evet'} else {'Hayir'})"
Write-Host ''

# =====================================================================
# [1/10] KURULU MASAUSTU PROGRAMLARI (Registry - Guvenli .GetValue)
# =====================================================================
Write-Host '[1/10] Kurulu programlar taraniyor...' -ForegroundColor White
$regSources = @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';             Scope = '64-bit' },
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = '32-bit' },
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';             Scope = "Kullanici ($curUser)" }
)

$progMap = @{}
$sysCandidates = New-Object 'System.Collections.Generic.List[object]'

foreach ($src in $regSources) {
    if (-not (Test-Path -LiteralPath $src.Path)) { continue }
    Get-ChildItem -LiteralPath $src.Path | ForEach-Object {
        try {
            $name = [string]$_.GetValue('DisplayName')
            if ([string]::IsNullOrWhiteSpace($name)) { return }
            $name = $name.Trim()
            $ver = [string]$_.GetValue('DisplayVersion')
            $pub = [string]$_.GetValue('Publisher')
            $dt  = Format-RegDate ([string]$_.GetValue('InstallDate'))
            $loc = [string]$_.GetValue('InstallLocation')
            $sys = $_.GetValue('SystemComponent')
            $rel = [string]$_.GetValue('ReleaseType')
            $par = [string]$_.GetValue('ParentKeyName')
            $parDisp = [string]$_.GetValue('ParentDisplayName')

            if ($rel -match 'Update|Hotfix|Security Update' -and ($par -or $parDisp)) { return }
            if ($name -match '^KB\d{6,}' -and $par) { return }

            $obj = [PSCustomObject]@{
                Ad = $name
                Surum = if ($ver) { $ver.Trim() } else { '-' }
                Yayinci = if ($pub) { $pub.Trim() } else { '-' }
                Tarih = $dt
                Konum = if ($loc) { $loc.Trim() } else { '-' }
                Scope = $src.Scope
                Sys = ($sys -eq 1)
            }

            if ($obj.Sys) {
                # Bazi muhendislik/CAD bilesenleri SystemComponent=1 isaretli olabiliyor; sonradan sadece ana listede yoksa dahil et
                if ($name -match 'SOLIDWORKS|SolidCAM|ANSYS|SpaceClaim|Autodesk|Revit|AutoCAD|Inventor|3ds Max|Maya|Siemens|CATIA|Creo|Mastercam|MATLAB|LabVIEW|Altium|TIA Portal') {
                    $sysCandidates.Add($obj)
                }
                return
            }

            $key = ($name.ToLowerInvariant() + '|' + $obj.Surum.ToLowerInvariant())
            if (-not $progMap.ContainsKey($key)) {
                $progMap[$key] = $obj
            } else {
                $ex = $progMap[$key]
                if ($ex.Konum -eq '-' -and $obj.Konum -ne '-') { $ex.Konum = $obj.Konum }
                if ($ex.Tarih -eq '-' -and $obj.Tarih -ne '-') { $ex.Tarih = $obj.Tarih }
                if ($ex.Yayinci -eq '-' -and $obj.Yayinci -ne '-') { $ex.Yayinci = $obj.Yayinci }
            }
        } catch {}
    }
}

foreach ($c in $sysCandidates) {
    $normName = $c.Ad.ToLowerInvariant()
    $existsSameName = $false
    foreach ($v in $progMap.Values) {
        if ($v.Ad.ToLowerInvariant() -eq $normName) { $existsSameName = $true; break }
    }
    if (-not $existsSameName) {
        $key = $normName + '|' + $c.Surum.ToLowerInvariant()
        if (-not $progMap.ContainsKey($key)) {
            $c.Scope = "$($c.Scope), Sistem Bileseni"
            $progMap[$key] = $c
        }
    }
}

$progMap.Values | Sort-Object Ad, Surum | ForEach-Object {
    Add-Item -Kategori 'Kurulu Programlar' -Ad $_.Ad -Surum $_.Surum -Yayinci $_.Yayinci -KurulumTarihi $_.Tarih -Konum $_.Konum -Not $_.Scope
}

# Autodesk UPI2 (Uninstall'da gorunmeyen Autodesk urunleri icin ek kontrol)
if (Test-Path 'HKLM:\SOFTWARE\Autodesk\UPI2') {
    Get-ChildItem 'HKLM:\SOFTWARE\Autodesk\UPI2' | ForEach-Object {
        try {
            $pn = [string]$_.GetValue('ProductName')
            $bn = [string]$_.GetValue('BuildNumber')
            $rl = [string]$_.GetValue('Release')
            if (-not $pn) { return }
            $exists = $false
            foreach ($v in $progMap.Values) {
                if ($v.Ad -eq $pn) { $exists = $true; break }
            }
            if (-not $exists) {
                $ver = if ($bn) { $bn } elseif ($rl) { $rl } else { '-' }
                Add-Item -Kategori 'Kurulu Programlar' -Ad $pn -Surum $ver -Yayinci 'Autodesk' -Not 'Autodesk UPI2'
            }
        } catch {}
    }
}

# =====================================================================
# [2/10] MICROSOFT STORE (APPX) UYGULAMALARI
# =====================================================================
Write-Host '[2/10] Microsoft Store uygulamalari taraniyor...' -ForegroundColor White
$appxParams = if ($isAdmin) { @{ AllUsers = $true } } else { @{} }
$seenAppx = @{}
Get-AppxPackage @appxParams | Where-Object {
    -not $_.IsFramework -and -not $_.IsResourcePackage -and
    $_.SignatureKind -ne 'System' -and
    $_.Name -notmatch '^(Microsoft\.VCLibs|Microsoft\.NET\.Native|Microsoft\.UI\.Xaml|Microsoft\.Services\.Store|Microsoft\.Advertising|Microsoft\.Win32WebViewHost|MicrosoftWindows\.Client|Windows\.CBSPreview)'
} | Sort-Object Name | ForEach-Object {
    $k = "$($_.Name)|$($_.Version)"
    if ($seenAppx.ContainsKey($k)) { return }
    $seenAppx[$k] = $true
    $pub = if ($_.Publisher -match 'CN="([^"]+)"') { $Matches[1] }
           elseif ($_.Publisher -match 'CN=([^,]+)') { $Matches[1] }
           else { $_.Publisher }
    Add-Item -Kategori 'Microsoft Store Uygulamalari' -Ad $_.Name -Surum $_.Version -Yayinci $pub -Konum $_.InstallLocation -Not $_.Architecture
}

# =====================================================================
# [3/10] CAD / CAM / MUHENDISLIK PROGRAMLARI VE EKLENTILERI
# =====================================================================
Write-Host '[3/10] SolidWorks, SolidCAM, ANSYS/SpaceClaim, Autodesk, MATLAB taraniyor...' -ForegroundColor White

# --- 3A) SOLIDWORKS ---
$swStartup = @{}
foreach ($sk in @('HKLM:\SOFTWARE\SolidWorks\AddInsStartup', 'HKCU:\Software\SolidWorks\AddInsStartup')) {
    if (Test-Path $sk) {
        Get-ChildItem $sk | ForEach-Object {
            $g = $_.PSChildName.ToUpperInvariant()
            $val = $_.GetValue('')
            if ($null -ne $val -and "$val" -ne '') { $swStartup[$g] = "$val" }
        }
    }
}

$swAddinSeen = @{}
function Scan-SwAddinRoot {
    param([string]$RegPath, [string]$ParentLabel)
    if (-not (Test-Path -LiteralPath $RegPath)) { return }
    Get-ChildItem -LiteralPath $RegPath | ForEach-Object {
        try {
            $guid = $_.PSChildName
            if ($guid -notmatch '^\{?[0-9A-Fa-f-]{36}\}?$') { return }
            $gKey = ($ParentLabel + '|' + $guid.ToUpperInvariant())
            if ($swAddinSeen.ContainsKey($gKey)) { return }
            $swAddinSeen[$gKey] = $true

            $title = [string]$_.GetValue('Title')
            if (-not $title) { $title = [string]$_.GetValue('') }
            if (-not $title) { $title = $guid }
            $desc = [string]$_.GetValue('Description')
            $clsid = Resolve-ClsidInfo $guid
            $gUpper = $guid.ToUpperInvariant()
            if (-not $gUpper.StartsWith('{')) { $gUpper = "{$gUpper}" }
            $st = if ($swStartup.ContainsKey($gUpper)) {
                if ($swStartup[$gUpper] -eq '1') { 'Baslangicta Aktif' } elseif ($swStartup[$gUpper] -eq '0') { 'Baslangicta Pasif' } else { "Durum=$($swStartup[$gUpper])" }
            } else { 'Durum Bilinmiyor' }
            $noteParts = @($st)
            if ($desc -and $desc -ne $title) { $noteParts += $desc }

            Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram $ParentLabel -Ad $title -Surum $clsid.Version -Yayinci $clsid.Publisher -Konum $clsid.Path -Not ($noteParts -join ' | ')
        } catch {}
    }
}

Scan-SwAddinRoot 'HKLM:\SOFTWARE\SolidWorks\AddIns' 'SOLIDWORKS (Genel)'
Scan-SwAddinRoot 'HKLM:\SOFTWARE\WOW6432Node\SolidWorks\AddIns' 'SOLIDWORKS (Genel 32-bit)'

foreach ($swHive in @('HKLM:\SOFTWARE\SolidWorks', 'HKCU:\Software\SolidWorks')) {
    if (-not (Test-Path $swHive)) { continue }
    Get-ChildItem $swHive | Where-Object { $_.PSChildName -match '^SOLIDWORKS\s+\d{4}' } | ForEach-Object {
        $swVerName = $_.PSChildName
        $setupPath = Join-Path $_.PSPath 'Setup'
        if ($swHive -like 'HKLM:*' -and (Test-Path $setupPath)) {
            $sk = Get-Item $setupPath
            $swFolder = [string]$sk.GetValue('SolidWorks Folder')
            $swExe = if ($swFolder) { Join-Path $swFolder 'SLDWORKS.exe' } else { $null }
            $fv = Get-FileVer $swExe
            if ($fv -and $fv.Version) {
                Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram $swVerName -Ad "$swVerName (Ana Uygulama)" -Surum $fv.Version -Yayinci 'Dassault Systemes SolidWorks' -Konum $swFolder -Not 'SLDWORKS.exe'
            }
        }
        Scan-SwAddinRoot (Join-Path $_.PSPath 'Addins') $swVerName
    }
}

# --- 3B) SOLIDCAM ---
$scSeen = @{}
foreach ($scRoot in @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node', 'HKCU:\Software')) {
    if (-not (Test-Path $scRoot)) { continue }
    Get-ChildItem $scRoot | Where-Object { $_.PSChildName -match '^SolidCAM' } | ForEach-Object {
        $n = $_.PSChildName
        $ver = [string]$_.GetValue('Version')
        if (-not $ver) { $ver = [string]$_.GetValue('Build') }
        $dir = [string]$_.GetValue('InstallDir')
        if (-not $dir) { $dir = [string]$_.GetValue('Path') }
        $k = "$n|$ver|$dir"
        if (-not $scSeen.ContainsKey($k)) {
            $scSeen[$k] = $true
            Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram 'SolidCAM' -Ad $n -Surum $(if ($ver) {$ver} else {'-'}) -Yayinci 'SolidCAM' -Konum $(if ($dir) {$dir} else {'-'}) -Not 'Registry'
        }
        Get-ChildItem $_.PSPath | ForEach-Object {
            $subName = $_.PSChildName
            $subVer = [string]$_.GetValue('Version')
            if (-not $subVer) { $subVer = [string]$_.GetValue('BuildVersion') }
            $subDir = [string]$_.GetValue('SolidCAMDir')
            if (-not $subDir) { $subDir = [string]$_.GetValue('InstallDir') }
            if ($subVer -or $subDir) {
                $sk2 = "$n $subName|$subVer|$subDir"
                if (-not $scSeen.ContainsKey($sk2)) {
                    $scSeen[$sk2] = $true
                    Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram 'SolidCAM' -Ad "$n $subName" -Surum $(if ($subVer) {$subVer} else {'-'}) -Yayinci 'SolidCAM' -Konum $(if ($subDir) {$subDir} else {'-'}) -Not 'SolidCAM Surumu'
                }
            }
        }
    }
}
foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $pf -or -not (Test-Path $pf)) { continue }
    Get-ChildItem $pf -Directory -Filter 'SolidCAM*' | ForEach-Object {
        $dir = $_.FullName
        $exe = Get-ChildItem $dir -Filter '*.exe' -Depth 1 | Where-Object { $_.Name -match 'SolidCAM|SC' } | Select-Object -First 1
        $fv = if ($exe) { Get-FileVer $exe.FullName } else { $null }
        $v = if ($fv -and $fv.Version) { $fv.Version } else { '-' }
        $k = "DIR|$($_.Name)|$v"
        if (-not $scSeen.ContainsKey($k)) {
            $scSeen[$k] = $true
            Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram 'SolidCAM' -Ad $_.Name -Surum $v -Yayinci 'SolidCAM' -Konum $dir -Not 'Program Files'
        }
    }
}

# --- 3C) ANSYS & SPACECLAIM ---
$ansysRoots = New-Object 'System.Collections.Generic.HashSet[string]'
Get-ChildItem Env: | Where-Object { $_.Name -match '^AWP_ROOT(\d{3})$' } | ForEach-Object {
    if ($_.Value -and (Test-Path -LiteralPath $_.Value)) { [void]$ansysRoots.Add($_.Value) }
}
foreach ($cand in @('C:\Program Files\ANSYS Inc', 'D:\Ansys', 'D:\ANSYS Inc')) {
    if (Test-Path -LiteralPath $cand) {
        Get-ChildItem -LiteralPath $cand -Directory | Where-Object { $_.Name -match '^v\d{3}$' } | ForEach-Object {
            [void]$ansysRoots.Add($_.FullName)
        }
    }
}
$ansysModuleNames = @{
    'aisol'       = 'ANSYS Workbench / Mechanical'
    'ansys'       = 'ANSYS Mechanical APDL'
    'fluent'      = 'ANSYS Fluent'
    'CFX'         = 'ANSYS CFX'
    'scdm'        = 'ANSYS SpaceClaim'
    'Discovery'   = 'ANSYS Discovery'
    'optiSLang'   = 'ANSYS optiSLang'
    'ACP'         = 'ANSYS Composite PrepPost (ACP)'
    'Icepak'      = 'ANSYS Icepak'
    'Maxwell'     = 'ANSYS Maxwell'
    'HFSS'        = 'ANSYS HFSS'
    'Electronics' = 'ANSYS Electronics Desktop'
    'Motion'      = 'ANSYS Motion'
    'Rocky'       = 'ANSYS Rocky'
    'LSDYNA'      = 'ANSYS LS-DYNA'
    'TwinBuilder' = 'ANSYS Twin Builder'
    'Sherlock'    = 'ANSYS Sherlock'
    'Forte'       = 'ANSYS Forte'
    'Polyflow'    = 'ANSYS Polyflow'
    'Chemkin'     = 'ANSYS Chemkin'
    'CADConfig'   = 'ANSYS CAD Configuration'
}
foreach ($ar in $ansysRoots) {
    $vCode = if ($ar -match 'v(\d{2})(\d)$') { "20$($Matches[1]) R$($Matches[2])" } else { Split-Path $ar -Leaf }
    $parentLabel = "ANSYS $vCode"
    Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram $parentLabel -Ad "ANSYS $vCode (Ana Kurulum)" -Surum $vCode -Yayinci 'ANSYS, Inc.' -Konum $ar -Not 'AWP_ROOT / Kurulum Klasoru'
    Get-ChildItem -LiteralPath $ar -Directory | ForEach-Object {
        $dn = $_.Name
        foreach ($mk in $ansysModuleNames.Keys) {
            if ($dn -ieq $mk) {
                Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram $parentLabel -Ad $ansysModuleNames[$mk] -Surum $vCode -Yayinci 'ANSYS, Inc.' -Konum $_.FullName -Not "Modul ($dn)"
                break
            }
        }
    }
}
# Standalone SpaceClaim
foreach ($spReg in @('HKLM:\SOFTWARE\SpaceClaim', 'HKLM:\SOFTWARE\WOW6432Node\SpaceClaim')) {
    if (Test-Path $spReg) {
        Get-ChildItem $spReg | ForEach-Object {
            Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram 'SpaceClaim' -Ad "SpaceClaim $($_.PSChildName)" -Surum $_.PSChildName -Yayinci 'SpaceClaim / ANSYS' -Not 'Registry'
        }
    }
}

# --- 3D) AUTODESK (Revit, AutoCAD, Inventor, 3ds Max, Maya, Civil 3D) Eklentileri ---
$adBundleDirs = New-Object 'System.Collections.Generic.List[string]'
$adBundleDirs.Add('C:\ProgramData\Autodesk\ApplicationPlugins')
$adBundleDirs.Add('C:\Program Files\Autodesk\ApplicationPlugins')
foreach ($prof in $profileList) {
    $adBundleDirs.Add((Join-Path $prof.Path 'AppData\Roaming\Autodesk\ApplicationPlugins'))
}
$adSeen = @{}
foreach ($bd in $adBundleDirs) {
    if (-not (Test-Path -LiteralPath $bd)) { continue }
    Get-ChildItem -LiteralPath $bd -Directory -Filter '*.bundle' | ForEach-Object {
        $pkg = Join-Path $_.FullName 'PackageContents.xml'
        if (-not (Test-Path -LiteralPath $pkg)) { return }
        try {
            [xml]$xml = Get-Content -LiteralPath $pkg -Raw -Encoding UTF8
            $ap = $xml.ApplicationPackage
            $name = if ($ap.Name) { [string]$ap.Name } else { $_.BaseName }
            $ver  = if ($ap.AppVersion) { [string]$ap.AppVersion } else { '-' }
            $auth = if ($ap.Author) { [string]$ap.Author } else { '-' }
            $desc = if ($ap.Description) { [string]$ap.Description } else { '' }
            $k = "$name|$ver|$($_.FullName)"
            if ($adSeen.ContainsKey($k)) { return }
            $adSeen[$k] = $true
            Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram 'Autodesk (ApplicationPlugins)' -Ad $name -Surum $ver -Yayinci $auth -Konum $_.FullName -Not $(if ($desc) {$desc} else {'Bundle'})
        } catch {}
    }
}

# Revit .addin dosyalari
$revitRoots = New-Object 'System.Collections.Generic.List[string]'
$revitRoots.Add('C:\ProgramData\Autodesk\Revit\Addins')
foreach ($prof in $profileList) {
    $revitRoots.Add((Join-Path $prof.Path 'AppData\Roaming\Autodesk\Revit\Addins'))
}
foreach ($rr in $revitRoots) {
    if (-not (Test-Path -LiteralPath $rr)) { continue }
    Get-ChildItem -LiteralPath $rr -Filter '*.addin' -Recurse | ForEach-Object {
        try {
            $year = $_.Directory.Name
            $parent = if ($year -match '^\d{4}$') { "Autodesk Revit $year" } else { 'Autodesk Revit' }
            [xml]$xml = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
            foreach ($ai in $xml.RevitAddIns.AddIn) {
                $n = [string]$ai.Name
                if (-not $n) { $n = [string]$ai.Text }
                if (-not $n) { $n = $_.BaseName }
                $asm = [string]$ai.Assembly
                $vend = [string]$ai.VendorId
                if ($asm -and -not [IO.Path]::IsPathRooted($asm)) {
                    $asmFull = Join-Path $_.DirectoryName $asm
                } else { $asmFull = $asm }
                $fv = Get-FileVer $asmFull
                $ver = if ($fv -and $fv.Version) { $fv.Version } else { '-' }
                $pub = if ($fv -and $fv.Publisher) { $fv.Publisher } elseif ($vend) { $vend } else { '-' }
                Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram $parent -Ad $n -Surum $ver -Yayinci $pub -Konum $(if ($asmFull) {$asmFull} else {$_.FullName}) -Not 'Revit .addin'
            }
        } catch {}
    }
}

# Inventor .addin dosyalari
$invRoots = @('C:\ProgramData\Autodesk\Inventor Addins')
Get-ChildItem 'C:\ProgramData\Autodesk' -Directory -Filter 'Inventor*' | ForEach-Object {
    $p = Join-Path $_.FullName 'Addins'
    if (Test-Path -LiteralPath $p) { $invRoots += $p }
}
foreach ($ir in $invRoots) {
    if (-not (Test-Path -LiteralPath $ir)) { continue }
    Get-ChildItem -LiteralPath $ir -Filter '*.addin' -Recurse | ForEach-Object {
        try {
            [xml]$xml = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
            $ai = $xml.Addin
            if ($ai) {
                $n = if ($ai.DisplayName) { [string]$ai.DisplayName } else { $_.BaseName }
                $asm = [string]$ai.Assembly
                $fv = Get-FileVer $asm
                Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram 'Autodesk Inventor' -Ad $n -Surum $(if ($fv -and $fv.Version) {$fv.Version} else {'-'}) -Yayinci $(if ($fv -and $fv.Publisher) {$fv.Publisher} else {'-'}) -Konum $(if ($asm) {$asm} else {$_.FullName}) -Not 'Inventor .addin'
            }
        } catch {}
    }
}

# --- 3E) MATLAB TOOLBOXES ---
if (Test-Path 'HKLM:\SOFTWARE\MathWorks\MATLAB') {
    Get-ChildItem 'HKLM:\SOFTWARE\MathWorks\MATLAB' | ForEach-Object {
        $mVer = $_.PSChildName
        $mRoot = [string]$_.GetValue('MATLABROOT')
        if (-not $mRoot -or -not (Test-Path -LiteralPath $mRoot)) { return }
        $relName = Split-Path $mRoot -Leaf
        $parent = "MATLAB $relName"
        $tbSeen = @{}

        # 1) appdata\products\*.xml (tum kurulu urunler ve toolbox'lar)
        $prodDir = Join-Path $mRoot 'appdata\products'
        if (Test-Path -LiteralPath $prodDir) {
            Get-ChildItem -LiteralPath $prodDir -Filter '*.xml' | ForEach-Object {
                if ($_.BaseName -match '^(.+?)\s+(\d+\.\d+(?:\.\d+)?)\s+(?:common|win64|win32)$') {
                    $pName = $Matches[1].Trim()
                    $pVer  = "$($Matches[2]) ($relName)"
                    if (-not $tbSeen.ContainsKey($pName.ToLowerInvariant())) {
                        $tbSeen[$pName.ToLowerInvariant()] = $true
                        Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram $parent -Ad $pName -Surum $pVer -Yayinci 'MathWorks' -Konum $mRoot -Not 'MATLAB Product / Toolbox'
                    }
                }
            }
        }

        # 2) Yedek: toolbox\*\Contents.m (eski MATLAB surumleri icin)
        $tbDir = Join-Path $mRoot 'toolbox'
        if (Test-Path -LiteralPath $tbDir) {
            Get-ChildItem -LiteralPath $tbDir -Directory | ForEach-Object {
                $cm = Join-Path $_.FullName 'Contents.m'
                if (-not (Test-Path -LiteralPath $cm)) { return }
                $lines = Get-Content -LiteralPath $cm -TotalCount 3
                if (-not $lines -or $lines.Count -lt 2) { return }
                $l1 = ($lines[0] -replace '^%\s*', '').Trim()
                $l2 = ($lines[1] -replace '^%\s*', '').Trim()
                if ($l2 -match 'Version\s+([0-9]+\.[0-9]+(?:\s*\([^\)]+\))?)') {
                    $tbVer = $Matches[1]
                    if ($l1 -and $l1 -notmatch 'General preferences' -and -not $tbSeen.ContainsKey($l1.ToLowerInvariant())) {
                        $tbSeen[$l1.ToLowerInvariant()] = $true
                        Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram $parent -Ad $l1 -Surum $tbVer -Yayinci 'MathWorks' -Konum $_.FullName -Not "Toolbox ($($_.Name))"
                    }
                }
            }
        }
    }
}

# --- 3F) RHINO / GRASSHOPPER / SKETCHUP / BLENDER ---
foreach ($prof in $profileList) {
    $uTag = if ($profileList.Count -gt 1) { " [$($prof.Name)]" } else { '' }
    # Grasshopper .gha
    $ghDir = Join-Path $prof.Path 'AppData\Roaming\Grasshopper\Libraries'
    if (Test-Path -LiteralPath $ghDir) {
        Get-ChildItem -LiteralPath $ghDir -Filter '*.gha' -Recurse | ForEach-Object {
            $fv = Get-FileVer $_.FullName
            Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram "Rhino / Grasshopper$uTag" -Ad $_.BaseName -Surum $(if ($fv -and $fv.Version) {$fv.Version} else {'-'}) -Yayinci $(if ($fv -and $fv.Publisher) {$fv.Publisher} else {'-'}) -Konum $_.FullName -Not 'Grasshopper .gha'
        }
    }
    # Rhino Yak packages
    $yakDir = Join-Path $prof.Path 'AppData\Roaming\McNeel\Rhinoceros\packages'
    if (Test-Path -LiteralPath $yakDir) {
        Get-ChildItem -LiteralPath $yakDir -Directory | ForEach-Object {
            $rhVer = $_.Name
            Get-ChildItem -LiteralPath $_.FullName -Directory | ForEach-Object {
                $pkgName = $_.Name
                Get-ChildItem -LiteralPath $_.FullName -Directory | ForEach-Object {
                    Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram "Rhino $rhVer$uTag" -Ad $pkgName -Surum $_.Name -Konum $_.FullName -Not 'Rhino Package'
                }
            }
        }
    }
    # SketchUp plugins
    $suRoot = Join-Path $prof.Path 'AppData\Roaming\SketchUp'
    if (Test-Path -LiteralPath $suRoot) {
        Get-ChildItem -LiteralPath $suRoot -Directory -Filter 'SketchUp*' | ForEach-Object {
            $suVer = $_.Name
            $pDir = Join-Path $_.FullName 'SketchUp\Plugins'
            if (Test-Path -LiteralPath $pDir) {
                Get-ChildItem -LiteralPath $pDir -Filter '*.rb' | ForEach-Object {
                    Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram "$suVer$uTag" -Ad $_.BaseName -Konum $_.FullName -Not 'SketchUp Plugin (.rb)'
                }
            }
        }
    }
    # Blender addons
    $blRoot = Join-Path $prof.Path 'AppData\Roaming\Blender Foundation\Blender'
    if (Test-Path -LiteralPath $blRoot) {
        Get-ChildItem -LiteralPath $blRoot -Directory | ForEach-Object {
            $blVer = $_.Name
            $aDir = Join-Path $_.FullName 'scripts\addons'
            if (Test-Path -LiteralPath $aDir) {
                Get-ChildItem -LiteralPath $aDir | Where-Object { $_.Name -ne '__pycache__' } | ForEach-Object {
                    $pyFile = if ($_.PSIsContainer) { Join-Path $_.FullName '__init__.py' } elseif ($_.Extension -eq '.py') { $_.FullName } else { $null }
                    $aName = $_.BaseName; $aVer = '-'
                    if ($pyFile -and (Test-Path -LiteralPath $pyFile)) {
                        $txt = (Get-Content -LiteralPath $pyFile -TotalCount 40) -join "`n"
                        if ($txt -match '"name"\s*:\s*"([^"]+)"') { $aName = $Matches[1] }
                        if ($txt -match '"version"\s*:\s*\(([^)]+)\)') { $aVer = ($Matches[1] -replace '\s*', '') -replace ',', '.' }
                    }
                    Add-Item -Kategori 'CAD / CAM / Muhendislik Eklentileri' -UstProgram "Blender $blVer$uTag" -Ad $aName -Surum $aVer -Konum $_.FullName -Not 'Blender Addon'
                }
            }
        }
    }
}

# =====================================================================
# [4/10] VISUAL STUDIO (Sürümler, İş Yükleri ve VSIX Eklentileri)
# =====================================================================
Write-Host '[4/10] Visual Studio surumleri, is yukleri ve VSIX eklentileri taraniyor...' -ForegroundColor White

function Parse-VsixManifest {
    param([string]$ManifestPath)
    try {
        [xml]$xml = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
        $nsm = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $rootNs = $xml.DocumentElement.NamespaceURI
        if ($rootNs) { $nsm.AddNamespace('v', $rootNs) }
        $idNode = if ($rootNs) { $xml.SelectSingleNode('//v:Metadata/v:Identity', $nsm) } else { $xml.SelectSingleNode('//Metadata/Identity') }
        $dnNode = if ($rootNs) { $xml.SelectSingleNode('//v:Metadata/v:DisplayName', $nsm) } else { $xml.SelectSingleNode('//Metadata/DisplayName') }
        if (-not $idNode) {
            # VSIX v1 format (VS 2010/2012/2015)
            $idNode = if ($rootNs) { $xml.SelectSingleNode('//v:Identifier', $nsm) } else { $xml.SelectSingleNode('//Identifier') }
            if ($idNode) {
                $nameNode = if ($rootNs) { $idNode.SelectSingleNode('v:Name', $nsm) } else { $idNode.SelectSingleNode('Name') }
                $verNode  = if ($rootNs) { $idNode.SelectSingleNode('v:Version', $nsm) } else { $idNode.SelectSingleNode('Version') }
                $authNode = if ($rootNs) { $idNode.SelectSingleNode('v:Author', $nsm) } else { $idNode.SelectSingleNode('Author') }
                return @{
                    Id = $idNode.GetAttribute('Id')
                    Name = if ($nameNode) { $nameNode.InnerText } else { $idNode.GetAttribute('Id') }
                    Version = if ($verNode) { $verNode.InnerText } else { '-' }
                    Publisher = if ($authNode) { $authNode.InnerText } else { '-' }
                }
            }
            return $null
        }
        return @{
            Id        = $idNode.GetAttribute('Id')
            Name      = if ($dnNode -and $dnNode.InnerText) { $dnNode.InnerText } else { $idNode.GetAttribute('Id') }
            Version   = $idNode.GetAttribute('Version')
            Publisher = $idNode.GetAttribute('Publisher')
        }
    } catch { return $null }
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstances = @()
if (Test-Path -LiteralPath $vswhere) {
    $vsJson = Invoke-FastCmd -FileName $vswhere -Arguments '-all -products * -utf8 -format json' -TimeoutMs 5000
    if ($vsJson) {
        try { $vsInstances = As-Array ($vsJson | ConvertFrom-Json) } catch {}
    }
}

$vsInstanceMap = @{}
foreach ($vs in $vsInstances) {
    $vsName = if ($vs.displayName) { $vs.displayName } else { $vs.productId }
    $vsVer  = if ($vs.catalog -and $vs.catalog.productDisplayVersion) { "$($vs.catalog.productDisplayVersion) ($($vs.installationVersion))" } else { $vs.installationVersion }
    $instId = $vs.instanceId
    $vsInstanceMap[$instId] = $vsName

    Add-Item -Kategori 'Visual Studio' -UstProgram $vsName -Ad "$vsName (Ana Kurulum)" -Surum $vsVer -Yayinci 'Microsoft' -Konum $vs.installationPath -Not "Instance: $instId"

    # Workloads ve secili onemli eklenti bilesenleri (state.json)
    $stateFile = "C:\ProgramData\Microsoft\VisualStudio\Packages\_Instances\$instId\state.json"
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $st = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($pkg in $st.selectedPackages) {
                if ($pkg.type -eq 'Workload') {
                    Add-Item -Kategori 'Visual Studio' -UstProgram $vsName -Ad $pkg.id -Surum $pkg.version -Yayinci 'Microsoft' -Not 'Is Yuku (Workload)'
                } elseif ($pkg.id -match '(Copilot|LiveShare|IntelliCode|ModelBuilder|DockerTools|AzureFunctions|EntityFramework|RazorExtension|SSDT|Blend|GitHub|Python|Nodejs|Arduino|Qt|Unity|Xamarin|MAUI)') {
                    Add-Item -Kategori 'Visual Studio' -UstProgram $vsName -Ad $pkg.id -Surum $pkg.version -Yayinci 'Microsoft' -Not 'Bilesen / Eklenti'
                }
            }
        } catch {}
    }

    # Makine genelindeki 3. parti VSIX eklentileri (yerlesik Microsoft cekirdek bilesenlerini filtrele)
    if ($vs.installationPath) {
        $sysExtDir = Join-Path $vs.installationPath 'Common7\IDE\Extensions'
        if (Test-Path -LiteralPath $sysExtDir) {
            Get-ChildItem -LiteralPath $sysExtDir -Filter 'extension.vsixmanifest' -Recurse -Depth 3 | ForEach-Object {
                $vx = Parse-VsixManifest $_.FullName
                if ($vx -and $vx.Publisher -and ($vx.Publisher -notmatch '^Microsoft')) {
                    Add-Item -Kategori 'Visual Studio' -UstProgram $vsName -Ad $vx.Name -Surum $vx.Version -Yayinci $vx.Publisher -Konum $_.DirectoryName -Not "VSIX (Sistem) | $($vx.Id)"
                }
            }
        }
    }
}

# Kullanici bazli VSIX eklentileri
foreach ($prof in $profileList) {
    $uTag = if ($profileList.Count -gt 1) { " [$($prof.Name)]" } else { '' }
    $vsLocal = Join-Path $prof.Path 'AppData\Local\Microsoft\VisualStudio'
    if (-not (Test-Path -LiteralPath $vsLocal)) { continue }
    Get-ChildItem -LiteralPath $vsLocal -Directory | ForEach-Object {
        $dirName = $_.Name
        $extRoot = Join-Path $_.FullName 'Extensions'
        if (-not (Test-Path -LiteralPath $extRoot)) { return }
        $parentVs = "Visual Studio ($dirName)$uTag"
        if ($dirName -match '_([0-9a-fA-F]{8})$' -and $vsInstanceMap.ContainsKey($Matches[1])) {
            $parentVs = "$($vsInstanceMap[$Matches[1]])$uTag"
        }
        Get-ChildItem -LiteralPath $extRoot -Filter 'extension.vsixmanifest' -Recurse -Depth 2 | ForEach-Object {
            $vx = Parse-VsixManifest $_.FullName
            if ($vx) {
                Add-Item -Kategori 'Visual Studio' -UstProgram $parentVs -Ad $vx.Name -Surum $vx.Version -Yayinci $vx.Publisher -Konum $_.DirectoryName -Not "VSIX (Kullanici) | $($vx.Id)"
            }
        }
    }
}

# =====================================================================
# [5/10] VS CODE VE TABANLI EDITORLER (VS Code, Cursor, Windsurf, vb.)
# =====================================================================
Write-Host '[5/10] VS Code ve diger editor eklentileri taraniyor...' -ForegroundColor White

$vscodeEditors = @(
    @{ Name = 'VS Code';          ExtRel = '.vscode\extensions';          PkgPaths = @('{LOCAL}\Programs\Microsoft VS Code\resources\app\package.json', 'C:\Program Files\Microsoft VS Code\resources\app\package.json'); ExePaths = @('{LOCAL}\Programs\Microsoft VS Code\Code.exe', 'C:\Program Files\Microsoft VS Code\Code.exe') },
    @{ Name = 'VS Code Insiders'; ExtRel = '.vscode-insiders\extensions'; PkgPaths = @('{LOCAL}\Programs\Microsoft VS Code Insiders\resources\app\package.json', 'C:\Program Files\Microsoft VS Code Insiders\resources\app\package.json'); ExePaths = @('{LOCAL}\Programs\Microsoft VS Code Insiders\Code - Insiders.exe', 'C:\Program Files\Microsoft VS Code Insiders\Code - Insiders.exe') },
    @{ Name = 'Cursor';           ExtRel = '.cursor\extensions';          PkgPaths = @('{LOCAL}\Programs\cursor\resources\app\package.json', 'C:\Program Files\cursor\resources\app\package.json'); ExePaths = @('{LOCAL}\Programs\cursor\Cursor.exe', 'C:\Program Files\cursor\Cursor.exe') },
    @{ Name = 'Windsurf';         ExtRel = '.windsurf\extensions';        PkgPaths = @('{LOCAL}\Programs\Windsurf\resources\app\package.json', 'C:\Program Files\Windsurf\resources\app\package.json'); ExePaths = @('{LOCAL}\Programs\Windsurf\Windsurf.exe', 'C:\Program Files\Windsurf\Windsurf.exe') },
    @{ Name = 'Antigravity';      ExtRel = '.antigravity\extensions';     PkgPaths = @('{LOCAL}\Programs\Antigravity\resources\app\package.json', 'C:\Program Files\Antigravity\resources\app\package.json'); ExePaths = @('{LOCAL}\Programs\Antigravity\Antigravity.exe', 'C:\Program Files\Antigravity\Antigravity.exe') },
    @{ Name = 'VSCodium';         ExtRel = '.vscode-oss\extensions';      PkgPaths = @('{LOCAL}\Programs\VSCodium\resources\app\package.json', 'C:\Program Files\VSCodium\resources\app\package.json'); ExePaths = @('{LOCAL}\Programs\VSCodium\VSCodium.exe', 'C:\Program Files\VSCodium\VSCodium.exe') }
)

function Resolve-VscNls {
    param([string]$Val, [string]$ExtDir)
    if (-not $Val) { return $Val }
    if ($Val -match '^%(.+)%$') {
        $k = $Matches[1]
        $nls = Join-Path $ExtDir 'package.nls.json'
        if (Test-Path -LiteralPath $nls) {
            try {
                $nj = Get-Content -LiteralPath $nls -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($nj.PSObject.Properties[$k]) { return [string]$nj.$k }
            } catch {}
        }
    }
    return $Val
}

foreach ($prof in $profileList) {
    $uTag = if ($profileList.Count -gt 1) { " [$($prof.Name)]" } else { '' }
    $localApp = Join-Path $prof.Path 'AppData\Local'
    foreach ($ed in $vscodeEditors) {
        $edVer = $null
        foreach ($pp in $ed.PkgPaths) {
            $realP = $pp -replace '\{LOCAL\}', $localApp
            if (Test-Path -LiteralPath $realP) {
                try {
                    $rawPkg = Get-Content -LiteralPath $realP -TotalCount 30 -Encoding UTF8
                    $joined = $rawPkg -join "`n"
                    if ($joined -match '"version"\s*:\s*"([^"]+)"') { $edVer = $Matches[1]; break }
                } catch {}
            }
        }
        if (-not $edVer -and $ed.ExePaths) {
            foreach ($epx in $ed.ExePaths) {
                $fv = Get-FileVer ($epx -replace '\{LOCAL\}', $localApp)
                if ($fv -and $fv.Version) { $edVer = $fv.Version; break }
            }
        }
        $extDir = Join-Path $prof.Path $ed.ExtRel
        if (-not (Test-Path -LiteralPath $extDir)) { continue }

        $parentLabel = if ($edVer) { "$($ed.Name) $edVer$uTag" } else { "$($ed.Name)$uTag" }
        $activePaths = New-Object 'System.Collections.Generic.List[string]'
        $extJsonFile = Join-Path $extDir 'extensions.json'
        if (Test-Path -LiteralPath $extJsonFile) {
            try {
                $ej = As-Array (Get-Content -LiteralPath $extJsonFile -Raw -Encoding UTF8 | ConvertFrom-Json)
                foreach ($entry in $ej) {
                    $locPath = $null
                    if ($entry.location -and $entry.location.fsPath) { $locPath = [string]$entry.location.fsPath }
                    elseif ($entry.relativeLocation) { $locPath = Join-Path $extDir $entry.relativeLocation }
                    if ($locPath -and (Test-Path -LiteralPath $locPath)) { $activePaths.Add($locPath) }
                }
            } catch {}
        }
        if ($activePaths.Count -eq 0) {
            Get-ChildItem -LiteralPath $extDir -Directory | Where-Object { $_.Name -notlike '.*' } | ForEach-Object {
                $activePaths.Add($_.FullName)
            }
        }

        $seenExt = @{}
        foreach ($ep in $activePaths) {
            $pkgFile = Join-Path $ep 'package.json'
            if (-not (Test-Path -LiteralPath $pkgFile)) { continue }
            try {
                $p = Get-Content -LiteralPath $pkgFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $pub = [string]$p.publisher
                $nm  = [string]$p.name
                $id  = if ($pub -and $nm) { "$pub.$nm" } else { Split-Path $ep -Leaf }
                $ver = if ($p.version) { [string]$p.version } else { '-' }
                $dn  = Resolve-VscNls ([string]$p.displayName) $ep
                if (-not $dn) { $dn = $id }
                $sk = "$id|$ver"
                if ($seenExt.ContainsKey($sk)) { continue }
                $seenExt[$sk] = $true
                Add-Item -Kategori 'VS Code ve Editor Eklentileri' -UstProgram $parentLabel -Ad $dn -Surum $ver -Yayinci $(if ($pub) {$pub} else {'-'}) -Konum $ep -Not "ID: $id"
            } catch {}
        }
    }
}

# =====================================================================
# [6/10] JETBRAINS, ANDROID STUDIO VE ARDUINO IDE EKLENTILERI
# =====================================================================
Write-Host '[6/10] JetBrains, Android Studio ve Arduino eklentileri taraniyor...' -ForegroundColor White

function Read-JetBrainsPlugin {
    param([IO.FileSystemInfo]$Item)
    $pName = $Item.BaseName; $pVer = '-'; $pVendor = '-'
    try {
        if ($Item.PSIsContainer) {
            $xmlF = Join-Path $Item.FullName 'META-INF\plugin.xml'
            if (Test-Path -LiteralPath $xmlF) {
                [xml]$x = Get-Content -LiteralPath $xmlF -Raw -Encoding UTF8
                if ($x.'idea-plugin'.name) { $pName = [string]$x.'idea-plugin'.name }
                if ($x.'idea-plugin'.version) { $pVer = [string]$x.'idea-plugin'.version }
                if ($x.'idea-plugin'.vendor) { $pVendor = if ($x.'idea-plugin'.vendor -is [string]) { $x.'idea-plugin'.vendor } else { [string]$x.'idea-plugin'.vendor.'#text' } }
                return @{ Name = $pName; Version = $pVer; Vendor = $pVendor }
            }
            $libDir = Join-Path $Item.FullName 'lib'
            if (Test-Path -LiteralPath $libDir) {
                foreach ($jar in (Get-ChildItem -LiteralPath $libDir -Filter '*.jar' | Select-Object -First 8)) {
                    try {
                        $zip = [System.IO.Compression.ZipFile]::OpenRead($jar.FullName)
                        $ent = $zip.GetEntry('META-INF/plugin.xml')
                        if ($ent) {
                            $sr = New-Object System.IO.StreamReader($ent.Open(), [System.Text.Encoding]::UTF8)
                            $content = $sr.ReadToEnd(); $sr.Close()
                            $zip.Dispose()
                            [xml]$x = $content
                            if ($x.'idea-plugin'.name) { $pName = [string]$x.'idea-plugin'.name }
                            if ($x.'idea-plugin'.version) { $pVer = [string]$x.'idea-plugin'.version }
                            if ($x.'idea-plugin'.vendor) { $pVendor = if ($x.'idea-plugin'.vendor -is [string]) { $x.'idea-plugin'.vendor } else { [string]$x.'idea-plugin'.vendor.'#text' } }
                            return @{ Name = $pName; Version = $pVer; Vendor = $pVendor }
                        }
                        $zip.Dispose()
                    } catch {}
                }
            }
        } elseif ($Item.Extension -eq '.jar') {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($Item.FullName)
            $ent = $zip.GetEntry('META-INF/plugin.xml')
            if ($ent) {
                $sr = New-Object System.IO.StreamReader($ent.Open(), [System.Text.Encoding]::UTF8)
                $content = $sr.ReadToEnd(); $sr.Close()
                [xml]$x = $content
                if ($x.'idea-plugin'.name) { $pName = [string]$x.'idea-plugin'.name }
                if ($x.'idea-plugin'.version) { $pVer = [string]$x.'idea-plugin'.version }
                if ($x.'idea-plugin'.vendor) { $pVendor = if ($x.'idea-plugin'.vendor -is [string]) { $x.'idea-plugin'.vendor } else { [string]$x.'idea-plugin'.vendor.'#text' } }
            }
            $zip.Dispose()
        }
    } catch {}
    return @{ Name = $pName; Version = $pVer; Vendor = $pVendor }
}

foreach ($prof in $profileList) {
    $uTag = if ($profileList.Count -gt 1) { " [$($prof.Name)]" } else { '' }
    foreach ($jbRoot in @(
        (Join-Path $prof.Path 'AppData\Roaming\JetBrains'),
        (Join-Path $prof.Path 'AppData\Roaming\Google')
    )) {
        if (-not (Test-Path -LiteralPath $jbRoot)) { continue }
        Get-ChildItem -LiteralPath $jbRoot -Directory | ForEach-Object {
            $ideName = $_.Name
            $pDir = Join-Path $_.FullName 'plugins'
            if (-not (Test-Path -LiteralPath $pDir)) { return }
            Get-ChildItem -LiteralPath $pDir | Where-Object { $_.PSIsContainer -or $_.Extension -eq '.jar' } | ForEach-Object {
                $info = Read-JetBrainsPlugin $_
                Add-Item -Kategori 'JetBrains ve Diger IDE Eklentileri' -UstProgram "$ideName$uTag" -Ad $info.Name -Surum $info.Version -Yayinci $info.Vendor -Konum $_.FullName -Not 'IDE Plugin'
            }
        }
    }

    # Arduino IDE kart paketleri (cores)
    $ardPkg = Join-Path $prof.Path 'AppData\Local\Arduino15\packages'
    if (Test-Path -LiteralPath $ardPkg) {
        Get-ChildItem -LiteralPath $ardPkg -Directory | ForEach-Object {
            $vendor = $_.Name
            $hwDir = Join-Path $_.FullName 'hardware'
            if (Test-Path -LiteralPath $hwDir) {
                Get-ChildItem -LiteralPath $hwDir -Directory | ForEach-Object {
                    $arch = $_.Name
                    Get-ChildItem -LiteralPath $_.FullName -Directory | ForEach-Object {
                        Add-Item -Kategori 'JetBrains ve Diger IDE Eklentileri' -UstProgram "Arduino IDE$uTag" -Ad "$vendor ($arch)" -Surum $_.Name -Yayinci $vendor -Konum $_.FullName -Not 'Board Core'
                    }
                }
            }
        }
    }
    # Arduino IDE kutuphaneleri
    $ardLib = Join-Path $prof.Path 'Documents\Arduino\libraries'
    if (Test-Path -LiteralPath $ardLib) {
        Get-ChildItem -LiteralPath $ardLib -Directory | ForEach-Object {
            $lp = Join-Path $_.FullName 'library.properties'
            $lName = $_.Name; $lVer = '-'; $lAuth = '-'
            if (Test-Path -LiteralPath $lp) {
                Get-Content -LiteralPath $lp | ForEach-Object {
                    if ($_ -match '^name=(.+)$') { $lName = $Matches[1].Trim() }
                    elseif ($_ -match '^version=(.+)$') { $lVer = $Matches[1].Trim() }
                    elseif ($_ -match '^author=(.+)$') { $lAuth = $Matches[1].Trim() }
                }
            }
            Add-Item -Kategori 'JetBrains ve Diger IDE Eklentileri' -UstProgram "Arduino IDE$uTag" -Ad $lName -Surum $lVer -Yayinci $lAuth -Konum $_.FullName -Not 'Arduino Kutuphane'
        }
    }
}

# =====================================================================
# [7/10] MICROSOFT OFFICE EKLENTILERI (COM / VSTO Add-ins)
# =====================================================================
Write-Host '[7/10] Microsoft Office eklentileri taraniyor...' -ForegroundColor White

$officeSeen = @{}
$officeRoots = @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Office';             Scope = 'Sistem 64-bit' },
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office'; Scope = 'Sistem 32-bit' },
    @{ Path = 'HKCU:\Software\Microsoft\Office';             Scope = "Kullanici ($curUser)" }
)
$officeApps = @('Excel', 'Word', 'PowerPoint', 'Outlook', 'Visio', 'MS Project', 'Access', 'Publisher', 'OneNote')

foreach ($or in $officeRoots) {
    if (-not (Test-Path -LiteralPath $or.Path)) { continue }
    foreach ($app in $officeApps) {
        foreach ($sub in @('Addins', 'AddIns')) {
            $ap = Join-Path $or.Path "$app\$sub"
            if (-not (Test-Path -LiteralPath $ap)) { continue }
            Get-ChildItem -LiteralPath $ap | ForEach-Object {
                try {
                    $progId = $_.PSChildName
                    $k = "$app|$($progId.ToLowerInvariant())|$($or.Scope)"
                    if ($officeSeen.ContainsKey($k)) { return }
                    $officeSeen[$k] = $true

                    $fn = [string]$_.GetValue('FriendlyName')
                    if (-not $fn) { $fn = $progId }
                    $desc = [string]$_.GetValue('Description')
                    $lb = $_.GetValue('LoadBehavior')
                    $manifest = [string]$_.GetValue('Manifest')

                    $lbText = switch ($lb) {
                        3  { 'Baslangicta Aktif' }
                        2  { 'Pasif' }
                        0  { 'Devre Disi' }
                        8  { 'Istege Bagli' }
                        9  { 'Istege Bagli (Aktif)' }
                        16 { 'Ilk Acilista Yukle' }
                        default { if ($null -ne $lb) { "LoadBehavior=$lb" } else { 'Belirsiz' } }
                    }

                    # ProgID -> CLSID -> DLL Surumu veya VSTO Manifest Surumu
                    $ver = '-'; $loc = if ($manifest) { $manifest } else { '-' }; $pub = '-'
                    if ($manifest) {
                        $vstoPath = ($manifest -split '\|')[0].Trim()
                        if ($vstoPath -match '^file:///(.+)$') { $vstoPath = [System.Uri]::UnescapeDataString($Matches[1]) -replace '/', '\' }
                        if (Test-Path -LiteralPath $vstoPath -PathType Leaf) {
                            $loc = $vstoPath
                            try {
                                $vtxt = Get-Content -LiteralPath $vstoPath -Raw -Encoding UTF8
                                if ($vtxt -match 'assemblyIdentity[^>]*version="([^"]+)"') { $ver = $Matches[1] }
                                if ($vtxt -match 'publisher>([^<]+)</') { $pub = $Matches[1].Trim() }
                            } catch {}
                        }
                    }
                    if ($ver -eq '-') {
                        $clsidKey = "Registry::HKEY_CLASSES_ROOT\$progId\CLSID"
                        if (Test-Path -LiteralPath $clsidKey) {
                            $guid = [string](Get-Item -LiteralPath $clsidKey).GetValue('')
                            if ($guid) {
                                $ci = Resolve-ClsidInfo $guid
                                $ver = $ci.Version
                                if ($loc -eq '-' -and $ci.Path -ne '-') { $loc = $ci.Path }
                                if ($pub -eq '-' -and $ci.Publisher -ne '-') { $pub = $ci.Publisher }
                            }
                        }
                    }

                    $noteParts = @($lbText, $or.Scope)
                    if ($desc -and $desc -ne $fn) { $noteParts += $desc }
                    Add-Item -Kategori 'Microsoft Office Eklentileri' -UstProgram "Microsoft $app" -Ad $fn -Surum $ver -Yayinci $pub -Konum $loc -Not ($noteParts -join ' | ')
                } catch {}
            }
            break
        }
    }
}

# =====================================================================
# [8/10] ADOBE CEP EKLENTILERI
# =====================================================================
Write-Host '[8/10] Adobe eklentileri taraniyor...' -ForegroundColor White

$adobeDirs = New-Object 'System.Collections.Generic.List[string]'
$adobeDirs.Add('C:\Program Files (x86)\Common Files\Adobe\CEP\extensions')
$adobeDirs.Add('C:\Program Files\Common Files\Adobe\CEP\extensions')
foreach ($prof in $profileList) {
    $adobeDirs.Add((Join-Path $prof.Path 'AppData\Roaming\Adobe\CEP\extensions'))
}
foreach ($ad in $adobeDirs) {
    if (-not (Test-Path -LiteralPath $ad)) { continue }
    Get-ChildItem -LiteralPath $ad -Directory | ForEach-Object {
        $mf = Join-Path $_.FullName 'CSXS\manifest.xml'
        $name = $_.Name; $ver = '-'
        if (Test-Path -LiteralPath $mf) {
            try {
                [xml]$x = Get-Content -LiteralPath $mf -Raw -Encoding UTF8
                $em = $x.ExtensionManifest
                if ($em.ExtensionBundleName) { $name = [string]$em.ExtensionBundleName }
                if ($em.ExtensionBundleVersion) { $ver = [string]$em.ExtensionBundleVersion }
            } catch {}
        }
        Add-Item -Kategori 'Adobe Eklentileri' -UstProgram 'Adobe Creative Cloud (CEP)' -Ad $name -Surum $ver -Konum $_.FullName -Not 'CEP Extension'
    }
}

# =====================================================================
# [9/10] TARAYICI EKLENTILERI (Chrome, Edge, Brave, Opera, Vivaldi, Firefox)
# =====================================================================
Write-Host '[9/10] Tarayici eklentileri taraniyor...' -ForegroundColor White

$chromiumBrowsers = @(
    @{ Name = 'Google Chrome';  Rel = 'AppData\Local\Google\Chrome\User Data' },
    @{ Name = 'Microsoft Edge'; Rel = 'AppData\Local\Microsoft\Edge\User Data' },
    @{ Name = 'Brave';          Rel = 'AppData\Local\BraveSoftware\Brave-Browser\User Data' },
    @{ Name = 'Vivaldi';        Rel = 'AppData\Local\Vivaldi\User Data' },
    @{ Name = 'Opera';          Rel = 'AppData\Roaming\Opera Software\Opera Stable' },
    @{ Name = 'Opera GX';       Rel = 'AppData\Roaming\Opera Software\Opera GX Stable' }
)

function Resolve-ChromeMsg {
    param([string]$Val, [string]$VerDir)
    if (-not $Val -or $Val -notmatch '^__MSG_(.+)__$') { return $Val }
    $msgKey = $Matches[1]
    foreach ($loc in @('tr', 'en', 'en_US', 'en_GB')) {
        $f = Join-Path $VerDir "_locales\$loc\messages.json"
        if (Test-Path -LiteralPath $f) {
            try {
                $mj = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($prop in $mj.PSObject.Properties) {
                    if ($prop.Name -ieq $msgKey -and $prop.Value.message) {
                        return [string]$prop.Value.message
                    }
                }
            } catch {}
        }
    }
    return $Val
}

foreach ($prof in $profileList) {
    $uTag = if ($profileList.Count -gt 1) { " [$($prof.Name)]" } else { '' }
    foreach ($br in $chromiumBrowsers) {
        $ud = Join-Path $prof.Path $br.Rel
        if (-not (Test-Path -LiteralPath $ud)) { continue }
        $profDirs = New-Object 'System.Collections.Generic.List[object]'
        if (Test-Path -LiteralPath (Join-Path $ud 'Extensions')) {
            $profDirs.Add(@{ Name = 'Default'; ExtDir = (Join-Path $ud 'Extensions') })
        }
        Get-ChildItem -LiteralPath $ud -Directory | Where-Object {
            $_.Name -eq 'Default' -or $_.Name -match '^Profile \d+$'
        } | ForEach-Object {
            $ed = Join-Path $_.FullName 'Extensions'
            if (Test-Path -LiteralPath $ed) {
                $profDirs.Add(@{ Name = $_.Name; ExtDir = $ed })
            }
        }
        foreach ($pd in $profDirs) {
            $parentBr = "$($br.Name) ($($pd.Name))$uTag"
            Get-ChildItem -LiteralPath $pd.ExtDir -Directory | Where-Object { $_.Name -ne 'Temp' } | ForEach-Object {
                $extId = $_.Name
                $verDir = Get-ChildItem -LiteralPath $_.FullName -Directory | Sort-Object Name -Descending | Select-Object -First 1
                if (-not $verDir) { return }
                $mf = Join-Path $verDir.FullName 'manifest.json'
                if (-not (Test-Path -LiteralPath $mf)) { return }
                try {
                    $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($extId -eq 'nmmhkkegccagdldgiimedpiccmgmieda') { return }
                    $nm = Resolve-ChromeMsg ([string]$m.name) $verDir.FullName
                    if (-not $nm) { $nm = $extId }
                    if ($nm -match 'Edge PDF|Chrome Web Store Payments') { return }
                    $ver = if ($m.version_name) { [string]$m.version_name } elseif ($m.version) { [string]$m.version } else { $verDir.Name }
                    $auth = if ($m.author -is [string]) { $m.author } else { '-' }
                    Add-Item -Kategori 'Tarayici Eklentileri' -UstProgram $parentBr -Ad $nm -Surum $ver -Yayinci $auth -Konum $verDir.FullName -Not "ID: $extId"
                } catch {}
            }
        }
    }

    # Firefox
    $ffRoot = Join-Path $prof.Path 'AppData\Roaming\Mozilla\Firefox\Profiles'
    if (Test-Path -LiteralPath $ffRoot) {
        Get-ChildItem -LiteralPath $ffRoot -Directory | ForEach-Object {
            $ej = Join-Path $_.FullName 'extensions.json'
            if (-not (Test-Path -LiteralPath $ej)) { return }
            try {
                $data = Get-Content -LiteralPath $ej -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($adn in $data.addons) {
                    if ($adn.type -notin @('extension', 'plugin')) { continue }
                    if ($adn.location -eq 'app-builtin') { continue }
                    $nm = if ($adn.defaultLocale -and $adn.defaultLocale.name) { [string]$adn.defaultLocale.name } else { [string]$adn.id }
                    $auth = if ($adn.defaultLocale -and $adn.defaultLocale.creator) { [string]$adn.defaultLocale.creator } else { '-' }
                    $st = if ($adn.active) { 'Aktif' } else { 'Pasif' }
                    Add-Item -Kategori 'Tarayici Eklentileri' -UstProgram "Mozilla Firefox ($($_.Name))$uTag" -Ad $nm -Surum $(if ($adn.version) {[string]$adn.version} else {'-'}) -Yayinci $auth -Not "$st | ID: $($adn.id)"
                }
            } catch {}
        }
    }
}

# =====================================================================
# [10/10] GELISTIRICI ARACLARI, RUNTIME'LAR VE GLOBAL PAKETLER
# =====================================================================
Write-Host '[10/10] Gelistirici araclari, runtime surumleri ve global paketler taraniyor...' -ForegroundColor White

$cliTools = @(
    @{ Name = 'Python';         Cmd = 'python';  Args = '--version'; Pattern = 'Python\s+(.+)' },
    @{ Name = 'Conda';          Cmd = 'conda';   Args = '--version'; Pattern = 'conda\s+(.+)' },
    @{ Name = 'Node.js';        Cmd = 'node';    Args = '-v';        Pattern = 'v?([0-9]+\.[0-9]+\.[0-9]+.*)' },
    @{ Name = 'npm';            Cmd = 'npm.cmd'; Args = '-v';        Pattern = '([0-9]+\.[0-9]+\.[0-9]+.*)' },
    @{ Name = 'Git';            Cmd = 'git';     Args = '--version'; Pattern = 'git version\s+(.+)' },
    @{ Name = 'Java';           Cmd = 'java';    Args = '-version';  Pattern = 'version\s+"([^"]+)"' },
    @{ Name = 'Go';             Cmd = 'go';      Args = 'version';   Pattern = 'go([0-9]+\.[0-9]+[^\s]*)' },
    @{ Name = 'Rust (rustc)';   Cmd = 'rustc';   Args = '--version'; Pattern = 'rustc\s+([^\s]+)' },
    @{ Name = 'Docker';         Cmd = 'docker';  Args = '--version'; Pattern = 'Docker version\s+([^,]+)' },
    @{ Name = 'CMake';          Cmd = 'cmake';   Args = '--version'; Pattern = 'cmake version\s+([^\s]+)' },
    @{ Name = 'GCC';            Cmd = 'gcc';     Args = '--version'; Pattern = '(\d+\.\d+\.\d+)' },
    @{ Name = 'PowerShell';     Cmd = 'pwsh';    Args = '-NoProfile -Command $PSVersionTable.PSVersion.ToString()'; Pattern = '([0-9]+\.[0-9]+[^\s]*)' },
    @{ Name = 'Windows PowerShell'; Cmd = 'powershell'; Args = '-NoProfile -Command $PSVersionTable.PSVersion.ToString()'; Pattern = '([0-9]+\.[0-9]+[^\s]*)' }
)

foreach ($t in $cliTools) {
    $cmdInfo = Get-Command $t.Cmd -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmdInfo) { continue }
    $out = Invoke-FastCmd -FileName $cmdInfo.Source -Arguments $t.Args -TimeoutMs 3500
    if ($out) {
        $ver = if ($out -match $t.Pattern) { $Matches[1].Trim() } else { ($out -split "`n")[0].Trim() }
        Add-Item -Kategori 'Gelistirici Araclari ve Runtime' -UstProgram 'CLI / Runtime' -Ad $t.Name -Surum $ver -Konum $cmdInfo.Source -Not 'PATH'
    }
}

# Python Launcher (py -0p) tum kurulu Python surumleri
$pyCmd = Get-Command 'py' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pyCmd) {
    $pyOut = Invoke-FastCmd -FileName $pyCmd.Source -Arguments '-0p' -TimeoutMs 3500
    if ($pyOut) {
        ($pyOut -split "`r?`n") | ForEach-Object {
            if ($_ -match '^\s*-V?:?([^\s]+)\s+\*?\s*(.+)$') {
                Add-Item -Kategori 'Gelistirici Araclari ve Runtime' -UstProgram 'Python Kurulumlari' -Ad "Python $($Matches[1])" -Surum $Matches[1] -Konum $Matches[2].Trim() -Not 'py launcher'
            }
        }
    }
}

# .NET SDK'lar
$dnCmd = Get-Command 'dotnet' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($dnCmd) {
    $sdkOut = Invoke-FastCmd -FileName $dnCmd.Source -Arguments '--list-sdks' -TimeoutMs 3500
    if ($sdkOut) {
        ($sdkOut -split "`r?`n") | ForEach-Object {
            if ($_ -match '^([0-9][^\s]+)\s+\[(.+)\]$') {
                Add-Item -Kategori 'Gelistirici Araclari ve Runtime' -UstProgram '.NET SDK' -Ad ".NET SDK $($Matches[1])" -Surum $Matches[1] -Yayinci 'Microsoft' -Konum $Matches[2] -Not 'dotnet --list-sdks'
            }
        }
    }
}

# Flutter (ag kontrolu yapmadan version dosyasindan hizli okuma)
$flCmd = Get-Command 'flutter' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($flCmd) {
    $flRoot = Split-Path (Split-Path $flCmd.Source -Parent) -Parent
    $flVerFile = Join-Path $flRoot 'version'
    $flVer = if (Test-Path -LiteralPath $flVerFile) { (Get-Content -LiteralPath $flVerFile -TotalCount 1).Trim() } else { '-' }
    Add-Item -Kategori 'Gelistirici Araclari ve Runtime' -UstProgram 'CLI / Runtime' -Ad 'Flutter SDK' -Surum $flVer -Yayinci 'Google' -Konum $flRoot -Not 'SDK'
}

# Global npm paketleri
foreach ($prof in $profileList) {
    $npmGlobal = Join-Path $prof.Path 'AppData\Roaming\npm\node_modules'
    if (Test-Path -LiteralPath $npmGlobal) {
        Get-ChildItem -LiteralPath $npmGlobal -Directory | ForEach-Object {
            if ($_.Name.StartsWith('@')) {
                $scopeName = $_.Name
                Get-ChildItem -LiteralPath $_.FullName -Directory | ForEach-Object {
                    $pj = Join-Path $_.FullName 'package.json'
                    if (Test-Path -LiteralPath $pj) {
                        try {
                            $j = Get-Content -LiteralPath $pj -Raw -Encoding UTF8 | ConvertFrom-Json
                            Add-Item -Kategori 'Global Paketler ve Moduller' -UstProgram 'npm (Global)' -Ad "$scopeName/$($_.Name)" -Surum $(if ($j.version) {[string]$j.version} else {'-'}) -Konum $_.FullName -Not 'npm global'
                        } catch {}
                    }
                }
            } else {
                $pj = Join-Path $_.FullName 'package.json'
                if (Test-Path -LiteralPath $pj) {
                    try {
                        $j = Get-Content -LiteralPath $pj -Raw -Encoding UTF8 | ConvertFrom-Json
                        Add-Item -Kategori 'Global Paketler ve Moduller' -UstProgram 'npm (Global)' -Ad $_.Name -Surum $(if ($j.version) {[string]$j.version} else {'-'}) -Konum $_.FullName -Not 'npm global'
                    } catch {}
                }
            }
        }
    }
    # .NET Global Tools
    $dnTools = Join-Path $prof.Path '.dotnet\tools\.store'
    if (Test-Path -LiteralPath $dnTools) {
        Get-ChildItem -LiteralPath $dnTools -Directory | ForEach-Object {
            $tName = $_.Name
            Get-ChildItem -LiteralPath $_.FullName -Directory | ForEach-Object {
                Add-Item -Kategori 'Global Paketler ve Moduller' -UstProgram '.NET Global Tools' -Ad $tName -Surum $_.Name -Konum $_.FullName -Not 'dotnet tool'
            }
        }
    }
    # Kullanici PowerShell modulleri
    foreach ($psModDir in @(
        (Join-Path $prof.Path 'Documents\WindowsPowerShell\Modules'),
        (Join-Path $prof.Path 'Documents\PowerShell\Modules')
    )) {
        if (-not (Test-Path -LiteralPath $psModDir)) { continue }
        Get-ChildItem -LiteralPath $psModDir -Directory | ForEach-Object {
            $mName = $_.Name
            $vDirs = Get-ChildItem -LiteralPath $_.FullName -Directory | Where-Object { $_.Name -match '^\d+\.\d+' }
            if ($vDirs) {
                foreach ($vd in $vDirs) {
                    Add-Item -Kategori 'Global Paketler ve Moduller' -UstProgram 'PowerShell Modulleri' -Ad $mName -Surum $vd.Name -Konum $vd.FullName -Not 'PS Module'
                }
            } else {
                Add-Item -Kategori 'Global Paketler ve Moduller' -UstProgram 'PowerShell Modulleri' -Ad $mName -Surum '-' -Konum $_.FullName -Not 'PS Module'
            }
        }
    }
}

# =====================================================================
# RAPOR DOSYALARINI OLUSTUR (HTML + TXT + CSV)
# =====================================================================
$desk = [Environment]::GetFolderPath('Desktop')
if (-not $desk -or -not (Test-Path -LiteralPath $desk)) { $desk = $env:TEMP }
$outDir = Join-Path $desk "Program_Envanteri_${pcName}_${stamp}"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$htmlPath = Join-Path $outDir "Envanter_${pcName}.html"
$txtPath  = Join-Path $outDir "Envanter_${pcName}.txt"
$csvPath  = Join-Path $outDir "Envanter_${pcName}.csv"

$catOrder = @(
    'Kurulu Programlar',
    'CAD / CAM / Muhendislik Eklentileri',
    'Visual Studio',
    'VS Code ve Editor Eklentileri',
    'JetBrains ve Diger IDE Eklentileri',
    'Microsoft Office Eklentileri',
    'Adobe Eklentileri',
    'Tarayici Eklentileri',
    'Gelistirici Araclari ve Runtime',
    'Global Paketler ve Moduller',
    'Microsoft Store Uygulamalari'
)

$orderedItems = New-Object 'System.Collections.Generic.List[object]'
foreach ($cat in $catOrder) {
    $items | Where-Object { $_.Kategori -eq $cat } | Sort-Object UstProgram, Ad, Surum | ForEach-Object {
        $orderedItems.Add($_)
    }
}
$items | Where-Object { $_.Kategori -notin $catOrder } | Sort-Object Kategori, UstProgram, Ad | ForEach-Object {
    $orderedItems.Add($_)
}

$utf8Bom = New-Object System.Text.UTF8Encoding($true)

# --- 1) CSV (Turkce Excel uyumlu: UTF-8 BOM + ';') ---
$csvSb = New-Object System.Text.StringBuilder
[void]$csvSb.AppendLine('Kategori;UstProgram;Ad;Surum;Yayinci;KurulumTarihi;Konum;Not')
foreach ($it in $orderedItems) {
    [void]$csvSb.AppendLine((@($it.Kategori, $it.UstProgram, $it.Ad, $it.Surum, $it.Yayinci, $it.KurulumTarihi, $it.Konum, $it.Not) | ForEach-Object { CsvEsc $_ }) -join ';')
}
[System.IO.File]::WriteAllText($csvPath, $csvSb.ToString(), $utf8Bom)

# --- 2) TXT (Okunakli duz metin liste) ---
$txtSb = New-Object System.Text.StringBuilder
[void]$txtSb.AppendLine('================================================================================')
[void]$txtSb.AppendLine("  PROGRAM VE EKLENTI ENVANTERI - $pcName")
[void]$txtSb.AppendLine('================================================================================')
[void]$txtSb.AppendLine("Tarih      : $nowStr")
[void]$txtSb.AppendLine("Kullanici  : $curUser (Yonetici: $(if ($isAdmin) {'Evet'} else {'Hayir'}))")
[void]$txtSb.AppendLine("Isletim S. : $winFull")
[void]$txtSb.AppendLine("Donanim    : $cpu | $ramGb GB RAM")
[void]$txtSb.AppendLine("Toplam     : $($orderedItems.Count) kayit")
[void]$txtSb.AppendLine('')

$catCounts = [ordered]@{}
foreach ($cat in $catOrder) {
    $sub = @($orderedItems | Where-Object { $_.Kategori -eq $cat })
    if ($sub.Count -eq 0) { continue }
    $catCounts[$cat] = $sub.Count
    [void]$txtSb.AppendLine('--------------------------------------------------------------------------------')
    [void]$txtSb.AppendLine("  $($cat.ToUpperInvariant()) ($($sub.Count))")
    [void]$txtSb.AppendLine('--------------------------------------------------------------------------------')
    $hasParents = ($sub | Where-Object { $_.UstProgram -ne '-' } | Select-Object -First 1) -ne $null
    if ($hasParents) {
        $groups = $sub | Group-Object UstProgram | Sort-Object Name
        foreach ($g in $groups) {
            [void]$txtSb.AppendLine("")
            [void]$txtSb.AppendLine("  [$($g.Name)] ($($g.Count))")
            foreach ($r in $g.Group) {
                $line = "    - $($r.Ad)  |  Surum: $($r.Surum)"
                if ($r.Yayinci -ne '-') { $line += "  |  $($r.Yayinci)" }
                if ($r.Not -ne '-') { $line += "  |  $($r.Not)" }
                [void]$txtSb.AppendLine($line)
            }
        }
    } else {
        foreach ($r in $sub) {
            $line = "  - $($r.Ad)  |  Surum: $($r.Surum)"
            if ($r.Yayinci -ne '-') { $line += "  |  $($r.Yayinci)" }
            if ($r.KurulumTarihi -ne '-') { $line += "  |  Tarih: $($r.KurulumTarihi)" }
            if ($r.Not -ne '-') { $line += "  |  $($r.Not)" }
            [void]$txtSb.AppendLine($line)
        }
    }
    [void]$txtSb.AppendLine('')
}
[System.IO.File]::WriteAllText($txtPath, $txtSb.ToString(), $utf8Bom)

# --- 3) HTML (Cevrimdisi aranabilir, filtrelenebilir interaktif rapor) ---
$pillsSb = New-Object System.Text.StringBuilder
[void]$pillsSb.Append("<button class='pill active' data-cat='ALL'>Tumu <span>$($orderedItems.Count)</span></button>")
foreach ($ck in $catCounts.Keys) {
    $encCat = HtmlEnc $ck
    [void]$pillsSb.Append("<button class='pill' data-cat='$encCat'>$encCat <span>$($catCounts[$ck])</span></button>")
}

$rowsSb = New-Object System.Text.StringBuilder
foreach ($it in $orderedItems) {
    $cEnc = HtmlEnc $it.Kategori
    $uEnc = HtmlEnc $it.UstProgram
    $aEnc = HtmlEnc $it.Ad
    $sEnc = HtmlEnc $it.Surum
    $yEnc = HtmlEnc $it.Yayinci
    $tEnc = HtmlEnc $it.KurulumTarihi
    $kEnc = HtmlEnc $it.Konum
    $nEnc = HtmlEnc $it.Not
    [void]$rowsSb.AppendLine("<tr data-cat='$cEnc'><td class='cat'>$cEnc</td><td class='parent'>$uEnc</td><td class='name'>$aEnc</td><td class='ver'>$sEnc</td><td>$yEnc</td><td class='dt'>$tEnc</td><td class='note' title='$kEnc'>$nEnc</td></tr>")
}

$html = @"
<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Program ve Eklenti Envanteri - $(HtmlEnc $pcName)</title>
<style>
  :root { --bg:#f6f7f9; --card:#ffffff; --text:#1a1f29; --muted:#5c6675; --border:#dde2ea; --accent:#1f5eff; --accent-soft:#eaf0ff; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:"Segoe UI",system-ui,-apple-system,sans-serif; background:var(--bg); color:var(--text); font-size:14px; }
  .wrap { max-width:1440px; margin:0 auto; padding:20px; }
  .header { background:var(--card); border:1px solid var(--border); border-radius:10px; padding:18px 22px; margin-bottom:16px; display:flex; flex-wrap:wrap; justify-content:space-between; gap:14px; align-items:center; }
  .header h1 { margin:0 0 6px 0; font-size:20px; }
  .meta { color:var(--muted); font-size:13px; line-height:1.5; }
  .actions { display:flex; gap:8px; }
  .btn { border:1px solid var(--border); background:#fff; color:var(--text); padding:8px 13px; border-radius:7px; cursor:pointer; font-size:13px; font-weight:600; }
  .btn:hover { background:#f0f2f5; }
  .toolbar { background:var(--card); border:1px solid var(--border); border-radius:10px; padding:14px 16px; margin-bottom:14px; }
  .search-row { display:flex; gap:10px; align-items:center; margin-bottom:12px; flex-wrap:wrap; }
  #q { flex:1; min-width:260px; padding:9px 12px; border:1px solid var(--border); border-radius:7px; font-size:14px; outline:none; }
  #q:focus { border-color:var(--accent); box-shadow:0 0 0 3px var(--accent-soft); }
  #cnt { color:var(--muted); font-size:13px; font-weight:600; white-space:nowrap; }
  .pills { display:flex; flex-wrap:wrap; gap:6px; }
  .pill { border:1px solid var(--border); background:#fff; color:var(--text); padding:6px 10px; border-radius:999px; font-size:12px; cursor:pointer; display:inline-flex; align-items:center; gap:6px; }
  .pill span { background:#eef1f6; color:var(--muted); padding:1px 6px; border-radius:999px; font-weight:600; font-size:11px; }
  .pill.active { background:var(--accent); color:#fff; border-color:var(--accent); }
  .pill.active span { background:rgba(255,255,255,0.22); color:#fff; }
  .table-wrap { background:var(--card); border:1px solid var(--border); border-radius:10px; overflow:auto; }
  table { width:100%; border-collapse:collapse; font-size:13px; }
  thead th { position:sticky; top:0; background:#f1f4f9; text-align:left; padding:10px 12px; border-bottom:1px solid var(--border); font-weight:600; white-space:nowrap; cursor:pointer; user-select:none; }
  tbody td { padding:8px 12px; border-bottom:1px solid #eef1f5; vertical-align:top; }
  tbody tr:hover { background:#f8faff; }
  td.cat { color:var(--muted); font-size:12px; white-space:nowrap; }
  td.parent { font-weight:600; color:#2b3a55; }
  td.name { font-weight:500; }
  td.ver { font-family:Consolas,"Cascadia Mono",monospace; font-size:12px; white-space:nowrap; color:#0b5394; }
  td.dt { white-space:nowrap; color:var(--muted); font-size:12px; }
  td.note { color:var(--muted); font-size:12px; max-width:340px; word-break:break-word; }
  .hidden { display:none; }
  @media print { .toolbar, .actions { display:none; } .wrap { padding:0; } .header, .table-wrap { border:none; } }
</style>
</head>
<body>
<div class="wrap">
  <div class="header">
    <div>
      <h1>Program ve Eklenti Envanteri &mdash; $(HtmlEnc $pcName)</h1>
      <div class="meta">
        <strong>Tarih:</strong> $(HtmlEnc $nowStr) &nbsp;|&nbsp;
        <strong>Kullanici:</strong> $(HtmlEnc $curUser) ($(if ($isAdmin) {'Yonetici'} else {'Standart'})) &nbsp;|&nbsp;
        <strong>Sistem:</strong> $(HtmlEnc $winFull)<br>
        <strong>Donanim:</strong> $(HtmlEnc $cpu) &nbsp;|&nbsp; <strong>RAM:</strong> $ramGb GB
      </div>
    </div>
    <div class="actions">
      <button class="btn" onclick="window.print()">Yazdir / PDF</button>
    </div>
  </div>
  <div class="toolbar">
    <div class="search-row">
      <input id="q" type="search" placeholder="Program, eklenti, surum veya yayinci ara (orn: solidworks, solidcam, visual studio, code, revit, python)..." autofocus>
      <div id="cnt">$($orderedItems.Count) / $($orderedItems.Count) kayit</div>
    </div>
    <div class="pills">$($pillsSb.ToString())</div>
  </div>
  <div class="table-wrap">
    <table id="tbl">
      <thead>
        <tr>
          <th data-col="0">Kategori</th>
          <th data-col="1">Ust Program</th>
          <th data-col="2">Ad</th>
          <th data-col="3">Surum</th>
          <th data-col="4">Yayinci</th>
          <th data-col="5">Tarih</th>
          <th data-col="6">Not (Konum icin uzerine gelin)</th>
        </tr>
      </thead>
      <tbody>
$($rowsSb.ToString())
      </tbody>
    </table>
  </div>
</div>
<script>
(function(){
  var q = document.getElementById('q');
  var cnt = document.getElementById('cnt');
  var pills = document.querySelectorAll('.pill');
  var tbody = document.querySelector('#tbl tbody');
  var rows = Array.prototype.slice.call(tbody.rows);
  var activeCat = 'ALL';

  function applyFilter(){
    var term = (q.value || '').toLowerCase().trim();
    var parts = term ? term.split(/\s+/) : [];
    var shown = 0;
    for (var i = 0; i < rows.length; i++){
      var r = rows[i];
      var okCat = (activeCat === 'ALL') || (r.getAttribute('data-cat') === activeCat);
      var okTerm = true;
      if (okCat && parts.length){
        var txt = r.textContent.toLowerCase();
        for (var j = 0; j < parts.length; j++){
          if (txt.indexOf(parts[j]) === -1){ okTerm = false; break; }
        }
      }
      if (okCat && okTerm){ r.classList.remove('hidden'); shown++; }
      else { r.classList.add('hidden'); }
    }
    cnt.textContent = shown + ' / ' + rows.length + ' kayit';
  }

  q.addEventListener('input', applyFilter);
  pills.forEach(function(p){
    p.addEventListener('click', function(){
      pills.forEach(function(x){ x.classList.remove('active'); });
      p.classList.add('active');
      activeCat = p.getAttribute('data-cat');
      applyFilter();
    });
  });

  var sortDir = {};
  document.querySelectorAll('#tbl thead th').forEach(function(th){
    th.addEventListener('click', function(){
      var col = parseInt(th.getAttribute('data-col'), 10);
      sortDir[col] = !sortDir[col];
      var asc = sortDir[col] ? 1 : -1;
      rows.sort(function(a, b){
        var ta = a.cells[col].textContent.toLowerCase();
        var tb = b.cells[col].textContent.toLowerCase();
        return ta.localeCompare(tb, 'tr') * asc;
      });
      var frag = document.createDocumentFragment();
      rows.forEach(function(r){ frag.appendChild(r); });
      tbody.appendChild(frag);
    });
  });
})();
</script>
</body>
</html>
"@
[System.IO.File]::WriteAllText($htmlPath, $html, $utf8Bom)

$sw.Stop()
Write-Host ''
Write-Host '======================================================' -ForegroundColor Green
Write-Host "  TAMAMLANDI ($([math]::Round($sw.Elapsed.TotalSeconds, 1)) sn) - Toplam $($orderedItems.Count) kayit" -ForegroundColor Green
Write-Host '======================================================' -ForegroundColor Green
foreach ($ck in $catCounts.Keys) {
    Write-Host ("  {0,-38} : {1}" -f $ck, $catCounts[$ck])
}
Write-Host ''
Write-Host "Rapor klasoru : $outDir" -ForegroundColor Cyan
Write-Host "  - HTML (aranabilir) : $htmlPath"
Write-Host "  - TXT  (duz liste)  : $txtPath"
Write-Host "  - CSV  (Excel)      : $csvPath"

if ($env:ENVANTER_NO_OPEN -ne '1') {
    try { Start-Process -FilePath $htmlPath } catch {}
}
