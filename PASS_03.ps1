& {
<#
  llms-tree  Pass 3  -  SUMMARIZE with a local Ollama model. Replaces "> TODO-SUMMARY" in the sidecar llms.txt files.
  PASTE-ABLE: no param(), no .ps1 needed. Edit VARIABLES, paste all.
  Reads : <RunDir>\pass2-index.tsv, <RunDir>\tree\...\llms.txt + llms-manifest.json  (Pass 2 output)
          + a few small text files from the SOURCE tree (README etc: first $HeadLines lines / $HeadMaxBytes bytes each)
  Writes: the same sidecar llms.txt (summary line + footer) and the manifest "summary" field, plus <RunDir>\pass3-log.tsv
  Order : deepest chunks first, so a parent's summary is written from its children's summaries (+ its own evidence).
  Safe  : $DryRun = $true (default) calls NO model and writes NOTHING; it prints the evidence/prompt for $PreviewCount chunks.
          Re-runs resume automatically (finished chunks no longer contain TODO-SUMMARY). $Redo = $true regenerates all.
#>

# =====================================================================  VARIABLES (edit me)
$RunDir      = 'C:\Users\zasz_\llms-out\20261031-124239'   # Pass 0/1/2 run folder
$DryRun      = $false                                # $false = call the model and write summaries
$Only        = ''                                   # '' = all chunks; or one chunk id, e.g. 'steamapps/common/Fallout 4'  (use '.' for the root)
$Limit       = 0                                    # 0 = no limit; N = stop after N model calls (good for a first trial: 3)
$Redo        = $false                               # $true = also regenerate chunks that already have a summary
$SourceRoot  = ''                                   # '' = Root recorded in run.json; set if the drive letter/path changed

$Mode        = 'api'                                # 'api' = REST (recommended) | 'cli' = pipe the prompt to `ollama run`
$Model       = 'gemma4:latest'
$OllamaUrl   = 'http://localhost:11434'
$Think       = $false                               # --think=false
$Temperature = 0.2
$NumPredict  = 400                                  # max tokens generated (115 words is ~170 tokens)
$KeepAlive   = '30m'
$TimeoutSec  = 900
$Retries     = 1                                    # extra attempts when the answer is empty / too short

$MinWords    = 25
$MaxWords    = 115
$HeadLines   = 80                                   # per text file
$HeadMaxBytes= 4096                                 # per text file
$TextFilesMax= 4                                    # max text files read per chunk (README-class first)
$OtherFilesMax = 2                                  # of those, at most this many are NOT readme-class (code/config/etc.)
$OtherHeadLines = 25                                # shorter excerpt for non-readme files
$OtherHeadMaxBytes = 1500
$DirNameSample = 30                                 # subfolder names shown to the model
$FileNameSample = 30                                # loose file names shown to the model
$EnumCap     = 3000                                 # never enumerate more than this many entries in one folder
$EvidenceMaxChars = 14000
$ChildChars  = 220                                  # per-child summary excerpt when summarising a parent
$ChildMax    = 40
$PreviewCount= 2

$LlmsFileName     = 'llms-txt.md'   # must match Pass 2
$ManifestFileName = 'llms-manifest.json'
$TextExts    = @('.md','.txt','.rst','.cfg','.ini','.json','.yml','.yaml','.toml','.xml','.csv','.py','.m','.ps1','.sh','.c','.h','.cpp','.cs','.js','.ts','.java','.go','.rs','.bat','.cmd','.html','.tex')
$PreferNames = @('readme.md','readme.txt','readme','readme.rst','package.json','pyproject.toml','setup.py','cargo.toml','makefile','index.md','manifest.json')
$TypeMeaning = @{ 'REPO'='git repository (version-controlled project)'; 'OPAQUE-BULK'='bulk collection of many similar files'; 'BLOB'='a few very large files (archives or data blobs)'
                  'DATASET'='dataset (signal recordings or data files)'; 'PROJECT'='software project with build or readme markers'
                  'CONTAINER'='folder holding several separate sub-collections'; 'WRAPPER'='pass-through folder around a larger collection'
                  'MIXED-LEAF'='mixed-content folder with no clear internal structure' }
# =====================================================================  END VARIABLES

$ErrorActionPreference = 'Stop'
$IsWin = ([IO.Path]::DirectorySeparatorChar -eq '\')
$utf8 = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------- helpers
function ConvertTo-LongPath([string]$p) {
  if (-not $IsWin) { return $p }
  if ($p.StartsWith('\\?\')) { return $p }
  if ($p.StartsWith('\\')) { return '\\?\UNC\' + $p.Substring(2) }
  return '\\?\' + $p
}
function Format-Size([long]$b) {
  if ($b -ge 1TB) { return ('{0:N1} TB' -f ($b / 1TB)) }
  if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
  if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }
  if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
  return "$b B"
}
function Join-Rel([string]$baseDir, [string]$rel, [string]$sep) {   # rel uses '\' (index) or '/' (manifest id)
  $d = $baseDir
  if ($rel -ne '.') { foreach ($seg in ($rel -split '[\\/]')) { if ($seg) { $d = [IO.Path]::Combine($d, $seg) } } }
  return $d
}
function Get-Head([string]$path, [int]$maxLines, [int]$maxBytes) {
  $buf = New-Object byte[] $maxBytes; $got = 0
  try {
    $fs = [IO.File]::Open((ConvertTo-LongPath $path), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $got = $fs.Read($buf, 0, $maxBytes) } finally { $fs.Dispose() }
  } catch { return $null }
  if ($got -le 0) { return '' }
  if ($got -ge 2 -and $buf[0] -eq 0xFF -and $buf[1] -eq 0xFE) { $txt = [Text.Encoding]::Unicode.GetString($buf, 2, $got - 2) }
  elseif ($got -ge 3 -and $buf[0] -eq 0xEF -and $buf[1] -eq 0xBB -and $buf[2] -eq 0xBF) { $txt = [Text.Encoding]::UTF8.GetString($buf, 3, $got - 3) }
  else {
    for ($i = 0; $i -lt $got; $i++) { if ($buf[$i] -eq 0) { return $null } }       # binary
    $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $got)
  }
  $lines = $txt -split "`r?`n"
  if ($lines.Count -gt $maxLines) { $lines = $lines[0..($maxLines - 1)] }
  return ($lines -join "`n").TrimEnd()
}
function Get-Blockquote([string]$text) {
  foreach ($ln in ($text -split "`n")) { if ($ln.StartsWith('> ')) { return $ln.Substring(2).Trim() } }
  return ''
}
function Format-Summary([string]$t) {
  if (-not $t) { return '' }
  $t = $t -replace '(?s)<think>.*?</think>', ''
  $t = $t -replace '\x1B\[[0-9;?]*[A-Za-z]', ''
  $t = $t -replace '[\r\n]+', ' '
  $t = $t -replace '[*`#_]{1,3}', ''
  $t = $t -replace '^\s*(summary|answer)\s*:\s*', ''
  $t = ($t -replace '\s+', ' ').Trim().Trim('"').Trim()
  return $t
}
function Limit-Words([string]$t) {
  $w = @($t -split '\s+' | Where-Object { $_ })
  if ($w.Count -le $MaxWords) { return ($w -join ' ') }
  $cut = ($w[0..($MaxWords - 1)] -join ' ')
  $i = $cut.LastIndexOf('. ')
  if ($i -gt 0) { $head = $cut.Substring(0, $i + 1); if (@($head -split '\s+').Count -ge $MinWords) { return $head } }
  return ($cut.TrimEnd('.', ',', ';') + '...')
}
function Get-WordCount([string]$t) { return @($t -split '\s+' | Where-Object { $_ }).Count }

function Invoke-Model([string]$prompt) {
  if ($Mode -eq 'api') {
    $body = @{ model = $Model; prompt = $prompt; stream = $false; think = $Think; keep_alive = $KeepAlive
               options = @{ temperature = $Temperature; num_predict = $NumPredict } } | ConvertTo-Json -Depth 5 -Compress
    $resp = Invoke-WebRequest -UseBasicParsing -Uri "$OllamaUrl/api/generate" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
              -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSec
    $obj = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
    return [string]$obj.response
  }
  $tf = $Think.ToString().ToLower()
  $out = $prompt | & ollama run $Model "--think=$tf" 2>$null
  return ($out -join "`n")
}

# ---------------------------------------------------------------- load run
$idxPath = Join-Path $RunDir 'pass2-index.tsv'
if (-not (Test-Path -LiteralPath $idxPath)) { throw "pass2-index.tsv not found in $RunDir (run Pass 2 with `$DryRun = `$false first)" }
$treeRoot = Join-Path $RunDir 'tree'
if (-not $SourceRoot) {
  $rj = Get-Content -LiteralPath (Join-Path $RunDir 'run.json') -Raw | ConvertFrom-Json
  $SourceRoot = $rj.Root
}
Write-Host "Source root: $SourceRoot"
$chunkRows = @()
foreach ($row in (Import-Csv -LiteralPath $idxPath -Delimiter "`t")) {
  if ($row.Type -eq 'GROUP') { continue }
  if ($row.Rel -eq '.') { $depth = 0 } else { $depth = @($row.Rel -split '\\').Count }
  $id = $row.Rel.Replace('\', '/')
  if ($Only -and $id -ne $Only) { continue }
  $chunkRows += [pscustomobject]@{ Rel = $row.Rel; Id = $id; Type = $row.Type; File = $row.File; Depth = $depth }
}
$chunkRows = @($chunkRows | Sort-Object { $_.Depth } -Descending)
Write-Host "$($chunkRows.Count) chunk(s) in scope; mode=$Mode model=$Model dryRun=$DryRun"

if (-not $DryRun -and $Mode -eq 'api') {
  try {
    $tags = Invoke-RestMethod -UseBasicParsing -Uri "$OllamaUrl/api/tags" -TimeoutSec 20
    $names = @($tags.models | ForEach-Object { $_.name })
    $ok = ($names -contains $Model) -or ($names -contains "$Model`:latest")
    if (-not $ok) { throw "Model '$Model' is not in 'ollama list' ($($names -join ', '))." }
    Write-Host "Ollama reachable; model present."
  } catch { throw "Ollama preflight failed at $OllamaUrl : $($_.Exception.Message)" }
}
if ($Mode -eq 'cli') { try { [Console]::OutputEncoding = $utf8; $OutputEncoding = $utf8 } catch {} }

# ---------------------------------------------------------------- evidence + prompt
function New-Evidence($rel, $man, [string]$myDir) {
  $sb = New-Object System.Text.StringBuilder
  $srcDir = Join-Rel $SourceRoot $rel '\'
  $kind = $TypeMeaning[[string]$man.type]; if (-not $kind) { $kind = [string]$man.type }
  $facts = "Name: $($man.name)`nPath: $($man.id)`nKind: $kind`nSize: $(Format-Size ([long]$man.stats.bytes)) in $('{0:N0}' -f [long]$man.stats.files) files"
  if ($man.stats.minWrite) { $facts += "`nFile dates: $($man.stats.minWrite) to $($man.stats.maxWrite)" }
  if ($man.topExt) { $facts += "`nTop file types by size: $($man.topExt)" }
  if ($man.crumbs -and @($man.crumbs).Count) { $facts += "`nName hints: $(@($man.crumbs) -join ', ')" }
  [void]$sb.Append("FACTS`n$facts`n`n")

  # text files from the source folder
  $loose = @(); $enumerated = 0; $srcOk = Test-Path -LiteralPath (ConvertTo-LongPath $srcDir)
  if ($srcOk) {
    try {
      foreach ($fp in [IO.Directory]::EnumerateFiles((ConvertTo-LongPath $srcDir))) {
        $loose += [IO.Path]::GetFileName($fp); $enumerated++
        if ($enumerated -ge $EnumCap) { break }
      }
    } catch {}
  } else { [void]$sb.Append("(source folder not reachable from this machine: $srcDir)`n`n") }
  $primary = New-Object 'System.Collections.Generic.List[string]'
  foreach ($nm in @($man.readmes)) { if ($nm -and ($loose -contains $nm) -and $primary.Count -lt $TextFilesMax) { $primary.Add($nm) } }
  foreach ($pn in $PreferNames) { foreach ($nm in $loose) { if ($nm.ToLowerInvariant() -eq $pn -and -not $primary.Contains($nm) -and $primary.Count -lt $TextFilesMax) { $primary.Add($nm) } } }
  $secondary = New-Object 'System.Collections.Generic.List[string]'
  $secMax = [math]::Min($OtherFilesMax, [math]::Max(0, $TextFilesMax - $primary.Count))
  if ($primary.Count -eq 0) { $secMax = [math]::Min($OtherFilesMax, $TextFilesMax) }
  foreach ($nm in ($loose | Sort-Object)) {
    if ($secondary.Count -ge $secMax) { break }
    $ex = [IO.Path]::GetExtension($nm).ToLowerInvariant()
    if (($TextExts -contains $ex) -and -not $primary.Contains($nm)) { $secondary.Add($nm) }
  }
  foreach ($nm in $primary) {
    $head = Get-Head ([IO.Path]::Combine($srcDir, $nm)) $HeadLines $HeadMaxBytes
    if ($head) { [void]$sb.Append("FILE: $nm (first lines)`n$head`n`n") }
  }
  foreach ($nm in $secondary) {
    $head = Get-Head ([IO.Path]::Combine($srcDir, $nm)) $OtherHeadLines $OtherHeadMaxBytes
    if ($head) { [void]$sb.Append("FILE: $nm (short excerpt)`n$head`n`n") }
  }
  if ($loose.Count -gt 0) {
    $show = @($loose | Select-Object -First $FileNameSample) -join ', '
    $more = ''; if ($loose.Count -ge $EnumCap) { $more = " (at least $EnumCap files directly here)" } elseif ($loose.Count -gt $FileNameSample) { $more = " (of $($loose.Count) files directly here)" }
    [void]$sb.Append("FILES DIRECTLY IN THIS FOLDER$more`: $show`n`n")
  }
  if ($srcOk) {
    $dn = @(); $dc = 0
    try { foreach ($dp in [IO.Directory]::EnumerateDirectories((ConvertTo-LongPath $srcDir))) { $dc++; if ($dn.Count -lt $DirNameSample) { $dn += [IO.Path]::GetFileName($dp) }; if ($dc -ge $EnumCap) { break } } } catch {}
    if ($dn.Count -gt 0) { $dm = ''; if ($dc -gt $dn.Count) { $dm = " (first $($dn.Count) of $dc)" }; [void]$sb.Append("SUBFOLDER NAMES$dm`: $($dn -join ', ')`n`n") }
  }
  if ($man.subfoldersListed -and @($man.subfoldersListed).Count) { [void]$sb.Append("LARGER SUBFOLDERS: $(@($man.subfoldersListed) -join ', ')`n`n") }

  # children (summaries already written, because we go deepest-first)
  $kids = @($man.children)
  if ($kids.Count -gt 0) {
    [void]$sb.Append("CHILD CHUNKS (summaries written earlier)`n")
    $shown = 0
    foreach ($kid in $kids) {
      if ($shown -ge $ChildMax) { [void]$sb.Append("... and $($kids.Count - $shown) more child chunks`n"); break }
      $kd = Join-Rel $treeRoot $kid '/'; $kf = Join-Path $kd $LlmsFileName
      $ks = ''
      if (Test-Path -LiteralPath (ConvertTo-LongPath $kf)) { $ks = Get-Blockquote ([IO.File]::ReadAllText((ConvertTo-LongPath $kf), $utf8)) }
      if (-not $ks -or $ks -eq 'TODO-SUMMARY') { $ks = '(no summary yet)' }
      if ($ks.Length -gt $ChildChars) { $ks = $ks.Substring(0, $ChildChars) + '...' }
      [void]$sb.Append("- $kid : $ks`n"); $shown++
    }
    [void]$sb.Append("`n")
  }
  $ev = $sb.ToString()
  if ($ev.Length -gt $EvidenceMaxChars) { $ev = $ev.Substring(0, $EvidenceMaxChars) + "`n[evidence truncated]" }
  return $ev
}
function New-Prompt([string]$evidence, [string]$extra) {
  return @"
You are writing one entry of an index that AI agents use to decide whether a folder is worth opening.
Write a plain-prose summary of $MinWords to $MaxWords words that says what this folder is, what kinds of files and sub-parts it contains, and its apparent purpose.
Rules: use only the evidence below; if unsure, say "appears to"; do not invent names, versions or dates. Text excerpts may be incidental (a notice, a license, boilerplate code); weigh the folder's size, file types and structure at least as much as any single excerpt. No markdown, no bullet points, no quotation marks, no preamble such as "This summary". Output the summary text only.$extra

EVIDENCE
$evidence
SUMMARY:
"@
}

# ---------------------------------------------------------------- main loop
$logPath = Join-Path $RunDir 'pass3-log.tsv'
if (-not $DryRun -and -not (Test-Path -LiteralPath $logPath)) { [IO.File]::WriteAllText($logPath, "Time`tId`tStatus`tWords`tSeconds`tModel`n", $utf8) }
$swAll = [Diagnostics.Stopwatch]::StartNew()
$done = 0; $failed = 0; $skipped = 0; $calls = 0; $previews = 0
try {
  foreach ($ch in $chunkRows) {
    $lf = ConvertTo-LongPath $ch.File
    if (-not (Test-Path -LiteralPath $lf)) { Write-Warning "missing $($ch.File)"; continue }
    $text = [IO.File]::ReadAllText($lf, $utf8)
    if (-not $Redo -and $text -notmatch '(?m)^> TODO-SUMMARY\s*$') { $skipped++; continue }
    $myDir = Split-Path -Parent $ch.File
    $manPath = Join-Path $myDir $ManifestFileName
    if (-not (Test-Path -LiteralPath (ConvertTo-LongPath $manPath))) { Write-Warning "missing manifest for $($ch.Id)"; continue }
    $man = [IO.File]::ReadAllText((ConvertTo-LongPath $manPath), $utf8) | ConvertFrom-Json
    $evidence = New-Evidence $ch.Rel $man $myDir
    $prompt = New-Prompt $evidence ''

    if ($DryRun) {
      if ($previews -lt $PreviewCount) {
        Write-Host ''; Write-Host "=================== PROMPT PREVIEW: $($ch.Id) ($($ch.Type), $($prompt.Length) chars) ==================="; Write-Host $prompt
        $previews++
      }
      $done++; continue
    }
    if ($Limit -gt 0 -and $calls -ge $Limit) { Write-Host "Limit of $Limit model calls reached."; break }

    $sw = [Diagnostics.Stopwatch]::StartNew(); $summary = ''; $status = 'ok'; $attempt = 0
    while ($true) {
      $extra = ''; if ($attempt -gt 0) { $extra = "`nPrevious answer was too short or empty. Write between $MinWords and $MaxWords words." }
      try { $raw = Invoke-Model (New-Prompt $evidence $extra) } catch { $raw = ''; $status = 'error: ' + ($_.Exception.Message -replace '[\r\n\t]', ' ') }
      $calls++
      $summary = Limit-Words (Format-Summary $raw)
      if ((Get-WordCount $summary) -ge $MinWords) { $status = 'ok'; break }
      if ($attempt -ge $Retries) { break }
      $attempt++
    }
    $words = Get-WordCount $summary
    if ($words -lt 8) {
      $failed++; if ($status -eq 'ok') { $status = "too-short($words words)" }
      Write-Host ("[{0}] FAILED {1}: {2}" -f $swAll.Elapsed.ToString('hh\:mm\:ss'), $ch.Id, $status)
    } else {
      if ($words -lt $MinWords) { $status = "short($words words)" }
      # --- write llms.txt
      $lines = $text -split "`n"
      for ($li = 0; $li -lt $lines.Count; $li++) { if ($lines[$li].StartsWith('> ')) { $lines[$li] = "> $summary"; break } }
      $newText = ($lines -join "`n")
      $newText = $newText -replace 'summary pending \(Pass 3\)', ("summary by $Model on " + (Get-Date -Format 'yyyy-MM-dd'))
      [IO.File]::WriteAllText($lf, $newText, $utf8)
      # --- write manifest summary field
      $mj = [IO.File]::ReadAllText((ConvertTo-LongPath $manPath), $utf8)
      $mt = [regex]::Match($mj, '"summary"\s*:\s*"(?:[^"\\]|\\.)*"')
      if ($mt.Success) {
        $q = ($summary | ConvertTo-Json -Compress)
        $mj = $mj.Substring(0, $mt.Index) + '"summary": ' + $q + $mj.Substring($mt.Index + $mt.Length)
        [IO.File]::WriteAllText((ConvertTo-LongPath $manPath), $mj, $utf8)
      }
      $done++
      Write-Host ("[{0}] {1}  ({2} words, {3:N1}s)" -f $swAll.Elapsed.ToString('hh\:mm\:ss'), $ch.Id, $words, $sw.Elapsed.TotalSeconds)
    }
    [IO.File]::AppendAllText($logPath, ("{0}`t{1}`t{2}`t{3}`t{4:N1}`t{5}`n" -f (Get-Date -Format s), $ch.Id, $status, $words, $sw.Elapsed.TotalSeconds, $Model), $utf8)
  }
} finally { }
Write-Host ''
if ($DryRun) { Write-Host "Dry run: $done chunk(s) need summaries, $skipped already done. No model was called and nothing was written." ; Write-Host 'Set $DryRun = $false (try $Limit = 3 first) and paste again.' }
else { Write-Host ("Done: {0} written, {1} failed, {2} already had summaries, {3} model calls, {4}. Log: {5}" -f $done, $failed, $skipped, $calls, $swAll.Elapsed.ToString('hh\:mm\:ss'), $logPath) }
}