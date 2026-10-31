# llms-tree: chunking heuristics spec

**Version:** 0.1 (DRAFT, iterate after the first real Pass 0 manifest)
**Target:** Windows PowerShell 5.1, default tools only, ~1 TB / millions of files on a network share
**llms.txt format:** v2 (Jeremy Howard), as pasted in the brief

---

## 0. Decisions log (from the Q&A)

| ID | Decision |
|----|----------|
| D-01 | PowerShell 5.1. No ternary, `??`, `-Parallel`, or `ForEach-Object -Parallel`. |
| D-02 | Output goes to a **sidecar tree**. The source tree is never written to. |
| D-03 | Share is live, so change detection uses a metadata fingerprint (section 5). |
| D-04 | Script runs from inside the folder (`cd` first). Long paths and UNC are handled via `\\?\`. |
| D-05 | Millions of files. Streaming and per-folder aggregates only, never a per-file list in memory. |
| D-06 | No content hashing. The fingerprint is built from names, sizes and timestamps. |
| D-07 | Header sniffing (first 512 bytes) is allowed but **opt-in** (`-SniffUnknown`), extension-less files only. |
| D-08 | Reparse points (symlinks and junctions) are never followed. |
| D-09 | Breadcrumbs (file, folder, size, name) are **config variables**, not hard-coded. |
| D-10 | Thresholds are variables (section 3). |
| D-11 | Max entries per llms.txt = **53**, the first prime greater than 50. |
| D-12 | Hidden folders are not descended. They are subsumed by their parent. Hidden files are counted. |
| D-13 | Default exclusions: `node_modules`, `.venv`, `venv`, `__pycache__`, `bin`, `obj`, `.git` and similar. |
| D-14 | Name crumbs (archive, old, tmp, year...) are regex variables the executor can edit. |
| D-15 | A local open-source LLM is called through PowerShell REST calls. It is used only in Pass 3. |
| D-16 | The LLM sees `head -n N` of human-readable files, and returns 25 to 115 words max. |
| D-17 | Parent summaries use **both** a deterministic roll-up and an LLM blurb. |
| D-18 | Machine-readable facts go in `llms-manifest.json` next to each `llms.txt`. |
| D-19 | Links are relative. |
| D-20 | The `.md` companion files idea is out of scope. File names are variables, and we assume `llms.txt` exists nowhere in the source tree. Pass 0 logs collisions. |
| D-21 | Re-runs overwrite. Each run gets a timestamped sidecar folder. |
| D-22 | Nothing is redacted or skipped for sensitivity. The goal is to know what we have. |
| D-23 | Design blind. Tune thresholds on the first Pass 0 output. |

---

## 1. Pipeline

```
Pass 0  INVENTORY   read-only crawl            -> folders.tsv (1 row/folder) + skipped/errors/extensions
Pass 1  CLASSIFY    manifest only, no I/O      -> classification.tsv (node type + rule ID + reason)
Pass 2  EMIT        post-order, deterministic  -> llms.txt + llms-manifest.json per chunk (sidecar mirror)
Pass 3  SUMMARIZE   optional, local LLM        -> replaces `> TODO-SUMMARY` stubs
Pass 4  PUBLISH     optional                   -> copy sidecar files into the source tree (new, separate decision)
```

Passes 1 and 2 are fully deterministic and reproducible from the manifest. Only Pass 3 touches an LLM.

### Sidecar layout

```
<OutRoot>\<yyyyMMdd-HHmmss>\
  run.json  config.json                 run metadata and the effective config
  folders.tsv                           Pass 0 manifest (the system of record)
  extensions.tsv                        global extension totals
  skipped.tsv   errors.tsv              what we did not enter, and what failed
  classification.tsv                    Pass 1
  tree\<same relative path>\llms.txt            Pass 2 and 3
  tree\<same relative path>\llms-manifest.json
