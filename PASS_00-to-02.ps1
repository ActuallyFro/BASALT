& {
<#
  llms-tree  Passes 0-2 + POST 01  -  inventory, classify, emit, and export an LPG graph (PowerShell 5.1).
  PASTE-ABLE: no param(), no .ps1 needed. Edit the VARIABLES block, cd to the folder to scan, paste all.
  Pass 2 writes by default; set $DryRun = $true to preview. $CleanTree removes only the sidecar tree in this run folder.
  Output (sidecar, never inside the scanned tree):
    <OutRoot>\<yyyyMMdd-HHmmss>\ run.json config.json folders.tsv extensions.tsv skipped.tsv errors.tsv
                                    classification.tsv classification-summary.txt
                                    tree\...\llms-txt.md llms-manifest.json
                                    pass2-index.tsv pass2-report.txt
                                    mega-manifest.json mega-manifest.jsonl nodes.csv edges.csv mega-catalog.md
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

# =====================================================================  PASS 1 VARIABLES (edit me)
$P = @{
  MinChunkBytes  = 50MB
  MaxLeafBytes   = 2GB
  SigShare       = 0.10
  NestedMinBytes = 5MB
  BulkMinFiles   = 500
  BulkShare      = 0.90
  BlobShare      = 0.90
  DatasetShare   = 0.60
  MaxEntries     = 53
  ColdAgeYears   = 5
  TopN           = 25
}
$StrongMarkers = @('Build')
$StrongReadmeNames = @('readme.md','readme.txt','readme.rst','readme.markdown')
$DatasetMarkers = @('SDR')
$ExtFamilies = @{
  image        = '.png .jpg .jpeg .jpe .jfif .gif .bmp .tif .tiff .webp .avif .heic .heif .jxl .raw .cr2 .cr3 .nef .nrw .arw .dng .orf .rw2 .pef .raf .srw .x3f .dds .tga .psd .icns .ico .cur .apng .jp2 .j2k .jpf .jpx .jpm .mj2 .pcx .ppm .pgm .pbm .pnm .qoi .exr .hdr .dpx .cin .xbm .xpm'
  video        = '.mp4 .m4v .mkv .avi .mov .wmv .asf .webm .ogv .flv .f4v .3gp .3g2 .mpg .mpeg .mpe .m1v .m2v .mpv .vob .mts .m2ts .ts .mxf .rm .rmvb .divx .y4m .bik .bk2 .usm .h264 .264 .h265 .265 .ivf'
  audio        = '.mp3 .wav .wave .flac .aac .ogg .oga .opus .m4a .m4b .m4p .wma .aif .aiff .aifc .caf .amr .awb .ape .alac .ac3 .eac3 .dts .mid .midi .mod .xm .it .s3m .mt2 .umx .wvc .wv .dsf .dff .ra .ram .au .snd .spx .wem .bnk .xwm'
  doc          = '.pdf .doc .docx .docm .dot .dotx .xls .xlsx .xlsm .xltx .ppt .pptx .pptm .pps .ppsx .odt .ott .ods .ots .odp .otp .rtf .txt .md .rst .tex .bib .csv .tsv .ps .xps .djvu .wpd .wps .pages .numbers .key'
  archive      = '.zip .7z .rar .tar .gz .tgz .bz2 .tbz .tbz2 .bz .xz .txz .lz .lzma .lzo .zst .z .br .cab .arj .ace .lha .lzh .sit .sitx .sea .dmg .iso .img .vhd .vhdx .vmdk .vdi .qcow .qcow2 .wim .esd .rpf .vpk .pak .ucas .ba2 .bsa .gma .assetbundle .bundle .ress .resource .fbq .sbt .pak2 .scm'
  sdr          = '.cfile .iq .sigmf-data .sigmf-meta .cf32 .fc32 .cf64 .fc64 .cs8 .cs16 .cs32 .cu8 .cu16 .cu32 .ci8 .ci16 .ci32 .sc8 .sc16 .sc32 .grc'
  data         = '.mat .h5 .hdf .hdf4 .hdf5 .h5ad .npy .npz .parquet .arrow .feather .orc .avro .sqlite .sqlite3 .nc .nc4 .cdf .fits .fit .fts .grib .grb .zarr .rds .rda .rdata .sav .dta .sas7bdat .por'
  code         = '.py .pyi .pyx .pxd .m .ps1 .psm1 .psd1 .ps1xml .c .cc .cpp .cxx .h .hh .hpp .hxx .cs .fs .fsx .vb .java .kt .kts .scala .sc .groovy .gvy .clj .cljs .cljc .edn .ex .exs .erl .hrl .hs .lhs .elm .dart .lua .pl .pm .rb .r .rmd .jl .f .for .f77 .f90 .f95 .f03 .f08 .cob .cbl .pas .pp .d .nim .zig .v .sv .svh .vhd .vhdl .ino .pde .go .rs .sh .bash .zsh .fish .bat .cmd .js .jsx .mjs .cjs .ts .tsx .mts .cts .vue .svelte .astro .php .phtml .sql .graphql .gql .ipynb'
  config       = '.json .jsonc .json5 .yaml .yml .toml .ini .cfg .conf .config .properties .env .xml .plist .reg .editorconfig .lock .service .target .mount .socket .timer .desktop'
  web          = '.html .htm .xhtml .css .scss .sass .less .webmanifest'
  database     = '.db .db3 .sqlite2 .sqlitedb .mdb .accdb .realm .leveldb .ldb .sst .ibd .frm .myd .myi .rdb .aof'
  vector       = '.svg .svgz .eps .ai .cdr .emf .wmf .odg .vsd .vsdx .drawio'
  design       = '.xcf .kra .ora .afdesign .afphoto .afpub .indd .idml .sketch .fig .xd .blend1'
  font         = '.ttf .otf .woff .woff2 .eot .fon .fnt .pfb .pfm .sfd .bdf .pcf .ttc'
  model3d      = '.obj .mtl .stl .3mf .blend .fbx .gltf .glb .usd .usda .usdc .usdz .dae .3ds .max .ma .mb .abc .ply .x3d .wrl'
  cad          = '.dwg .dxf .step .stp .iges .igs .sldprt .sldasm .slddrw .ipt .iam .idw .f3d .f3z .fcstd .ifc .sat .sab .3dm'
  gis          = '.shp .shx .prj .gpkg .kml .kmz .gpx .gml .topojson .las .laz .dem .vrt .grd .geojson'
  model        = '.onnx .pt .pth .safetensors .gguf .ggml .ckpt .tflite .mlmodel .mlpackage .pkl .pickle'
  binary       = '.exe .dll .so .dylib .a .lib .o .objdump .class .jar .war .ear .wasm .pdb'
  package      = '.msi .msix .appx .appxbundle .ipa .apk .aab .appimage .snap .flatpak .crx .vsix .nupkg .whl .gem .pkg .rpm .deb'
  subtitle     = '.srt .ass .ssa .vtt .sub .smi .sami .ttml .dfxp .sbv .lrc'
  playlist     = '.m3u .m3u8 .pls .xspf .cue'
  email        = '.eml .msg .mbox .pst .ost .ics .vcf .vcs'
  localization = '.po .pot .mo .resx .strings .stringsdict .xlf .xliff .arb .locres'
  log          = '.log .trace .dump .dmp .core .crash .etl .evtx .journal'
  network      = '.pcap .pcapng .har'
}

# =====================================================================  PASS 2 VARIABLES (edit me)
$DryRun          = $false # $true previews output without writing it
$CleanTree       = $true  # remove the existing sidecar tree before writing
$ReserveEntries  = 6
$ReadmeMax       = 3
$ListMinBytes    = 0
$CollapseWrappers = $true
$PreviewCount    = 3

# =====================================================================  POST 01 VARIABLES (edit me)
$TreeSubdir = 'tree'
$ExportName = 'llms-mega-manifest'
$GraphId = 'graph1'
$TierColors = @('#00b4f0', '#70db43', '#c8f000', '#a000f0', '#ff6666')
$TierRadii = @(50, 40, 30, 25, 20)
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

# ------------------------------------------------------------------ Pass 1: classify the Pass 0 inventory
$ErrorActionPreference = 'Stop'
$fam = @{}
foreach ($family in $ExtFamilies.Keys) {
  foreach ($ext in $ExtFamilies[$family].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) { $fam[$ext] = $family }
}

function ConvertFrom-Hist([string]$s) { return (Convert-HistFromString $s) }
function Test-Noise([string]$family) { return ($family -eq '(other)' -or $family.StartsWith('other:')) }
function Get-Shares($node) {
  $fileCounts = @{}; $fileBytes = @{}
  foreach ($ext in $node.E.Keys) {
    if ($ext -eq '(other)') { $family = '(other)' }
    elseif ($fam.ContainsKey($ext)) { $family = $fam[$ext] }
    else { $family = "other:$ext" }
    $fileCounts[$family] = [long]$fileCounts[$family] + $node.E[$ext][0]
    $fileBytes[$family] = [long]$fileBytes[$family] + $node.E[$ext][1]
  }
  $topCountFamily = ''; $maxCount = 0L
  foreach ($family in $fileCounts.Keys) { if ($fileCounts[$family] -gt $maxCount) { $maxCount = $fileCounts[$family]; $topCountFamily = $family } }
  $topByteFamily = ''; $maxBytes = 0L
  foreach ($family in $fileBytes.Keys) { if ($fileBytes[$family] -gt $maxBytes) { $maxBytes = $fileBytes[$family]; $topByteFamily = $family } }
  $datasetBytes = [long]$fileBytes['sdr'] + [long]$fileBytes['data']
  return @{
    TopC = $topCountFamily
    CShare = $(if ($node.SF -gt 0) { $maxCount / $node.SF } else { 0 })
    TopB = $topByteFamily
    BShare = $(if ($node.SB -gt 0) { $maxBytes / $node.SB } else { 0 })
    DShare = $(if ($node.SB -gt 0) { $datasetBytes / $node.SB } else { 0 })
  }
}

$foldersPath = Join-Path $runPath 'folders.tsv'
if (-not (Test-Path -LiteralPath $foldersPath)) { throw "Pass 0 output not found: $foldersPath" }
$rows = Import-Csv -LiteralPath $foldersPath -Delimiter "`t"
$N = @{}
foreach ($r in $rows) {
  $N[$r.RelPath] = @{
    Rel = $r.RelPath; Depth = [int]$r.Depth; SB = [long]$r.SubBytes; SF = [long]$r.SubFiles
    DF = [long]$r.DirectFiles; DB = [long]$r.DirectBytes
    M = (Convert-CountsFromString $r.Markers); SM = (Convert-CountsFromString $r.SubMarkers)
    E = (ConvertFrom-Hist $r.SubExt); Readmes = $r.Readmes; Crumbs = $r.NameCrumbs
    MaxWrite = $r.MaxWrite; MinWrite = $r.MinWrite; MaxW = $r.MaxWrite; MinW = $r.MinWrite
    Sig = $r.TreeSig; Kids = (New-Object 'System.Collections.Generic.List[object]')
  }
}
if (-not $N.ContainsKey('.')) { throw "Pass 0 inventory has no root row: $foldersPath" }
foreach ($rel in $N.Keys) {
  if ($rel -eq '.') { continue }
  $separator = $rel.LastIndexOf('\')
  $parent = if ($separator -lt 0) { '.' } else { $rel.Substring(0, $separator) }
  if ($N.ContainsKey($parent)) { $N[$parent].Kids.Add($N[$rel]) }
}
Write-Host "Pass 1: loaded $($N.Count) folders from $foldersPath."

$script:Out = New-Object 'System.Collections.Generic.List[object]'
function Add-Chunk($node, [string]$type, [string]$rule, [string]$why) {
  $flags = @()
  if ($node.Crumbs -match 'Archive|Temp') { $flags += 'cold' }
  if ($node.MaxWrite) {
    try {
      if ([datetime]::ParseExact($node.MaxWrite, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) -lt (Get-Date).AddYears(-$P.ColdAgeYears)) { $flags += 'cold-age' }
    } catch {}
  }
  $script:Out.Add([pscustomobject]@{
    Rel = $node.Rel; Depth = $node.Depth; Type = $type; Rule = $rule; Bytes = $node.SB; Files = $node.SF
    Flags = (($flags | Select-Object -Unique) -join '|'); Why = $why
  })
}
function Get-StopType($node) {
  if ($node.M.ContainsKey('Repo')) { return @('REPO','R-110','Repo marker in this folder') }
  if ($node.SF -eq 0) { return $null }
  $noRepoBelow = (-not $node.SM.ContainsKey('Repo'))
  $shares = Get-Shares $node
  if ($node.SF -ge $P.BulkMinFiles -and $shares.CShare -ge $P.BulkShare -and $noRepoBelow -and -not (Test-Noise $shares.TopC)) {
    return @('OPAQUE-BULK','R-130', ("{0:P0} of {1:N0} files are {2}" -f $shares.CShare, $node.SF, $shares.TopC))
  }
  if ($node.SF -lt $P.BulkMinFiles -and $shares.BShare -ge $P.BlobShare -and $noRepoBelow -and -not (Test-Noise $shares.TopB)) {
    return @('BLOB','R-135', ("{0:P0} of bytes are {1} in only {2:N0} files" -f $shares.BShare, $shares.TopB, $node.SF))
  }
  $hasDatasetMarker = $false
  foreach ($category in $DatasetMarkers) { if ($node.SM.ContainsKey($category)) { $hasDatasetMarker = $true } }
  if ($shares.DShare -ge $P.DatasetShare -or $hasDatasetMarker) {
    return @('DATASET','R-140', ("sdr+data bytes {0:P0}; markers {1}" -f $shares.DShare, ($DatasetMarkers -join ',')))
  }
  return $null
}
function Test-StrongProject($node) {
  foreach ($category in $StrongMarkers) { if ($node.M.ContainsKey($category)) { return $true } }
  foreach ($name in $node.Readmes.Split('|')) { if ($name -and ($StrongReadmeNames -contains $name.ToLowerInvariant())) { return $true } }
  return $false
}
function Add-NestedRepos($node) {
  foreach ($child in $node.Kids) {
    if ($child.M.ContainsKey('Repo')) { Add-Chunk $child 'REPO' 'R-110n' 'nested repo inside a closed chunk' }
    else { Add-NestedRepos $child }
  }
}
function Add-NestedStops($node) {
  foreach ($child in $node.Kids) {
    if ($child.SB -lt $P.MinChunkBytes -and -not $child.M.ContainsKey('Repo')) { continue }
    $stop = Get-StopType $child
    if ($stop -and ($stop[0] -eq 'REPO' -or $child.SB -ge $P.NestedMinBytes)) {
      Add-Chunk $child ($stop[0] + '(nested)') 'R-155' $stop[2]
    } else { Add-NestedStops $child }
  }
}
function Invoke-Classify($node) {
  if ($node.SB -lt $P.MinChunkBytes -and -not $node.M.ContainsKey('Repo')) { return $null }
  $stop = Get-StopType $node
  if ($stop) { Add-Chunk $node $stop[0] $stop[1] $stop[2]; return $stop[0] }
  if ($node.Depth -gt 0 -and (Test-StrongProject $node)) {
    Add-Chunk $node 'PROJECT' 'R-150' ("breadcrumbs: markers={0} readmes={1}" -f (($node.M.Keys | Sort-Object) -join ','), $node.Readmes)
    Add-NestedStops $node
    return 'PROJECT'
  }
  if ($node.Depth -gt 0 -and $node.SB -le $P.MaxLeafBytes) {
    Add-Chunk $node 'MIXED-LEAF' 'R-125' ("<= MaxLeafBytes ({0:N1} GB)" -f ($node.SB / 1GB))
    Add-NestedRepos $node
    return 'MIXED-LEAF'
  }
  $index = $script:Out.Count
  $script:Out.Add($null)
  $mark = $script:Out.Count
  $significant = 0
  $significantTypes = @()
  foreach ($child in $node.Kids) {
    $childType = Invoke-Classify $child
    if ($childType -and $child.SB -ge ($P.SigShare * $node.SB)) { $significant++; $significantTypes += $childType }
  }
  if ($significant -ge 2 -or $node.Depth -eq 0 -or ($significant -eq 1 -and $significantTypes[0] -in @('CONTAINER','WRAPPER'))) {
    $type = if ($significant -ge 2) { 'CONTAINER' } else { 'WRAPPER' }
    $script:Out[$index] = [pscustomobject]@{
      Rel = $node.Rel; Depth = $node.Depth; Type = $type; Rule = 'R-160'; Bytes = $node.SB; Files = $node.SF; Flags = ''
      Why = ("{0} significant chunk child(ren) (>= {1:P0} of {2:N1} GB)" -f $significant, $P.SigShare, ($node.SB / 1GB))
    }
    return $type
  }
  $script:Out.RemoveRange($mark, $script:Out.Count - $mark)
  Add-Chunk $node 'MIXED-LEAF' 'R-170' 'no >=2 significant chunk children'
  Add-NestedRepos $node
  return 'MIXED-LEAF'
}

$null = Invoke-Classify $N['.']
$chunks = @($script:Out | Where-Object { $_ -ne $null })
$classificationPath = Join-Path $runPath 'classification.tsv'
$chunks | Select-Object Rel, Depth, Type, Rule, @{n='GB';e={[math]::Round($_.Bytes / 1GB, 2)}}, Files, Flags, Why |
  Export-Csv -LiteralPath $classificationPath -Delimiter "`t" -NoTypeInformation -Encoding UTF8

$summary = New-Object 'System.Collections.Generic.List[string]'
$summary.Add("llms-tree Pass 1   folders=$($N.Count)   chunks=$($chunks.Count)   ($($rows.Count) manifest rows)")
$summary.Add('Params: ' + (($P.Keys | Sort-Object | ForEach-Object { "$_=$($P[$_])" }) -join '  '))
$summary.Add(''); $summary.Add('--- chunks by type')
$chunks | Group-Object Type | Sort-Object Count -Descending | ForEach-Object {
  $summary.Add(("{0,-18}{1,6}   {2,10:N1} GB" -f $_.Name, $_.Count, (($_.Group | Measure-Object Bytes -Sum).Sum / 1GB)))
}
$summary.Add(''); $summary.Add('--- chunks by depth')
$chunks | Group-Object Depth | Sort-Object { [int]$_.Name } | ForEach-Object { $summary.Add(("depth {0,-3}{1,6}" -f $_.Name, $_.Count)) }
$summary.Add(''); $summary.Add("--- largest $($P.TopN) chunks")
$chunks | Sort-Object Bytes -Descending | Select-Object -First $P.TopN | ForEach-Object {
  $summary.Add(("{0,-12}{1,8:N1} GB {2,9:N0} files  {3}" -f $_.Type, ($_.Bytes / 1GB), $_.Files, $_.Rel))
}
$summary.Add(''); $summary.Add('--- fan-out check (children chunks per parent chunk, limit ' + $P.MaxEntries + ')')
$byParent = @{}
foreach ($chunk in $chunks) {
  if ($chunk.Rel -ne '.') {
    $separator = $chunk.Rel.LastIndexOf('\')
    $parent = if ($separator -lt 0) { '.' } else { $chunk.Rel.Substring(0, $separator) }
    $byParent[$parent] = 1 + [int]$byParent[$parent]
  }
}
$overLimit = $byParent.GetEnumerator() | Where-Object { $_.Value -gt $P.MaxEntries }
if ($overLimit) {
  $overLimit | ForEach-Object { $summary.Add("OVER: $($_.Key) -> $($_.Value) direct chunk children (R-211 grouping needed)") }
} else { $summary.Add('ok: no parent exceeds the cap (direct children only; nested links not counted)') }
$summary.Add(''); $summary.Add('--- cold-flagged chunks: ' + (@($chunks | Where-Object { $_.Flags }).Count))
$summary.Add('--- tuning: raise MaxLeafBytes for fewer/bigger chunks, lower it for finer chunks; see classification.tsv "Why" column')
[IO.File]::WriteAllLines((Join-Path $runPath 'classification-summary.txt'), $summary)
$summary | ForEach-Object { Write-Host $_ }
Write-Host "Wrote $classificationPath"

# ------------------------------------------------------------------ Pass 2: emit llms pages and manifests
$LlmsFileName = $Config.LlmsFileName
$ManifestFileName = $Config.ManifestFileName
$MaxEntries = [int]$P.MaxEntries
$Generator = 'llms-tree pass2 0.2'
$G = $MaxEntries - $ReserveEntries
$rootName = 'root'
if ($runInfo.Root) {
  $rootName = (($runInfo.Root.TrimEnd('\', '/')) -split '[\\/]')[-1]
  if (-not $rootName) { $rootName = $runInfo.Root }
}

function Format-Size([long]$bytes) {
  if ($bytes -ge 1TB) { return ('{0:N1} TB' -f ($bytes / 1TB)) }
  if ($bytes -ge 1GB) { return ('{0:N1} GB' -f ($bytes / 1GB)) }
  if ($bytes -ge 1MB) { return ('{0:N0} MB' -f ($bytes / 1MB)) }
  if ($bytes -ge 1KB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
  return "$bytes B"
}
function ConvertTo-Url([string]$relativePath) {
  return (($relativePath.Split('\') | ForEach-Object {
    [uri]::EscapeDataString($_).Replace('(', '%28').Replace(')', '%29').Replace("'", '%27').Replace('!', '%21').Replace('*', '%2A')
  }) -join '/')
}
function ConvertTo-LinkText([string]$text) { return $text.Replace('[', '\[').Replace(']', '\]') }
function Get-ParentRel([string]$relativePath) {
  $separator = $relativePath.LastIndexOf('\')
  if ($separator -lt 0) { return '.' }
  return $relativePath.Substring(0, $separator)
}
function Get-LeafName([string]$relativePath) {
  $separator = $relativePath.LastIndexOf('\')
  if ($separator -lt 0) { return $relativePath }
  return $relativePath.Substring($separator + 1)
}
function Get-RelFrom([string]$parent, [string]$child) {
  if ($parent -eq '.') { return $child }
  return $child.Substring($parent.Length + 1)
}
function Get-TopExt($node, [int]$count) {
  $items = $node.E.GetEnumerator() | Where-Object { $_.Key -ne '(other)' } |
    Sort-Object @{Expression={$_.Value[1]};Descending=$true} | Select-Object -First $count
  $output = @()
  foreach ($item in $items) {
    if ($node.SB -gt 0) { $output += ('{0} {1:P0}' -f $item.Key, ($item.Value[1] / $node.SB)) }
  }
  return ($output -join ', ')
}
function Get-FamShares($node) {
  $familyBytes = @{}
  foreach ($ext in $node.E.Keys) {
    if ($ext -eq '(other)') { $family = 'other' }
    elseif ($fam.ContainsKey($ext)) { $family = $fam[$ext] }
    else { $family = 'other' }
    $familyBytes[$family] = [long]$familyBytes[$family] + $node.E[$ext][1]
  }
  $shares = [ordered]@{}
  foreach ($family in ($familyBytes.Keys | Sort-Object { -$familyBytes[$_] })) {
    if ($node.SB -gt 0) { $shares[$family] = [math]::Round($familyBytes[$family] / $node.SB, 3) }
  }
  return $shares
}

$ChunkMap = @{}
foreach ($row in (Import-Csv -LiteralPath $classificationPath -Delimiter "`t")) {
  if ($ChunkMap.ContainsKey($row.Rel)) { continue }
  if (-not $N.ContainsKey($row.Rel)) { Write-Warning "classification row not in inventory: $($row.Rel)"; continue }
  $ChunkMap[$row.Rel] = @{
    Rel = $row.Rel; Type = ($row.Type -replace '\(nested\)', ''); Nested = ($row.Type -match 'nested')
    Rule = $row.Rule; Why = $row.Why; Flags = $row.Flags; Node = $N[$row.Rel]
    Kids = (New-Object 'System.Collections.Generic.List[object]'); Parent = $null
  }
}
if (-not $ChunkMap.ContainsKey('.')) { throw 'Root (.) is not a chunk in classification.tsv' }
foreach ($relativePath in @($ChunkMap.Keys)) {
  if ($relativePath -eq '.') { continue }
  $parentRel = Get-ParentRel $relativePath
  while (-not $ChunkMap.ContainsKey($parentRel)) { $parentRel = Get-ParentRel $parentRel }
  $ChunkMap[$relativePath].Parent = $ChunkMap[$parentRel]
  $ChunkMap[$parentRel].Kids.Add($ChunkMap[$relativePath])
}
foreach ($chunk in $ChunkMap.Values) {
  $chunk.Kids.Sort([Comparison[object]]{ param($left, $right) [string]::CompareOrdinal($left.Rel, $right.Rel) })
}
Write-Host "Pass 2: loaded $($N.Count) folders and $($ChunkMap.Count) chunks."

function Test-Collapsed($chunk) {
  return ($CollapseWrappers -and $chunk.Type -eq 'WRAPPER' -and $chunk.Rel -ne '.' -and $chunk.Kids.Count -eq 1)
}
function Resolve-Chunk($chunk) {
  while (Test-Collapsed $chunk) { $chunk = $chunk.Kids[0] }
  return $chunk
}
function Get-EffKids($chunk) {
  $children = New-Object 'System.Collections.Generic.List[object]'
  foreach ($child in $chunk.Kids) { $children.Add((Resolve-Chunk $child)) }
  return $children
}
function Get-EmittedParent($chunk) {
  $parent = $chunk.Parent
  while ($parent -and (Test-Collapsed $parent)) { $parent = $parent.Parent }
  return $parent
}

$Files = New-Object 'System.Collections.Generic.List[object]'
$Problems = New-Object 'System.Collections.Generic.List[string]'
$script:groupCount = 0
$script:collapsedCount = 0
function New-Item2($parentRel, $chunk) {
  $node = $chunk.Node
  $relativePath = Get-RelFrom $parentRel $chunk.Rel
  $description = '{0}, {1}, {2:N0} files' -f $chunk.Type, (Format-Size $node.SB), $node.SF
  if ($chunk.Nested) { $description += ', nested' }
  if ($chunk.Flags) { $description += ', ' + ($chunk.Flags -replace '\|', '/') }
  return @{
    Name = $relativePath.Replace('\', '/')
    Link = ((ConvertTo-Url $relativePath) + '/' + $LlmsFileName)
    Desc = $description
    Cold = ($chunk.Flags -match 'cold')
  }
}
function New-GroupFile($chunk, [string]$groupName, $members) {
  $title = if ($chunk.Rel -eq '.') { $rootName } else { Get-LeafName $chunk.Rel }
  $builder = New-Object System.Text.StringBuilder
  [void]$builder.Append("# $title / $groupName`n`n> Virtual group of $($members.Count) entries from $title, in alphabetical order ($($members[0].Name) to $($members[$members.Count-1].Name)).`n`n## Entries`n")
  foreach ($member in $members) {
    [void]$builder.Append("- [$(ConvertTo-LinkText $member.Name)](../$($member.Link)): $($member.Desc)`n")
  }
  [void]$builder.Append("`n<!-- generated by $Generator; group file, sidecar only -->`n")
  $Files.Add(@{
    Dir = $chunk.Rel; Sub = $groupName; Name = $LlmsFileName; Text = $builder.ToString()
    Links = $members.Count; Rel = $chunk.Rel + '/' + $groupName; Type = 'GROUP'; Bytes = $chunk.Node.SB
  })
}

foreach ($chunk in ($ChunkMap.Values | Sort-Object { $_.Rel })) {
  if (Test-Collapsed $chunk) { $script:collapsedCount++; continue }
  $node = $chunk.Node
  $relativePath = $chunk.Rel
  $title = if ($relativePath -eq '.') { $rootName } else { Get-LeafName $relativePath }
  $effectiveKids = Get-EffKids $chunk
  $items = New-Object 'System.Collections.Generic.List[object]'
  foreach ($child in $effectiveKids) { $items.Add((New-Item2 $relativePath $child)) }
  $groupNames = @(); $mainItems = @(); $optionalItems = @()
  if ($items.Count -gt $G) {
    $current = @($items | Sort-Object { $_.Name })
    while ($current.Count -gt $G) {
      $groupCount = [math]::Ceiling($current.Count / $G)
      $groupSize = [math]::Ceiling($current.Count / $groupCount)
      $next = @()
      for ($i = 0; $i -lt $current.Count; $i += $groupSize) {
        $members = @($current[$i..([math]::Min($i + $groupSize, $current.Count) - 1)])
        $script:groupCount++
        $groupName = '_g{0:D2}' -f ($groupNames.Count + 1)
        New-GroupFile $chunk $groupName $members
        $groupNames += $groupName
        $next += @{
          Name = $groupName; Link = "$groupName/$LlmsFileName"
          Desc = ('GROUP, {0} entries ({1} to {2})' -f $members.Count, $members[0].Name, $members[$members.Count-1].Name)
          Cold = $false
        }
      }
      $current = $next
    }
    $mainItems = $current
  } else {
    $mainItems = @($items | Where-Object { -not $_.Cold })
    $optionalItems = @($items | Where-Object { $_.Cold })
  }

  $readLinks = @()
  foreach ($readme in $node.Readmes.Split('|')) {
    if ($readme -and $readLinks.Count -lt $ReadmeMax) { $readLinks += $readme }
  }
  $used = $mainItems.Count + $optionalItems.Count + $readLinks.Count
  $budget = [math]::Max(0, $MaxEntries - $used)
  $candidates = @($node.Kids | Where-Object { -not $ChunkMap.ContainsKey($_.Rel) } | Sort-Object { -$_.SB })
  $subfolders = @(); $optionalSubfolders = @(); $omittedCount = 0; [long]$omittedBytes = 0
  foreach ($child in $candidates) {
    $leafName = Get-LeafName $child.Rel
    if ($child.SB -ge $ListMinBytes -and $budget -gt 0) {
      $entry = @{
        Name = $leafName; Link = ((ConvertTo-Url $leafName) + '/')
        Desc = ('{0}, {1:N0} files, {2}' -f (Format-Size $child.SB), $child.SF, (Get-TopExt $child 2))
      }
      if ($child.Crumbs -match 'Archive|Temp') { $optionalSubfolders += $entry }
      else { $subfolders += $entry }
      $budget--
    } else { $omittedCount++; $omittedBytes += $child.SB }
  }

  $builder = New-Object System.Text.StringBuilder
  [void]$builder.Append("# $title`n`n> TODO-SUMMARY`n`n")
  $pathShown = if ($relativePath -eq '.') { '.' } else { $relativePath.Replace('\', '/') }
  $pathText = if ($relativePath -eq '.') { '(scan root)' } else { $pathShown }
  $dates = ''; if ($node.MinW) { $dates = "; files last modified $($node.MinW) to $($node.MaxW)" }
  $flagsText = ''; if ($chunk.Flags) { $flagsText = ' Flags: ' + ($chunk.Flags -replace '\|', ', ') + '.' }
  [void]$builder.Append("Path: $pathText. Type: $($chunk.Type) ($($chunk.Rule)). $(Format-Size $node.SB) in $('{0:N0}' -f $node.SF) files$dates. Why: $($chunk.Why).$flagsText`n`n")
  $topExtensions = Get-TopExt $node 5
  if ($topExtensions) { [void]$builder.Append("Top file types by size: $topExtensions.`n`n") }
  if ($node.SM.ContainsKey('Repo') -and $chunk.Type -ne 'REPO') {
    [void]$builder.Append("Contains $($node.SM['Repo']) git repo(s) below this folder.`n`n")
  }
  if ($chunk.Type -in @('OPAQUE-BULK','BLOB','DATASET','MIXED-LEAF','REPO','PROJECT')) {
    [void]$builder.Append("Contents are not itemised file by file; use the sections below to navigate.`n`n")
  }
  $notListed = @()
  if ($omittedCount -gt 0) { $notListed += "$omittedCount smaller subfolder(s) totalling $(Format-Size $omittedBytes)" }
  if ($node.DF -gt 0) { $notListed += "$('{0:N0}' -f $node.DF) loose file(s) ($(Format-Size $node.DB)) directly in this folder" }
  if ($notListed.Count -gt 0) { [void]$builder.Append("Not listed: " + ($notListed -join ', and ') + ".`n`n") }
  if ($groupNames.Count -gt 0) {
    [void]$builder.Append("This folder has $($items.Count) chunk children, so they are listed through $($groupNames.Count) group file(s).`n`n")
  }
  $linkCount = 0
  if ($mainItems.Count) {
    [void]$builder.Append("## Chunks`n")
    foreach ($item in $mainItems) { [void]$builder.Append("- [$(ConvertTo-LinkText $item.Name)]($($item.Link)): $($item.Desc)`n"); $linkCount++ }
    [void]$builder.Append("`n")
  }
  if ($readLinks.Count) {
    [void]$builder.Append("## Key files`n")
    foreach ($readme in $readLinks) { [void]$builder.Append("- [$(ConvertTo-LinkText $readme)]($(ConvertTo-Url $readme)): readme-style file`n"); $linkCount++ }
    [void]$builder.Append("`n")
  }
  if ($subfolders.Count) {
    [void]$builder.Append("## Subfolders`n")
    foreach ($item in $subfolders) { [void]$builder.Append("- [$(ConvertTo-LinkText $item.Name)]($($item.Link)): $($item.Desc)`n"); $linkCount++ }
    [void]$builder.Append("`n")
  }
  if (($optionalItems.Count + $optionalSubfolders.Count) -gt 0) {
    [void]$builder.Append("## Optional`n")
    foreach ($item in ($optionalItems + $optionalSubfolders)) { [void]$builder.Append("- [$(ConvertTo-LinkText $item.Name)]($($item.Link)): $($item.Desc)`n"); $linkCount++ }
    [void]$builder.Append("`n")
  }
  [void]$builder.Append("<!-- generated by $Generator; summary pending (Pass 3) -->`n")
  if ($linkCount -gt $MaxEntries) { $Problems.Add("OVER CAP: $relativePath has $linkCount links") }

  $emittedParent = Get-EmittedParent $chunk
  $manifest = [ordered]@{
    id = $pathShown; name = $title; type = $chunk.Type; rule = $chunk.Rule; nested = $chunk.Nested; why = $chunk.Why
    parent = $(if ($emittedParent) { $emittedParent.Rel.Replace('\', '/') } else { $null })
    children = @($effectiveKids | ForEach-Object { $_.Rel.Replace('\', '/') })
    collapsedWrappers = @($chunk.Kids | Where-Object { Test-Collapsed $_ } | ForEach-Object { $_.Rel.Replace('\', '/') })
    groups = @($groupNames)
    subfoldersListed = @(($subfolders + $optionalSubfolders) | ForEach-Object { $_.Name })
    stats = [ordered]@{
      files = $node.SF; bytes = $node.SB; directFiles = $node.DF; directBytes = $node.DB
      minWrite = $node.MinW; maxWrite = $node.MaxW; omittedSubfolders = $omittedCount; omittedBytes = $omittedBytes
    }
    extFamilies = (Get-FamShares $node); topExt = (Get-TopExt $node 5)
    markers = $node.M; subMarkers = $node.SM; readmes = @($readLinks)
    crumbs = @($node.Crumbs.Split('|') | Where-Object { $_ })
    flags = @($chunk.Flags.Split('|') | Where-Object { $_ }); treeSig = $node.Sig
    summary = 'TODO'; generator = $Generator; links = $linkCount
  }
  $Files.Add(@{
    Dir = $relativePath; Sub = ''; Name = $LlmsFileName; Text = $builder.ToString()
    Links = $linkCount; Rel = $relativePath; Type = $chunk.Type; Bytes = $node.SB
  })
  $Files.Add(@{
    Dir = $relativePath; Sub = ''; Name = $ManifestFileName; Text = ($manifest | ConvertTo-Json -Depth 6)
    Links = 0; Rel = $relativePath; Type = 'MANIFEST'; Bytes = 0
  })
}

foreach ($file in $Files) {
  if ($file.Name -ne $LlmsFileName) { continue }
  $lines = $file.Text.Split("`n")
  if (-not $lines[0].StartsWith('# ')) { $Problems.Add("H1 not first: $($file.Rel)") }
  $h1Count = @($lines | Where-Object { $_ -match '^# ' }).Count
  if ($h1Count -ne 1) { $Problems.Add("expected 1 H1, found $h1Count`: $($file.Rel)") }
  $firstH2 = -1
  for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
    if ($lines[$lineIndex].StartsWith('## ')) { $firstH2 = $lineIndex; break }
  }
  if ($firstH2 -gt 0) { $beforeH2 = $lines[0..($firstH2 - 1)] } else { $beforeH2 = $lines }
  if (@($beforeH2 | Where-Object { $_ -match '^#{3,6} ' }).Count -gt 0) { $Problems.Add("heading before first H2: $($file.Rel)") }
  $linkCount = @($lines | Where-Object { $_ -match '^- \[' }).Count
  if ($linkCount -gt $MaxEntries) { $Problems.Add("link cap exceeded ($linkCount): $($file.Rel)") }
}

$llmsFiles = @($Files | Where-Object { $_.Name -eq $LlmsFileName })
$report = New-Object 'System.Collections.Generic.List[string]'
$report.Add("llms-tree Pass 2 $(if ($DryRun) { 'DRY RUN (nothing written)' } else { 'WRITE' })  chunks=$($ChunkMap.Count)  emitted=$($ChunkMap.Count - $script:collapsedCount)  collapsed wrappers=$($script:collapsedCount)  group files=$($script:groupCount)")
$report.Add("files to write: $($llmsFiles.Count) $LlmsFileName (incl. groups) + $(@($Files | Where-Object { $_.Name -eq $ManifestFileName }).Count) $ManifestFileName")
$report.Add("max links in one file: $(($llmsFiles | ForEach-Object { $_.Links } | Measure-Object -Maximum).Maximum)  (cap $MaxEntries)")
$report.Add("validation problems: $($Problems.Count)")
foreach ($problem in $Problems) { $report.Add("  - $problem") }

if ($DryRun) {
  $report | ForEach-Object { Write-Host $_ }
  $preview = @($llmsFiles | Where-Object { $_.Rel -eq '.' }) +
    @($llmsFiles | Where-Object { $_.Rel -ne '.' -and $_.Type -ne 'GROUP' } | Sort-Object { $_.Bytes } -Descending | Select-Object -First ($PreviewCount - 1))
  foreach ($file in $preview) {
    Write-Host ''
    Write-Host ("=================== PREVIEW: {0} ({1}) ===================" -f $file.Rel, $file.Type)
    Write-Host $file.Text
  }
  Write-Host ''
  Write-Host 'Dry run only. Set $DryRun = $false and run again to write the sidecar tree.'
} else {
  $treeRoot = Join-Path $runPath 'tree'
  if ($CleanTree -and (Test-Path -LiteralPath $treeRoot)) {
    [IO.Directory]::Delete((ConvertTo-LongPath $treeRoot), $true)
    Write-Host "Removed old sidecar tree: $treeRoot"
  }
  $idx = New-Object 'System.Collections.Generic.List[string]'
  $idx.Add("Rel`tType`tFile`tLinks`tBytes")
  foreach ($file in $Files) {
    $directory = $treeRoot
    if ($file.Dir -ne '.') {
      foreach ($segment in $file.Dir.Split('\')) { $directory = [IO.Path]::Combine($directory, $segment) }
    }
    if ($file.Sub) { $directory = [IO.Path]::Combine($directory, $file.Sub) }
    [void][IO.Directory]::CreateDirectory((ConvertTo-LongPath $directory))
    $filePath = [IO.Path]::Combine($directory, $file.Name)
    [IO.File]::WriteAllText((ConvertTo-LongPath $filePath), $file.Text, $utf8)
    if ($file.Name -eq $LlmsFileName) { $idx.Add("$($file.Rel)`t$($file.Type)`t$filePath`t$($file.Links)`t$($file.Bytes)") }
  }
  [IO.File]::WriteAllLines((Join-Path $runPath 'pass2-index.tsv'), $idx)
  [IO.File]::WriteAllLines((Join-Path $runPath 'pass2-report.txt'), $report)
  $report | ForEach-Object { Write-Host $_ }
  Write-Host "Wrote sidecar tree: $treeRoot"
}

# ------------------------------------------------------------------ POST 01: export mega-manifest and LPG graph
if ($DryRun) {
  Write-Host 'POST 01 skipped because Pass 2 is in dry-run mode.'
} else {
  $tree = Join-Path $runPath $TreeSubdir
  if (-not (Test-Path -LiteralPath $tree)) { throw "No tree folder at $tree (Pass 2 did not emit output)" }

  $manifestNodes = New-Object 'System.Collections.Generic.Dictionary[string, object]'
  $existingIds = New-Object 'System.Collections.Generic.Dictionary[string, bool]'
  foreach ($manifestPath in [IO.Directory]::EnumerateFiles((ConvertTo-LongPath $tree), $ManifestFileName, [IO.SearchOption]::AllDirectories)) {
    $manifestNode = [IO.File]::ReadAllText($manifestPath, $utf8) | ConvertFrom-Json
    $rawId = [string]$manifestNode.id
    $nodeId = if ($rawId -eq '.') { 'llms-root' } else { $rawId.Replace('\', '/') }
    $manifestNodes[$nodeId] = $manifestNode
    $existingIds[$nodeId] = $true
  }

  foreach ($nodeId in @($manifestNodes.Keys)) {
    if ($nodeId -eq 'llms-root') { continue }
    $parts = $nodeId -split '/'
    $currentPath = ''
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
      if ($currentPath -eq '') { $currentPath = $parts[$i] }
      else { $currentPath = "$currentPath/$($parts[$i])" }
      if (-not $existingIds.ContainsKey($currentPath)) {
        $syntheticManifest = [ordered]@{
          id = $currentPath; name = $parts[$i]; type = 'folder'; rule = 'gap-filler'; nested = $false
          parent = $(if ($i -eq 0) { 'llms-root' } else { $currentPath.Substring(0, $currentPath.LastIndexOf('/')) })
          summary = '(intermediate folder)'
          stats = [ordered]@{ files = 0; bytes = 0; directFiles = 0; minWrite = $null; maxWrite = $null }
          flags = @('gap-filler'); children = @(); readmes = @(); crumbs = @()
        }
        $manifestNodes[$currentPath] = [pscustomobject]$syntheticManifest
        $existingIds[$currentPath] = $true
      }
    }
  }

  if (-not $existingIds.ContainsKey('llms-root')) {
    $rootManifest = [ordered]@{
      id = '.'
      name = $(if ($runInfo -and $runInfo.Root) { (($runInfo.Root.TrimEnd('\', '/')) -split '[\\/]')[-1] } else { 'root' })
      type = 'folder'; rule = 'root'; nested = $false; parent = $null; summary = 'Root folder'
      stats = [ordered]@{ files = 0; bytes = 0; directFiles = 0; minWrite = $null; maxWrite = $null }
      flags = @(); children = @(); readmes = @(); crumbs = @()
    }
    $manifestNodes['llms-root'] = [pscustomobject]$rootManifest
    $existingIds['llms-root'] = $true
  }

  $items = New-Object 'System.Collections.Generic.List[object]'
  foreach ($nodeId in $manifestNodes.Keys) {
    $manifestNode = $manifestNodes[$nodeId]
    $rawId = [string]$manifestNode.id
    $cleanId = if ($rawId -eq '.') { 'llms-root' } else { $nodeId }
    $fileRel = if ($cleanId -eq 'llms-root') { $LlmsFileName } else { "$rawId/$LlmsFileName" }
    $nodeName = if ($manifestNode.name) { [string]$manifestNode.name } else { $cleanId }
    $depth = if ($cleanId -eq 'llms-root') { 0 } else { ($cleanId -split '/').Count }
    $colorIndex = [math]::Min($depth, $TierColors.Length - 1)
    $radiusIndex = [math]::Min($depth, $TierRadii.Length - 1)
    $nodeColor = $TierColors[$colorIndex]
    $nodeRadius = $TierRadii[$radiusIndex]
    $isSynthetic = ($manifestNode.rule -eq 'gap-filler')
    $bytesValue = if ($manifestNode.stats -and $manifestNode.stats.bytes) { [long]$manifestNode.stats.bytes } else { 0L }
    $filesValue = if ($manifestNode.stats -and $manifestNode.stats.files) { [long]$manifestNode.stats.files } else { 0L }

    $node = [ordered]@{
      id = $rawId; name = $nodeName; type = $manifestNode.type; rule = $manifestNode.rule
      nested = $manifestNode.nested; parent = $manifestNode.parent; summary = $manifestNode.summary; file = $fileRel
      files = $filesValue; bytes = $bytesValue
      flags = @($manifestNode.flags); treeSig = if ($manifestNode.treeSig) { $manifestNode.treeSig } else { '' }
      children = @($manifestNode.children)
    }
    $webappProps = [ordered]@{
      type = [string]$manifestNode.type; rule = [string]$manifestNode.rule
      summary = if ($manifestNode.summary) { [string]$manifestNode.summary } else { '' }
      bytes = $bytesValue; files = $filesValue; depth = $depth; isFiller = $isSynthetic
    }
    $webappNode = [ordered]@{
      id = $cleanId; label = $nodeName; x = 0.0; y = 0.0; color = $nodeColor; r = $nodeRadius
      fontSize = 11; labelAlign = 'center'; labelColor = ''; props = $webappProps
    }
    $jsonLine = $node | ConvertTo-Json -Compress -Depth 6
    $items.Add([pscustomobject]@{
      Id = $rawId; NodeId = $cleanId; Obj = $node; WebappNode = $webappNode; Json = $jsonLine
    })
  }
  $items = @($items | Sort-Object { $_.Id })
  Write-Host "POST 01: processed $($items.Count) nodes (including gap-fillers)."

  $edges = New-Object 'System.Collections.Generic.List[object]'
  $webappEdges = New-Object 'System.Collections.Generic.List[object]'
  $edgeCounter = 1
  foreach ($item in $items) {
    $currentId = $item.NodeId
    if ($currentId -eq 'llms-root') { continue }
    $lastSlash = $currentId.LastIndexOf('/')
    $parentId = if ($lastSlash -gt 0) { $currentId.Substring(0, $lastSlash) } else { 'llms-root' }
    if ($existingIds.ContainsKey($parentId)) {
      $edges.Add([pscustomobject]@{ from = $currentId; to = $parentId; rel = 'HAS_CHUNK' })
      $webappEdges.Add([pscustomobject]@{
        id = "edge-$edgeCounter"; source = $currentId; target = $parentId; label = ''
        directed = $true; style = 'straight'; dash = 'solid'; arrowSize = 'medium'; props = [ordered]@{}
      })
      $edgeCounter++
    }
  }

  [IO.File]::WriteAllLines((Join-Path $runPath 'mega-manifest.jsonl'), [string[]]@($items | ForEach-Object { $_.Json }), $utf8)
  $webappNodes = @($items | ForEach-Object { $_.WebappNode })
  $webappEdgesArray = $webappEdges.ToArray()
  $graphDocument = [ordered]@{
    nodes = $webappNodes; edges = $webappEdgesArray; idCounter = $edgeCounter; graphId = $GraphId
    graphMeta = [ordered]@{ edgedefault = 'undirected' }; exportName = $ExportName
    view = [ordered]@{ x = 0; y = 0; k = 1.0 }; clampNodeLabels = $false
  }
  $graphJson = $graphDocument | ConvertTo-Json -Depth 10
  [IO.File]::WriteAllText((Join-Path $runPath 'mega-manifest.json'), $graphJson, $utf8)

  $items | ForEach-Object {
    [pscustomobject]@{
      id = $_.Obj.id; name = $_.Obj.name; type = $_.Obj.type; bytes = $_.Obj.bytes
      files = $_.Obj.files; summary = $_.Obj.summary
    }
  } | Export-Csv -LiteralPath (Join-Path $runPath 'nodes.csv') -NoTypeInformation -Encoding UTF8
  $edges | Export-Csv -LiteralPath (Join-Path $runPath 'edges.csv') -NoTypeInformation -Encoding UTF8

  $catalog = New-Object System.Text.StringBuilder
  [void]$catalog.Append("# Catalogue of chunks`n`n> $($items.Count) nodes, $($edges.Count) parent-child links. Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm').`n`n")
  foreach ($item in $items) {
    $node = $item.Obj
    $catalogPath = ("$TreeSubdir/" + $node.file).Replace('/', '\')
    $link = ConvertTo-Url $catalogPath
    $nodeSummary = [string]$node.summary
    if (-not $nodeSummary) { $nodeSummary = '(no summary)' }
    [void]$catalog.Append("- [$($node.id)]($link) - $($node.type), $(Format-Size ([long]$node.bytes))`n  $nodeSummary`n")
  }
  [IO.File]::WriteAllText((Join-Path $runPath 'mega-catalog.md'), $catalog.ToString(), $utf8)

  Write-Host "POST 01 complete. LPG graph exports are in ${runPath}:"
  Write-Host '  - mega-manifest.json (LPG Webapp Graph format)'
  Write-Host '  - mega-manifest.jsonl'
  Write-Host '  - nodes.csv and edges.csv'
  Write-Host '  - mega-catalog.md'
  Write-Host 'LPG editor: https://actuallyfro.github.io/Break-FAST/Examples/01_GraphML-Editor/Single-page-Apps/AA_2026-REDUX/LPG-Editor.html'
}
}