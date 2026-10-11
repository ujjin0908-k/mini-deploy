# Graph Report - mini-deploy  (2026-10-11)

## Corpus Check
- Corpus is ~3,249 words - fits in a single context window. You may not need a graph.

## Summary
- 37 nodes · 68 edges · 6 communities (3 shown, 3 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- Release lookup and rollback
- Deploy: copy, flip, prune
- CLI entry and imports
- Per-app lock
- Deploy test script
- WSL probe script

## God Nodes (most connected - your core abstractions)
1. `deploy()` - 12 edges
2. `rollback()` - 8 edges
3. `DeployError` - 7 edges
4. `current_id()` - 7 edges
5. `locked` - 7 edges
6. `app_paths()` - 5 edges
7. `release_ids()` - 5 edges
8. `flip()` - 5 edges
9. `reject_symlinks()` - 5 edges
10. `prune()` - 5 edges

## Surprising Connections (you probably didn't know these)
- `deploy()` --calls--> `DeployError`  [EXTRACTED]
  scripts/deploy.py → scripts/deploy.py  _Bridges community 0 → community 1_
- `deploy()` --calls--> `locked`  [EXTRACTED]
  scripts/deploy.py → scripts/deploy.py  _Bridges community 3 → community 1_
- `rollback()` --calls--> `locked`  [EXTRACTED]
  scripts/deploy.py → scripts/deploy.py  _Bridges community 3 → community 0_
- `main()` --calls--> `deploy()`  [EXTRACTED]
  scripts/deploy.py → scripts/deploy.py  _Bridges community 1 → community 2_
- `main()` --calls--> `rollback()`  [EXTRACTED]
  scripts/deploy.py → scripts/deploy.py  _Bridges community 0 → community 2_

## Import Cycles
- None detected.

## Communities (6 total, 3 thin omitted)

### Community 0 - "Release lookup and rollback"
Cohesion: 0.33
Nodes (6): app_paths(), current_id(), DeployError, list_releases(), release_ids(), rollback()

### Community 1 - "Deploy: copy, flip, prune"
Cohesion: 0.33
Nodes (4): deploy(), flip(), prune(), reject_symlinks()

### Community 4 - "Deploy test script"
Cohesion: 0.83
Nodes (3): expect_fail(), get(), test-deploy.sh script

## Knowledge Gaps
- **1 isolated node(s):** `probe.sh script`
  These have ≤1 connection - possible missing edges. (Counts symbols only; 16 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `locked` connect `Per-app lock` to `Release lookup and rollback`, `Deploy: copy, flip, prune`, `CLI entry and imports`?**
  _High betweenness centrality (0.175) - this node is a cross-community bridge._
- **What connects `probe.sh script` to the rest of the system?**
  _1 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Why does `deploy()` connect `Deploy: copy, flip, prune` to `Release lookup and rollback`, `CLI entry and imports`, `Per-app lock`?**
  _High betweenness centrality (0.089) - this node is a cross-community bridge._
- **Why does `DeployError` connect `Release lookup and rollback` to `Deploy: copy, flip, prune`, `CLI entry and imports`?**
  _High betweenness centrality (0.051) - this node is a cross-community bridge._