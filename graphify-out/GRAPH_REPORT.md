# Graph Report - mini-deploy  (2026-10-12)

## Corpus Check
- 5 files · ~0 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 314 nodes · 684 edges · 18 communities (13 shown, 5 thin omitted)
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 12 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- deploy.py, webhook.py
- deploy.py, webhook.py
- test-webhook.sh
- dashboard.py, deploy.py
- webhook.py
- build.py
- export-diagrams.py
- app.js
- package.json
- test-build.sh
- test-deploy.sh
- build.js
- test-sites.sh
- webhook.py
- probe.sh
- run-webhook.sh
- sync-theme.sh

## God Nodes (most connected - your core abstractions)
1. `test-webhook.sh script` - 26 edges
2. `run_job()` - 20 edges
3. `refresh()` - 15 edges
4. `_deploy_locked()` - 15 edges
5. `remove_preview()` - 15 edges
6. `main()` - 15 edges
7. `main()` - 15 edges
8. `DeployError` - 14 edges
9. `main()` - 13 edges
10. `app_paths()` - 11 edges

## Surprising Connections (you probably didn't know these)
- `collect_apps()` --calls--> `current_id()`  [EXTRACTED]
  scripts/dashboard.py → scripts/deploy.py
- `collect_apps()` --calls--> `preview_parent()`  [EXTRACTED]
  scripts/dashboard.py → scripts/deploy.py
- `collect_apps()` --calls--> `release_ids()`  [EXTRACTED]
  scripts/dashboard.py → scripts/deploy.py
- `refresh()` --calls--> `clear_hold()`  [EXTRACTED]
  scripts/dashboard.py → scripts/deploy.py
- `refresh()` --calls--> `deploy_holding_lock()`  [EXTRACTED]
  scripts/dashboard.py → scripts/deploy.py

## Import Cycles
- None detected.

## Communities (18 total, 5 thin omitted)

### Community 0 - "deploy.py, webhook.py"
Cohesion: 0.06
Nodes (40): app_paths(), check_preview(), check_tree(), cleanup_stale(), clear_hold(), clear_hold_after_manual_deploy(), current_id(), deploy() (+32 more)

### Community 1 - "deploy.py, webhook.py"
Cohesion: 0.07
Nodes (25): record_preview_branch(), check_checkout_size(), check_disk(), ConfigError, git(), GitError, Handler, init_env() (+17 more)

### Community 2 - "test-webhook.sh"
Cohesion: 0.15
Nodes (28): bad(), body(), bpush(), break_build(), code_of(), commit_page(), expect(), g() (+20 more)

### Community 3 - "dashboard.py, deploy.py"
Cohesion: 0.14
Nodes (13): collect(), collect_apps(), _comparable(), main(), maybe_refresh(), parse_log(), public_detail(), read_log_tail() (+5 more)

### Community 4 - "webhook.py"
Cohesion: 0.10
Nodes (3): Jobs, Seen, State

### Community 5 - "build.py"
Cohesion: 0.17
Nodes (9): build_and_deploy(), _build_locked(), BuildError, chown_tree(), docker_build(), image_ref(), main(), node_major() (+1 more)

### Community 6 - "export-diagrams.py"
Cohesion: 0.18
Nodes (7): css_variables(), export(), main(), resolve(), standalone(), svg_rules(), xml_safe()

### Community 7 - "app.js"
Cohesion: 0.38
Nodes (10): appCard(), command(), copyText(), fallback(), manual(), say(), el(), load() (+2 more)

### Community 8 - "package.json"
Cohesion: 0.22
Nodes (8): description, engines, node, name, private, scripts, build, version

### Community 9 - "test-build.sh"
Cohesion: 0.44
Nodes (8): bad(), expect_error(), get(), link_of(), make_repo(), MINI_DEPLOY_NO_DASHBOARD, ok(), test-build.sh script

### Community 10 - "test-deploy.sh"
Cohesion: 0.44
Nodes (8): bad(), expect_error(), host_get(), link_of(), live_id(), MINI_DEPLOY_NO_DASHBOARD, ok(), test-deploy.sh script

### Community 11 - "build.js"
Cohesion: 0.25
Nodes (5): fs, outDir, path, srcDir, WEB_FILES

### Community 12 - "test-sites.sh"
Cohesion: 0.43
Nodes (6): bad(), get(), jq_py(), live_json(), ok(), test-sites.sh script

## Knowledge Gaps
- **17 isolated node(s):** `MINI_DEPLOY_NO_DASHBOARD`, `fs`, `outDir`, `path`, `srcDir` (+12 more)
  These have ≤1 connection - possible missing edges. (Counts symbols only; 111 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **5 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Jobs` connect `webhook.py` to `deploy.py, webhook.py`?**
  _High betweenness centrality (0.035) - this node is a cross-community bridge._
- **What connects `MINI_DEPLOY_NO_DASHBOARD`, `fs`, `outDir` to the rest of the system?**
  _17 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `deploy.py, webhook.py` be split into smaller, more focused modules?**
  _Cohesion score 0.06278538812785388 - nodes in this community are weakly interconnected._
- **Why does `Seen` connect `webhook.py` to `deploy.py, webhook.py`?**
  _High betweenness centrality (0.032) - this node is a cross-community bridge._
- **Should `deploy.py, webhook.py` be split into smaller, more focused modules?**
  _Cohesion score 0.07256894049346879 - nodes in this community are weakly interconnected._
- **Why does `Server` connect `webhook.py` to `deploy.py, webhook.py`?**
  _High betweenness centrality (0.027) - this node is a cross-community bridge._
- **Should `test-webhook.sh` be split into smaller, more focused modules?**
  _Cohesion score 0.14838709677419354 - nodes in this community are weakly interconnected._