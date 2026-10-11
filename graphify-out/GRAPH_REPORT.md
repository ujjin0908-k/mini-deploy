# Graph Report - mini-deploy  (2026-10-12)

## Corpus Check
- 8 files · ~0 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 301 nodes · 652 edges · 18 communities (13 shown, 5 thin omitted)
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 12 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- Deploy, previews, prune
- Webhook request handling
- Webhook test script
- Dashboard data and refresh
- Docker build
- Webhook job queue
- Diagram export
- Dashboard page script
- Demo site package
- Build test script
- Deploy test script
- Demo site build step
- Sites test script
- Webhook HTTP server
- WSL probe script
- Webhook launcher
- Theme sync script

## God Nodes (most connected - your core abstractions)
1. `test-webhook.sh script` - 26 edges
2. `run_job()` - 18 edges
3. `refresh()` - 15 edges
4. `_deploy_locked()` - 15 edges
5. `main()` - 15 edges
6. `build_and_deploy()` - 14 edges
7. `DeployError` - 14 edges
8. `remove_preview()` - 13 edges
9. `main()` - 13 edges
10. `main()` - 12 edges

## Surprising Connections (you probably didn't know these)
- `build_and_deploy()` --calls--> `app_paths()`  [EXTRACTED]
  scripts/build.py → scripts/deploy.py
- `build_and_deploy()` --calls--> `deploy()`  [EXTRACTED]
  scripts/build.py → scripts/deploy.py
- `build_and_deploy()` --calls--> `locked`  [EXTRACTED]
  scripts/build.py → scripts/deploy.py
- `run_job()` --calls--> `build_and_deploy()`  [EXTRACTED]
  scripts/webhook.py → scripts/build.py
- `main()` --calls--> `check_preview_room()`  [EXTRACTED]
  scripts/build.py → scripts/deploy.py

## Import Cycles
- None detected.

## Communities (18 total, 5 thin omitted)

### Community 0 - "Deploy, previews, prune"
Cohesion: 0.07
Nodes (35): app_paths(), check_preview_room(), check_tree(), cleanup_stale(), clear_hold(), clear_hold_after_manual_deploy(), current_id(), deploy() (+27 more)

### Community 1 - "Webhook request handling"
Cohesion: 0.07
Nodes (25): check_checkout_size(), check_disk(), ConfigError, git(), GitError, Handler, init_env(), load_config() (+17 more)

### Community 2 - "Webhook test script"
Cohesion: 0.15
Nodes (28): bad(), body(), bpush(), break_build(), code_of(), commit_page(), expect(), g() (+20 more)

### Community 3 - "Dashboard data and refresh"
Cohesion: 0.16
Nodes (12): collect(), collect_apps(), _comparable(), main(), maybe_refresh(), parse_log(), public_detail(), read_log_tail() (+4 more)

### Community 4 - "Docker build"
Cohesion: 0.17
Nodes (8): build_and_deploy(), BuildError, chown_tree(), docker_build(), image_ref(), main(), node_major(), sweep_stale()

### Community 5 - "Webhook job queue"
Cohesion: 0.11
Nodes (3): Jobs, Seen, State

### Community 6 - "Diagram export"
Cohesion: 0.18
Nodes (7): css_variables(), export(), main(), resolve(), standalone(), svg_rules(), xml_safe()

### Community 7 - "Dashboard page script"
Cohesion: 0.38
Nodes (10): appCard(), command(), copyText(), fallback(), manual(), say(), el(), load() (+2 more)

### Community 8 - "Demo site package"
Cohesion: 0.22
Nodes (8): description, engines, node, name, private, scripts, build, version

### Community 9 - "Build test script"
Cohesion: 0.44
Nodes (8): bad(), expect_error(), get(), link_of(), make_repo(), MINI_DEPLOY_NO_DASHBOARD, ok(), test-build.sh script

### Community 10 - "Deploy test script"
Cohesion: 0.44
Nodes (8): bad(), expect_error(), host_get(), link_of(), live_id(), MINI_DEPLOY_NO_DASHBOARD, ok(), test-deploy.sh script

### Community 11 - "Demo site build step"
Cohesion: 0.25
Nodes (5): fs, outDir, path, srcDir, WEB_FILES

### Community 12 - "Sites test script"
Cohesion: 0.43
Nodes (6): bad(), get(), jq_py(), live_json(), ok(), test-sites.sh script

## Knowledge Gaps
- **17 isolated node(s):** `MINI_DEPLOY_NO_DASHBOARD`, `fs`, `outDir`, `path`, `srcDir` (+12 more)
  These have ≤1 connection - possible missing edges. (Counts symbols only; 107 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **5 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Seen` connect `Webhook job queue` to `Webhook request handling`?**
  _High betweenness centrality (0.033) - this node is a cross-community bridge._
- **What connects `MINI_DEPLOY_NO_DASHBOARD`, `fs`, `outDir` to the rest of the system?**
  _17 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Deploy, previews, prune` be split into smaller, more focused modules?**
  _Cohesion score 0.07219662058371736 - nodes in this community are weakly interconnected._
- **Why does `Jobs` connect `Webhook job queue` to `Webhook request handling`?**
  _High betweenness centrality (0.029) - this node is a cross-community bridge._
- **Should `Webhook request handling` be split into smaller, more focused modules?**
  _Cohesion score 0.06988120195667366 - nodes in this community are weakly interconnected._
- **Why does `Server` connect `Webhook HTTP server` to `Webhook request handling`?**
  _High betweenness centrality (0.027) - this node is a cross-community bridge._
- **Should `Webhook test script` be split into smaller, more focused modules?**
  _Cohesion score 0.14838709677419354 - nodes in this community are weakly interconnected._