```

---

## 2. Config variables (defaults live in the script's `$Config`; override via `-ConfigPath x.psd1`)

| Var | Default | Purpose |
|-----|---------|---------|
| `LlmsFileName` | `llms.txt` | Output name. Collisions in the source are logged as `LLMS-NAME-COLLISION`. |
| `ManifestFileName` | `llms-manifest.json` | Machine-readable sibling. |
| `SkipHiddenDirs` | `$true` | D-12. |
| `FollowReparsePoints` | `$false` | D-08. |
| `ExcludeDirNames` | see script | D-13. Not descended, and listed in `skipped.tsv`. |
| `MarkerDirNames` / `MarkerFileNames` / `MarkerExts` | see script | Breadcrumb to category map (`Repo`, `Build`, `Matlab`, `SDR`, `Notebook`, `Database`, `Meta`). |
| `ReadmePrefix` | `readme` | Any file starting with this counts as the `Readme` marker. |
| `NameCrumbs` | see script | Regexes on the folder's own name: `Archive`, `Temp`, `Misc`, `Year`, `HasYear`, `Version`. |
| `ExtTopN` | 30 | Extensions kept per histogram column. The remainder is folded into `(other)`. |
| `SniffMaxPerFolder` | 3 | Extension-less files sniffed per folder, when `-SniffUnknown` is on. |

Pass 1 and 2 variables (not yet in the script, added with the classifier):

| Var | Default | Used by |
|-----|---------|---------|
| `MaxEntries` | **53** | R-210 |
| `MinChunkBytes` | 500 MB | R-120 |
| `BulkMinFiles` | 500 | R-130 |
| `BulkDominantShare` | 0.90 | R-130 |
| `DatasetByteShare` | 0.60 | R-140 |
| `ContainerMinChunkChildren` | 2 | R-160 |
| `EvidenceHeadLines` | 80 | Pass 3 |
| `EvidenceMaxBytes` | 4096 | Pass 3 |
| `SummaryWords` | 25 to 115 | Pass 3 |
| `ExtFamilies` | table below | R-130, R-140 |

### Extension families (starter table, edit freely)

| Family | Extensions |
|--------|------------|
| image | `.png .jpg .jpeg .gif .bmp .tif .tiff .webp .heic .raw .cr2 .nef .dng` |
| video | `.mp4 .mkv .avi .mov .wmv .m4v .webm` |
| audio | `.mp3 .wav .flac .aac .ogg .m4a` |
| doc | `.pdf .doc .docx .xls .xlsx .ppt .pptx .txt .md .rtf .csv` |
| archive | `.zip .7z .rar .tar .gz .tgz .bz2 .iso` |
| sdr | `.cfile .iq .sigmf-data .sigmf-meta .cf32 .fc32 .cs16 .cu8 .grc` |
| data | `.mat .h5 .hdf5 .npy .npz .parquet .sqlite .db .bin .dat` |
| code | `.py .m .ps1 .c .cpp .h .cs .java .js .ts .go .rs .sh .ipynb` |

---

## 3. Pass 0: inventory (implemented in `llms-pass0-inventory.ps1`)

### Rules

| ID | Rule |
|----|------|
| R-001 | Read-only. File contents are not read, except the optional 512-byte sniff (D-07). |
| R-002 | Reparse points are recorded in `skipped.tsv` (reason `reparse`) and not entered. |
| R-003 | `ExcludeDirNames` are recorded (`excluded`) and not entered. A marker match (for example `.git`) is recorded **before** the exclusion check. |
| R-004 | Hidden directories are recorded (`hidden`) and not entered. Hidden files are counted in their folder and in `HiddenFiles`. |
| R-005 | Post-order write: a folder's row is appended only after its whole subtree is done. Resume therefore reuses finished rows and re-crawls only unfinished branches. |
| R-006 | Paths use the `\\?\` and `\\?\UNC\` prefixes (long paths). Errors (access denied and so on) go to `errors.tsv` and the crawl continues. |
| R-007 | A file named `LlmsFileName` or `ManifestFileName` in the source is logged as `LLMS-NAME-COLLISION`. |
| R-008 | The sidecar must live outside the scanned root. The script refuses to run otherwise. |

### `folders.tsv` columns

`Sub*` means the **whole subtree including this folder**. `Direct*` means this folder's own entries only.

| Column | Meaning |
|--------|---------|
| `RelPath`, `Depth` | Relative path (`.` is the root) and depth (root = 0). |
| `DirectFiles`, `DirectBytes`, `DirectDirs` | This folder's files, bytes and immediate subfolders (including skipped ones). |
| `SubFiles`, `SubBytes` | Totals across the scanned subtree. |
| `SubDirs` | Scanned descendant folders (excluding this one). |
| `MinWrite`, `MaxWrite` | Oldest and newest file write date in the subtree (UTC, `yyyy-MM-dd`). |
| `DirectExt`, `SubExt` | Histograms as `ext:count:bytes;...`, top N by bytes, plus `(other)`. `(none)` means no extension. |
| `Markers`, `SubMarkers` | Breadcrumb counts as `Cat=n;...`, for this folder and for the subtree. |
| `Readmes` | Up to 3 README file names in this folder. |
| `NameCrumbs` | Matching name tags, such as `Archive\|HasYear`. |
| `HiddenDirs`, `HiddenFiles`, `ExcludedDirs`, `ReparseSkipped` | Skip accounting. |
| `Sniffed` | Header-sniff results, for example `text=2;zip=1`. |
| `DirSig`, `TreeSig` | Fingerprints (section 5). |
| `Errors` | Error count for this folder. |

Known approximation: after a resume, completed folders carry their top-N truncated `SubExt` in roll-ups. Sizes and counts stay exact.

---

## 4. Running Pass 0

```powershell
cd \\server\share\Main
# 1) dry run: top 2 levels only
& .\llms-pass0-inventory.ps1 -MaxDepth 2 -OutRoot D:\llms-out
# 2) full run (resume with -RunDir if interrupted)
& .\llms-pass0-inventory.ps1 -SniffUnknown -OutRoot D:\llms-out
```

Quick looks at the manifest (default tools only):

```powershell
$m = Import-Csv D:\llms-out\<stamp>\folders.tsv -Delimiter "`t"
# biggest subtrees
$m | Sort-Object {[long]$_.SubBytes} -Descending | Select -First 25 RelPath,SubFiles,@{n='GB';e={[math]::Round($_.SubBytes/1GB,1)}}
# every repo
$m | Where-Object { $_.Markers -match 'Repo=' } | Select RelPath,SubBytes
# folders with a million-ish small files
$m | Where-Object {[long]$_.SubFiles -gt 100000} | Select RelPath,SubFiles,SubExt
# how many folders each size floor would erase
$m | Where-Object {[long]$_.SubBytes -lt 500MB} | Measure-Object
```

---

## 5. Change detection ("tree | md5sum", metadata only)

* `DirSig` = SHA-1 (first 16 hex chars) of this folder's sorted entry list: `f|name|length|lastWriteTicks` for files, `d|name` for directories (with a flag for skipped ones).
* `TreeSig` = SHA-1 (first 16 hex) of `DirSig` plus the sorted `childName:childTreeSig` list.
* Any add, delete, rename, resize, or touch below a folder changes its `TreeSig` and every ancestor's. Siblings are unaffected.
* **Use:** compare two runs' `folders.tsv` by `RelPath`. Where `TreeSig` is equal, reuse the previous `llms.txt` and LLM summary. Regenerate only changed chunks and their ancestors.
* Limitations: a content edit that keeps size and timestamp is invisible. Directory timestamps are deliberately excluded because they are noisy on SMB. The root `TreeSig` is stored in `run.json`.

---

## 6. Pass 1: classifier (manifest-only; spec for the next iteration)

### Node types

| Type | Meaning | Descend? | Emits llms.txt? |
|------|---------|----------|-----------------|
| `REPO` | Folder holds `Repo` marker (`.git` dir or gitlink file) | **Stop** | Yes. Nested repos are listed as links. |
| `OPAQUE-BULK` | Homogeneous mass of one file family | **Stop** | Yes (one, at the top). |
| `DATASET` | Mostly `sdr` and `data` family bytes | **Stop** | Yes. |
| `PROJECT` | Has Build or Readme crumbs and is not one of the above | Yes | Yes |
| `CONTAINER` | Mostly subfolders containing chunks | Yes | Yes (aggregate roll-up) |
| `MIXED-LEAF` | No markers, heterogeneous, big enough to matter, no chunkable children | No | Yes |
| `SUBSUMED` | Too small to chunk | No | No. Listed in the parent's `## Optional` section. |
| `EXCLUDED` | Name-excluded, hidden, or reparse | No | No |

