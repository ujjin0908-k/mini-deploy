# Graph Report - mini-deploy  (2026-10-13)

## Corpus Check
- 43 files · ~56,655 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 533 nodes · 1202 edges · 35 communities (24 shown, 11 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 15 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- build
- admin
- build
- buildlog
- test-webhook script
- appenv
- ci_forwarder
- dashboard
- export-diagrams
- webhook
- webhook
- webhook
- test-build script
- app page
- app page
- test-sites script
- webhook
- package pageon
- test-deploy script
- build page
- admin
- run-caddy script
- webhook
- webhook
- webhook
- test-admin script
- webhook
- app page
- test-ci script
- probe script
- run-webhook script
- sync-theme script

## God Nodes (most connected - your core abstractions)
1. `test-webhook.sh script` - 26 edges
2. `run_job()` - 20 edges
3. `Handler` - 17 edges
4. `DeployError` - 16 edges
5. `_deploy_locked()` - 15 edges
6. `remove_preview()` - 15 edges
7. `main()` - 15 edges
8. `main()` - 15 edges
9. `load()` - 14 edges
10. `db()` - 14 edges

## Surprising Connections (you probably didn't know these)
- `build_and_deploy()` --calls--> `app_paths()`  [EXTRACTED]
  scripts/build.py → scripts/deploy.py
- `build_and_deploy()` --calls--> `drop_if_empty()`  [EXTRACTED]
  scripts/build.py → scripts/deploy.py
- `run_job()` --calls--> `build_and_deploy()`  [EXTRACTED]
  scripts/webhook.py → scripts/build.py
- `_build_locked()` --calls--> `deploy()`  [EXTRACTED]
  scripts/build.py → scripts/deploy.py
- `_build_locked()` --calls--> `locked`  [EXTRACTED]
  scripts/build.py → scripts/deploy.py

## Import Cycles
- None detected.

## Communities (35 total, 11 thin omitted)

### Community 0 - "build"
Cohesion: 0.05
Nodes (47): main(), app_paths(), _check_expected(), check_preview(), check_tree(), cleanup_stale(), clear_hold(), clear_hold_after_manual_deploy() (+39 more)

### Community 1 - "admin"
Cohesion: 0.09
Nodes (19): audit(), check_password(), _clean(), db(), find_session(), Handler, hash_password(), log_login() (+11 more)

### Community 2 - "build"
Cohesion: 0.08
Nodes (18): all_forms(), build_and_deploy(), _build_locked(), BuildError, chown_tree(), client_env(), docker_build(), EnvBuildError (+10 more)

### Community 3 - "buildlog"
Cohesion: 0.09
Nodes (14): Capture, clean(), _key(), _locked(), logs_of(), _new_id(), prune(), read_header() (+6 more)

### Community 4 - "test-webhook script"
Cohesion: 0.15
Nodes (28): bad(), body(), bpush(), break_build(), code_of(), commit_page(), expect(), g() (+20 more)

### Community 5 - "appenv"
Cohesion: 0.17
Nodes (15): check_key(), _check_private(), check_root(), check_value(), env_file(), EnvError, file_for_build(), for_build() (+7 more)

### Community 6 - "ci_forwarder"
Cohesion: 0.12
Nodes (8): _check_private(), ConfigError, Handler, load_upstream(), main(), save_upstream(), serve(), valid_upstream()

### Community 7 - "dashboard"
Cohesion: 0.18
Nodes (11): collect(), collect_apps(), _comparable(), main(), maybe_refresh(), parse_log(), public_detail(), read_log_tail() (+3 more)

### Community 8 - "export-diagrams"
Cohesion: 0.23
Nodes (7): css_variables(), export(), main(), resolve(), standalone(), svg_rules(), xml_safe()

### Community 9 - "webhook"
Cohesion: 0.24
Nodes (10): check_checkout_size(), check_disk(), git(), GitError, read_deployed(), remote_tip(), run_job(), tree_size() (+2 more)

### Community 11 - "webhook"
Cohesion: 0.19
Nodes (5): Handler, revive(), make_job(), safe_branch(), verify_signature()

### Community 12 - "test-build script"
Cohesion: 0.30
Nodes (11): bad(), expect_error(), get(), link_of(), make_repo(), MINI_DEPLOY_APP_ENV, MINI_DEPLOY_NO_DASHBOARD, MINI_DEPLOY_TESTING (+3 more)

### Community 13 - "app page"
Cohesion: 0.41
Nodes (11): act(), api(), appCard(), copyButton(), el(), load(), render(), say() (+3 more)

### Community 14 - "app page"
Cohesion: 0.38
Nodes (11): appCard(), command(), copyText(), fallback(), manual(), say(), el(), load() (+3 more)

### Community 15 - "test-sites script"
Cohesion: 0.31
Nodes (8): at_home(), bad(), get(), jq_py(), lcode(), live_json(), ok(), test-sites.sh script

### Community 16 - "webhook"
Cohesion: 0.24
Nodes (5): ConfigError, load_config(), main(), read_secret(), read_secret_from_file()

### Community 17 - "package pageon"
Cohesion: 0.22
Nodes (8): description, engines, node, name, private, scripts, build, version

### Community 18 - "test-deploy script"
Cohesion: 0.44
Nodes (8): bad(), expect_error(), host_get(), link_of(), live_id(), MINI_DEPLOY_NO_DASHBOARD, ok(), test-deploy.sh script

### Community 19 - "build page"
Cohesion: 0.25
Nodes (5): fs, outDir, path, srcDir, WEB_FILES

### Community 21 - "run-caddy script"
Cohesion: 0.54
Nodes (7): do_reload(), gateway_ip(), gateway_mac(), lan_bind(), listening_lan(), saved(), run-caddy.sh script

### Community 23 - "webhook"
Cohesion: 0.29
Nodes (3): load_pending(), save_pending(), write_pending()

### Community 25 - "test-admin script"
Cohesion: 0.47
Nodes (4): bad(), MINI_DEPLOY_NO_DASHBOARD, ok(), test-admin.sh script

### Community 27 - "app page"
Cohesion: 0.87
Nodes (5): card(), el(), render(), show(), when()

### Community 28 - "test-ci script"
Cohesion: 0.83
Nodes (3): bad(), ok(), test-ci.sh script

## Knowledge Gaps
- **20 isolated node(s):** `description`, `node`, `name`, `private`, `build` (+15 more)
  These have ≤1 connection - possible missing edges. (Counts symbols only; 183 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **11 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Jobs` connect `webhook` to `webhook`, `webhook`?**
  _High betweenness centrality (0.030) - this node is a cross-community bridge._
- **What connects `description`, `node`, `name` to the rest of the system?**
  _20 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `build` be split into smaller, more focused modules?**
  _Cohesion score 0.05378151260504202 - nodes in this community are weakly interconnected._
- **Why does `Seen` connect `webhook` to `webhook`, `webhook`?**
  _High betweenness centrality (0.020) - this node is a cross-community bridge._
- **Should `admin` be split into smaller, more focused modules?**
  _Cohesion score 0.08672699849170437 - nodes in this community are weakly interconnected._
- **Should `build` be split into smaller, more focused modules?**
  _Cohesion score 0.08130081300813008 - nodes in this community are weakly interconnected._
- **Should `buildlog` be split into smaller, more focused modules?**
  _Cohesion score 0.09206349206349207 - nodes in this community are weakly interconnected._