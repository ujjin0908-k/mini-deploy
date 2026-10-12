# Graph Report - mini-deploy  (2026-10-12)

## Corpus Check
- 13 files · ~0 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 374 nodes · 822 edges · 21 communities (16 shown, 5 thin omitted)
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 13 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- build.py, deploy.py
- webhook.py
- buildlog.py, logs.py
- test-webhook.sh
- webhook.py
- dashboard.py, deploy.py
- export-diagrams.py, logs.py
- build.py
- app.js
- test-sites.sh
- test-build.sh
- package.json
- test-deploy.sh
- build.js
- run-caddy.sh
- webhook.py
- app.js
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
8. `build_and_deploy()` - 14 edges
9. `DeployError` - 14 edges
10. `main()` - 13 edges

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

## Communities (21 total, 5 thin omitted)

### Community 0 - "build.py, deploy.py"
Cohesion: 0.06
Nodes (40): main(), app_paths(), check_preview(), check_tree(), cleanup_stale(), clear_hold(), clear_hold_after_manual_deploy(), current_id() (+32 more)

### Community 1 - "webhook.py"
Cohesion: 0.07
Nodes (27): check_checkout_size(), check_disk(), ConfigError, git(), GitError, Handler, init_env(), load_config() (+19 more)

### Community 2 - "buildlog.py, logs.py"
Cohesion: 0.10
Nodes (14): Capture, clean(), _key(), _locked(), logs_of(), _new_id(), prune(), read_header() (+6 more)

### Community 3 - "test-webhook.sh"
Cohesion: 0.15
Nodes (28): bad(), body(), bpush(), break_build(), code_of(), commit_page(), expect(), g() (+20 more)

### Community 4 - "webhook.py"
Cohesion: 0.09
Nodes (4): Jobs, QueueFull, Seen, State

### Community 5 - "dashboard.py, deploy.py"
Cohesion: 0.17
Nodes (12): collect(), collect_apps(), _comparable(), main(), maybe_refresh(), parse_log(), public_detail(), read_log_tail() (+4 more)

### Community 6 - "export-diagrams.py, logs.py"
Cohesion: 0.16
Nodes (7): css_variables(), export(), main(), resolve(), standalone(), svg_rules(), xml_safe()

### Community 7 - "build.py"
Cohesion: 0.16
Nodes (9): build_and_deploy(), _build_locked(), BuildError, chown_tree(), docker_build(), image_ref(), node_major(), pump_output() (+1 more)

### Community 8 - "app.js"
Cohesion: 0.38
Nodes (11): appCard(), command(), copyText(), fallback(), manual(), say(), el(), load() (+3 more)

### Community 9 - "test-sites.sh"
Cohesion: 0.31
Nodes (8): at_home(), bad(), get(), jq_py(), lcode(), live_json(), ok(), test-sites.sh script

### Community 10 - "test-build.sh"
Cohesion: 0.40
Nodes (9): bad(), expect_error(), get(), link_of(), make_repo(), MINI_DEPLOY_NO_DASHBOARD, newest(), ok() (+1 more)

### Community 11 - "package.json"
Cohesion: 0.22
Nodes (8): description, engines, node, name, private, scripts, build, version

### Community 12 - "test-deploy.sh"
Cohesion: 0.44
Nodes (8): bad(), expect_error(), host_get(), link_of(), live_id(), MINI_DEPLOY_NO_DASHBOARD, ok(), test-deploy.sh script

### Community 13 - "build.js"
Cohesion: 0.25
Nodes (5): fs, outDir, path, srcDir, WEB_FILES

### Community 14 - "run-caddy.sh"
Cohesion: 0.54
Nodes (7): do_reload(), gateway_ip(), gateway_mac(), lan_bind(), listening_lan(), saved(), run-caddy.sh script

### Community 16 - "app.js"
Cohesion: 0.87
Nodes (5): card(), el(), render(), show(), when()

## Knowledge Gaps
- **17 isolated node(s):** `MINI_DEPLOY_NO_DASHBOARD`, `fs`, `outDir`, `path`, `srcDir` (+12 more)
  These have ≤1 connection - possible missing edges. (Counts symbols only; 129 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **5 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Jobs` connect `webhook.py` to `webhook.py`?**
  _High betweenness centrality (0.040) - this node is a cross-community bridge._
- **What connects `MINI_DEPLOY_NO_DASHBOARD`, `fs`, `outDir` to the rest of the system?**
  _17 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `build.py, deploy.py` be split into smaller, more focused modules?**
  _Cohesion score 0.0647887323943662 - nodes in this community are weakly interconnected._
- **Why does `Seen` connect `webhook.py` to `webhook.py`?**
  _High betweenness centrality (0.027) - this node is a cross-community bridge._
- **Should `webhook.py` be split into smaller, more focused modules?**
  _Cohesion score 0.06533575317604355 - nodes in this community are weakly interconnected._
- **Why does `Server` connect `webhook.py` to `webhook.py`?**
  _High betweenness centrality (0.022) - this node is a cross-community bridge._
- **Should `buildlog.py, logs.py` be split into smaller, more focused modules?**
  _Cohesion score 0.1028225806451613 - nodes in this community are weakly interconnected._