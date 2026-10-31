& {
<#
  llms-tree MEGA MANIFEST & LPG WEBAPP CONVERTER (PowerShell 5.1 Compatible)
  Rolls up every <chunk>\llms-manifest.json into:
    - mega-manifest.json  (LPG Webapp Graph JSON format with Tiered Depth Coloring)
    - mega-manifest.jsonl (line-by-line JSON nodes)
    - nodes.csv, edges.csv (LPG-style imports)
    - mega-catalog.md     (VS Code readable markdown catalogue)
#>

# =====================================================================  VARIABLES (edit me)
$RunDir           = 'C:\Users\zasz_\llms-out\20261030-202409'
$TreeSubdir       = 'tree'
$ManifestFileName = 'llms-manifest.json'
$LlmsFileName     = 'llms-txt.md'

# LPG Webapp Visual & Graph Config
$ExportName       = 'llms-mega-manifest'
$GraphId          = 'graph1'

# Tiered Depth Styling (Index 0 = Root, Index 1 = Level 1, etc. Caps out at the last color)
$TierColors       = @(
    '#00b4f0', # Level 0 (ROOT - Cyan/Blue)
    '#70db43', # Level 1 (Green)
    '#c8f000', # Level 2 (Yellow-Green)
    '#a000f0', # Level 3 (Purple)
    '#ff6666'  # Level 4+ (Coral/Red for deep subfolders)
)
$TierRadii        = @(50, 40, 30, 25, 20) # Sizing scales down as depth increases
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
  $nodeId   = if ($mf.id -eq '.') { 'llms-root' } else { [string]$mf.id }
  $nodeName = if ($mf.name) { $mf.name } else { $nodeId }

  # --- Programmatic Depth & Tier Calculation ---
  $depth = if ($mf.id -eq '.') { 0 } else { ($mf.id -split '/').Count }
  $colorIndex = [Math]::Min($depth, ($TierColors.Length - 1))
  $radiusIndex = [Math]::Min($depth, ($TierRadii.Length - 1))

  $nodeColor  = $TierColors[$colorIndex]
  $nodeRadius = $TierRadii[$radiusIndex]

  # Original structured node object
  $node = [ordered]@{
    id = $mf.id; name = $mf.name; type = $mf.type; rule = $mf.rule; nested = $mf.nested; parent = $mf.parent
    summary = $mf.summary; file = $fileRel
    files = $mf.stats.files; bytes = $mf.stats.bytes; directFiles = $mf.stats.directFiles
    minWrite = $mf.stats.minWrite; maxWrite = $mf.stats.maxWrite
    topExt = $mf.topExt; extFamilies = $mf.extFamilies; markers = $mf.markers; subMarkers = $mf.subMarkers
    flags = @($mf.flags); crumbs = @($mf.crumbs); readmes = @($mf.readmes); treeSig = $mf.treeSig
    children = @($mf.children); collapsedWrappers = @($mf.collapsedWrappers); groups = @($mf.groups); subfoldersListed = @($mf.subfoldersListed)
  }

  # Webapp graph node object
  $webappProps = [ordered]@{
    type        = [string]$mf.type
    rule        = [string]$mf.rule
    summary     = if ($mf.summary) { [string]$mf.summary } else { '' }
    bytes       = [long]$mf.stats.bytes
    files       = [long]$mf.stats.files
    directFiles = [long]$mf.stats.directFiles
    flags       = (@($mf.flags) -join ', ')
    treeSig     = [string]$mf.treeSig
    depth       = $depth
  }

  $webappNode = [ordered]@{
    id         = $nodeId
    label      = $nodeName
    x          = 0.0
    y          = 0.0
    color      = $nodeColor
    r          = $nodeRadius
    fontSize   = 11
    labelAlign = 'center'
    labelColor = ''
    props      = $webappProps
  }

  $jsonLine = $node | ConvertTo-Json -Compress -Depth 6
  $items.Add([pscustomobject]@{ Id = [string]$mf.id; NodeId = $nodeId; Children = @($mf.children); Obj = $node; WebappNode = $webappNode; Json = $jsonLine })
}

$items = @($items | Sort-Object { $_.Id })
Write-Host "Read $($items.Count) manifests and calculated tiered depths."

# ---- Edges (Tree Hierarchy)
$edges = New-Object 'System.Collections.Generic.List[object]'
$webappEdges = New-Object 'System.Collections.Generic.List[object]'
$edgeCounter = 1

foreach ($it in $items) { 
  foreach ($ch in $it.Children) { 
    $childId = if ($ch -eq '.') { 'llms-root' } else { [string]$ch }
    
    $edges.Add([pscustomobject]@{ from = $it.Id; to = [string]$ch; rel = 'HAS_CHUNK' }) 
    
    $webappEdges.Add([pscustomobject]@{
      id        = "edge-$edgeCounter"
      source    = $childId
      target    = $it.NodeId
      label     = ""
      directed  = $true
      style     = "straight"
      dash      = "solid"
      arrowSize = "medium"
      props     = [ordered]@{}
    })
    $edgeCounter++
  } 
}

# ---- 1. JSONL Output
[IO.File]::WriteAllLines((Join-Path $RunDir 'mega-manifest.jsonl'), [string[]]@($items | ForEach-Object { $_.Json }), $utf8)

# ---- 2. LPG Webapp Graph JSON Output (mega-manifest.json)
$webappNodesArray = foreach ($it in $items) { $it.WebappNode }
$webappEdgesArray = foreach ($we in $webappEdges) { $we }

$webappGraphDoc = [ordered]@{
  nodes           = $webappNodesArray
  edges           = $webappEdgesArray
  idCounter       = $edgeCounter
  graphId         = $GraphId
  graphMeta       = [ordered]@{ edgedefault = "undirected" }
  exportName      = $ExportName
  view            = [ordered]@{ x = 0; y = 0; k = 1.0 }
  clampNodeLabels = $false
}

$webappJsonOutput = $webappGraphDoc | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText((Join-Path $RunDir 'mega-manifest.json'), $webappJsonOutput, $utf8)

# ---- 3. CSV Outputs (LPG-style)
$items | ForEach-Object { 
  [pscustomobject]@{ 
    id = $_.Id; name = $_.Obj.name; type = $_.Obj.type; nested = $_.Obj.nested; bytes = $_.Obj.bytes; files = $_.Obj.files
    minWrite = $_.Obj.minWrite; maxWrite = $_.Obj.maxWrite; flags = (@($_.Obj.flags) -join '|'); treeSig = $_.Obj.treeSig; summary = $_.Obj.summary 
  } 
} | Export-Csv -LiteralPath (Join-Path $RunDir 'nodes.csv') -NoTypeInformation -Encoding UTF8

$edges | Export-Csv -LiteralPath (Join-Path $RunDir 'edges.csv') -NoTypeInformation -Encoding UTF8

# ---- 4. Flat Catalogue Markdown Output (mega-catalog.md)
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

Write-Host "Success! Generated all tier-painted files in ${RunDir}:"
Write-Host "  - mega-manifest.json (LPG Webapp Graph format with depth coloring)"
Write-Host "  - mega-manifest.jsonl"
Write-Host "  - nodes.csv & edges.csv"
Write-Host "  - mega-catalog.md"
}