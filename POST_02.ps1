& {
<#
  llms-tree  EXPLORER  -  native WPF window (Windows PowerShell 5.1, default .NET only; no server, no WinForms, no HTA, no HTML).
  PASTE-ABLE: edit $Cfg.RunDir, paste. The console stays busy while the window is open; close the window to return.
  Reads ONLY files inside the run folder:  folders.tsv, tree\**\llms-txt.md + llms-manifest.json, run.json, annotations.json
  Writes ONLY <RunDir>\annotations.json (stars / reviewed / notes), when you press Save in the Notes tab.
  Features: lazy folder tree (all folders or chunks only), rendered llms-txt.md with clickable links, Back / Forward / Home,
            search (words, "phrases", type:REPO flag:cold size>10GB files<1000 depth<=3 is:chunk), facts + histogram,
            Ask-Ollama panel (sends the selected folder's index data + your question to your local Ollama).
  Set $Cfg.SelfTest = $true to run the data layer only (no window) and print diagnostics.
#>
# =====================================================================  VARIABLES (edit me)
$Cfg = @{
  RunDir            = 'C:\Users\zasz_\llms-out\20261031-124239'
  TreeSubdir        = 'tree'
  LlmsFileName      = 'llms-txt.md'
  ManifestFileName  = 'llms-manifest.json'
  FoldersFile       = 'folders.tsv'
  AnnotationsFile   = 'annotations.json'
  Theme             = 'auto'          # 'auto' | 'light' | 'dark'
  StartChunksOnly   = $false
  TreeChildCap      = 500             # max child nodes created per expand (the rest: use search)
  SearchMax         = 500
  IndexTextMaxChars = 60000           # per llms doc kept in the search index
  SourceRootOverride= ''              # '' = Root from run.json (used only by "Copy source path" / "Open in Explorer")
  AllowOpenSource   = $true
  TierColors        = @('#00b4f0','#70db43','#c8f000','#a000f0','#ff6666')   # depth 0,1,2,3,4+
  AskContextChars   = 12000
  AskHistoryTurns   = 3
  Ollama            = @{ Mode = 'api'; Model = 'gemma4:latest'; Url = 'http://localhost:11434'; Think = $false
                         Temperature = 0.2; NumPredict = 700; TimeoutSec = 900; KeepAlive = '30m' }
  SelfTest          = $false
}
# =====================================================================  END VARIABLES

$App = {
param($Cfg)
$ErrorActionPreference = 'Stop'
$global:G = @{ Cfg = $Cfg; Suppress = $false; Hist = (New-Object System.Collections.ArrayList); HistPos = -1; Cur = $null
               Folders = @{}; Kids = @{}; Chunks = @{}; Docs = @{}; Ann = @{}; Index = (New-Object 'System.Collections.Generic.List[object]')
               LastHits = @(); Chat = (New-Object System.Collections.ArrayList); Ask = $null; RootName = 'root'; SourceRoot = ''; Cols = @{} }
$global:Utf8 = New-Object System.Text.UTF8Encoding($false)

function global:LxLog([string]$m) { try { [Console]::WriteLine($m) } catch {} }
function global:LxSafe([scriptblock]$sb) {
  try { & $sb } catch { try { $global:W.TxtStatus.Text = 'ERROR: ' + $_.Exception.Message } catch {}; LxLog ('ERROR: ' + $_.Exception.Message + "`n" + $_.ScriptStackTrace) }
}
function global:LxLong([string]$p) {
  if ([IO.Path]::DirectorySeparatorChar -ne '\') { return $p }
  if ($p.StartsWith('\\?\')) { return $p }
  if ($p.StartsWith('\\')) { return '\\?\UNC\' + $p.Substring(2) }
  return '\\?\' + $p
}
function global:LxSize([long]$b) {
  if ($b -ge 1TB) { return ('{0:N1} TB' -f ($b / 1TB)) }; if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
  if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }; if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }; return "$b B"
}
function global:LxParent([string]$rel) { $i = $rel.LastIndexOf('\'); if ($i -lt 0) { return '.' }; return $rel.Substring(0, $i) }
function global:LxLeaf([string]$rel) { if ($rel -eq '.') { return $global:G.RootName }; $i = $rel.LastIndexOf('\'); if ($i -lt 0) { return $rel }; return $rel.Substring($i + 1) }
function global:LxJoin([string]$a, [string]$b) { if ($a -eq '.' -or -not $a) { return $b }; return "$a\$b" }
function global:LxDepth([string]$rel) { if ($rel -eq '.') { return 0 }; return @($rel.Split('\')).Count }

# ---------------------------------------------------------------- data layer
function global:LxLoad {
  $G = $global:G; $c = $G.Cfg; $run = $c.RunDir
  if (-not (Test-Path -LiteralPath $run)) { throw "RunDir not found: $run" }
  $rjp = Join-Path $run 'run.json'
  if (Test-Path -LiteralPath $rjp) {
    try { $rj = Get-Content -LiteralPath $rjp -Raw | ConvertFrom-Json; $G.SourceRoot = [string]$rj.Root
          $nm = (($G.SourceRoot.TrimEnd('\', '/')) -split '[\\/]')[-1]; if ($nm) { $G.RootName = $nm } } catch {}
  }
  if ($c.SourceRootOverride) { $G.SourceRoot = $c.SourceRootOverride }
  # --- folders.tsv with byte offsets (rows are re-read on demand)
  $fp = Join-Path $run $c.FoldersFile
  if (-not (Test-Path -LiteralPath $fp)) { throw "folders.tsv not found in $run" }
  $G.FoldersPath = $fp
  $fs = [IO.File]::Open($fp, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  $head = New-Object byte[] 8192; $got = $fs.Read($head, 0, 8192); $nl = 1; $pos = 0L
  if ($got -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) { $pos = 3 }
  for ($i = 0; $i -lt $got; $i++) { if ($head[$i] -eq 10) { if ($i -gt 0 -and $head[$i - 1] -eq 13) { $nl = 2 }; break } }
  $fs.Position = 0
  $sr = New-Object IO.StreamReader($fs, $global:Utf8, $true, 65536)
  $hdr = $sr.ReadLine(); if ($hdr.Length -gt 0 -and [int][char]$hdr[0] -eq 0xFEFF) { $hdr = $hdr.Substring(1) }
  $pos += $global:Utf8.GetByteCount($hdr) + $nl
  $cols = $hdr.Split("`t"); for ($i = 0; $i -lt $cols.Count; $i++) { $G.Cols[$cols[$i]] = $i }
  $iRel = $G.Cols['RelPath']; $iDep = $G.Cols['Depth']; $iSF = $G.Cols['SubFiles']; $iSB = $G.Cols['SubBytes']; $iMin = $G.Cols['MinWrite']; $iMax = $G.Cols['MaxWrite']
  $n = 0
  try {
    while ($null -ne ($line = $sr.ReadLine())) {
      $len = $global:Utf8.GetByteCount($line) + $nl
      $f = $line.Split("`t")
      if ($f.Count -eq $cols.Count) {
        $rel = $f[$iRel]
        $G.Folders[$rel] = @([int]$f[$iDep], [long]$f[$iSF], [long]$f[$iSB], [long]$pos, $f[$iMin], $f[$iMax])
        if ($rel -ne '.') {
          $par = LxParent $rel
          $lst = $G.Kids[$par]; if ($null -eq $lst) { $lst = New-Object 'System.Collections.Generic.List[string]'; $G.Kids[$par] = $lst }
          $lst.Add($rel)
        }
        $n++; if (($n % 50000) -eq 0) { LxLog "  ... $n folders" }
      }
      $pos += $len
    }
  } finally { $sr.Dispose(); $fs.Dispose() }
  LxLog "Loaded $n folders from folders.tsv."
  # --- sidecar docs + manifests
  $tree = Join-Path $run $c.TreeSubdir
  if (-not (Test-Path -LiteralPath $tree)) { throw "tree folder not found: $tree (run Pass 2 first)" }
  $treeL = LxLong $tree; $prefixLen = $treeL.TrimEnd('\', '/').Length
  $dn = 0
  foreach ($p in [IO.Directory]::EnumerateFiles($treeL, $c.LlmsFileName, [IO.SearchOption]::AllDirectories)) {
    $dirPath = [IO.Path]::GetDirectoryName($p)
    $dirRel = $dirPath.Substring([math]::Min($prefixLen, $dirPath.Length)).Trim('\', '/').Replace('/', '\')
    if (-not $dirRel) { $dirRel = '.' }
    $txt = [IO.File]::ReadAllText($p, $global:Utf8)
    $leaf = LxLeaf $dirRel
    $isGroup = ($dirRel -ne '.' -and $leaf -match '^_g\d+$')
    $entry = @{ Text = $txt; Dir = $dirRel; IsGroup = $isGroup; ManText = ''; Man = $null }
    if (-not $isGroup) {
      $mp = [IO.Path]::Combine($dirPath, $c.ManifestFileName)
      if ([IO.File]::Exists($mp)) { try { $entry.ManText = [IO.File]::ReadAllText($mp, $global:Utf8); $entry.Man = $entry.ManText | ConvertFrom-Json } catch {} }
    }
    $G.Docs[$dirRel] = $entry
    $dn++; if (($dn % 2000) -eq 0) { LxLog "  ... $dn docs" }
  }
  foreach ($k in @($G.Docs.Keys)) {
    $d = $G.Docs[$k]; if ($d.IsGroup -or -not $d.Man) { continue }
    $m = $d.Man; $kids = New-Object 'System.Collections.Generic.List[string]'
    foreach ($ch in @($m.children)) { if ($ch) { $kids.Add(([string]$ch).Replace('/', '\')) } }
    $sum = [string]$m.summary; if ($sum -eq 'TODO') { $sum = '' }
    $G.Chunks[$k] = @{ Type = [string]$m.type; Rule = [string]$m.rule; Nested = [bool]$m.nested; Flags = (@($m.flags) -join '|'); Summary = $sum
                       Children = $kids; Bytes = [long]$m.stats.bytes; Files = [long]$m.stats.files; Why = [string]$m.why }
  }
  LxLog "Loaded $($G.Docs.Count) docs ($($G.Chunks.Count) chunks)."
  # --- search index (chunks only; non-chunk folders are searched by path)
  foreach ($k in $G.Chunks.Keys) {
    $ch = $G.Chunks[$k]; $t = $G.Docs[$k].Text; if ($t.Length -gt $c.IndexTextMaxChars) { $t = $t.Substring(0, $c.IndexTextMaxChars) }
    $G.Index.Add(@{ Rel = $k; Name = (LxLeaf $k); Type = $ch.Type; Bytes = $ch.Bytes; Files = $ch.Files; Depth = (LxDepth $k); Flags = $ch.Flags.ToLowerInvariant()
                    PathLow = $k.ToLowerInvariant(); Low = ($k + ' ' + $ch.Type + ' ' + $ch.Flags + ' ' + $t).ToLowerInvariant(); Summary = $ch.Summary })
  }
  # --- annotations
  $ap = Join-Path $run $c.AnnotationsFile
  if (Test-Path -LiteralPath $ap) {
    try { foreach ($a in @(Get-Content -LiteralPath $ap -Raw | ConvertFrom-Json)) { if ($a.id) { $G.Ann[[string]$a.id] = @{ star = [bool]$a.star; reviewed = [bool]$a.reviewed; note = [string]$a.note } } } } catch {}
  }
}
function global:LxRow([string]$rel) {
  $rec = $global:G.Folders[$rel]; if (-not $rec) { return $null }
  $fs = [IO.File]::Open($global:G.FoldersPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try { $fs.Position = [long]$rec[3]; $sr = New-Object IO.StreamReader($fs, $global:Utf8, $false, 8192); $line = $sr.ReadLine() } finally { $fs.Dispose() }
  return $line.Split("`t")
}
function global:LxCol([string[]]$row, [string]$name) { $i = $global:G.Cols[$name]; if ($null -eq $i -or $null -eq $row) { return '' }; return $row[$i] }
function global:LxNearestChunk([string]$rel) {
  $r = $rel
  while ($true) { if ($global:G.Chunks.ContainsKey($r)) { return $r }; if ($r -eq '.') { return $null }; $r = LxParent $r }
}
function global:LxChildren([string]$rel) {
  $G = $global:G
  if ($G.W_ChunksOnly) { $c = $G.Chunks[$rel]; if ($c) { return @($c.Children) }; return @() }
  $l = $G.Kids[$rel]; if ($l) { return @($l) }; return @()
}
function global:LxSortKids([string[]]$kids) {
  $G = $global:G
  if ($G.W_SortName) { return @($kids | Sort-Object { (LxLeaf $_).ToLowerInvariant() }) }
  return @($kids | Sort-Object { - [long]$(if ($G.Folders.ContainsKey($_)) { $G.Folders[$_][2] } else { 0 }) })
}

# ---------------------------------------------------------------- facts text
function global:LxHist([string]$s, [long]$total, [int]$top) {
  if (-not $s) { return '  (none)' }
  $out = New-Object 'System.Collections.Generic.List[string]'; $i = 0; $blk = [string][char]0x2588
  foreach ($p in $s.Split(';')) {
    $q = $p.Split(':'); if ($q.Count -lt 3) { continue }
    $b = [long]$q[2]; $sh = 0.0; if ($total -gt 0) { $sh = $b / $total }
    $bar = $blk * [int][math]::Round(30 * $sh)
    $out.Add(('  {0,-14}{1,10:N0} files {2,10}  {3,5:P0} {4}' -f $q[0], [long]$q[1], (LxSize $b), $sh, $bar)); $i++; if ($i -ge $top) { break }
  }
  return ($out -join "`n")
}
function global:LxFactsText([string]$rel) {
  $G = $global:G; $row = LxRow $rel; if (-not $row) { return "(no row for $rel in folders.tsv)" }
  $L = New-Object 'System.Collections.Generic.List[string]'
  $sb = [long](LxCol $row 'SubBytes')
  $L.Add("Path        : $rel"); $L.Add("Depth       : $(LxCol $row 'Depth')")
  $ch = $G.Chunks[$rel]
  if ($ch) { $L.Add("Chunk       : $($ch.Type)  rule $($ch.Rule)  nested=$($ch.Nested)  flags=$($ch.Flags)"); $L.Add("Why         : $($ch.Why)") } else { $L.Add('Chunk       : (not a chunk; part of a parent chunk or too small)') }
  $L.Add(''); $L.Add("Subtree     : $(LxSize $sb) in $('{0:N0}' -f [long](LxCol $row 'SubFiles')) files, $(LxCol $row 'SubDirs') folders below")
  $L.Add("Direct      : $('{0:N0}' -f [long](LxCol $row 'DirectFiles')) files ($(LxSize ([long](LxCol $row 'DirectBytes')))), $(LxCol $row 'DirectDirs') subfolders")
  $L.Add("File dates  : $(LxCol $row 'MinWrite') to $(LxCol $row 'MaxWrite')")
  $L.Add("Markers     : $(LxCol $row 'Markers')   (subtree: $(LxCol $row 'SubMarkers'))")
  $L.Add("Readmes     : $(LxCol $row 'Readmes')"); $L.Add("Name crumbs : $(LxCol $row 'NameCrumbs')")
  $L.Add("Skipped     : hidden dirs $(LxCol $row 'HiddenDirs'), hidden files $(LxCol $row 'HiddenFiles'), excluded [$(LxCol $row 'ExcludedDirs')], reparse $(LxCol $row 'ReparseSkipped')")
  $L.Add("Sniffed     : $(LxCol $row 'Sniffed')"); $L.Add("DirSig/TreeSig: $(LxCol $row 'DirSig') / $(LxCol $row 'TreeSig')   errors: $(LxCol $row 'Errors')")
  $L.Add(''); $L.Add('Top file types in subtree (by size):'); $L.Add((LxHist (LxCol $row 'SubExt') $sb 15))
  $L.Add(''); $L.Add('Top file types directly here:'); $L.Add((LxHist (LxCol $row 'DirectExt') ([long](LxCol $row 'DirectBytes')) 10))
  $kids = $G.Kids[$rel]
  if ($kids -and $kids.Count -gt 0) {
    $L.Add(''); $L.Add("Subfolders ($($kids.Count)), largest first:")
    foreach ($k in @(@($kids) | Sort-Object { - [long]$G.Folders[$_][2] } | Select-Object -First 30)) {
      $mark = ' '; if ($G.Chunks.ContainsKey($k)) { $mark = '*' }
      $L.Add(('  {0} {1,10}  {2}' -f $mark, (LxSize ([long]$G.Folders[$k][2])), (LxLeaf $k)))
    }
    $L.Add('  (* = chunk)')
  }
  return ($L -join "`n")
}

# ---------------------------------------------------------------- markdown (pure parse, then WPF build)
function global:LxMdInlines([string]$s) {
  $out = New-Object 'System.Collections.Generic.List[object]'; $pos = 0
  $rx = [regex]'\[((?:[^\]\\]|\\.)*)\]\(([^)]*)\)|\*\*([^*]+)\*\*|`([^`]+)`'
  foreach ($m in $rx.Matches($s)) {
    if ($m.Index -gt $pos) { $out.Add(@{ K = 't'; Text = $s.Substring($pos, $m.Index - $pos) }) }
    if ($m.Groups[2].Success) { $out.Add(@{ K = 'l'; Text = ($m.Groups[1].Value -replace '\\([\[\]])', '$1'); Url = $m.Groups[2].Value }) }
    elseif ($m.Groups[3].Success) { $out.Add(@{ K = 'b'; Text = $m.Groups[3].Value }) }
    else { $out.Add(@{ K = 'c'; Text = $m.Groups[4].Value }) }
    $pos = $m.Index + $m.Length
  }
  if ($pos -lt $s.Length) { $out.Add(@{ K = 't'; Text = $s.Substring($pos) }) }
  return $out
}
function global:LxMdBlocks([string]$text) {
  $blocks = New-Object 'System.Collections.Generic.List[object]'
  $text = [regex]::Replace($text, '(?s)<!--.*?-->', '')
  foreach ($ln in ($text -split "`r?`n")) {
    if ($ln.Trim() -eq '') { continue }
    if ($ln.StartsWith('# ')) { $blocks.Add(@{ Kind = 'h1'; In = (LxMdInlines $ln.Substring(2)) }) }
    elseif ($ln.StartsWith('## ')) { $blocks.Add(@{ Kind = 'h2'; In = (LxMdInlines $ln.Substring(3)) }) }
    elseif ($ln.StartsWith('> ')) { $blocks.Add(@{ Kind = 'quote'; In = (LxMdInlines $ln.Substring(2)) }) }
    elseif ($ln -match '^\s*[-*] ') { $blocks.Add(@{ Kind = 'li'; In = (LxMdInlines ($ln -replace '^\s*[-*] ', '')) }) }
    else { $blocks.Add(@{ Kind = 'p'; In = (LxMdInlines $ln.Trim()) }) }
  }
  return $blocks
}
function global:LxResolveLink([string]$dirRel, [string]$url) {
  $c = $global:G.Cfg; $G = $global:G
  if ($url -match '^nav:(.*)$') { return @{ Kind = 'folder'; Rel = [uri]::UnescapeDataString($Matches[1]) } }
  if ($url -match '^[a-z][a-z0-9+.-]*:') { return @{ Kind = 'external'; Rel = $url } }
  $parts = New-Object 'System.Collections.Generic.List[string]'
  if ($dirRel -and $dirRel -ne '.') { foreach ($s in $dirRel.Split('\')) { $parts.Add($s) } }
  $segs = ([uri]::UnescapeDataString($url)).Split('/'); $endsSlash = ($url.EndsWith('/'))
  $lastIsDoc = ($segs[$segs.Count - 1] -eq $c.LlmsFileName)
  foreach ($s in $segs) {
    if ($s -eq '' -or $s -eq '.') { continue }
    if ($s -eq '..') { if ($parts.Count -gt 0) { $parts.RemoveAt($parts.Count - 1) }; continue }
    if ($s -eq $c.LlmsFileName -and $s -eq $segs[$segs.Count - 1]) { continue }
    $parts.Add($s)
  }
  $rel = ($parts -join '\'); if (-not $rel) { $rel = '.' }
  if ($lastIsDoc) {
    if ($G.Docs.ContainsKey($rel)) {
      if ($G.Docs[$rel].IsGroup) { return @{ Kind = 'group'; Rel = (LxParent $rel); Group = (LxLeaf $rel) } }
      return @{ Kind = 'doc'; Rel = $rel }
    }
    return @{ Kind = 'missing'; Rel = $rel }
  }
  if ($endsSlash -or $G.Folders.ContainsKey($rel)) { if ($G.Folders.ContainsKey($rel)) { return @{ Kind = 'folder'; Rel = $rel } }; return @{ Kind = 'missing'; Rel = $rel } }
  return @{ Kind = 'external'; Rel = $rel }   # e.g. a README in the source tree (not stored in the run folder)
}
function global:LxMdDoc([string]$text, [string]$dirRel) {
  $G = $global:G; $T = $G.Theme
  $doc = New-Object System.Windows.Documents.FlowDocument
  $doc.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI'; $doc.FontSize = 14
  $doc.PagePadding = New-Object System.Windows.Thickness 18; $doc.Foreground = $T.Fg; $doc.Background = $T.Bg
  foreach ($b in (LxMdBlocks $text)) {
    $p = New-Object System.Windows.Documents.Paragraph
    $p.Margin = New-Object System.Windows.Thickness 0, 3, 0, 3
    switch ($b.Kind) {
      'h1' { $p.FontSize = 26; $p.FontWeight = [System.Windows.FontWeights]::Bold; $p.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8 }
      'h2' { $p.FontSize = 19; $p.FontWeight = [System.Windows.FontWeights]::Bold; $p.Margin = New-Object System.Windows.Thickness 0, 14, 0, 4 }
      'quote' { $p.FontStyle = [System.Windows.FontStyles]::Italic; $p.BorderBrush = $T.Accent; $p.BorderThickness = New-Object System.Windows.Thickness 3, 0, 0, 0
                $p.Padding = New-Object System.Windows.Thickness 10, 4, 4, 4; $p.Margin = New-Object System.Windows.Thickness 0, 4, 0, 8; $p.Background = $T.Panel }
      'li' { $p.Margin = New-Object System.Windows.Thickness 22, 2, 0, 2; [void]$p.Inlines.Add((New-Object System.Windows.Documents.Run ([string][char]0x2022 + '  '))) }
    }
    foreach ($il in $b.In) {
      switch ($il.K) {
        't' { [void]$p.Inlines.Add((New-Object System.Windows.Documents.Run $il.Text)) }
        'b' { $r = New-Object System.Windows.Documents.Run $il.Text; $r.FontWeight = [System.Windows.FontWeights]::Bold; [void]$p.Inlines.Add($r) }
        'c' { $r = New-Object System.Windows.Documents.Run $il.Text; $r.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas'; [void]$p.Inlines.Add($r) }
        'l' {
          $r = New-Object System.Windows.Documents.Run $il.Text
          $h = New-Object System.Windows.Documents.Hyperlink $r
          $h.Tag = @{ Dir = $dirRel; Url = $il.Url }
          $h.Add_Click({ param($s, $e) $tag = $s.Tag; LxSafe { LxOnLink $tag } })
          [void]$p.Inlines.Add($h)
        }
      }
    }
    [void]$doc.Blocks.Add($p)
  }
  return $doc
}
function global:LxOnLink($tag) {
  $r = LxResolveLink $tag.Dir $tag.Url
  switch ($r.Kind) {
    'doc'    { LxNavigate $r.Rel $null $true $false }
    'group'  { LxNavigate $r.Rel $r.Group $true $false }
    'folder' { LxNavigate $r.Rel $null $true $false }
    'external' { $global:W.TxtStatus.Text = "Not in the run folder (source file, not previewed): $($r.Rel)" }
    default  { $global:W.TxtStatus.Text = "Link target not found: $($tag.Url)" }
  }
}

# ---------------------------------------------------------------- search
function global:LxParseSize([string]$s) {
  if ($s -match '^\s*([\d.]+)\s*(b|kb|mb|gb|tb)?\s*$') {
    $n = [double]$Matches[1]; $u = $Matches[2].ToLowerInvariant()
    switch ($u) { 'kb' { $n *= 1KB } 'mb' { $n *= 1MB } 'gb' { $n *= 1GB } 'tb' { $n *= 1TB } }
    return [long]$n
  }
  return $null
}
function global:LxCompare([double]$a, [string]$op, [double]$b) {
  switch ($op) { '>' { return ($a -gt $b) } '<' { return ($a -lt $b) } '>=' { return ($a -ge $b) } '<=' { return ($a -le $b) } '=' { return ($a -eq $b) } }
  return $false
}
function global:LxParseQuery([string]$q) {
  $f = @{ Words = @(); Type = @(); Flag = @(); Nums = @(); Is = '' }
  foreach ($m in [regex]::Matches($q, '"[^"]*"|\S+')) {
    $t = $m.Value
    if ($t.StartsWith('"')) { $w = $t.Trim('"').ToLowerInvariant(); if ($w) { $f.Words += $w }; continue }
    if ($t -match '^type:(.+)$') { $f.Type += $Matches[1].ToLowerInvariant(); continue }
    if ($t -match '^flag:(.+)$') { $f.Flag += $Matches[1].ToLowerInvariant(); continue }
    if ($t -match '^is:(chunk|folder)$') { $f.Is = $Matches[1].ToLowerInvariant(); continue }
    if ($t -match '^(size|files|depth)(>=|<=|>|<|=)(.+)$') {
      $val = $null; if ($Matches[1] -eq 'size') { $val = LxParseSize $Matches[3] } else { $d = 0.0; if ([double]::TryParse($Matches[3], [ref]$d)) { $val = [long]$d } }
      if ($null -ne $val) { $f.Nums += @{ Field = $Matches[1]; Op = $Matches[2]; Val = [double]$val }; continue }
    }
    $f.Words += $t.ToLowerInvariant()
  }
  return $f
}
function global:LxSearch([string]$q) {
  $G = $global:G; $max = $G.Cfg.SearchMax; $f = LxParseQuery $q
  $res = New-Object 'System.Collections.Generic.List[object]'
  $chunkOnly = ($f.Type.Count -gt 0 -or $f.Flag.Count -gt 0 -or $f.Is -eq 'chunk')
  $folderOnly = ($f.Is -eq 'folder' -or ($f.Type.Count -gt 0 -and ($f.Type -contains 'folder') -and $f.Type.Count -eq 1))
  $numOk = { param($bytes, $files, $depth)
    foreach ($n in $f.Nums) { $v = $bytes; if ($n.Field -eq 'files') { $v = $files } elseif ($n.Field -eq 'depth') { $v = $depth }; if (-not (LxCompare ([double]$v) $n.Op $n.Val)) { return $false } }
    return $true }
  if (-not $folderOnly) {
    foreach ($e in $G.Index) {
      if ($f.Type.Count -gt 0 -and -not ($f.Type -contains $e.Type.ToLowerInvariant())) { continue }
      $okF = $true; foreach ($fl in $f.Flag) { if (-not $e.Flags.Contains($fl)) { $okF = $false } }; if (-not $okF) { continue }
      if (-not (& $numOk $e.Bytes $e.Files $e.Depth)) { continue }
      $okW = $true; $inName = $true
      foreach ($w in $f.Words) { if (-not $e.Low.Contains($w)) { $okW = $false; break }; if (-not $e.PathLow.Contains($w)) { $inName = $false } }
      if (-not $okW) { continue }
      $snip = $e.Summary; if ($f.Words.Count -gt 0 -and -not $inName) { $ix = $e.Low.IndexOf($f.Words[0]); if ($ix -ge 0) { $a = [math]::Max(0, $ix - 50); $snip = '...' + $e.Low.Substring($a, [math]::Min(140, $e.Low.Length - $a)).Replace("`n", ' ') } }
      if (-not $snip -and $e.Summary) { $snip = $e.Summary }
      if ($snip.Length -gt 160) { $snip = $snip.Substring(0, 160) + '...' }
      $res.Add(@{ Rel = $e.Rel; Type = $e.Type; Bytes = $e.Bytes; Files = $e.Files; Score = $(if ($inName) { 2 } else { 1 }); Snippet = $snip })
    }
  }
  if (-not $chunkOnly -and $res.Count -lt $max) {
    $hasWords = ($f.Words.Count -gt 0)
    foreach ($k in $G.Folders.Keys) {
      if ($res.Count -ge $max) { break }
      if ($G.Chunks.ContainsKey($k)) { continue }
      $rec = $G.Folders[$k]
      if (-not (& $numOk $rec[2] $rec[1] $rec[0])) { continue }
      if ($hasWords) { $low = $k.ToLowerInvariant(); $okW = $true; foreach ($w in $f.Words) { if (-not $low.Contains($w)) { $okW = $false; break } }; if (-not $okW) { continue } }
      elseif ($f.Nums.Count -eq 0 -and $f.Is -ne 'folder') { continue }
      $res.Add(@{ Rel = $k; Type = 'folder'; Bytes = $rec[2]; Files = $rec[1]; Score = 0; Snippet = '' })
    }
  }
  return ,@($res | Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Bytes }; Descending = $true } | Select-Object -First $max)   # comma: keep a 1-item result an array
}

# ---------------------------------------------------------------- tree (lazy)
function global:LxBrush([string]$c) { return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($c) }
function global:LxTypeColor([string]$t) {
  switch ($t) { 'REPO' { return '#e08a00' } 'PROJECT' { return '#2aa198' } 'BLOB' { return '#b58900' } 'DATASET' { return '#d33682' }
                'OPAQUE-BULK' { return '#6c71c4' } 'CONTAINER' { return '#859900' } 'WRAPPER' { return '#93a1a1' } default { return '#839496' } }
}
function global:LxMakeHeader([string]$rel, [double]$share) {
  $G = $global:G; $T = $G.Theme
  $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $depth = LxDepth $rel; $tc = $G.Cfg.TierColors; $col = $tc[[math]::Min($depth, $tc.Count - 1)]
  $dot = New-Object System.Windows.Shapes.Ellipse; $dot.Width = 10; $dot.Height = 10; $dot.Fill = (LxBrush $col); $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $dot.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0; [void]$sp.Children.Add($dot)
  $ch = $G.Chunks[$rel]
  $tb = New-Object System.Windows.Controls.TextBlock; $tb.Text = (LxLeaf $rel); $tb.Foreground = $T.Fg; if ($ch) { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }; [void]$sp.Children.Add($tb)
  if ($ch) { $tt = New-Object System.Windows.Controls.TextBlock; $tt.Text = '  [' + $ch.Type + ']'; $tt.Foreground = (LxBrush (LxTypeColor $ch.Type)); $tt.FontSize = 11; $tt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center; [void]$sp.Children.Add($tt) }
  $rec = $G.Folders[$rel]
  if ($rec) { $sz = New-Object System.Windows.Controls.TextBlock; $sz.Text = '  ' + (LxSize ([long]$rec[2])); $sz.Foreground = $T.Dim; $sz.FontSize = 11; $sz.VerticalAlignment = [System.Windows.VerticalAlignment]::Center; [void]$sp.Children.Add($sz) }
  $a = $G.Ann[$rel]; if ($a -and $a.star) { $st = New-Object System.Windows.Controls.TextBlock; $st.Text = '  ' + [string][char]0x2605; $st.Foreground = (LxBrush '#e0b000'); [void]$sp.Children.Add($st) }
  if ($a -and $a.reviewed) { $rv = New-Object System.Windows.Controls.TextBlock; $rv.Text = ' ' + [string][char]0x2713; $rv.Foreground = (LxBrush '#2aa198'); [void]$sp.Children.Add($rv) }
  if ($share -gt 0) { $bar = New-Object System.Windows.Shapes.Rectangle; $bar.Height = 5; $bar.Width = [math]::Max(2, [math]::Round(70 * $share)); $bar.Fill = (LxBrush $col); $bar.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0; $bar.VerticalAlignment = [System.Windows.VerticalAlignment]::Center; [void]$sp.Children.Add($bar) }
  return $sp
}
function global:LxHasKids([string]$rel) { return (@(LxChildren $rel).Count -gt 0) }
function global:LxMakeItem([string]$rel, [double]$share) {
  $it = New-Object System.Windows.Controls.TreeViewItem
  $it.Tag = $rel; $it.Header = (LxMakeHeader $rel $share); $it.Foreground = $global:G.Theme.Fg
  if (LxHasKids $rel) {
    $d = New-Object System.Windows.Controls.TreeViewItem; $d.Tag = '__dummy__'; [void]$it.Items.Add($d)
    $it.Add_Expanded({ param($s, $e) if ($e.OriginalSource -eq $s) { LxSafe { LxPopulate $s } } })
  }
  return $it
}
function global:LxPopulate($item) {
  if (-not ($item.Items.Count -eq 1 -and $item.Items[0].Tag -eq '__dummy__')) { return }
  $G = $global:G; $item.Items.Clear(); $rel = [string]$item.Tag
  $kids = @(LxSortKids @(LxChildren $rel)); $cap = $G.Cfg.TreeChildCap
  $pb = 0.0; if ($G.Folders.ContainsKey($rel)) { $pb = [double]$G.Folders[$rel][2] }
  $n = 0
  foreach ($k in $kids) {
    if ($n -ge $cap) { break }
    $sh = 0.0; if ($pb -gt 0 -and $G.Folders.ContainsKey($k)) { $sh = [double]$G.Folders[$k][2] / $pb }
    [void]$item.Items.Add((LxMakeItem $k $sh)); $n++
  }
  if ($kids.Count -gt $cap) {
    $m = New-Object System.Windows.Controls.TreeViewItem; $m.Tag = '__more__'; $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = "... $($kids.Count - $cap) more (not shown; use Search)"; $tb.Foreground = $G.Theme.Dim; $m.Header = $tb; [void]$item.Items.Add($m)
  }
}
function global:LxBuildTree {
  $G = $global:G; $W = $global:W
  $W.Tree.Items.Clear()
  $root = LxMakeItem '.' 0.0; $G.RootItem = $root; [void]$W.Tree.Items.Add($root)
  LxPopulate $root; $root.IsExpanded = $true
}
function global:LxReveal([string]$rel) {
  $G = $global:G; $item = $G.RootItem; if (-not $item) { return $false }
  LxPopulate $item; $item.IsExpanded = $true
  $cur = ''; $parts = @(); if ($rel -ne '.') { $parts = $rel.Split('\') }
  for ($i = 0; $i -lt $parts.Count; $i++) {
    $cur = LxJoin $(if ($cur) { $cur } else { '.' }) $parts[$i]
    $next = $null; foreach ($ci in $item.Items) { if ($ci.Tag -eq $cur) { $next = $ci; break } }
    if (-not $next) {
      if ($G.W_ChunksOnly -or -not $G.Folders.ContainsKey($cur)) { return $false }
      $next = LxMakeItem $cur 0.0; $item.Items.Insert(0, $next)
    }
    $item = $next
    if ($i -lt $parts.Count - 1) { LxPopulate $item; $item.IsExpanded = $true }
  }
  $G.Suppress = $true
  try { $item.IsSelected = $true; $item.BringIntoView() } finally { $G.Suppress = $false }
  $G.SelItem = $item
  return $true
}

# ---------------------------------------------------------------- navigation + detail
function global:LxNavigate([string]$rel, $group, [bool]$push, [bool]$fromTree) {
  $G = $global:G; $W = $global:W
  if (-not $G.Folders.ContainsKey($rel) -and -not $G.Docs.ContainsKey($rel)) { $W.TxtStatus.Text = "Unknown folder: $rel"; return }
  $G.Cur = @{ Rel = $rel; Group = $group }
  if ($push) {
    while ($G.Hist.Count -gt ($G.HistPos + 1)) { $G.Hist.RemoveAt($G.Hist.Count - 1) }
    $last = $null; if ($G.Hist.Count -gt 0) { $last = $G.Hist[$G.Hist.Count - 1] }
    if (-not ($last -and $last.Rel -eq $rel -and $last.Group -eq $group)) { [void]$G.Hist.Add(@{ Rel = $rel; Group = $group }); $G.HistPos = $G.Hist.Count - 1 }
  }
  if (-not $fromTree) {
    $ok = LxReveal $rel
    if (-not $ok -and $G.W_ChunksOnly) {   # target not visible in chunks-only view: fall back to the nearest chunk ancestor in the tree
      $near = LxNearestChunk $rel; if ($near) { [void](LxReveal $near) }
    }
  }
  LxRender
}
function global:LxBack { $G = $global:G; if ($G.HistPos -gt 0) { $G.HistPos--; $e = $G.Hist[$G.HistPos]; LxNavigate $e.Rel $e.Group $false $false } }
function global:LxFwd  { $G = $global:G; if ($G.HistPos -lt $G.Hist.Count - 1) { $G.HistPos++; $e = $G.Hist[$G.HistPos]; LxNavigate $e.Rel $e.Group $false $false } }
function global:LxHome {
  $G = $global:G; $W = $global:W
  $W.TxtSearch.Text = ''; $W.LvSearch.ItemsSource = $null; $G.LastHits = @()
  LxBuildTree; LxNavigate '.' $null $true $false; $W.Tabs.SelectedIndex = 0
}
function global:LxRender {
  $G = $global:G; $W = $global:W; $cur = $G.Cur; if (-not $cur) { return }
  $rel = $cur.Rel; $grp = $cur.Group
  # breadcrumb
  $W.Crumb.Inlines.Clear(); $acc = '.'
  $segs = @('.'); if ($rel -ne '.') { $segs += $rel.Split('\') }
  for ($i = 0; $i -lt $segs.Count; $i++) {
    if ($i -gt 0) { [void]$W.Crumb.Inlines.Add((New-Object System.Windows.Documents.Run '  >  ')) }
    if ($i -eq 0) { $acc = '.'; $label = $G.RootName } else { $acc = LxJoin $acc $segs[$i]; $label = $segs[$i] }
    $h = New-Object System.Windows.Documents.Hyperlink (New-Object System.Windows.Documents.Run $label)
    $h.Tag = $acc; $h.Add_Click({ param($s, $e) $t = $s.Tag; LxSafe { LxNavigate $t $null $true $false } }); [void]$W.Crumb.Inlines.Add($h)
  }
  if ($grp) { [void]$W.Crumb.Inlines.Add((New-Object System.Windows.Documents.Run "  >  [$grp]")) }
  # summary document
  $docKey = $rel; if ($grp) { $docKey = LxJoin $rel $grp }
  $d = $G.Docs[$docKey]
  if ($d) { $W.DocViewer.Document = (LxMdDoc $d.Text $docKey) }
  else {
    $near = LxNearestChunk $rel; $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# $(LxLeaf $rel)`n`n> This folder is not a chunk (no $($G.Cfg.LlmsFileName)); it is part of a larger chunk or too small to index on its own.`n`n")
    if ($near) { [void]$sb.Append("Nearest chunk: [$(LxLeaf $near)](nav:$([uri]::EscapeDataString($near)))`n`n") }
    $kids = $G.Kids[$rel]
    if ($kids -and $kids.Count -gt 0) {
      [void]$sb.Append("## Subfolders`n")
      foreach ($k in @(@($kids) | Sort-Object { - [long]$G.Folders[$_][2] } | Select-Object -First 40)) {
        [void]$sb.Append("- [$((LxLeaf $k).Replace('[','\[').Replace(']','\]'))](nav:$([uri]::EscapeDataString($k))): $(LxSize ([long]$G.Folders[$k][2])), $('{0:N0}' -f [long]$G.Folders[$k][1]) files`n")
      }
    }
    $W.DocViewer.Document = (LxMdDoc $sb.ToString() $rel)
  }
  $W.TxtFacts.Text = (LxFactsText $rel)
  if ($G.Docs.ContainsKey($rel) -and $G.Docs[$rel].ManText) { $W.TxtManifest.Text = $G.Docs[$rel].ManText } else { $W.TxtManifest.Text = '(not a chunk: no manifest)' }
  $a = $G.Ann[$rel]
  $W.ChkStar.IsChecked = [bool]($a -and $a.star); $W.ChkReviewed.IsChecked = [bool]($a -and $a.reviewed); $W.TxtNote.Text = $(if ($a) { $a.note } else { '' })
  $W.TxtStatus.Text = "$rel   |   $($G.Folders.Count) folders, $($G.Chunks.Count) chunks   |   history $($G.HistPos + 1)/$($G.Hist.Count)"
  $W.BtnBack.IsEnabled = ($G.HistPos -gt 0); $W.BtnFwd.IsEnabled = ($G.HistPos -lt $G.Hist.Count - 1)
}

# ---------------------------------------------------------------- annotations
function global:LxSaveNote {
  $G = $global:G; $W = $global:W; $rel = $G.Cur.Rel
  $G.Ann[$rel] = @{ star = [bool]$W.ChkStar.IsChecked; reviewed = [bool]$W.ChkReviewed.IsChecked; note = [string]$W.TxtNote.Text }
  $arr = @(); foreach ($k in $G.Ann.Keys) { $v = $G.Ann[$k]; if ($v.star -or $v.reviewed -or $v.note) { $arr += [ordered]@{ id = $k; star = $v.star; reviewed = $v.reviewed; note = $v.note } } }
  $json = ConvertTo-Json -InputObject $arr -Depth 4
  [IO.File]::WriteAllText((Join-Path $G.Cfg.RunDir $G.Cfg.AnnotationsFile), $json, $global:Utf8)
  if ($G.SelItem -and $G.SelItem.Tag -eq $rel) { $G.SelItem.Header = (LxMakeHeader $rel 0.0) }
  $W.TxtStatus.Text = "Saved notes for $rel"
}

# ---------------------------------------------------------------- Ask Ollama
function global:LxBuildContext {
  $G = $global:G; $W = $global:W; $rel = $G.Cur.Rel; $sb = New-Object System.Text.StringBuilder
  if ($W.ChkCtxNode.IsChecked) {
    [void]$sb.Append("=== SELECTED FOLDER: $rel ===`n"); [void]$sb.Append((LxFactsText $rel)); [void]$sb.Append("`n`n")
    $dk = $rel; if ($G.Cur.Group) { $dk = LxJoin $rel $G.Cur.Group }
    if ($G.Docs.ContainsKey($dk)) { [void]$sb.Append("=== INDEX PAGE ($($G.Cfg.LlmsFileName)) ===`n$($G.Docs[$dk].Text)`n`n") }
  }
  if ($W.ChkCtxKids.IsChecked -and $G.Chunks.ContainsKey($rel)) {
    [void]$sb.Append("=== CHILD CHUNKS (path : type, size : summary) ===`n")
    foreach ($k in @($G.Chunks[$rel].Children)) { $c = $G.Chunks[$k]; if ($c) { $s = $c.Summary; if ($s.Length -gt 300) { $s = $s.Substring(0, 300) + '...' }; [void]$sb.Append("$k : $($c.Type), $(LxSize $c.Bytes) : $s`n") } }
    [void]$sb.Append("`n")
  }
  if ($W.ChkCtxHits.IsChecked -and $G.LastHits.Count -gt 0) {
    [void]$sb.Append("=== CURRENT SEARCH HITS ===`n")
    foreach ($h in @($G.LastHits | Select-Object -First 15)) { $s = ''; if ($G.Chunks.ContainsKey($h.Rel)) { $s = $G.Chunks[$h.Rel].Summary }; if ($s.Length -gt 300) { $s = $s.Substring(0, 300) + '...' }; [void]$sb.Append("$($h.Rel) : $($h.Type), $(LxSize ([long]$h.Bytes)) : $s`n") }
    [void]$sb.Append("`n")
  }
  $t = $sb.ToString(); $cap = $G.Cfg.AskContextChars; if ($t.Length -gt $cap) { $t = $t.Substring(0, $cap) + "`n[context truncated]" }
  return $t
}
function global:LxAsk {
  $G = $global:G; $W = $global:W; $o = $G.Cfg.Ollama
  $q = ([string]$W.TxtQuestion.Text).Trim(); if (-not $q) { return }
  if ($G.Ask) { $W.TxtStatus.Text = 'A question is already running (Cancel to stop it).'; return }
  $hist = ''
  if ($W.ChkCtxHist.IsChecked -and $G.Chat.Count -gt 0) {
    $take = @($G.Chat | Select-Object -Last $G.Cfg.AskHistoryTurns); $hist = "=== EARLIER TURNS ===`n"
    foreach ($t in $take) { $hist += "Q: $($t.Q)`nA: $($t.A)`n" }; $hist += "`n"
  }
  if ($W.ChkRaw.IsChecked) { $prompt = $hist + $q }
  else {
    $ctx = LxBuildContext
    $prompt = "You answer questions about a file archive that was indexed by a tool. Use ONLY the INDEX DATA below. Refer to folders by their path. If the data does not contain the answer, say so plainly; do not invent files, sizes or dates. Be concise.`n`nINDEX DATA`n$ctx`n$hist`nQUESTION: $q`nANSWER:"
  }
  $model = ([string]$W.TxtModel.Text).Trim(); if (-not $model) { $model = $o.Model }
  $W.TxtTranscript.AppendText("`r`nYou: $q`r`n`r`n[$model is thinking...]`r`n"); $W.TxtTranscript.ScrollToEnd()
  $ps = [powershell]::Create()
  [void]$ps.AddScript({
    param($mode, $url, $model, $prompt, $think, $temp, $np, $timeout, $keep)
    $ProgressPreference = 'SilentlyContinue'
    try {
      if ($mode -eq 'api') {
        $body = @{ model = $model; prompt = $prompt; stream = $false; think = $think; keep_alive = $keep; options = @{ temperature = $temp; num_predict = $np } } | ConvertTo-Json -Depth 5 -Compress
        $resp = Invoke-WebRequest -UseBasicParsing -Uri "$url/api/generate" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec $timeout
        $obj = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
        return [string]$obj.response
      } else {
        $enc = New-Object System.Text.UTF8Encoding($false); [Console]::OutputEncoding = $enc; $OutputEncoding = $enc
        $out = $prompt | & ollama run $model ("--think=" + $think.ToString().ToLower()) 2>$null
        return ($out -join "`n")
      }
    } catch { return 'ERROR: ' + $_.Exception.Message }
  }).AddArgument($o.Mode).AddArgument($o.Url).AddArgument($model).AddArgument($prompt).AddArgument($o.Think).AddArgument($o.Temperature).AddArgument($o.NumPredict).AddArgument($o.TimeoutSec).AddArgument($o.KeepAlive)
  $async = $ps.BeginInvoke()
  $G.Ask = @{ Ps = $ps; Async = $async; Q = $q }
  $W.BtnAsk.IsEnabled = $false
  $timer = New-Object System.Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromMilliseconds(400)
  $timer.Add_Tick({
    $G = $global:G; $W = $global:W
    if ($G.Ask -and $G.Ask.Async.IsCompleted) {
      $this.Stop()
      $ans = ''
      try { $res = $G.Ask.Ps.EndInvoke($G.Ask.Async); $ans = (@($res) -join "`n").Trim() } catch { $ans = 'ERROR: ' + $_.Exception.Message }
      try { $G.Ask.Ps.Dispose() } catch {}
      $q = $G.Ask.Q; $G.Ask = $null; $W.BtnAsk.IsEnabled = $true
      $W.TxtTranscript.AppendText("Ollama: $ans`r`n`r`n" + ('-' * 60) + "`r`n"); $W.TxtTranscript.ScrollToEnd()
      [void]$G.Chat.Add(@{ Q = $q; A = $ans })
    }
  })
  $timer.Start(); $G.Ask.Timer = $timer
}
function global:LxCancelAsk {
  $G = $global:G; $W = $global:W
  if ($G.Ask) { try { $G.Ask.Timer.Stop(); $G.Ask.Ps.Stop(); $G.Ask.Ps.Dispose() } catch {}; $G.Ask = $null; $W.BtnAsk.IsEnabled = $true; $W.TxtTranscript.AppendText("[cancelled]`r`n") }
}

# ---------------------------------------------------------------- self test (no window)
if ($Cfg.SelfTest) {
  LxLoad; $G = $global:G
  LxLog "folders=$($G.Folders.Count) chunks=$($G.Chunks.Count) docs=$($G.Docs.Count) index=$($G.Index.Count) root=$($G.RootName)"
  $G.W_ChunksOnly = $false; $G.W_SortName = $false
  $k = LxSortKids (LxChildren '.'); LxLog "root children (all): $($k -join ', ')"
  $G.W_ChunksOnly = $true; LxLog "root children (chunks): $((LxChildren '.') -join ', ')"
  foreach ($q in @('type:REPO', 'size>10GB', '"half-life"', 'flag:cold', 'fallout type:PROJECT', 'is:folder size>1GB depth<=3', 'archive files<500')) {
    $r = LxSearch $q; LxLog ("search [{0}] -> {1} hits; first: {2}" -f $q, $r.Count, $(if ($r.Count) { "$($r[0].Rel) ($($r[0].Type))" } else { '-' }))
  }
  $any = @($G.Chunks.Keys)[0]
  foreach ($t in @(@('steamapps\common', 'Fallout%204/llms-txt.md'), @('steamapps\common', '_g01/llms-txt.md'), @('steamapps\common\_g01', '../Fallout%204/llms-txt.md'), @('steamapps', 'common/'), @('steamapps\common\Godot Engine', 'README.md'), @('.', 'nav:steamapps'))) {
    $r = LxResolveLink $t[0] $t[1]; LxLog ("link [{0}] + [{1}] -> {2} {3} {4}" -f $t[0], $t[1], $r.Kind, $r.Rel, $r.Group)
  }
  $rt = $G.Docs['.'].Text; $bl = LxMdBlocks $rt; LxLog "root doc blocks: $($bl.Count); kinds: $((@($bl | ForEach-Object { $_.Kind }) | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ')"
  $first = @($bl | Where-Object { $_.Kind -eq 'li' } | Select-Object -First 1); if ($first) { LxLog ("first list item inlines: " + (($first[0].In | ForEach-Object { "$($_.K):$($_.Text)" }) -join ' | ')) }
  LxLog ((LxFactsText 'steamapps\common') -split "`n" | Select-Object -First 12 | Out-String)
  return
}

# ---------------------------------------------------------------- window
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="llms-tree explorer" Width="1400" Height="860" WindowStartupLocation="CenterScreen">
  <Grid Margin="6">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <DockPanel Grid.Row="0" LastChildFill="True" Margin="0,0,0,4">
      <Button x:Name="BtnHome" Content="Home" Width="64" Margin="0,0,4,0" DockPanel.Dock="Left"/>
      <Button x:Name="BtnBack" Content="&lt; Back" Width="64" Margin="0,0,4,0" DockPanel.Dock="Left"/>
      <Button x:Name="BtnFwd" Content="Fwd &gt;" Width="64" Margin="0,0,4,0" DockPanel.Dock="Left"/>
      <ComboBox x:Name="CmbSort" DockPanel.Dock="Right" Width="110" SelectedIndex="0">
        <ComboBoxItem Content="Sort: size"/><ComboBoxItem Content="Sort: name"/>
      </ComboBox>
      <CheckBox x:Name="ChkChunks" Content="Chunks only" DockPanel.Dock="Right" Margin="8,0,8,0" VerticalAlignment="Center"/>
      <TextBlock x:Name="Crumb" VerticalAlignment="Center" Margin="10,0,0,0" TextTrimming="CharacterEllipsis"/>
    </DockPanel>
    <DockPanel Grid.Row="1" Margin="0,0,0,4">
      <Button x:Name="BtnClearSearch" Content="Clear" DockPanel.Dock="Right" Width="60" Margin="4,0,0,0"/>
      <Button x:Name="BtnSearch" Content="Search" DockPanel.Dock="Right" Width="70" Margin="4,0,0,0"/>
      <TextBox x:Name="TxtSearch" ToolTip="Words (AND), &quot;phrases&quot;, type:REPO  flag:cold  is:chunk|folder  size&gt;10GB  files&lt;1000  depth&lt;=3" />
    </DockPanel>
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions><ColumnDefinition Width="430"/><ColumnDefinition Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <TreeView x:Name="Tree" Grid.Column="0"/>
      <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch"/>
      <TabControl x:Name="Tabs" Grid.Column="2">
        <TabItem Header="Summary">
          <FlowDocumentScrollViewer x:Name="DocViewer" IsToolBarVisible="False"/>
        </TabItem>
        <TabItem Header="Facts">
          <TextBox x:Name="TxtFacts" IsReadOnly="True" FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
        </TabItem>
        <TabItem Header="Manifest">
          <TextBox x:Name="TxtManifest" IsReadOnly="True" FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
        </TabItem>
        <TabItem Header="Search results">
          <ListView x:Name="LvSearch">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="Path" Width="380" DisplayMemberBinding="{Binding Path}"/>
                <GridViewColumn Header="Type" Width="90" DisplayMemberBinding="{Binding Type}"/>
                <GridViewColumn Header="Size" Width="80" DisplayMemberBinding="{Binding Size}"/>
                <GridViewColumn Header="Files" Width="80" DisplayMemberBinding="{Binding Files}"/>
                <GridViewColumn Header="Match" Width="520" DisplayMemberBinding="{Binding Snippet}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </TabItem>
        <TabItem Header="Ask Ollama">
          <Grid Margin="4">
            <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="90"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <TextBox x:Name="TxtTranscript" Grid.Row="0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Segoe UI" FontSize="13"/>
            <WrapPanel Grid.Row="1" Margin="0,6,0,4">
              <CheckBox x:Name="ChkCtxNode" Content="Selected folder + its page" IsChecked="True" Margin="0,0,12,0"/>
              <CheckBox x:Name="ChkCtxKids" Content="Child chunk summaries" IsChecked="True" Margin="0,0,12,0"/>
              <CheckBox x:Name="ChkCtxHits" Content="Current search hits" Margin="0,0,12,0"/>
              <CheckBox x:Name="ChkCtxHist" Content="Earlier turns" IsChecked="True" Margin="0,0,12,0"/>
              <CheckBox x:Name="ChkRaw" Content="Raw (my text only, no index data)" Margin="0,0,12,0"/>
              <TextBlock Text="Model:" VerticalAlignment="Center" Margin="0,0,4,0"/>
              <TextBox x:Name="TxtModel" Width="170"/>
            </WrapPanel>
            <TextBox x:Name="TxtQuestion" Grid.Row="2" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
            <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,6,0,0">
              <Button x:Name="BtnAsk" Content="Ask" Width="90" Margin="0,0,6,0"/>
              <Button x:Name="BtnCancel" Content="Cancel" Width="80" Margin="0,0,6,0"/>
              <Button x:Name="BtnClearChat" Content="Clear chat" Width="90"/>
            </StackPanel>
          </Grid>
        </TabItem>
        <TabItem Header="Notes">
          <StackPanel Margin="8">
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <CheckBox x:Name="ChkStar" Content="Star" Margin="0,0,16,0"/>
              <CheckBox x:Name="ChkReviewed" Content="Reviewed"/>
            </StackPanel>
            <TextBox x:Name="TxtNote" Height="220" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <Button x:Name="BtnSaveNote" Content="Save notes" Width="100" Margin="0,0,8,0"/>
              <Button x:Name="BtnCopyPath" Content="Copy source path" Width="130" Margin="0,0,8,0"/>
              <Button x:Name="BtnOpenSource" Content="Open source folder" Width="140" Margin="0,0,8,0"/>
              <Button x:Name="BtnOpenSidecar" Content="Show index file" Width="120"/>
            </StackPanel>
            <TextBlock Text="Notes are saved to annotations.json inside the run folder. Nothing else is written." Margin="0,10,0,0" Opacity="0.7"/>
          </StackPanel>
        </TabItem>
      </TabControl>
    </Grid>
    <TextBlock x:Name="TxtStatus" Grid.Row="3" Margin="2,6,2,0" TextTrimming="CharacterEllipsis"/>
  </Grid>
</Window>
'@
[xml]$xaml = $xamlText
$global:W = @{}
$win = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($m in [regex]::Matches($xamlText, 'x:Name="(\w+)"')) { $global:W[$m.Groups[1].Value] = $win.FindName($m.Groups[1].Value) }
$global:W.Win = $win
$G = $global:G

# theme
$dark = ($Cfg.Theme -eq 'dark')
if ($Cfg.Theme -eq 'auto') { try { $dark = ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).AppsUseLightTheme -eq 0) } catch { $dark = $false } }
if ($dark) { $pal = @{ Bg = '#1e1e1e'; Fg = '#e6e6e6'; Panel = '#2a2a2d'; Accent = '#00b4f0'; Dim = '#9a9a9a' } }
else { $pal = @{ Bg = '#ffffff'; Fg = '#1a1a1a'; Panel = '#f2f4f7'; Accent = '#00a0d8'; Dim = '#6b7280' } }
$G.Theme = @{ Bg = (LxBrush $pal.Bg); Fg = (LxBrush $pal.Fg); Panel = (LxBrush $pal.Panel); Accent = (LxBrush $pal.Accent); Dim = (LxBrush $pal.Dim) }
$win.Background = $G.Theme.Bg; $win.Foreground = $G.Theme.Fg
foreach ($n in 'Tree', 'TxtFacts', 'TxtManifest', 'LvSearch', 'TxtTranscript', 'TxtQuestion', 'TxtSearch', 'TxtNote', 'TxtModel', 'DocViewer') {
  $el = $global:W[$n]; if ($el) { $el.Background = $G.Theme.Bg; $el.Foreground = $G.Theme.Fg }
}
foreach ($n in 'Crumb', 'TxtStatus') { $global:W[$n].Foreground = $G.Theme.Fg }

# load data (console shows progress)
LxLog "Loading run: $($Cfg.RunDir)"
LxLoad
$G.W_ChunksOnly = [bool]$Cfg.StartChunksOnly; $G.W_SortName = $false
$global:W.ChkChunks.IsChecked = $G.W_ChunksOnly
$global:W.TxtModel.Text = $Cfg.Ollama.Model
$global:W.Win.Title = "llms-tree explorer - $($G.RootName)"
$global:W.TxtTranscript.Text = "Ask questions about the folder you have selected. The text sent to Ollama is the index data inside the run folder (facts, llms page, child summaries, optional search hits), capped at $($Cfg.AskContextChars) characters.`r`n" + ('-' * 60) + "`r`n"

# events
$W = $global:W
$W.BtnHome.Add_Click({ LxSafe { LxHome } })
$W.BtnBack.Add_Click({ LxSafe { LxBack } })
$W.BtnFwd.Add_Click({ LxSafe { LxFwd } })
$W.ChkChunks.Add_Click({ LxSafe {
  $G = $global:G; $G.W_ChunksOnly = [bool]$global:W.ChkChunks.IsChecked; $rel = '.'; if ($G.Cur) { $rel = $G.Cur.Rel }
  LxBuildTree; $near = $rel; if ($G.W_ChunksOnly) { $near = LxNearestChunk $rel }; if (-not $near) { $near = '.' }
  [void](LxReveal $near) } })
$W.CmbSort.Add_SelectionChanged({ LxSafe {
  $G = $global:G; $G.W_SortName = ($global:W.CmbSort.SelectedIndex -eq 1)
  if ($global:W.Tree.Items.Count -gt 0) { $rel = '.'; if ($G.Cur) { $rel = $G.Cur.Rel }; LxBuildTree; [void](LxReveal $rel) } } })
$W.Tree.Add_SelectedItemChanged({ LxSafe {
  $G = $global:G; if ($G.Suppress) { return }
  $it = $global:W.Tree.SelectedItem
  if ($it -and ($it.Tag -is [string]) -and -not ([string]$it.Tag).StartsWith('__')) { $G.SelItem = $it; LxNavigate ([string]$it.Tag) $null $true $true } } })
$global:DoSearch = { LxSafe {
  $G = $global:G; $W = $global:W; $q = ([string]$W.TxtSearch.Text).Trim(); if (-not $q) { return }
  $W.TxtStatus.Text = 'Searching...'
  $hits = @(LxSearch $q); $G.LastHits = $hits
  $rows = New-Object 'System.Collections.Generic.List[object]'
  foreach ($h in $hits) { $rows.Add([pscustomobject]@{ Path = $h.Rel; Type = $h.Type; Size = (LxSize ([long]$h.Bytes)); Files = ('{0:N0}' -f [long]$h.Files); Snippet = $h.Snippet; Rel = $h.Rel }) }
  $W.LvSearch.ItemsSource = $rows; $W.Tabs.SelectedIndex = 3
  $W.TxtStatus.Text = "$($hits.Count) result(s) for: $q" + $(if ($hits.Count -ge $G.Cfg.SearchMax) { "  (capped at $($G.Cfg.SearchMax))" } else { '' }) } }
$W.BtnSearch.Add_Click($global:DoSearch)
$W.TxtSearch.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { & $global:DoSearch } })
$W.BtnClearSearch.Add_Click({ LxSafe { $global:W.TxtSearch.Text = ''; $global:W.LvSearch.ItemsSource = $null; $global:G.LastHits = @(); $global:W.Tabs.SelectedIndex = 0 } })
$W.LvSearch.Add_MouseDoubleClick({ LxSafe { $sel = $global:W.LvSearch.SelectedItem; if ($sel) { LxNavigate ([string]$sel.Rel) $null $true $false; $global:W.Tabs.SelectedIndex = 0 } } })
$W.BtnAsk.Add_Click({ LxSafe { LxAsk } })
$W.BtnCancel.Add_Click({ LxSafe { LxCancelAsk } })
$W.BtnClearChat.Add_Click({ LxSafe { $global:G.Chat.Clear(); $global:W.TxtTranscript.Clear() } })
$W.BtnSaveNote.Add_Click({ LxSafe { LxSaveNote } })
$W.BtnCopyPath.Add_Click({ LxSafe {
  $G = $global:G; $rel = $G.Cur.Rel; $p = $G.SourceRoot; if ($rel -ne '.') { $p = Join-Path $G.SourceRoot $rel }
  [System.Windows.Clipboard]::SetText($p); $global:W.TxtStatus.Text = "Copied: $p" } })
$W.BtnOpenSource.Add_Click({ LxSafe {
  $G = $global:G; if (-not $G.Cfg.AllowOpenSource) { $global:W.TxtStatus.Text = 'Disabled (AllowOpenSource = false)'; return }
  $rel = $G.Cur.Rel; $p = $G.SourceRoot; if ($rel -ne '.') { $p = Join-Path $G.SourceRoot $rel }
  if (Test-Path -LiteralPath $p) { Start-Process explorer.exe ('"' + $p + '"') } else { $global:W.TxtStatus.Text = "Source path not reachable: $p" } } })
$W.BtnOpenSidecar.Add_Click({ LxSafe {
  $G = $global:G; $rel = $G.Cur.Rel; $dir = Join-Path $G.Cfg.RunDir $G.Cfg.TreeSubdir; if ($rel -ne '.') { foreach ($s in $rel.Split('\')) { $dir = Join-Path $dir $s } }
  $f = Join-Path $dir $G.Cfg.LlmsFileName; if (Test-Path -LiteralPath $f) { Start-Process explorer.exe ('/select,"' + $f + '"') } elseif (Test-Path -LiteralPath $dir) { Start-Process explorer.exe ('"' + $dir + '"') } else { $global:W.TxtStatus.Text = 'No index file for this folder.' } } })

LxBuildTree
LxNavigate '.' $null $true $false
[void]$win.ShowDialog()
}   # end $App

# ---- STA launcher: WPF needs a single-threaded apartment; the Windows PowerShell console is MTA by default
$apt = [Threading.Thread]::CurrentThread.GetApartmentState()
if ($Cfg.SelfTest -or $apt -eq 'STA') { & $App $Cfg }
else {
  $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
  $ps = [powershell]::Create(); $ps.Runspace = $rs
  [void]$ps.AddScript($App.ToString()).AddArgument($Cfg)
  try {
    [void]$ps.Invoke()
    foreach ($er in $ps.Streams.Error) { Write-Host ("ERROR: " + $er) -ForegroundColor Red }
  } finally { $ps.Dispose(); $rs.Dispose() }
}
}