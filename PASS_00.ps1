& {
<#
  BASALT  Pass 0  -  read-only, resumable folder inventory (PowerShell 5.1, default tools only).
  PASTE-ABLE: no param(), no .ps1 needed. Edit the VARIABLES block, cd to the folder to scan, paste all.
  Output (sidecar, never inside the scanned tree):
    <OutRoot>\<yyyyMMdd-HHmmss>\ run.json config.json folders.tsv extensions.tsv skipped.tsv errors.tsv
  Resume: set $RunDir to an existing run folder and paste again.
#>

# =====================================================================  VARIABLES (edit me)
$Root          = '.'                                      # '.' = current folder (cd there first)
$OutRoot       = Join-Path $env:USERPROFILE 'llms-out'    # sidecar parent; MUST be outside $Root
$RunDir        = ''                                       # set to an existing run folder to RESUME
$ConfigPath    = ''                                       # optional .psd1 whose keys override $Config below
$SniffUnknown  = $false                                   # $true = read first 512 bytes of a few extension-less files per folder
$MaxDepth      = 0                                        # 0 = unlimited; 2 = quick dry run

$Config = @{
  LlmsFileName        = 'llms-txt.md'          # assumed to exist NOWHERE in the source tree; collisions are logged (plain llms.txt is flagged too)
  ManifestFileName    = 'llms-manifest.json'
  SkipHiddenDirs      = $true                  # hidden dirs are "subsumed by their parent"
  FollowReparsePoints = $false                 # symlinks / junctions are never traversed
  ExtTopN             = 30
  SniffMaxPerFolder   = 3
  ProgressSeconds     = 20
  ExcludeDirNames     = @('node_modules','.venv','venv','__pycache__','bin','obj','.git','.svn','.hg',
                          '.idea','.vs','.pytest_cache','.mypy_cache','$RECYCLE.BIN','System Volume Information')
  ReadmePrefix        = 'readme'
  MarkerDirNames      = @{ '.git'='Repo'; '.svn'='Repo'; '.hg'='Repo' }
  MarkerFileNames     = @{ '.git'='Repo'
                           'pyproject.toml'='Build'; 'setup.py'='Build'; 'requirements.txt'='Build'
                           'package.json'='Build'; 'makefile'='Build'; 'cmakelists.txt'='Build'
                           'cargo.toml'='Build'; 'pom.xml'='Build'; 'build.gradle'='Build'; 'go.mod'='Build'
                           'dockerfile'='Build'; 'docker-compose.yml'='Build'; 'environment.yml'='Build'
                           'license'='Meta'; 'license.txt'='Meta'; 'changelog.md'='Meta'; 'index.md'='Meta' }
  MarkerExts          = @{ '.sln'='Build'; '.csproj'='Build'; '.vcxproj'='Build'
                           '.slx'='Matlab'; '.mlx'='Matlab'; '.prj'='Matlab'; '.mat'='Matlab'
                           '.grc'='SDR'; '.sigmf-meta'='SDR'; '.sigmf-data'='SDR'; '.cfile'='SDR'
                           '.iq'='SDR'; '.cf32'='SDR'; '.fc32'='SDR'; '.cs16'='SDR'; '.cu8'='SDR'
                           '.ipynb'='Notebook'
                           '.sqlite'='Database'; '.sqlite3'='Database'; '.db'='Database'; '.mdb'='Database'
                           '.accdb'='Database'; '.mdf'='Database'; '.ldf'='Database' }
  NameCrumbs          = [ordered]@{
                           Archive = '(?i)(^|[^a-z])(old|bak|backup|backups|archive|archives|archived|cold|deprecated)([^a-z]|$)'
                           Temp    = '(?i)(^|[^a-z])(tmp|temp|scratch|trash|junk)([^a-z]|$)'
                           Misc    = '(?i)^(misc|stuff|random|untitled|new folder.*|copy of .*)$'
                           Year    = '^(19|20)\d\d$'
                           HasYear = '(^|[^0-9])(19|20)\d\d([^0-9]|$)'
                           Version = '(?i)(^|[^a-z])v?\d+(\.\d+)+([^0-9]|$)'
                        }
}
# =====================================================================  END VARIABLES

$ErrorActionPreference = 'Continue'
$ScriptVersion = '0.1.1-paste'

if ($ConfigPath) {
  $ov = Import-PowerShellDataFile -LiteralPath $ConfigPath
  foreach ($k in $ov.Keys) { $Config[$k] = $ov[$k] }
}
$ExcludeSet = @{}; foreach ($n in $Config.ExcludeDirNames) { $ExcludeSet[$n] = 1 }
$MarkerDirs = $Config.MarkerDirNames
$MarkerFiles = $Config.MarkerFileNames
$MarkerExts = $Config.MarkerExts
$MarkerFiles[$Config.LlmsFileName] = 'LlmsCollision'
$MarkerFiles['llms.txt'] = 'LlmsCollision'
$MarkerFiles[$Config.ManifestFileName] = 'LlmsCollision'
$ReadmePrefix = $Config.ReadmePrefix

$Cols = @('RelPath','Depth','DirectFiles','DirectBytes','DirectDirs','SubFiles','SubBytes','SubDirs',
          'MinWrite','MaxWrite','DirectExt','SubExt','Markers','SubMarkers','Readmes','NameCrumbs',
          'HiddenDirs','HiddenFiles','ExcludedDirs','ReparseSkipped','Sniffed','DirSig','TreeSig','Errors')
$ci = @{}; for ($i = 0; $i -lt $Cols.Count; $i++) { $ci[$Cols[$i]] = $i }

# ------------------------------------------------------------------ helpers
function ConvertTo-LongPath([string]$p) {
  if ($p.StartsWith('\\?\')) { return $p }
  if ($p.StartsWith('\\'))   { return '\\?\UNC\' + $p.Substring(2) }
  return '\\?\' + $p
}
$script:sha = [System.Security.Cryptography.SHA1]::Create()
function Get-ShortHash([string]$s) {
  $h = $script:sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))
  return [BitConverter]::ToString($h).Replace('-', '').Substring(0, 16)
}
function Add-Hist($h, [string]$ext, [long]$cnt, [long]$bytes) {
  $v = $h[$ext]
  if ($null -eq $v) { $h[$ext] = [long[]]@($cnt, $bytes) } else { $v[0] += $cnt; $v[1] += $bytes }
}
function Format-Hist($h, [int]$topN) {
  if ($h.Count -eq 0) { return '' }
  $items = $h.GetEnumerator() | Sort-Object @{Expression={$_.Value[1]};Descending=$true}, @{Expression={$_.Key}}
  $out = New-Object 'System.Collections.Generic.List[string]'
  $i = 0; [long]$oc = 0; [long]$ob = 0
  foreach ($it in $items) {
    if ($i -lt $topN) {
      $k = ([string]$it.Key).ToLowerInvariant().Replace(';', '_').Replace(':', '_')
      $out.Add("${k}:$($it.Value[0]):$($it.Value[1])")
    } else { $oc += $it.Value[0]; $ob += $it.Value[1] }
    $i++
  }
  if ($oc -gt 0) { $out.Add("(other):${oc}:${ob}") }
  return ($out -join ';')
}
function Convert-HistFromString([string]$s) {
  $h = @{}
  if (-not $s) { return $h }
  foreach ($p in $s.Split(';')) {
    $f = $p.Split(':')
    if ($f.Count -ge 3) { $h[$f[0]] = [long[]]@([long]$f[1], [long]$f[2]) }
  }
  return $h
}
function Format-Counts($h) {
  if ($h.Count -eq 0) { return '' }
  return (($h.Keys | Sort-Object | ForEach-Object { "$_=$($h[$_])" }) -join ';')
}
function Convert-CountsFromString([string]$s) {
  $h = @{}
  if (-not $s) { return $h }
  foreach ($p in $s.Split(';')) { $f = $p.Split('='); if ($f.Count -eq 2) { $h[$f[0]] = [long]$f[1] } }
  return $h
}
function Format-Day([long]$t) {
  if ($t -le 0 -or $t -eq [long]::MaxValue -or $t -gt 3155378975999999999) { return '' }
  return (New-Object DateTime -ArgumentList $t).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}
function Convert-DayToTicks([string]$s, [long]$default) {
  if (-not $s) { return $default }
  return [DateTime]::ParseExact($s, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture).Ticks
}
function Get-Sniff([string]$Path) {
  $buf = New-Object byte[] 512; $n = 0
  try {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $n = $fs.Read($buf, 0, 512) } finally { $fs.Dispose() }
  } catch { return 'unreadable' }
  if ($n -eq 0) { return 'empty' }
  if ($n -ge 4) {
    $h = '{0:X2}{1:X2}{2:X2}{3:X2}' -f $buf[0], $buf[1], $buf[2], $buf[3]
    switch ($h) {
      '89504E47' { return 'png' }  '25504446' { return 'pdf' }  '504B0304' { return 'zip' }
      '7F454C46' { return 'elf' }  '377ABCAF' { return '7z' }   '52617221' { return 'rar' }
      '53514C69' { return 'sqlite' }
    }
  }
  if ($n -ge 3 -and $buf[0] -eq 0xFF -and $buf[1] -eq 0xD8 -and $buf[2] -eq 0xFF) { return 'jpeg' }
  if ($n -ge 2 -and $buf[0] -eq 0x1F -and $buf[1] -eq 0x8B) { return 'gzip' }
  if ($n -ge 2 -and $buf[0] -eq 0x4D -and $buf[1] -eq 0x5A) { return 'mz-exe' }
  for ($i = 0; $i -lt $n; $i++) { if ($buf[$i] -eq 0) { return 'binary' } }
  return 'text'
}

# ------------------------------------------------------------------ paths / run folder
$rootFull = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\')
if ($rootFull -match '^[A-Za-z]:$') { $rootFull += '\' }
$null = New-Item -ItemType Directory -Force -Path $OutRoot
$outFull = (Resolve-Path -LiteralPath $OutRoot).ProviderPath.TrimEnd('\')
if ($outFull.StartsWith($rootFull.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
  throw "OutRoot ($outFull) is inside the scanned Root ($rootFull). The sidecar must live outside the source tree."
}
$resuming = $false
if ($RunDir) { $runPath = (Resolve-Path -LiteralPath $RunDir).ProviderPath; $resuming = $true }
else { $runPath = Join-Path $outFull (Get-Date -Format 'yyyyMMdd-HHmmss'); $null = New-Item -ItemType Directory -Force -Path $runPath }

$pFolders = Join-Path $runPath 'folders.tsv'
$pSkipped = Join-Path $runPath 'skipped.tsv'
$pErrors  = Join-Path $runPath 'errors.tsv'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$Done = @{}
if ($resuming -and (Test-Path -LiteralPath $pFolders)) {
  $first = $true
  foreach ($line in [IO.File]::ReadLines($pFolders)) {
    if ($first) { $first = $false; continue }
    $f = $line.Split("`t")
    if ($f.Count -eq $Cols.Count) { $Done[$f[0]] = $line }
  }
  Write-Host "Resuming: $($Done.Count) completed folders loaded."
}
function New-TsvWriter([string]$path, [string[]]$header) {
  $isNew = -not (Test-Path -LiteralPath $path)
  $w = New-Object IO.StreamWriter($path, $true, $utf8)
  if ($isNew) { $w.WriteLine(($header -join "`t")) }
  return $w
}
$script:wF = New-TsvWriter $pFolders $Cols
$script:wS = New-TsvWriter $pSkipped @('RelPath','Name','Reason')
$script:wE = New-TsvWriter $pErrors  @('Time','RelPath','Kind','Message')
$script:rowsSinceFlush = 0; $script:errTotal = 0
function Write-Skip([string]$rel, [string]$name, [string]$reason) { $script:wS.WriteLine("$rel`t$name`t$reason") }
function Write-Err([string]$rel, [string]$kind, [string]$msg) {
  $script:errTotal++
  $script:wE.WriteLine("$(Get-Date -Format s)`t$rel`t$kind`t$($msg -replace '[\r\n\t]',' ')")
}

($Config | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $runPath 'config.json') -Encoding UTF8
$runInfo = [ordered]@{
  ScriptVersion = $ScriptVersion; Status = 'running'; Host = $env:COMPUTERNAME; User = $env:USERNAME
  Root = $rootFull; RunPath = $runPath; Started = (Get-Date -Format 'o'); Resumed = $resuming
  MaxDepth = $MaxDepth; SniffUnknown = [bool]$SniffUnknown; PSVersion = $PSVersionTable.PSVersion.ToString()
}
($runInfo | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $runPath 'run.json') -Encoding UTF8

$script:nDirs = 0L; $script:nFiles = 0L; $script:nBytes = 0L
$sw = [Diagnostics.Stopwatch]::StartNew(); $script:nextBeat = $Config.ProgressSeconds

function Convert-RowToStats([string]$line) {
  $f = $line.Split("`t")
  return @{
    SubFiles = [long]$f[$ci['SubFiles']]; SubBytes = [long]$f[$ci['SubBytes']]; SubDirs = [long]$f[$ci['SubDirs']]
    SubHist = (Convert-HistFromString $f[$ci['SubExt']])
    MinT = (Convert-DayToTicks $f[$ci['MinWrite']] ([long]::MaxValue)); MaxT = (Convert-DayToTicks $f[$ci['MaxWrite']] 0)
    SubMarkers = (Convert-CountsFromString $f[$ci['SubMarkers']]); TreeSig = $f[$ci['TreeSig']]
  }
}

# ------------------------------------------------------------------ the crawl (post-order)
function Invoke-Crawl($Dir, [string]$Rel, [int]$Depth) {
  $script:nDirs++
  if ($sw.Elapsed.TotalSeconds -ge $script:nextBeat) {
    $script:nextBeat = $sw.Elapsed.TotalSeconds + $Config.ProgressSeconds
    $rate = [math]::Round($script:nFiles / [math]::Max(1, $sw.Elapsed.TotalSeconds))
    Write-Host ("[{0:hh\:mm\:ss}] dirs={1:N0} files={2:N0} GB={3:N1} ~{4:N0} files/s  at {5}" -f $sw.Elapsed, $script:nDirs, $script:nFiles, ($script:nBytes / 1GB), $rate, $Rel)
  }
  $dHist = @{}; $sHist = @{}
  [long]$dFiles = 0; [long]$dBytes = 0; [long]$dDirs = 0
  [long]$minT = [long]::MaxValue; [long]$maxT = 0
  $markers = @{}; $subMarkers = @{}
  $readmes = New-Object 'System.Collections.Generic.List[string]'
  $sig = New-Object 'System.Collections.Generic.List[string]'
  $kids = New-Object 'System.Collections.Generic.List[object]'
  $excl = @{}; $hidD = 0; $hidF = 0; $rep = 0; $errCount = 0; $sniffC = @{}; $sniffN = 0

  try {
    foreach ($e in $Dir.EnumerateFileSystemInfos()) {
      $attr = [int]$e.Attributes; $name = $e.Name
      if ($attr -band 16) {                                   # directory
        $dDirs++
        if ($MarkerDirs.ContainsKey($name)) { $c = $MarkerDirs[$name]; $markers[$c] = 1 + [int]$markers[$c] }
        if (($attr -band 1024) -and -not $Config.FollowReparsePoints) { $rep++; $sig.Add("d|$name|R"); Write-Skip $Rel $name 'reparse'; continue }
        if ($ExcludeSet.ContainsKey($name)) { $excl[$name] = 1; $sig.Add("d|$name|X"); Write-Skip $Rel $name 'excluded'; continue }
        if (($attr -band 2) -and $Config.SkipHiddenDirs) { $hidD++; $sig.Add("d|$name|H"); Write-Skip $Rel $name 'hidden'; continue }
        if ($MaxDepth -gt 0 -and $Depth -ge $MaxDepth) { $sig.Add("d|$name|M"); Write-Skip $Rel $name 'maxdepth'; continue }
        $sig.Add("d|$name"); $kids.Add($e)
      } else {                                                # file
        $len = [long]$e.Length; $t = $e.LastWriteTimeUtc.Ticks
        $dFiles++; $dBytes += $len
        if ($t -lt $minT) { $minT = $t }
        if ($t -gt $maxT) { $maxT = $t }
        if ($attr -band 2) { $hidF++ }
        $ext = [IO.Path]::GetExtension($name); if ($ext.Length -eq 0) { $ext = '(none)' }
        Add-Hist $dHist $ext 1 $len
        $cat = $MarkerFiles[$name]
        if (-not $cat) { $cat = $MarkerExts[$ext] }
        if ($cat) { $markers[$cat] = 1 + [int]$markers[$cat]
                    if ($cat -eq 'LlmsCollision') { Write-Err $Rel 'LLMS-NAME-COLLISION' $name } }
        if ($name.StartsWith($ReadmePrefix, [StringComparison]::OrdinalIgnoreCase)) {
          $markers['Readme'] = 1 + [int]$markers['Readme']; if ($readmes.Count -lt 3) { $readmes.Add($name) } }
        $sig.Add("f|$name|$len|$t")
        if ($SniffUnknown -and $ext -eq '(none)' -and $sniffN -lt $Config.SniffMaxPerFolder) {
          $s = Get-Sniff $e.FullName; $sniffC[$s] = 1 + [int]$sniffC[$s]; $sniffN++ }
      }
    }
  } catch { $errCount++; Write-Err $Rel 'enumerate' $_.Exception.Message }

  [long]$subFiles = $dFiles; [long]$subBytes = $dBytes; [long]$subDirs = 0
  [long]$sMin = $minT; [long]$sMax = $maxT
  foreach ($k in $dHist.Keys) { Add-Hist $sHist $k $dHist[$k][0] $dHist[$k][1] }
  foreach ($k in $markers.Keys) { $subMarkers[$k] = [long]$markers[$k] }
  $script:nFiles += $dFiles; $script:nBytes += $dBytes
  $childSigs = New-Object 'System.Collections.Generic.List[string]'

  foreach ($c in $kids) {
    $cname = $c.Name
    if ($Rel -eq '.') { $crel = $cname } else { $crel = "$Rel\$cname" }
    if ($Done.ContainsKey($crel)) { $cs = Convert-RowToStats $Done[$crel] }
    else { $cs = Invoke-Crawl $c $crel ($Depth + 1) }
    $subFiles += $cs.SubFiles; $subBytes += $cs.SubBytes; $subDirs += (1 + $cs.SubDirs)
    if ($cs.MinT -lt $sMin) { $sMin = $cs.MinT }
    if ($cs.MaxT -gt $sMax) { $sMax = $cs.MaxT }
    foreach ($k in $cs.SubHist.Keys) { Add-Hist $sHist $k $cs.SubHist[$k][0] $cs.SubHist[$k][1] }
    foreach ($k in $cs.SubMarkers.Keys) { $subMarkers[$k] = [long]$subMarkers[$k] + [long]$cs.SubMarkers[$k] }
    $childSigs.Add("${cname}:$($cs.TreeSig)")
  }

  $sig.Sort([StringComparer]::Ordinal); $childSigs.Sort([StringComparer]::Ordinal)
  $dirSig  = Get-ShortHash ($sig -join "`n")
  $treeSig = Get-ShortHash ($dirSig + "`n" + ($childSigs -join "`n"))

  $crumbs = New-Object 'System.Collections.Generic.List[string]'
  $leaf = $Dir.Name
  foreach ($tag in $Config.NameCrumbs.Keys) { if ($leaf -match $Config.NameCrumbs[$tag]) { $crumbs.Add($tag) } }

  $row = @($Rel, $Depth, $dFiles, $dBytes, $dDirs, $subFiles, $subBytes, $subDirs,
           (Format-Day $sMin), (Format-Day $sMax), (Format-Hist $dHist $Config.ExtTopN), (Format-Hist $sHist $Config.ExtTopN),
           (Format-Counts $markers), (Format-Counts $subMarkers), ($readmes -join '|'), ($crumbs -join '|'),
           $hidD, $hidF, (($excl.Keys | Sort-Object | Select-Object -First 10) -join '|'), $rep,
           (Format-Counts $sniffC), $dirSig, $treeSig, $errCount)
  $script:wF.WriteLine(($row -join "`t"))
  $script:rowsSinceFlush++
  if ($script:rowsSinceFlush -ge 200) { $script:wF.Flush(); $script:wS.Flush(); $script:wE.Flush(); $script:rowsSinceFlush = 0 }

  return @{ SubFiles = $subFiles; SubBytes = $subBytes; SubDirs = $subDirs; SubHist = $sHist
           MinT = $sMin; MaxT = $sMax; SubMarkers = $subMarkers; TreeSig = $treeSig }
}

# ------------------------------------------------------------------ main
$rootStats = $null
try {
  if ($Done.ContainsKey('.')) { Write-Host 'Root row already present: run is complete. Nothing to do.'; $rootStats = Convert-RowToStats $Done['.'] }
  else {
    $rootDir = New-Object IO.DirectoryInfo (ConvertTo-LongPath $rootFull)
    $rootStats = Invoke-Crawl $rootDir '.' 0
  }
} finally {
  $script:wF.Flush(); $script:wS.Flush(); $script:wE.Flush()
  $script:wF.Dispose(); $script:wS.Dispose(); $script:wE.Dispose()
}

if ($rootStats) {
  $extPath = Join-Path $runPath 'extensions.tsv'
  $lines = @("Extension`tFiles`tBytes")
  $lines += $rootStats.SubHist.GetEnumerator() | Sort-Object @{Expression={$_.Value[1]};Descending=$true} |
            ForEach-Object { "$($_.Key.ToLowerInvariant())`t$($_.Value[0])`t$($_.Value[1])" }
  [IO.File]::WriteAllLines($extPath, $lines, $utf8)
  $runInfo['Status'] = 'complete'; $runInfo['Finished'] = (Get-Date -Format 'o')
  $runInfo['ElapsedThisSession'] = $sw.Elapsed.ToString()
  $runInfo['Folders'] = $rootStats.SubDirs + 1; $runInfo['Files'] = $rootStats.SubFiles; $runInfo['Bytes'] = $rootStats.SubBytes
  $runInfo['RootTreeSig'] = $rootStats.TreeSig; $runInfo['ErrorsThisSession'] = $script:errTotal
  ($runInfo | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $runPath 'run.json') -Encoding UTF8
  Write-Host ("Done. folders={0:N0} files={1:N0} size={2:N1} GB RootTreeSig={3}" -f ($rootStats.SubDirs + 1), $rootStats.SubFiles, ($rootStats.SubBytes / 1GB), $rootStats.TreeSig)
  Write-Host "Sidecar: $runPath"
}
}