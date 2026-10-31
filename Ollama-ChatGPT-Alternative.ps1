# -----------------------------------------------------------------------
# ADAPTIVE SEMANTIC CHUNKING SYSTEM (LLM Indexer)
# Version: 1.0
# Description: Recursively scans a vast, unstructured data set (1TB) 
#              and generates semantic index files (llms.txt) in a separate 
#              output directory based on prioritized heuristics.
# -----------------------------------------------------------------------

& {
    # ======================================================
    # 1. GLOBAL CONFIGURATION AND PARAMETERS
    # ======================================================

    # !!! IMPORTANT !!! Modify these paths before running.
    $SourcePath = "D:\SteamLibrary"
    $OutputRoot = "D:\SteamLibrary_LLMs" 

    # Tier 4 Fallback Thresholds
    $MaxSizeGB = 60 # Max folder size (in GB) before forced chunking
    $MaxAgeYears = 5 # Max age (in years) before forced chunking

    $ErrorActionPreference = "Stop"

    # ======================================================
    # 2. HELPER FUNCTIONS
    # ======================================================
    Function Test-IsProjectMarker {
        Param([string]$Path)

        $Markers = @(
            ".git",
            "package.json",
            "requirements.txt",
            "pom.xml",
            "go.mod",
            "web.config"
        )

        foreach ($Marker in $Markers) {
            if (Test-Path -LiteralPath (Join-Path $Path $Marker)) {
                return $true
            }
        }

        return $false
    }

    Function Get-DirectoryMetadata {
        Param( [string]$Path )
        try {
            $Item = Get-Item $Path -Force
            $Size = $Item.Length
            $Age = (Get-Item $Path).LastWriteTime
            return [PSCustomObject]@{
                Size = $Size
                Age = $Age
            }
        }
        catch {
            # --- THE DEFINITIVE FIX: Concatenation ---
            # Build the warning message using the '+' operator instead of a single quoted string
            $WarningMessage = "Could not retrieve metadata for ${Path}: " + $_.Exception.Message
            Write-Warning $WarningMessage
            # ----------------------------------------
            return [PSCustomObject]@{ Size = 0; Age = [DateTime]::MinValue }
        }
    }

    # ======================================================
    # 3. CORE RECURSIVE PROCESSING FUNCTION
    # ======================================================

    Function Process-Directory {
        Param(
            [Parameter(Mandatory=$true)]
            [string]$SourcePath,
            [Parameter(Mandatory=$true)]
            [string]$OutputRoot,
            [Parameter(Mandatory=$true)]
            [PSCustomObject]$CurrentChunkMeta # Accumulated metadata for the current directory scope
        )
        
        Write-Host "--- Scanning Scope: $SourcePath"

        $ChildIndexPaths = @()
        $Children = Get-ChildItem -Path $SourcePath -Force | Where-Object { 
            # T0: Noise Filter - Skip known noise
            $_.Name -notmatch "node_modules|venv|.git|Thumbs\.db|desktop\.ini|llms\.txt" 
        }

        # 1. RECURSION (Explore Subfolders First)
        foreach ($Item in $Children) {
            if ($Item.PSIsContainer) {
                
                # Initialize new meta object for the child recursion
                $ChildMeta = [PSCustomObject]@{
                    Size = 0
                    Age = $null
                }
                
                # Recursive Call
                $ChildResult = Process-Directory -SourcePath $Item.FullName -OutputRoot $OutputRoot -CurrentChunkMeta $ChildMeta
                
                # Collect the path to the child's generated index file
                if ($ChildResult -is [string]) {
                    $ChildIndexPaths += $ChildResult
                }
                # Aggregate size/metadata (simplified aggregation)
                $CurrentChunkMeta.Size += $ChildMeta.Size
            }
        }

        # 2. AGGREGATE SELF-META DATA (For current folder)
        # This requires advanced file traversal for true size, but we'll assume the 
        # script has enough metadata to trigger the checks.
        $CurrentChunkMeta.Age = (Get-Item $SourcePath).LastWriteTime

        # 3. HEURISTIC CHECK (The Chunking Decision Point)
        # Check T1, T2, T3, T4 in priority order
        
        $ChunkType = $null
        
        # T1: Structural Boundary Check (Code Projects)
        if (Test-IsProjectMarker -Path $SourcePath) {
            $ChunkType = "StructuralProject"
        } 
        # T2: Semantic Anchor Check (Documentation/Configs)
        # elseif (Test-Path "$SourcePath\README.md" -or Test-Path "$SourcePath\config.yaml") {
        elseif ((Test-Path "$SourcePath\README.md") -or (Test-Path "$SourcePath\config.yaml")) {
            $ChunkType = "SemanticUnit"
        } 
        # T4: Fallback Check (Size/Age)
        elseif (($CurrentChunkMeta.Size -ge $MaxSizeGB*1GB) -or ($CurrentChunkMeta.Age -lt [DateTime]::Now.AddYears(-$MaxAgeYears))) {
            $ChunkType = "ForcedFallback"
        }
        # T3: Homogeneity Check (Needs real file counting, simplified for prototype)
        # NOTE: A full implementation would check file extension count here.
        elseif (($Children | Where-Object {$_.PSIsContainer -eq $false}).Count -ge 50) { 
             $ChunkType = "HomogeneousCluster"
        }


        # 4. INDEX GENERATION (If Chunk is Defined)
        if ($ChunkType -ne $null) {
            Write-Host "  [CHUNK DEFINED - Type: $ChunkType] Generating index for: $SourcePath"

            # Generate Markdown Content
            $LLMSTXTContent = @(
                "# $SourcePath (Type: $ChunkType)"
                "> This chunk was defined by the $($ChunkType) heuristic, encompassing all sub-data. Total estimated size: $($CurrentChunkMeta.Size / 1GB | ForEach-Object {'{0:N2}' -f $_}) GB"
                ""
                "## Sub-Chunks Found"
            )
            
            # Link to children indices (Topography)
            foreach ($Path in $ChildIndexPaths) {
                $LLMSTXTContent += "- [Referenced Child Index]($OutputRoot\$(Split-Path -Path $Path -Leaf))"
            }
            
            # Add a description based on the type
            if ($ChunkType -eq "StructuralProject") {
                 $LLMSTXTContent += "`n*This area contains active source code and development assets.*"
            }
            
            # Use the last path segment of the SourcePath to name the output file
            $SourceRootNormalized = $SourceRoot.TrimEnd('\')
            $SourcePathNormalized = $SourcePath.TrimEnd('\')

            if ($SourcePathNormalized.Length -eq $SourceRootNormalized.Length) {
                $RelativePath = ""
            }
            else {
                $RelativePath = $SourcePathNormalized.Substring($SourceRootNormalized.Length).TrimStart('\')
            }

            $OutputDirectory = $OutputRoot

            if ($RelativePath) {
                $OutputDirectory = Join-Path -Path $OutputRoot -ChildPath $RelativePath
            }

            New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null

            $OutputPath = Join-Path -Path $OutputDirectory -ChildPath "llms.txt"

            $LLMSTXTContent | Out-File -FilePath $OutputPath -Encoding UTF8

            # Return the path of the generated index file back to the parent
            return $OutputPath
        }
        else {
            # If no chunk boundary is met, return null to indicate continued traversal
            return $null
        }
    }

    # ======================================================
    # 4. MAIN EXECUTION FLOW
    # ======================================================
    
    Write-Host "`n====================================================="
    Write-Host "🚀 STARTING SEMANTIC INDEXING PROCESS"
    Write-Host "Source: $SourcePath | Output: $OutputRoot"
    Write-Host "====================================================="

    # Ensure the output directory exists
    if (-not (Test-Path $OutputRoot)) {
        New-Item -Path $OutputRoot -ItemType Directory | Out-Null
    }

    # Start the recursive process from the root. 
    # The root directory is the initial 'chunk' and its index will be generated last.
    $RootMeta = [PSCustomObject]@{
        Size = 0
        Age  = [DateTime]::MinValue
    }

    Process-Directory `
        -SourcePath $SourcePath `
        -OutputRoot $OutputRoot `
        -CurrentChunkMeta $RootMeta

    Write-Host "`n====================================================="
    Write-Host "✅ Indexing Complete. Check the output folder: $OutputRoot"
    Write-Host "====================================================="
}
