& {
<#
  llms-tree  Pass 1  -  CLASSIFY (dry run). Reads folders.tsv from Pass 0, touches NO data files.
  PASTE-ABLE: no param(), no .ps1 needed. Edit VARIABLES, paste all.
  Writes next to folders.tsv:  classification.tsv  (every chunk + rule + reason)
                               classification-summary.txt  (counts, biggest chunks, tuning hints)
#>

# =====================================================================  VARIABLES (edit me)
$RunDir  = 'D:\llms-out\REPLACE-WITH-STAMP'     # the Pass 0 run folder that holds folders.tsv
$P = @{
  MinChunkBytes     = 500MB    # R-120  below this a folder is SUBSUMED (repos exempt)
  MaxLeafBytes      = 60GB     # R-125  non-stop folders at or below this close as a leaf (no deeper chunks)  <-- main granularity knob
  SigShare          = 0.10     # R-160  a child is "significant" if it holds >= this share of the parent's bytes
  NestedMinBytes    = 5GB      # R-155  stop-type chunks inside a closed PROJECT need at least this size (repos exempt)
  BulkMinFiles      = 500      # R-130
  BulkShare         = 0.90     # R-130  dominant family share by FILE COUNT
  BlobShare         = 0.90     # R-135  dominant family share by BYTES when files < BulkMinFiles (few huge files)
  DatasetShare      = 0.60     # R-140  sdr+data family share by BYTES
  MaxEntries        = 53       # R-210  first prime > 50 (checked in the summary)
  ColdAgeYears      = 5        # R-181
  TopN              = 25       # rows in the summary lists
}
# markers that count as "strong" breadcrumbs for PROJECT (R-150). Others in the manifest are ignored here.
$StrongMarkers       = @('Build')                       # own-folder marker categories
$StrongReadmeNames   = @('readme.md','readme.txt','readme.rst','readme.markdown')   # bare 'README' is treated as noise
$DatasetMarkers      = @('SDR')                          # SubMarkers categories that force DATASET
$ExtFamilies = @{
  image   = '.png .jpg .jpeg .gif .bmp .tif .tiff .webp .heic .raw .cr2 .nef .dng .dds .tga .psd'
  video   = '.mp4 .mkv .avi .mov .wmv .m4v .webm .bik .bk2 .usm'
  audio   = '.mp3 .wav .flac .aac .ogg .m4a .wem .bnk .xwm'
  doc     = '.pdf .doc .docx .xls .xlsx .ppt .pptx .txt .md .rtf .csv'
  archive = '.zip .7z .rar .tar .gz .tgz .bz2 .iso .rpf .vpk .pak .ucas .ba2 .bsa .gma .pkg .assetbundle .bundle .ress .resource .fbq .sbt .pak2 .scm'
  sdr     = '.cfile .iq .sigmf-data .sigmf-meta .cf32 .fc32 .cs16 .cu8 .grc'
  data    = '.mat .h5 .hdf5 .npy .npz .parquet .sqlite .sqlite3'
  code    = '.py .m .ps1 .c .cpp .h .cs .java .js .ts .go .rs .sh .ipynb'
}
# =====================================================================  END VARIABLES

$ErrorActionPreference = 'Stop'
$fam = @{}
foreach ($f in $ExtFamilies.Keys) { foreach ($e in $ExtFamilies[$f].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) { $fam[$e] = $f } }

function ConvertFrom-Counts([string]$s) {
  $h = @{}; if (-not $s) { return $h }
  foreach ($p in $s.Split(';')) { $q = $p.Split('='); if ($q.Count -eq 2) { $h[$q[0]] = [long]$q[1] } }
  return $h
}
function ConvertFrom-Hist([string]$s) {
  $h = @{}; if (-not $s) { return $h }
  foreach ($p in $s.Split(';')) { $q = $p.Split(':'); if ($q.Count -ge 3) { $h[$q[0]] = [long[]]@([long]$q[1], [long]$q[2]) } }
  return $h
}
function Get-Shares($node) {
  # returns @{ Top; TopCountShare; TopByteShare; DataShare }
  $fc = @{}; $fb = @{}
  foreach ($k in $node.E.Keys) {
    if ($k -eq '(other)') { $f = '(other)' } elseif ($fam.ContainsKey($k)) { $f = $fam[$k] } else { $f = "other:$k" }
    $fc[$f] = [long]$fc[$f] + $node.E[$k][0]; $fb[$f] = [long]$fb[$f] + $node.E[$k][1]
  }
  $topC = ''; $maxC = 0L; foreach ($k in $fc.Keys) { if ($fc[$k] -gt $maxC) { $maxC = $fc[$k]; $topC = $k } }
  $topB = ''; $maxB = 0L; foreach ($k in $fb.Keys) { if ($fb[$k] -gt $maxB) { $maxB = $fb[$k]; $topB = $k } }
  $ds = [long]$fb['sdr'] + [long]$fb['data']
  return @{ TopC = $topC; CShare = $(if ($node.SF -gt 0) { $maxC / $node.SF } else { 0 }); TopB = $topB
           BShare = $(if ($node.SB -gt 0) { $maxB / $node.SB } else { 0 }); DShare = $(if ($node.SB -gt 0) { $ds / $node.SB } else { 0 }) }
}
function Test-Noise([string]$f) { return ($f -eq '(other)' -or $f.StartsWith('other:')) }

# ---------------------------------------------------------------- load manifest
$path = Join-Path $RunDir 'folders.tsv'
if (-not (Test-Path -LiteralPath $path)) { throw "folders.tsv not found in $RunDir" }
$rows = Import-Csv -LiteralPath $path -Delimiter "`t"
$N = @{}
foreach ($r in $rows) {
  $node = @{ Rel = $r.RelPath; Depth = [int]$r.Depth; SB = [long]$r.SubBytes; SF = [long]$r.SubFiles; DF = [long]$r.DirectFiles
             M = (ConvertFrom-Counts $r.Markers); SM = (ConvertFrom-Counts $r.SubMarkers); E = (ConvertFrom-Hist $r.SubExt)
             Readmes = $r.Readmes; Crumbs = $r.NameCrumbs; MaxWrite = $r.MaxWrite; MinWrite = $r.MinWrite; Kids = (New-Object 'System.Collections.Generic.List[object]') }
  $N[$r.RelPath] = $node
}
foreach ($k in $N.Keys) {
  if ($k -eq '.') { continue }
  $i = $k.LastIndexOf('\'); if ($i -lt 0) { $par = '.' } else { $par = $k.Substring(0, $i) }
  if ($N.ContainsKey($par)) { $N[$par].Kids.Add($N[$k]) }
}
Write-Host "Loaded $($N.Count) folders."

# ---------------------------------------------------------------- classifier
$script:Out = New-Object 'System.Collections.Generic.List[object]'
function Add-Chunk($node, [string]$type, [string]$rule, [string]$why) {
  $flags = @()
  if ($node.Crumbs -match 'Archive|Temp') { $flags += 'cold' }
  if ($node.MaxWrite) { try { if ([datetime]::ParseExact($node.MaxWrite,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture) -lt (Get-Date).AddYears(-$P.ColdAgeYears)) { $flags += 'cold-age' } } catch {} }
  $script:Out.Add([pscustomobject]@{ Rel = $node.Rel; Depth = $node.Depth; Type = $type; Rule = $rule; Bytes = $node.SB; Files = $node.SF
                                      Flags = (($flags | Select-Object -Unique) -join '|'); Why = $why })
}
function Get-StopType($node) {
  if ($node.M.ContainsKey('Repo')) { return @('REPO','R-110','Repo marker in this folder') }
  if ($node.SF -eq 0) { return $null }
  $noRepoBelow = (-not $node.SM.ContainsKey('Repo'))
  $s = Get-Shares $node
  if ($node.SF -ge $P.BulkMinFiles -and $s.CShare -ge $P.BulkShare -and $noRepoBelow -and -not (Test-Noise $s.TopC)) {
    return @('OPAQUE-BULK','R-130', ("{0:P0} of {1:N0} files are {2}" -f $s.CShare, $node.SF, $s.TopC)) }
  if ($node.SF -lt $P.BulkMinFiles -and $s.BShare -ge $P.BlobShare -and $noRepoBelow -and -not (Test-Noise $s.TopB)) {
    return @('BLOB','R-135', ("{0:P0} of bytes are {1} in only {2:N0} files" -f $s.BShare, $s.TopB, $node.SF)) }
  $hasDs = $false; foreach ($c in $DatasetMarkers) { if ($node.SM.ContainsKey($c)) { $hasDs = $true } }
  if ($s.DShare -ge $P.DatasetShare -or $hasDs) { return @('DATASET','R-140', ("sdr+data bytes {0:P0}; markers {1}" -f $s.DShare, ($DatasetMarkers -join ','))) }
  return $null
}
function Test-StrongProject($node) {
  foreach ($c in $StrongMarkers) { if ($node.M.ContainsKey($c)) { return $true } }
  foreach ($n in $node.Readmes.Split('|')) { if ($n -and ($StrongReadmeNames -contains $n.ToLowerInvariant())) { return $true } }
  return $false
}
function Add-NestedRepos($node) {
  foreach ($k in $node.Kids) { if ($k.M.ContainsKey('Repo')) { Add-Chunk $k 'REPO' 'R-110n' 'nested repo inside a closed chunk' } else { Add-NestedRepos $k } }
}
function Add-NestedStops($node) {
  foreach ($k in $node.Kids) {
    if ($k.SB -lt $P.MinChunkBytes -and -not $k.M.ContainsKey('Repo')) { continue }
    $st = Get-StopType $k
    if ($st -and ($st[0] -eq 'REPO' -or $k.SB -ge $P.NestedMinBytes)) { Add-Chunk $k ($st[0] + '(nested)') 'R-155' $st[2] } else { Add-NestedStops $k }
  }
}
# returns the chunk type of $node (or $null if SUBSUMED)
function Invoke-Classify($node) {
  if ($node.SB -lt $P.MinChunkBytes -and -not $node.M.ContainsKey('Repo')) { return $null }       # R-120
  $st = Get-StopType $node
  if ($st) { Add-Chunk $node $st[0] $st[1] $st[2]; return $st[0] }                                   # R-110/130/135/140
  if ($node.Depth -gt 0 -and (Test-StrongProject $node)) {                                           # R-150
    Add-Chunk $node 'PROJECT' 'R-150' ("breadcrumbs: markers={0} readmes={1}" -f (($node.M.Keys | Sort-Object) -join ','), $node.Readmes)
    Add-NestedStops $node; return 'PROJECT' }
  if ($node.Depth -gt 0 -and $node.SB -le $P.MaxLeafBytes) {                                         # R-125
    Add-Chunk $node 'MIXED-LEAF' 'R-125' ("<= MaxLeafBytes ({0:N1} GB)" -f ($node.SB / 1GB)); Add-NestedRepos $node; return 'MIXED-LEAF' }
  $idx = $script:Out.Count; $script:Out.Add($null); $mark = $script:Out.Count
  $sig = 0; $sigTypes = @()
  foreach ($k in $node.Kids) {
    $t = Invoke-Classify $k
    if ($t -and $k.SB -ge ($P.SigShare * $node.SB)) { $sig++; $sigTypes += $t }
  }
  if ($sig -ge 2 -or $node.Depth -eq 0 -or ($sig -eq 1 -and ($sigTypes[0] -eq 'CONTAINER' -or $sigTypes[0] -eq 'WRAPPER'))) {   # R-160
    if ($sig -ge 2) { $ty = 'CONTAINER' } else { $ty = 'WRAPPER' }
    $tmpNode = [pscustomobject]@{ Rel = $node.Rel; Depth = $node.Depth; Type = $ty; Rule = 'R-160'; Bytes = $node.SB; Files = $node.SF; Flags = ''
                                  Why = ("{0} significant chunk child(ren) (>= {1:P0} of {2:N1} GB)" -f $sig, $P.SigShare, ($node.SB / 1GB)) }
    $script:Out[$idx] = $tmpNode; return $ty }
  # not enough structure below: close as a leaf, keep only nested repos
  $script:Out.RemoveRange($mark, $script:Out.Count - $mark)
  Add-Chunk $node 'MIXED-LEAF' 'R-170' 'no >=2 significant chunk children'; Add-NestedRepos $node
  return 'MIXED-LEAF'
}

$null = Invoke-Classify $N['.']
$chunks = @($script:Out | Where-Object { $_ -ne $null })

# ---------------------------------------------------------------- outputs
$tsv = Join-Path $RunDir 'classification.tsv'
$chunks | Select-Object Rel, Depth, Type, Rule, @{n='GB';e={[math]::Round($_.Bytes/1GB,2)}}, Files, Flags, Why |
  Export-Csv -LiteralPath $tsv -Delimiter "`t" -NoTypeInformation -Encoding UTF8

$sum = New-Object 'System.Collections.Generic.List[string]'
$sum.Add("llms-tree Pass 1 dry run   folders=$($N.Count)   chunks=$($chunks.Count)   ($($rows.Count) manifest rows)")
$sum.Add("Params: " + (($P.Keys | Sort-Object | ForEach-Object { "$_=$($P[$_])" }) -join '  '))
$sum.Add(''); $sum.Add('--- chunks by type')
$chunks | Group-Object Type | Sort-Object Count -Descending | ForEach-Object { $sum.Add(("{0,-18}{1,6}   {2,10:N1} GB" -f $_.Name, $_.Count, (($_.Group | Measure-Object Bytes -Sum).Sum / 1GB))) }
$sum.Add(''); $sum.Add('--- chunks by depth')
$chunks | Group-Object Depth | Sort-Object { [int]$_.Name } | ForEach-Object { $sum.Add(("depth {0,-3}{1,6}" -f $_.Name, $_.Count)) }
$sum.Add(''); $sum.Add("--- largest $($P.TopN) chunks")
$chunks | Sort-Object Bytes -Descending | Select-Object -First $P.TopN | ForEach-Object { $sum.Add(("{0,-12}{1,8:N1} GB {2,9:N0} files  {3}" -f $_.Type, ($_.Bytes/1GB), $_.Files, $_.Rel)) }
$sum.Add(''); $sum.Add('--- fan-out check (children chunks per parent chunk, limit ' + $P.MaxEntries + ')')
$byParent = @{}
foreach ($c in $chunks) { if ($c.Rel -ne '.') { $i = $c.Rel.LastIndexOf('\'); if ($i -lt 0) { $pp = '.' } else { $pp = $c.Rel.Substring(0, $i) }; $byParent[$pp] = 1 + [int]$byParent[$pp] } }
$over = $byParent.GetEnumerator() | Where-Object { $_.Value -gt $P.MaxEntries }
if ($over) { $over | ForEach-Object { $sum.Add("OVER: $($_.Key) -> $($_.Value) direct chunk children (R-211 grouping needed)") } } else { $sum.Add('ok: no parent exceeds the cap (direct children only; nested links not counted)') }
$sum.Add(''); $sum.Add('--- cold-flagged chunks: ' + (@($chunks | Where-Object { $_.Flags }).Count))
$sum.Add('--- tuning: raise MaxLeafBytes for fewer/bigger chunks, lower it for finer chunks; see classification.tsv "Why" column')
[IO.File]::WriteAllLines((Join-Path $RunDir 'classification-summary.txt'), $sum)
$sum | ForEach-Object { Write-Host $_ }
Write-Host "Wrote $tsv"
}
