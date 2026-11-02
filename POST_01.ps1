& {
<#
  llms-tree GAP-FILLING MEGA MANIFEST & LPG WEBAPP CONVERTER (PowerShell 5.1)
  Fixed root ID mapping so all top-level clusters correctly anchor to 'llms-root'.
#>

# =====================================================================  VARIABLES (edit me)
$RunDir           = 'C:\Users\zasz_\llms-out\20261101-211907'
$TreeSubdir       = 'tree'
$ManifestFileName = 'llms-manifest.json'
$LlmsFileName     = 'llms-txt.md'

$ExportName       = 'llms-mega-manifest'
$GraphId          = 'graph1'

# Tiered Depth Styling (Index 0 = Root, Index 1 = Level 1, etc.)
$TierColors       = @(
    '#00b4f0', # Level 0 (ROOT - Cyan/Blue)
    '#70db43', # Level 1 (Green)
    '#c8f000', # Level 2 (Yellow-Green)
    '#a000f0', # Level 3 (Purple)
    '#ff6666'  # Level 4+ (Coral/Red for deep subfolders)
)
$TierRadii        = @(50, 40, 30, 25, 20)
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

# --- 1. Load Real Manifests from Pass 2 ---
$manifestNodes = New-Object 'System.Collections.Generic.Dictionary[string, object]'
$existingIds = New-Object 'System.Collections.Generic.Dictionary[string, bool]'

foreach ($mpath in [IO.Directory]::EnumerateFiles((ConvertTo-LongPath $tree), $ManifestFileName, [IO.SearchOption]::AllDirectories)) {
  $mf = [IO.File]::ReadAllText($mpath, $utf8) | ConvertFrom-Json
  $rawId = [string]$mf.id
  $nodeId = if ($rawId -eq '.') { 'llms-root' } else { $rawId.Replace('\', '/') }
  
  $manifestNodes[$nodeId] = $mf
  $existingIds[$nodeId] = $true
}

# --- 2. Gap-Filling: Discover and Create Missing Intermediate Parents ---
$allNodeIds = @($manifestNodes.Keys)
foreach ($id in $allNodeIds) {
  if ($id -eq 'llms-root') { continue }
  
  $parts = $id -split '/'
  $currentPath = ''
  for ($i = 0; $i -lt $parts.Count - 1; $i++) {
    if ($currentPath -eq '') { $currentPath = $parts[$i] } else { $currentPath = "$currentPath/$($parts[$i])" }
    
    if (-not $existingIds.ContainsKey($currentPath)) {
      $syntheticMf = [ordered]@{
        id          = $currentPath
        name        = $parts[$i]
        type        = 'folder'
        rule        = 'gap-filler'
        nested      = $false
        parent      = if ($i -eq 0) { 'llms-root' } else { $currentPath.Substring(0, $currentPath.LastIndexOf('/')) }
        summary     = '(intermediate folder)'
        stats       = [ordered]@{ files = 0; bytes = 0; directFiles = 0; minWrite = $null; maxWrite = $null }
        flags       = @('gap-filler')
        children    = @()
        readmes     = @()
        crumbs      = @()
      }
      $manifestNodes[$currentPath] = [pscustomobject]$syntheticMf
      $existingIds[$currentPath] = $true
    }
  }
}

# Ensure root 'llms-root' exists
if (-not $existingIds.ContainsKey('llms-root')) {
  $rootMf = [ordered]@{
    id          = '.'
    name        = $(if ($runInfo -and $runInfo.Root) { (($runInfo.Root.TrimEnd('\', '/')) -split '[\\/]')[-1] } else { 'root' })
    type        = 'folder'
    rule        = 'root'
    nested      = $false
    parent      = $null
    summary     = 'Root folder'
    stats       = [ordered]@{ files = 0; bytes = 0; directFiles = 0; minWrite = $null; maxWrite = $null }
    flags       = @()
    children    = @()
    readmes     = @()
    crumbs      = @()
  }
  $manifestNodes['llms-root'] = [pscustomobject]$rootMf
  $existingIds['llms-root'] = $true
}

# --- 3. Process All Nodes into Webapp & Export Items ---
$items = New-Object 'System.Collections.Generic.List[object]'

foreach ($nodeId in $manifestNodes.Keys) {
  $mf = $manifestNodes[$nodeId]
  $rawId = [string]$mf.id
  
  $cleanId = if ($rawId -eq '.') { 'llms-root' } else { $nodeId }
  $fileRel = if ($cleanId -eq 'llms-root') { $LlmsFileName } else { "$rawId/$LlmsFileName" }

  $nodeName = if ($mf.name) { [string]$mf.name } else { $cleanId }

  # Depth & Tier Styling
  $depth = if ($cleanId -eq 'llms-root') { 0 } else { ($cleanId -split '/').Count }
  $colorIndex = [Math]::Min($depth, ($TierColors.Length - 1))
  $radiusIndex = [Math]::Min($depth, ($TierRadii.Length - 1))

  $nodeColor  = $TierColors[$colorIndex]
  $nodeRadius = $TierRadii[$radiusIndex]

  $isSynthetic = ($mf.rule -eq 'gap-filler')
  $bytesVal = if ($mf.stats -and $mf.stats.bytes) { [long]$mf.stats.bytes } else { 0L }
  $filesVal = if ($mf.stats -and $mf.stats.files) { [long]$mf.stats.files } else { 0L }

  $node = [ordered]@{
    id = $rawId; name = $nodeName; type = $mf.type; rule = $mf.rule; nested = $mf.nested; parent = $mf.parent
    summary = $mf.summary; file = $fileRel
    files = $filesVal; bytes = $bytesVal
    flags = @($mf.flags); treeSig = if ($mf.treeSig) { $mf.treeSig } else { '' }
    children = @($mf.children)
  }

  $webappProps = [ordered]@{
    type        = [string]$mf.type
    rule        = [string]$mf.rule
    summary     = if ($mf.summary) { [string]$mf.summary } else { '' }
    bytes       = $bytesVal
    files       = $filesVal
    depth       = $depth
    isFiller    = $isSynthetic
  }

  $webappNode = [ordered]@{
    id         = $cleanId
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
  $items.Add([pscustomobject]@{ Id = $rawId; NodeId = $cleanId; Obj = $node; WebappNode = $webappNode; Json = $jsonLine })
}

$items = @($items | Sort-Object { $_.Id })
Write-Host "Processed $($items.Count) nodes (including gap-fillers)."

# --- 4. Build Strict Path-Based Edges (Using consistent 'llms-root' IDs) ---
$edges = New-Object 'System.Collections.Generic.List[object]'
$webappEdges = New-Object 'System.Collections.Generic.List[object]'
$edgeCounter = 1

foreach ($it in $items) {
  $currentId = $it.NodeId
  if ($currentId -eq 'llms-root') { continue }

  $lastSlash = $currentId.LastIndexOf('/')
  $targetParentId = if ($lastSlash -gt 0) { $currentId.Substring(0, $lastSlash) } else { 'llms-root' }

  if ($existingIds.ContainsKey($targetParentId)) {
    $edges.Add([pscustomobject]@{ from = $currentId; to = $targetParentId; rel = 'HAS_CHUNK' }) 
    
    $webappEdges.Add([pscustomobject]@{
      id        = "edge-$edgeCounter"
      source    = $currentId
      target    = $targetParentId
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

# --- 5. Output Generation ---
[IO.File]::WriteAllLines((Join-Path $RunDir 'mega-manifest.jsonl'), [string[]]@($items | ForEach-Object { $_.Json }), $utf8)

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

$items | ForEach-Object { 
  [pscustomobject]@{ 
    id = $_.Obj.id; name = $_.Obj.name; type = $_.Obj.type; bytes = $_.Obj.bytes; files = $_.Obj.files
    summary = $_.Obj.summary 
  } 
} | Export-Csv -LiteralPath (Join-Path $RunDir 'nodes.csv') -NoTypeInformation -Encoding UTF8

$edges | Export-Csv -LiteralPath (Join-Path $RunDir 'edges.csv') -NoTypeInformation -Encoding UTF8

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("# Catalogue of chunks`n`n> $($items.Count) nodes, $($edges.Count) parent-child links. Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm').`n`n")
foreach ($it in $items) {
  $o = $it.Obj
  $link = ConvertTo-Url ("$TreeSubdir/" + $o.file)
  $sum = [string]$o.summary; if (-not $sum) { $sum = '(no summary)' }
  [void]$sb.Append("- [$($o.id)]($link) - $($o.type), $(Format-Size ([long]$o.bytes))`n  $sum`n")
}
[IO.File]::WriteAllText((Join-Path $RunDir 'mega-catalog.md'), $sb.ToString(), $utf8)

Write-Host "Success! Generated fully connected graph files in ${RunDir}:"
Write-Host "  - mega-manifest.json (LPG Webapp Graph format)"
Write-Host "  - mega-manifest.jsonl"
Write-Host "  - nodes.csv & edges.csv"
Write-Host "  - mega-catalog.md"
Write-Host ""
Write-Host "You can now open the LPG Webapp and load the mega-manifest.json to visualize the complete hierarchy."
Write-Host "(https://actuallyfro.github.io/Break-FAST/Examples/01_GraphML-Editor/Single-page-Apps/AA_2026-REDUX/LPG-Editor.html"
}