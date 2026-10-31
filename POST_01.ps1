& {
<#
  llms-tree  MEGA MANIFEST  -  roll up every <chunk>\llms-manifest.json into single files. Read-only on the tree; writes into <RunDir>.
  PASTE-ABLE. Edit $RunDir, paste. Run it after Pass 2 (and ideally after Pass 3, so summaries are included).
  Outputs (all in <RunDir>):
    mega-manifest.json   {generated, source, counts, nodes[], edges[]}   one document, graph-shaped
    mega-manifest.jsonl  one JSON node per line (children inline)         easy for RAG / embeddings / grep
    nodes.csv, edges.csv                                                  LPG-style import (Neo4j, etc.)
    mega-catalog.md      flat, VS Code-friendly catalogue: path, type, size, summary
#>
# =====================================================================  VARIABLES (edit me)
$RunDir           = 'C:\Users\zasz_\llms-out\20261030-202409'
$TreeSubdir       = 'tree'
$ManifestFileName = 'llms-manifest.json'
$LlmsFileName     = 'llms-txt.md'        # must match Pass 2 (used for the "file" field and catalogue links)
# =====================================================================  END VARIABLES

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function ConvertTo-LongPath([string]$p) {
  if ([IO.Path]::DirectorySeparatorChar -ne '\') { return $p }
  if ($p.StartsWith('\\?\')) { return $p }
  if ($p.StartsWith('\\')) { return '\\?\UNC\' + $p.Substring(2) }
  return '\\?\' + $p
}
function Format-Size([long]$b) {
  if ($b -ge 1TB) { return ('{0:N1} TB' -f ($b / 1TB)) }; if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
  if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }; if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }; return "$b B"
}
function ConvertTo-Url([string]$path) {
  return (($path.Split('/') | ForEach-Object { [uri]::EscapeDataString($_).Replace('(', '%28').Replace(')', '%29').Replace("'", '%27').Replace('!', '%21').Replace('*', '%2A') }) -join '/')
}

$tree = Join-Path $RunDir $TreeSubdir
if (-not (Test-Path -LiteralPath $tree)) { throw "No tree folder at $tree (run Pass 2 first)" }
$runInfo = $null
$rjp = Join-Path $RunDir 'run.json'
if (Test-Path -LiteralPath $rjp) { $runInfo = Get-Content -LiteralPath $rjp -Raw | ConvertFrom-Json }

$items = New-Object 'System.Collections.Generic.List[object]'
foreach ($mpath in [IO.Directory]::EnumerateFiles((ConvertTo-LongPath $tree), $ManifestFileName, [IO.SearchOption]::AllDirectories)) {
  $mf = [IO.File]::ReadAllText($mpath, $utf8) | ConvertFrom-Json
  if ($mf.id -eq '.') { $fileRel = $LlmsFileName } else { $fileRel = "$($mf.id)/$LlmsFileName" }
  $node = [ordered]@{
    id = $mf.id; name = $mf.name; type = $mf.type; rule = $mf.rule; nested = $mf.nested; parent = $mf.parent
    summary = $mf.summary; file = $fileRel
    files = $mf.stats.files; bytes = $mf.stats.bytes; directFiles = $mf.stats.directFiles
    minWrite = $mf.stats.minWrite; maxWrite = $mf.stats.maxWrite
    topExt = $mf.topExt; extFamilies = $mf.extFamilies; markers = $mf.markers; subMarkers = $mf.subMarkers
    flags = @($mf.flags); crumbs = @($mf.crumbs); readmes = @($mf.readmes); treeSig = $mf.treeSig
    children = @($mf.children); collapsedWrappers = @($mf.collapsedWrappers); groups = @($mf.groups); subfoldersListed = @($mf.subfoldersListed)
  }
  $items.Add([pscustomobject]@{ Id = [string]$mf.id; Obj = $node; Json = ($node | ConvertTo-Json -Compress -Depth 6) })
}
$items = @($items | Sort-Object { $_.Id })
Write-Host "Read $($items.Count) manifests."

# ---- edges (parent -> child chunk; collapsed wrappers are already skipped in `children`)
$edges = New-Object 'System.Collections.Generic.List[object]'
foreach ($it in $items) { foreach ($ch in @($it.Obj.children)) { $edges.Add([pscustomobject]@{ from = $it.Id; to = [string]$ch; rel = 'HAS_CHUNK' }) } }

# ---- JSONL
[IO.File]::WriteAllLines((Join-Path $RunDir 'mega-manifest.jsonl'), [string[]]@($items | ForEach-Object { $_.Json }), $utf8)

# ---- one JSON document (assembled from the compact node strings; avoids one giant ConvertTo-Json call)
$meta = ([ordered]@{ generated = (Get-Date -Format 'o'); source = $(if ($runInfo) { $runInfo.Root } else { '' }); run = $RunDir
                     nodeCount = $items.Count; edgeCount = $edges.Count } | ConvertTo-Json -Compress)
$edgeJson = @($edges | ForEach-Object { $_ | ConvertTo-Json -Compress })
$doc = $meta.Substring(0, $meta.Length - 1) + ',"nodes":[' + "`n" + (($items | ForEach-Object { $_.Json }) -join ",`n") + "`n" + '],"edges":[' + "`n" + ($edgeJson -join ",`n") + "`n]}"
[IO.File]::WriteAllText((Join-Path $RunDir 'mega-manifest.json'), $doc, $utf8)

# ---- CSV (LPG-style)
$items | ForEach-Object { [pscustomobject]@{ id = $_.Id; name = $_.Obj.name; type = $_.Obj.type; nested = $_.Obj.nested; bytes = $_.Obj.bytes; files = $_.Obj.files
                                              minWrite = $_.Obj.minWrite; maxWrite = $_.Obj.maxWrite; flags = (@($_.Obj.flags) -join '|'); treeSig = $_.Obj.treeSig; summary = $_.Obj.summary } } |
  Export-Csv -LiteralPath (Join-Path $RunDir 'nodes.csv') -NoTypeInformation -Encoding UTF8
$edges | Export-Csv -LiteralPath (Join-Path $RunDir 'edges.csv') -NoTypeInformation -Encoding UTF8

# ---- flat catalogue (open in VS Code, Ctrl+Shift+V)
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("# Catalogue of chunks`n`n> $($items.Count) chunks, $($edges.Count) parent-child links. Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm').`n`n")
foreach ($it in $items) {
  $o = $it.Obj
  $link = ConvertTo-Url ("$TreeSubdir/" + $o.file)
  $sum = [string]$o.summary; if ($sum -eq 'TODO' -or -not $sum) { $sum = '(no summary yet)' }
  $flag = ''; if (@($o.flags).Count) { $flag = ' [' + (@($o.flags) -join ', ') + ']' }
  [void]$sb.Append("- [$($o.id.Replace('[','\[').Replace(']','\]'))]($link) - $($o.type), $(Format-Size ([long]$o.bytes)), $('{0:N0}' -f [long]$o.files) files$flag`n  $sum`n")
}
[IO.File]::WriteAllText((Join-Path $RunDir 'mega-catalog.md'), $sb.ToString(), $utf8)
Write-Host "Wrote mega-manifest.json, mega-manifest.jsonl, nodes.csv, edges.csv, mega-catalog.md in $RunDir"
}