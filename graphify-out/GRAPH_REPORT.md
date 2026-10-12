# Graph Report - mini-deploy  (2026-10-12)

## Corpus Check
- 37 files · ~46,297 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 425 nodes · 939 edges · 21 communities (17 shown, 4 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 14 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- Deploy and releases
- Webhook handler
- Container build and secret checks
- Per-app env values
- Build logs
- Webhook tests
- Webhook job queue
- Dashboard data
- Diagram export
- Build tests
- Dashboard page JS
- Site tests
- Example package.json
- Deploy tests
- Example build script
- Caddy home check
- Logs page JS
- WSL probe
- Webhook runner
- Theme sync

## God Nodes (most connected - your core abstractions)
1. `test-webhook.sh script` - 26 edges
2. `_deploy_locked()` - 15 edges
3. `main()` - 15 edges
4. `run_job()` - 15 edges
5. `main()` - 15 edges
6. `DeployError` - 14 edges
7. `remove_preview()` - 14 edges
8. `load()` - 14 edges
9. `refresh()` - 12 edges
10. `EnvError` - 11 edges

## Surprising Connections (you probably didn't know these)
- `load_env()` --calls--> `for_build()`  [EXTRACTED]
  scripts/build.py → scripts/appenv.py
- `run_job()` --calls--> `build_and_deploy()`  [EXTRACTED]
  scripts/webhook.py → scripts/build.py
- `main()` --calls--> `logs_of()`  [EXTRACTED]
  scripts/logs.py → scripts/buildlog.py
- `main()` --calls--> `read_header()`  [EXTRACTED]
  scripts/logs.py → scripts/buildlog.py

## Import Cycles
- None detected.

## Communities (21 total, 4 thin omitted)

### Community 0 - "Deploy and releases"
Cohesion: 0.06
Nodes (39): app_paths(), check_preview(), check_tree(), cleanup_stale(), clear_hold(), clear_hold_after_manual_deploy(), current_id(), deploy() (+31 more)

### Community 1 - "Webhook handler"
Cohesion: 0.05
Nodes (29): check_checkout_size(), check_disk(), ConfigError, git(), GitError, Handler, init_env(), load_config() (+21 more)

### Community 2 - "Container build and secret checks"
Cohesion: 0.08
Nodes (19): all_forms(), build_and_deploy(), _build_locked(), BuildError, chown_tree(), client_env(), docker_build(), EnvBuildError (+11 more)

### Community 3 - "Per-app env values"
Cohesion: 0.13
Nodes (17): check_key(), _check_private(), check_root(), check_value(), env_file(), EnvError, file_for_build(), for_build() (+9 more)

### Community 4 - "Build logs"
Cohesion: 0.10
Nodes (13): Capture, clean(), _key(), _locked(), logs_of(), _new_id(), prune(), read_header() (+5 more)

### Community 5 - "Webhook tests"
Cohesion: 0.15
Nodes (28): bad(), body(), bpush(), break_build(), code_of(), commit_page(), expect(), g() (+20 more)

### Community 6 - "Webhook job queue"
Cohesion: 0.10
Nodes (3): Jobs, Seen, State

### Community 7 - "Dashboard data"
Cohesion: 0.18
Nodes (11): collect(), collect_apps(), _comparable(), main(), maybe_refresh(), parse_log(), public_detail(), read_log_tail() (+3 more)

### Community 8 - "Diagram export"
Cohesion: 0.21
Nodes (7): css_variables(), export(), main(), resolve(), standalone(), svg_rules(), xml_safe()

### Community 9 - "Build tests"
Cohesion: 0.30
Nodes (11): bad(), expect_error(), get(), link_of(), make_repo(), MINI_DEPLOY_APP_ENV, MINI_DEPLOY_NO_DASHBOARD, MINI_DEPLOY_TESTING (+3 more)

### Community 10 - "Dashboard page JS"
Cohesion: 0.38
Nodes (11): appCard(), command(), copyText(), fallback(), manual(), say(), el(), load() (+3 more)

### Community 11 - "Site tests"
Cohesion: 0.31
Nodes (8): at_home(), bad(), get(), jq_py(), lcode(), live_json(), ok(), test-sites.sh script

### Community 12 - "Example package.json"
Cohesion: 0.22
Nodes (8): description, engines, node, name, private, scripts, build, version

### Community 13 - "Deploy tests"
Cohesion: 0.44
Nodes (8): bad(), expect_error(), host_get(), link_of(), live_id(), MINI_DEPLOY_NO_DASHBOARD, ok(), test-deploy.sh script

### Community 14 - "Example build script"
Cohesion: 0.25
Nodes (5): fs, outDir, path, srcDir, WEB_FILES

### Community 15 - "Caddy home check"
Cohesion: 0.54
Nodes (7): do_reload(), gateway_ip(), gateway_mac(), lan_bind(), listening_lan(), saved(), run-caddy.sh script

### Community 16 - "Logs page JS"
Cohesion: 0.87
Nodes (5): card(), el(), render(), show(), when()

## Knowledge Gaps
- **19 isolated node(s):** `description`, `node`, `name`, `private`, `build` (+14 more)
  These have ≤1 connection - possible missing edges. (Counts symbols only; 152 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **4 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Jobs` connect `Webhook job queue` to `Webhook handler`?**
  _High betweenness centrality (0.036) - this node is a cross-community bridge._
- **What connects `description`, `node`, `name` to the rest of the system?**
  _19 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Deploy and releases` be split into smaller, more focused modules?**
  _Cohesion score 0.06479113384484228 - nodes in this community are weakly interconnected._
- **Why does `Seen` connect `Webhook job queue` to `Webhook handler`?**
  _High betweenness centrality (0.025) - this node is a cross-community bridge._
- **Should `Webhook handler` be split into smaller, more focused modules?**
  _Cohesion score 0.052083333333333336 - nodes in this community are weakly interconnected._
- **Should `Container build and secret checks` be split into smaller, more focused modules?**
  _Cohesion score 0.07770582793709528 - nodes in this community are weakly interconnected._
- **Should `Per-app env values` be split into smaller, more focused modules?**
  _Cohesion score 0.13333333333333333 - nodes in this community are weakly interconnected._