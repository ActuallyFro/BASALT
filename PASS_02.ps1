& {
<#
  llms-tree  Pass 2  -  EMIT llms.txt + llms-manifest.json into the SIDECAR tree. Reads Pass 0 + Pass 1 output only.
  PASTE-ABLE: no param(), no .ps1 needed. Edit VARIABLES, paste all.
  $DryRun = $true (default) writes NOTHING: it prints a plan, validation results and sample renderings.
  Writes (when $DryRun = $false):  <RunDir>\tree\<same relative path>\llms.txt + llms-manifest.json
                                   <RunDir>\tree\...\_gNN\llms.txt   (virtual groups when a chunk has too many children)
                                   <RunDir>\pass2-index.tsv, pass2-report.txt
  Links are RELATIVE and written as if the file sat inside the source folder (so a later "publish" can copy them in place).
  Summaries are left as "> TODO-SUMMARY" for Pass 3 (local LLM).
#>

# =====================================================================  VARIABLES (edit me)
$RunDir          = 'C:\Users\zasz_\llms-out\20261031-124239'   # Pass 0 run folder (must contain folders.tsv AND classification.tsv from Pass 1)
$DryRun          = $false                      # $false = actually write files
$CleanTree       = $true                       # $true = delete the old <RunDir>\tree first (sidecar only) so renamed/stale files do not linger
$LlmsFileName     = 'llms-txt.md'   # sidecar name (VS Code previews .md). Rename to 'llms.txt' at publish time if agents must fetch /llms.txt
$ManifestFileName = 'llms-manifest.json'
$MaxEntries       = 53       # first prime > 50: hard cap on links per llms.txt
$ReserveEntries   = 6        # links kept free for README + subfolder entries before a chunk is forced into groups (R-211)
$ReadmeMax        = 3
$ListMinBytes     = 50MB     # subfolders smaller than this are counted but not listed
$CollapseWrappers = $true    # a non-root WRAPPER with exactly 1 chunk child is skipped; its parent links straight to the child
$PreviewCount     = 3        # dry run: how many llms.txt files to print in full
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
$Generator = 'llms-tree pass2 0.2'
$fam = @{}
foreach ($f in $ExtFamilies.Keys) { foreach ($e in $ExtFamilies[$f].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) { $fam[$e] = $f } }
$G = $MaxEntries - $ReserveEntries

# ---------------------------------------------------------------- helpers
function ConvertFrom-Counts([string]$s) { $h = @{}; if (-not $s) { return $h }; foreach ($p in $s.Split(';')) { $q = $p.Split('='); if ($q.Count -eq 2) { $h[$q[0]] = [long]$q[1] } }; return $h }
function ConvertFrom-Hist([string]$s) { $h = @{}; if (-not $s) { return $h }; foreach ($p in $s.Split(';')) { $q = $p.Split(':'); if ($q.Count -ge 3) { $h[$q[0]] = [long[]]@([long]$q[1], [long]$q[2]) } }; return $h }
function Format-Size([long]$b) {
  if ($b -ge 1TB) { return ('{0:N1} TB' -f ($b / 1TB)) }
  if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
  if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }
  if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
  return "$b B"
}
function ConvertTo-Url([string]$rel) {
  # .NET Framework (PS 5.1) leaves ! * ' ( ) unescaped; parentheses would break markdown links, so escape them explicitly
  return (($rel.Split('\') | ForEach-Object { [uri]::EscapeDataString($_).Replace('(', '%28').Replace(')', '%29').Replace("'", '%27').Replace('!', '%21').Replace('*', '%2A') }) -join '/')
}
function ConvertTo-LinkText([string]$s) { return $s.Replace('[', '\[').Replace(']', '\]') }
function Get-ParentRel([string]$rel) { $i = $rel.LastIndexOf('\'); if ($i -lt 0) { return '.' }; return $rel.Substring(0, $i) }
function Get-LeafName([string]$rel) { $i = $rel.LastIndexOf('\'); if ($i -lt 0) { return $rel }; return $rel.Substring($i + 1) }
function Get-RelFrom([string]$parent, [string]$child) { if ($parent -eq '.') { return $child }; return $child.Substring($parent.Length + 1) }
function ConvertTo-LongPath([string]$p) {
  if ([IO.Path]::DirectorySeparatorChar -ne '\') { return $p }
  if ($p.StartsWith('\\?\')) { return $p }
  if ($p.StartsWith('\\')) { return '\\?\UNC\' + $p.Substring(2) }
  return '\\?\' + $p
}
function Get-TopExt($node, [int]$n) {
  $items = $node.E.GetEnumerator() | Where-Object { $_.Key -ne '(other)' } | Sort-Object @{Expression={$_.Value[1]};Descending=$true} | Select-Object -First $n
  $out = @(); foreach ($i in $items) { if ($node.SB -gt 0) { $out += ('{0} {1:P0}' -f $i.Key, ($i.Value[1] / $node.SB)) } }
  return ($out -join ', ')
}
function Get-FamShares($node) {
  $fb = @{}
  foreach ($k in $node.E.Keys) { if ($k -eq '(other)') { $f = 'other' } elseif ($fam.ContainsKey($k)) { $f = $fam[$k] } else { $f = 'other' }; $fb[$f] = [long]$fb[$f] + $node.E[$k][1] }
  $o = [ordered]@{}; foreach ($k in ($fb.Keys | Sort-Object { -$fb[$_] })) { if ($node.SB -gt 0) { $o[$k] = [math]::Round($fb[$k] / $node.SB, 3) } }
  return $o
}

# ---------------------------------------------------------------- load
$pF = Join-Path $RunDir 'folders.tsv'; $pC = Join-Path $RunDir 'classification.tsv'
if (-not (Test-Path -LiteralPath $pF)) { throw "folders.tsv not found in $RunDir" }
if (-not (Test-Path -LiteralPath $pC)) { throw "classification.tsv not found in $RunDir (run Pass 1 first)" }
$rootName = 'root'
$pR = Join-Path $RunDir 'run.json'
if (Test-Path -LiteralPath $pR) { try { $rj = Get-Content -LiteralPath $pR -Raw | ConvertFrom-Json; if ($rj.Root) { $rootName = (($rj.Root.TrimEnd('\', '/')) -split '[\\/]')[-1]; if (-not $rootName) { $rootName = $rj.Root } } } catch {} }
$NodeMap = @{}
foreach ($r in (Import-Csv -LiteralPath $pF -Delimiter "`t")) {
  $NodeMap[$r.RelPath] = @{ Rel = $r.RelPath; Depth = [int]$r.Depth; SB = [long]$r.SubBytes; SF = [long]$r.SubFiles; DF = [long]$r.DirectFiles; DB = [long]$r.DirectBytes
                      M = (ConvertFrom-Counts $r.Markers); SM = (ConvertFrom-Counts $r.SubMarkers); E = (ConvertFrom-Hist $r.SubExt)
                      Readmes = $r.Readmes; Crumbs = $r.NameCrumbs; MinW = $r.MinWrite; MaxW = $r.MaxWrite; Sig = $r.TreeSig
                      Kids = (New-Object 'System.Collections.Generic.List[object]') }
}
foreach ($k in $NodeMap.Keys) { if ($k -ne '.') { $par = Get-ParentRel $k; if ($NodeMap.ContainsKey($par)) { $NodeMap[$par].Kids.Add($NodeMap[$k]) } } }
$ChunkMap = @{}
foreach ($r in (Import-Csv -LiteralPath $pC -Delimiter "`t")) {
  if ($ChunkMap.ContainsKey($r.Rel)) { continue }
  if (-not $NodeMap.ContainsKey($r.Rel)) { Write-Warning "classification row not in manifest: $($r.Rel)"; continue }
  $ChunkMap[$r.Rel] = @{ Rel = $r.Rel; Type = ($r.Type -replace '\(nested\)', ''); Nested = ($r.Type -match 'nested'); Rule = $r.Rule; Why = $r.Why; Flags = $r.Flags
                  Node = $NodeMap[$r.Rel]; Kids = (New-Object 'System.Collections.Generic.List[object]'); Parent = $null }
}
if (-not $ChunkMap.ContainsKey('.')) { throw 'Root (.) is not a chunk in classification.tsv' }
$Anc = @{}
foreach ($rel in @($ChunkMap.Keys)) {
  if ($rel -eq '.') { continue }
  $p = Get-ParentRel $rel
  while (-not $ChunkMap.ContainsKey($p)) { $p = Get-ParentRel $p }
  $ChunkMap[$rel].Parent = $ChunkMap[$p]; $ChunkMap[$p].Kids.Add($ChunkMap[$rel])
  $a = Get-ParentRel $rel; while ($a -ne '.') { $Anc[$a] = 1; $a = Get-ParentRel $a }
}
foreach ($c in $ChunkMap.Values) { $c.Kids.Sort([Comparison[object]]{ param($x, $y) [string]::CompareOrdinal($x.Rel, $y.Rel) }) }
Write-Host "Loaded $($NodeMap.Count) folders, $($ChunkMap.Count) chunks."

function Test-Collapsed($c) { return ($CollapseWrappers -and $c.Type -eq 'WRAPPER' -and $c.Rel -ne '.' -and $c.Kids.Count -eq 1) }
function Resolve-Chunk($c) { while (Test-Collapsed $c) { $c = $c.Kids[0] }; return $c }
function Get-EffKids($c) { $o = New-Object 'System.Collections.Generic.List[object]'; foreach ($k in $c.Kids) { $o.Add((Resolve-Chunk $k)) }; return $o }
function Get-EmittedParent($c) { $p = $c.Parent; while ($p -and (Test-Collapsed $p)) { $p = $p.Parent }; return $p }

$Files = New-Object 'System.Collections.Generic.List[object]'   # @{ Dir=<rel>; Name; Text }
$Index = New-Object 'System.Collections.Generic.List[object]'
$Problems = New-Object 'System.Collections.Generic.List[string]'
$script:groupCount = 0; $script:collapsedCount = 0

function New-Item2($parentRel, $c) {
  $n = $c.Node; $rel = Get-RelFrom $parentRel $c.Rel
  $d = '{0}, {1}, {2:N0} files' -f $c.Type, (Format-Size $n.SB), $n.SF
  if ($c.Nested) { $d += ', nested' }
  if ($c.Flags) { $d += ', ' + ($c.Flags -replace '\|', '/') }
  return @{ Name = $rel.Replace('\', '/'); Link = ((ConvertTo-Url $rel) + '/' + $LlmsFileName); Desc = $d; Cold = ($c.Flags -match 'cold') }
}
function New-GroupFile($c, [string]$gname, $members) {
  $n = $c.Node; $title = if ($c.Rel -eq '.') { $rootName } else { Get-LeafName $c.Rel }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append("# $title / $gname`n`n> Virtual group of $($members.Count) entries from $title, in alphabetical order ($($members[0].Name) to $($members[$members.Count-1].Name)).`n`n## Entries`n")
  foreach ($m in $members) { [void]$sb.Append("- [$(ConvertTo-LinkText $m.Name)](../$($m.Link)): $($m.Desc)`n") }
  [void]$sb.Append("`n<!-- generated by $Generator; group file, sidecar only -->`n")
  $Files.Add(@{ Dir = $c.Rel; Sub = $gname; Name = $LlmsFileName; Text = $sb.ToString(); Links = $members.Count; Rel = $c.Rel + '/' + $gname; Type = 'GROUP'; Bytes = $n.SB })
}

foreach ($c in ($ChunkMap.Values | Sort-Object { $_.Rel })) {
  if (Test-Collapsed $c) { $script:collapsedCount++; continue }
  $n = $c.Node; $rel = $c.Rel
  $title = if ($rel -eq '.') { $rootName } else { Get-LeafName $rel }
  $eff = Get-EffKids $c
  $items = New-Object 'System.Collections.Generic.List[object]'
  foreach ($k in $eff) { $items.Add((New-Item2 $rel $k)) }
  $groupNames = @(); $mainItems = @(); $optItems = @()
  if ($items.Count -gt $G) {
    $cur = @($items | Sort-Object { $_.Name })
    while ($cur.Count -gt $G) {
      $kc = [math]::Ceiling($cur.Count / $G); $sz = [math]::Ceiling($cur.Count / $kc); $next = @()
      for ($i = 0; $i -lt $cur.Count; $i += $sz) {
        $mem = @($cur[$i..([math]::Min($i + $sz, $cur.Count) - 1)])
        $script:groupCount++; $gn = '_g{0:D2}' -f ($groupNames.Count + 1)
        New-GroupFile $c $gn $mem
        $groupNames += $gn
        $next += @{ Name = $gn; Link = "$gn/$LlmsFileName"; Desc = ('GROUP, {0} entries ({1} to {2})' -f $mem.Count, $mem[0].Name, $mem[$mem.Count-1].Name); Cold = $false }
      }
      $cur = $next
    }
    $mainItems = $cur
  } else {
    $mainItems = @($items | Where-Object { -not $_.Cold }); $optItems = @($items | Where-Object { $_.Cold })
  }
  # readmes
  $readLinks = @()
  foreach ($rn in $n.Readmes.Split('|')) { if ($rn -and $readLinks.Count -lt $ReadmeMax) { $readLinks += $rn } }
  # subfolders (not chunks, no chunk below)
  $used = $mainItems.Count + $optItems.Count + $readLinks.Count
  $budget = [math]::Max(0, $MaxEntries - $used)
  $cand = @($n.Kids | Where-Object { -not $ChunkMap.ContainsKey($_.Rel) } | Sort-Object { -$_.SB })
  $subs = @(); $subOpt = @(); $omitN = 0; [long]$omitB = 0
  foreach ($k in $cand) {
    $leaf = Get-LeafName $k.Rel
    if ($k.SB -ge $ListMinBytes -and $budget -gt 0) {
      $e = @{ Name = $leaf; Link = ((ConvertTo-Url $leaf) + '/'); Desc = ('{0}, {1:N0} files, {2}' -f (Format-Size $k.SB), $k.SF, (Get-TopExt $k 2)) }
      if ($k.Crumbs -match 'Archive|Temp') { $subOpt += $e } else { $subs += $e }
      $budget--
    } else { $omitN++; $omitB += $k.SB }
  }
  # ---- text
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append("# $title`n`n> TODO-SUMMARY`n`n")
  $pathShown = if ($rel -eq '.') { '.' } else { $rel.Replace('\', '/') }
  $pathText = if ($rel -eq '.') { '(scan root)' } else { $pathShown }
  $dates = ''; if ($n.MinW) { $dates = "; files last modified $($n.MinW) to $($n.MaxW)" }
  $fl = ''; if ($c.Flags) { $fl = ' Flags: ' + ($c.Flags -replace '\|', ', ') + '.' }
  [void]$sb.Append("Path: $pathText. Type: $($c.Type) ($($c.Rule)). $(Format-Size $n.SB) in $('{0:N0}' -f $n.SF) files$dates. Why: $($c.Why).$fl`n`n")
  $te = Get-TopExt $n 5; if ($te) { [void]$sb.Append("Top file types by size: $te.`n`n") }
  if ($n.SM.ContainsKey('Repo') -and $c.Type -ne 'REPO') { [void]$sb.Append("Contains $($n.SM['Repo']) git repo(s) below this folder.`n`n") }
  if ($c.Type -in @('OPAQUE-BULK','BLOB','DATASET','MIXED-LEAF','REPO','PROJECT')) { [void]$sb.Append("Contents are not itemised file by file; use the sections below to navigate.`n`n") }
  $np = @()
  if ($omitN -gt 0) { $np += "$omitN smaller subfolder(s) totalling $(Format-Size $omitB)" }
  if ($n.DF -gt 0) { $np += "$('{0:N0}' -f $n.DF) loose file(s) ($(Format-Size $n.DB)) directly in this folder" }
  if ($np.Count -gt 0) { [void]$sb.Append("Not listed: " + ($np -join ', and ') + ".`n`n") }
  if ($groupNames.Count -gt 0) { [void]$sb.Append("This folder has $($items.Count) chunk children, so they are listed through $($groupNames.Count) group file(s).`n`n") }
  $links = 0
  if ($mainItems.Count) { [void]$sb.Append("## Chunks`n"); foreach ($i in $mainItems) { [void]$sb.Append("- [$(ConvertTo-LinkText $i.Name)]($($i.Link)): $($i.Desc)`n"); $links++ }; [void]$sb.Append("`n") }
  if ($readLinks.Count) { [void]$sb.Append("## Key files`n"); foreach ($r in $readLinks) { [void]$sb.Append("- [$(ConvertTo-LinkText $r)]($(ConvertTo-Url $r)): readme-style file`n"); $links++ }; [void]$sb.Append("`n") }
  if ($subs.Count) { [void]$sb.Append("## Subfolders`n"); foreach ($i in $subs) { [void]$sb.Append("- [$(ConvertTo-LinkText $i.Name)]($($i.Link)): $($i.Desc)`n"); $links++ }; [void]$sb.Append("`n") }
  if (($optItems.Count + $subOpt.Count) -gt 0) { [void]$sb.Append("## Optional`n"); foreach ($i in ($optItems + $subOpt)) { [void]$sb.Append("- [$(ConvertTo-LinkText $i.Name)]($($i.Link)): $($i.Desc)`n"); $links++ }; [void]$sb.Append("`n") }
  [void]$sb.Append("<!-- generated by $Generator; summary pending (Pass 3) -->`n")
  if ($links -gt $MaxEntries) { $Problems.Add("OVER CAP: $rel has $links links") }
  $segs = if ($rel -eq '.') { @() } else { $rel.Split('\') }
  # ---- manifest
  $ep = Get-EmittedParent $c
  $man = [ordered]@{
    id = $pathShown; name = $title; type = $c.Type; rule = $c.Rule; nested = $c.Nested; why = $c.Why
    parent = $(if ($ep) { $ep.Rel.Replace('\', '/') } else { $null })
    children = @($eff | ForEach-Object { $_.Rel.Replace('\', '/') })
    collapsedWrappers = @($c.Kids | Where-Object { Test-Collapsed $_ } | ForEach-Object { $_.Rel.Replace('\', '/') })
    groups = @($groupNames)
    subfoldersListed = @(($subs + $subOpt) | ForEach-Object { $_.Name })
    stats = [ordered]@{ files = $n.SF; bytes = $n.SB; directFiles = $n.DF; directBytes = $n.DB; minWrite = $n.MinW; maxWrite = $n.MaxW; omittedSubfolders = $omitN; omittedBytes = $omitB }
    extFamilies = (Get-FamShares $n); topExt = (Get-TopExt $n 5)
    markers = $n.M; subMarkers = $n.SM; readmes = @($readLinks); crumbs = @($n.Crumbs.Split('|') | Where-Object { $_ })
    flags = @($c.Flags.Split('|') | Where-Object { $_ }); treeSig = $n.Sig
    summary = 'TODO'; generator = $Generator; links = $links
  }
  $Files.Add(@{ Dir = $rel; Sub = ''; Name = $LlmsFileName; Text = $sb.ToString(); Links = $links; Rel = $rel; Type = $c.Type; Bytes = $n.SB })
  $Files.Add(@{ Dir = $rel; Sub = ''; Name = $ManifestFileName; Text = ($man | ConvertTo-Json -Depth 6); Links = 0; Rel = $rel; Type = 'MANIFEST'; Bytes = 0 })
}

# ---------------------------------------------------------------- validation
foreach ($f in $Files) {
  if ($f.Name -ne $LlmsFileName) { continue }
  $lines = $f.Text.Split("`n")
  if (-not $lines[0].StartsWith('# ')) { $Problems.Add("H1 not first: $($f.Rel)") }
  $h1 = @($lines | Where-Object { $_ -match '^# ' }).Count; if ($h1 -ne 1) { $Problems.Add("expected 1 H1, found ${h1}: $($f.Rel)") }
  $h2 = -1; for ($li = 0; $li -lt $lines.Count; $li++) { if ($lines[$li].StartsWith('## ')) { $h2 = $li; break } }
  if ($h2 -gt 0) { $pre = $lines[0..($h2 - 1)] } else { $pre = $lines }
  if (@($pre | Where-Object { $_ -match '^#{3,6} ' }).Count -gt 0) { $Problems.Add("heading before first H2: $($f.Rel)") }
  $lc = @($lines | Where-Object { $_ -match '^- \[' }).Count; if ($lc -gt $MaxEntries) { $Problems.Add("link cap exceeded ($lc): $($f.Rel)") }
}
$llmsFiles = @($Files | Where-Object { $_.Name -eq $LlmsFileName })
$report = New-Object 'System.Collections.Generic.List[string]'
$report.Add("llms-tree Pass 2 $(if ($DryRun) { 'DRY RUN (nothing written)' } else { 'WRITE' })  chunks=$($ChunkMap.Count)  emitted=$($ChunkMap.Count - $script:collapsedCount)  collapsed wrappers=$($script:collapsedCount)  group files=$($script:groupCount)")
$report.Add("files to write: $($llmsFiles.Count) $LlmsFileName (incl. groups) + $(@($Files | Where-Object { $_.Name -eq $ManifestFileName }).Count) $ManifestFileName")
$report.Add("max links in one file: $(($llmsFiles | ForEach-Object { $_.Links } | Measure-Object -Maximum).Maximum)  (cap $MaxEntries)")
$report.Add("validation problems: $($Problems.Count)"); foreach ($p in $Problems) { $report.Add("  - $p") }

# ---------------------------------------------------------------- dry run / write
if ($DryRun) {
  $report | ForEach-Object { Write-Host $_ }
  $pick = @($llmsFiles | Where-Object { $_.Rel -eq '.' }) + @($llmsFiles | Where-Object { $_.Rel -ne '.' -and $_.Type -ne 'GROUP' } | Sort-Object { $_.Bytes } -Descending | Select-Object -First ($PreviewCount - 1))
  foreach ($f in $pick) { Write-Host ''; Write-Host ("=================== PREVIEW: {0} ({1}) ===================" -f $f.Rel, $f.Type); Write-Host $f.Text }
  Write-Host ''; Write-Host 'Dry run only. Set $DryRun = $false and paste again to write the sidecar tree.'
} else {
  $treeRoot = Join-Path $RunDir 'tree'
  if ($CleanTree -and (Test-Path -LiteralPath $treeRoot)) { [IO.Directory]::Delete((ConvertTo-LongPath $treeRoot), $true); Write-Host "Removed old sidecar tree: $treeRoot" }
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $idx = New-Object 'System.Collections.Generic.List[string]'; $idx.Add("Rel`tType`tFile`tLinks`tBytes")
  foreach ($f in $Files) {
    $d = $treeRoot
    if ($f.Dir -ne '.') { foreach ($s in $f.Dir.Split('\')) { $d = [IO.Path]::Combine($d, $s) } }
    if ($f.Sub) { $d = [IO.Path]::Combine($d, $f.Sub) }
    [void][IO.Directory]::CreateDirectory((ConvertTo-LongPath $d))
    $fp = [IO.Path]::Combine($d, $f.Name)
    [IO.File]::WriteAllText((ConvertTo-LongPath $fp), $f.Text, $utf8)
    if ($f.Name -eq $LlmsFileName) { $idx.Add("$($f.Rel)`t$($f.Type)`t$fp`t$($f.Links)`t$($f.Bytes)") }
  }
  [IO.File]::WriteAllLines((Join-Path $RunDir 'pass2-index.tsv'), $idx)
  [IO.File]::WriteAllLines((Join-Path $RunDir 'pass2-report.txt'), $report)
  $report | ForEach-Object { Write-Host $_ }
  Write-Host "Wrote sidecar tree: $treeRoot"
}
}