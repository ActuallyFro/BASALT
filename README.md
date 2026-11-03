# llms-tree heuristics spec: v0.2 delta (read with v0.1)

Tuned against your first real manifest: `folders.tsv`, 15,400 folders, 228,901 files, 518 GB. It is a **Steam library** (`steamapps\common`, `steamapps\workshop`), so it is a stress test for "install-shaped" data, not yet your 1 TB mixed share.

## 1. What the manifest told us

| Observation | Consequence |
|---|---|
| 9,845 of 15,400 folders are under 1 MB, and only 322 are 500 MB or larger | The 500 MB floor (R-120) is right. It removes about 98% of folders from consideration. |
| Only 1 real repo (`Water\Water`, inside a Space Engineers workshop mod) | R-110 works, and the repo is correctly found as a nested chunk. |
| `Readme` markers: 244 folders, of which 211 are an extension-less file named `README` (Civ VI asset folders) | Bare `README` is noise. Pass 1 uses a strict name list (`readme.md/.txt/.rst/.markdown`). |
| `Matlab` (`.mat`, `.prj`), `Database` (`.db`), `Meta` (`license`, `index.md`) are all false positives (game materials, thumbnails, engine files) | Pass 1 ignores them. Only `Build` (own folder) counts as a strong marker, and `SDR` forces DATASET. No re-crawl is needed, because the weighting lives in Pass 1 config. |
| Games are dominated by engine archives (`.rpf`, `.vpk`, `.ba2`, `.ucas`, `.pak`, `.ress`) | The `archive` family now includes them. |
| Red Dead Redemption 2 is 119 GB in only 123 files (100% `.rpf`) | The v0.1 rules missed this case, because OPAQUE-BULK required 500 or more files. See R-135. |
| `bin` was excluded 22 times (plus `obj` and `.vs`) | Those folders are not counted in any size. Totals are slightly low. Check `skipped.tsv`. |
| No hidden, reparse, or error rows | Clean crawl. |

## 2. Rule changes (v0.1 to v0.2)

| ID | Change |
|---|---|
| R-120 | Unchanged: `SubBytes < MinChunkBytes` (500 MB) gives SUBSUMED. Repos are exempt. |
| **R-125 (new)** | **`MaxLeafBytes` (default 20 GB):** a non-stop folder at or below this size closes as `MIXED-LEAF`, and no deeper chunks are emitted (nested repos still are). This is the main granularity dial. Under the real manifest: 5 GB gives 124 chunks, 10 GB gives 97, **20 GB gives 64**, 60 GB gives 37. |
| **R-135 (new)** | `BLOB`: fewer than `BulkMinFiles` files, but at least `BlobShare` (0.90) of **bytes** in one family. This catches the few-huge-files case (RDR2, DuneAwakening). |
| R-140 | `data` family narrowed (`.bin .dat .raw` removed, as games use them). `DatasetShare` 0.60 by bytes, or an `SDR` marker. |
| R-150 | PROJECT only on a strong marker (`Build`, or a strict README name). |
| **R-155 (new)** | Inside a closed PROJECT, nested stop-type chunks are kept only if at least `NestedMinBytes` (5 GB). Nested repos are always kept. |
| **R-160 (revised)** | A folder is `CONTAINER` only if at least **2 significant children** exist (each child holds at least `SigShare` = 10% of the parent's bytes and is itself a chunk). A single significant child that is itself a container makes the parent a `WRAPPER` (pass-through). Otherwise the folder closes as a `MIXED-LEAF` (R-170). Without this, v0.1 produced 234 chunks of single-child wrapper chains such as `Game\Game_Data\...`. |

## Extension-family inventory

Pass 1 and Pass 2 use the same curated extension map. It covers common raster/vector images, video and audio, office and publishing documents, compressed/container formats, SDR and scientific/tabular data, source languages, configuration and web assets, databases, 2D/3D design and CAD, GIS, ML models, binaries/packages, subtitles/playlists, email/calendar/contact files, localization, logs, and network captures. This is a practical inventory, not an exhaustive registry of every format.

Family names are exclusive: each listed suffix maps to one family. Ambiguous generic suffixes such as `.bin` and `.dat` are deliberately not assigned because extensions alone cannot identify their contents. `data` remains limited to recognized scientific/tabular dataset formats (and the existing `.sqlite`/`.sqlite3` mapping); `database` is separate and does not contribute to R-140's `DatasetShare`. New `data` entries do contribute, so R-140 remains a suffix-based heuristic rather than content detection.

## 3. Result on your manifest (MaxLeafBytes 20 GB, SigShare 0.10)

64 chunks from 15,400 folders: 40 MIXED-LEAF, 6 BLOB, 6 WRAPPER, 5 CONTAINER, 3 OPAQUE-BULK, 3 PROJECT, 1 REPO. No fan-out violations. See `sample-classification-from-your-manifest.tsv`.

## 4. Known gaps for v0.3

1. **WRAPPER chains** (for example `SpaceEngineers2\GameData\Vanilla`) should collapse into one pass-through entry.
2. The `ColdAgeYears` flag is untested here (all data is recent), as are the `Archive`/`Temp` crumbs.
3. `bin`/`obj` exclusions understate sizes. Consider a config switch to measure but not describe them.
4. R-211 virtual grouping for more than 53 children is specified but not implemented. This sample never triggers it.
5. Pass 2 (emit `llms.txt` and `llms-manifest.json`) is next, followed by the Pass 3 LLM fill.