### Rules (evaluated top-down; first match stops descent)

| ID | Condition | Result |
|----|-----------|--------|
| R-100 | Skipped in Pass 0 (excluded, hidden, reparse) | `EXCLUDED` |
| R-110 | `Markers` has `Repo` | `REPO`. **Exempt from the size floor** (a tiny repo still gets its own chunk). Nested repos (`SubMarkers.Repo` greater than this folder's own) become links. |
| R-120 | `SubBytes < MinChunkBytes` (default 500 MB) | `SUBSUMED` |
| R-130 | `SubFiles >= BulkMinFiles` (500) **and** one family has at least `BulkDominantShare` (0.90) of `SubFiles`, **and** `SubMarkers.Repo` is absent. Applies regardless of subfolder depth. | `OPAQUE-BULK` |
| R-140 | `sdr` plus `data` family bytes are at least `DatasetByteShare` (0.60) of `SubBytes`, **or** `SubMarkers` has SDR or Database counts | `DATASET` |
| R-150 | Else, `Markers` has `Build` or `Readme` | `PROJECT` (descend, so nested chunks become links) |
| R-160 | Else, at least `ContainerMinChunkChildren` children classify as chunks | `CONTAINER` |
| R-170 | Else | `MIXED-LEAF` |

**Crumb modifiers (do not change the type; they add tags and notes):**

| ID | Condition | Effect |
|----|-----------|--------|
| R-180 | `NameCrumbs` has `Archive` or `Temp` | Add flag `cold`, and demote the link to `## Optional`. |
| R-181 | `MaxWrite` is older than `ColdAgeYears` (proposed 5) | Add flag `cold`. |
| R-182 | `NameCrumbs` has `Year` | Candidate to be grouped with sibling `Year` folders (R-211). |

Tuning order: first look at the manifest numbers, then adjust `MinChunkBytes`, `BulkDominantShare`, and the family table.

---

## 7. Pass 2: emit

**Walk:** post-order. Children first, then the parent builds its roll-up from the children's blockquotes and manifests.

### `llms.txt` template (spec-conformant: H1, blockquote, details, H2 file lists)

```markdown
# <folder name>

> TODO-SUMMARY  <!-- Pass 3 replaces this; deterministic fallback line is below -->

Type: PROJECT. 12.4 GB, 48,211 files, 2015-03-02 to 2024-11-19. Top types: .py 61%, .m 22%, .md 4%.

## Chunks
- [subfolder-a](subfolder-a/llms.txt): REPO, 3.1 GB, last change 2024-06-01
- [subfolder-b](subfolder-b/llms.txt): OPAQUE-BULK, 1,002,311 images (.jpg 98%)

## Key files
- [README.md](README.md): project readme

## Optional
- [old_backup_2019](old_backup_2019/): SUBSUMED, 210 MB, cold
```

R-200: No headings appear before the first H2. The "generated by" comment goes at the **end** of the file as an HTML comment, so the H1 stays first.

### Fan-out cap

| ID | Rule |
|----|------|
| R-210 | One `llms.txt` holds at most `MaxEntries` = 53 links in total. |
| R-211 | If chunks exceed 53, build **virtual group nodes** under `_g01`, `_g02`, ... in the sidecar. Group by shared name prefix or crumb (for example `Year`), else by alphabetical range, and recurse until every node has 53 or fewer entries. Groups link to real children with relative paths. |
| R-212 | Pass 2 never reads source files. Links to READMEs are paths only. |

### `llms-manifest.json` (per chunk, machine-readable, for LPG/RDF ingestion)

```json
{
  "id": "Projects/App1", "type": "REPO", "parent": "Projects",
  "children": ["Projects/App1/docs"], "subsumed": ["Projects/App1/old"],
  "stats": { "files": 48211, "bytes": 13312000000, "dirs": 920, "minWrite": "2015-03-02", "maxWrite": "2024-11-19" },
  "extFamilies": { "code": 0.83, "doc": 0.11 },
  "markers": { "Repo": 1, "Readme": 1, "Build": 2 },
  "crumbs": ["HasYear"], "flags": ["cold"],
  "treeSig": "9f2c...", "rule": "R-110", "generator": "llms-tree 0.1"
}
```

---

## 8. Pass 3: LLM summaries (local model, REST from PowerShell)

| ID | Rule |
|----|------|
| R-300 | Evidence pack per node: up to `EvidenceMaxBytes` of `head -n EvidenceHeadLines` (`Get-Content -TotalCount 80`) from README(s) and from text files (`Sniffed` has `text`, or the extension is in the `doc` or `code` family). Also included: up to 60 file or folder names and the extension histogram line. |
| R-301 | Output is 25 to 115 words, plain prose, no markdown. It replaces `> TODO-SUMMARY`. |
| R-302 | Parent node: the deterministic roll-up (counts, sizes, type mix, child list) is always written. The LLM blurb is generated from the **children's blockquotes**, not from raw files. |
| R-303 | Skip LLM calls when `TreeSig` matches the previous run and the old summary exists. |
| R-304 | The API shape is `Invoke-RestMethod -Uri http://localhost:<port>/... -Method Post -Body ($json)`. The exact endpoint depends on which local runner you pick. |

---

## 9. Open items for iteration 2

1. Pick the first real thresholds after Pass 0: how many folders land in each type at 500 MB, 0.90, and 500 files?
2. Should tiny-but-markered folders (README plus `.sln` at 20 MB) bypass the 500 MB floor, as repos do?
3. `bin` and `obj` are excluded by default. This is wrong for some data stores, so check `skipped.tsv` for large surprises.
4. Hidden folders are skipped, so their bytes are invisible. Do we want an optional `-MeasureHidden` pass?
5. Add `classification.tsv` and the Pass 2 emitter as scripts (deliverable (c) from the earlier plan).
6. Pick the local LLM runner and fix the endpoint.
