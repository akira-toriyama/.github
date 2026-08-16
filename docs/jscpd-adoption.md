# jscpd — an on-demand measuring tool, not a CI gate

**Decision (2026-08-16, ratified via t-x13w): jscpd stays an on-demand tool.
No hub reusable, no fleet caller stub, no standing CI gate anywhere.** Run it
when you want a number; do not wire it into anything that turns red.

## The command

```sh
npx jscpd@5.0.15 . --min-tokens 100 \
  --ignore '**/.git/**,**/.claude/**,**/report/**,**/docs/superpowers/plans/**,**/node_modules/**,**/pnpm-lock.yaml,**/Package.resolved,**/go.sum'
```

- **Pin the exact version.** The official composite action is rejected: its
  installer is `curl | bash` with no integrity verification, its `version`
  input defaults to `latest`, and its internal actions are tag-pinned.
- **`--min-tokens 100`.** At the default 50, Go table-test boilerplate rings
  in every Go repo.
- **The ignore list is load-bearing.** `docs/superpowers/plans/**` is the
  house practice of pasting implementation verbatim into plan documents — it
  accounts for 70–100% of strict clones in 6 repos (sill, cifail, vista,
  swift-toml-edit among them) and makes any un-ignored number meaningless.
  `.claude/**` excludes embedded worktrees (a second checkout of the repo
  inside itself — furrow measured 49% raw because of one). `report/**`
  excludes jscpd's own default output, which lands INSIDE the scan tree and
  inflates the next run.
- **Per-repo waivers** on top of the baseline: canon `keymap-drawer/**`
  (generated SVG, self-similar by construction) and chord
  `config.schema.json` + `docs/schema/**` (versioned schema snapshots —
  similarity is the point).

## Why not a gate

1. **Precedent.** t-tgbs (2026-07-22, user-ratified) already rejected a
   standing `dupl` gate. The strongest fact from that round: the fleet's one
   real duplication-caused bug (glyph `IsAncestor`'s third copy reading exit
   status before context) was found by a human during manual cleanup — every
   detector missed it at min-tokens 150/100/75, and at 50 two of four hits
   were false positives. jscpd at `--min-tokens 100` would have missed it
   the same way.
2. **Threshold semantics.** `--threshold` is a single aggregate over the
   whole scan, line-based — no per-path thresholds, no baseline file, no
   per-clone waivers. At the fleet's real levels (0.1–0.8% after noise), an
   achievable threshold stops nothing, and a tight one flips red/green on
   unrelated growth of clean code.
3. **Silent no-scan paths.** Measured on 5.0.15: a nonexistent path exits 0
   having scanned nothing (re-verified 2026-08-16); an unknown reporter, a
   snake_case config key (silently reset to defaults with only a warning),
   and an unset gate all pass green the same way. A gate you can
   accidentally turn off is not a gate.

## Fleet measurements (2026-08-16, jscpd 5.0.15, 28 of ~35 repos)

Raw top offenders were all artifacts, not code smell:

| repo | strict dup% | what it actually was | after baseline ignore |
|---|---|---|---|
| furrow | 49.45 | embedded worktree under `.claude/worktrees/` | 0.76 |
| canon | 17.25 | generated `keymap-drawer/imprint.svg`, 100% self-similar | 18.50 (waiver) |
| cifail | 9.32 | one plan doc pasting the implementation verbatim | 0.00 |
| swift-toml-edit | 5.39 | plan-doc self-copy | 0.14 |
| chord | 4.92 | `docs/schema/*.v{1,3,4}.json` version snapshots | 5.03 (waiver) |
| vista | 2.67 | plan doc ↔ `src-tauri/src/*.rs` | 0.00 |

After noise removal, **sill is the only repo with human-fixable duplication**
(whole-repo 1.80% / 48 clones; `Tests/` alone 4.78% / 36 clones). The ten Go
repos measure 0.13–0.81% strict — no production signal. halo, capsule,
zmk-keyboards, prmap: zero.

Verification status: the original sweep ran on local checkouts (some on topic
branches / behind main). Re-verified on fresh clones 2026-08-16: sill 1.80% /
48 clones and `Tests/` 4.78% / 36 clones (exact match), cifail 0.00 after
baseline ignore (exact match), pare 0.81% vs 0.64% originally (one clone
either way — same conclusion). Footguns (nonexistent-path exit 0, aggregate
threshold) re-fired the same day.

If sill's `Tests/` duplication gets cleaned up and someone wants to hold the
line there, the shape that survives the threshold semantics is a
single-repo gate scoped to `Tests/`, thresholded at the post-cleanup
measurement + 0.5pt — see t-x13w for the full option analysis. That is a
sill decision for that day, not part of this record.
