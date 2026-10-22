# Graph Report - mini-deploy  (2026-10-23)

## Corpus Check
- 42 files · ~90,253 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 22 file(s) not represented in the graph (top: .css 11, .service 6, (none) 3)

## Summary
- 792 nodes · 1845 edges · 48 communities (34 shown, 14 thin omitted)
- Extraction: 96% EXTRACTED · 4% INFERRED · 0% AMBIGUOUS · INFERRED: 72 edges (avg confidence: 0.92)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `d6afa972`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- deploy.py
- Handler
- build.py
- time
- test-webhook.sh
- os
- re
- sys
- repos.py
- backup.py
- Jobs
- Handler
- test-build.sh
- admin/app.js
- upload.py
- test-sites.sh
- test-backup.sh
- package.json
- test-deploy.sh
- build.js
- admin.py
- run-caddy.sh
- find_secret
- mini-deploy: notes for agents
- db
- test-admin.sh
- The demo site, explained
- logs/app.js
- test-ci.sh
- probe.sh
- run-webhook.sh
- sync-theme.sh
- The landing page, explained
- Running commands in WSL
- Server
- README.md
- test-all.sh
- webhook.py
- Usage
- _build_locked
- state
- Capture
- secret_forms
- test-upload.sh
- _clean

## God Nodes (most connected - your core abstractions)
1. `test-webhook.sh script` - 31 edges
2. `Security rules (the reviewers check these)` - 29 edges
3. `Handler` - 24 edges
4. `run_job()` - 24 edges
5. `db()` - 21 edges
6. `make()` - 20 edges
7. `mini-deploy status log` - 20 edges
8. `DeployError` - 17 edges
9. `remove_preview()` - 16 edges
10. `take_redeploy_requests()` - 16 edges

## Surprising Connections (you probably didn't know these)
- `Security rules (the reviewers check these)` --references--> `fail()`  [INFERRED]
  CLAUDE.md → scripts/build.py
- `Environment` --references--> `git()`  [INFERRED]
  CLAUDE.md → scripts/webhook.py
- `Security rules (the reviewers check these)` --references--> `tailnet_urls()`  [INFERRED]
  CLAUDE.md → scripts/admin.py
- `Security rules (the reviewers check these)` --references--> `app_lock()`  [INFERRED]
  CLAUDE.md → scripts/backup.py
- `mini-deploy status log` --references--> `app_lock()`  [INFERRED]
  docs/status-log.md → scripts/backup.py

## Import Cycles
- None detected.

## Communities (48 total, 14 thin omitted)

### Community 0 - "deploy.py"
Cohesion: 0.06
Nodes (45): Stages, mini-deploy status log, collect_apps(), app_paths(), append_private(), _check_expected(), check_preview(), check_tree() (+37 more)

### Community 2 - "build.py"
Cohesion: 0.18
Nodes (6): client_env(), docker_build(), mask(), pump_output(), _run_box(), sweep_stale()

### Community 3 - "time"
Cohesion: 0.14
Nodes (12): _key(), _locked(), logs_of(), _new_id(), prune(), read_header(), remove_app(), _replace_atomically() (+4 more)

### Community 4 - "test-webhook.sh"
Cohesion: 0.11
Nodes (36): bad(), body(), bpush(), break_build(), check_code(), code_of(), commit_page(), expect() (+28 more)

### Community 5 - "os"
Cohesion: 0.05
Nodes (39): check_key(), _check_private(), check_root(), check_value(), env_file(), EnvError, file_for_build(), for_build() (+31 more)

### Community 6 - "re"
Cohesion: 0.09
Nodes (15): connected_apps(), is_test_name(), main(), plan(), collect(), parse_log(), public_detail(), read_log_tail() (+7 more)

### Community 7 - "sys"
Cohesion: 0.22
Nodes (5): build_and_deploy(), BuildError, image_ref(), main(), node_major()

### Community 8 - "repos.py"
Cohesion: 0.13
Nodes (13): _check(), _config(), connect(), _full_row(), hook_base(), list_repos(), repo_by_hook(), repo_by_name() (+5 more)

### Community 9 - "backup.py"
Cohesion: 0.09
Nodes (20): app_lock(), apply(), _apps(), BackupError, _check_app(), check_archive(), env_names(), _filter() (+12 more)

### Community 10 - "Jobs"
Cohesion: 0.10
Nodes (3): Jobs, Seen, State

### Community 12 - "test-build.sh"
Cohesion: 0.35
Nodes (10): bad(), expect_error(), get(), link_of(), make_repo(), MINI_DEPLOY_APP_ENV, MINI_DEPLOY_TESTING, newest() (+2 more)

### Community 13 - "admin/app.js"
Cohesion: 0.16
Nodes (32): act(), ageSeconds(), aiMeter(), api(), appCard(), appLabel(), beansRow(), clearSecret() (+24 more)

### Community 14 - "upload.py"
Cohesion: 0.17
Nodes (10): _check_kind(), _check_toc(), _make_dirs(), _parts(), _plan(), _shown(), _site_root(), unpack() (+2 more)

### Community 15 - "test-sites.sh"
Cohesion: 0.31
Nodes (8): at_home(), bad(), get(), lcode(), listed(), ok(), test-sites.sh script, tget()

### Community 16 - "test-backup.sh"
Cohesion: 0.83
Nodes (3): bad(), ok(), test-backup.sh script

### Community 17 - "package.json"
Cohesion: 0.22
Nodes (8): description, engines, node, name, private, scripts, build, version

### Community 18 - "test-deploy.sh"
Cohesion: 0.54
Nodes (7): bad(), expect_error(), host_get(), link_of(), live_id(), ok(), test-deploy.sh script

### Community 19 - "build.js"
Cohesion: 0.25
Nodes (5): fs, outDir, path, srcDir, WEB_FILES

### Community 20 - "admin.py"
Cohesion: 0.16
Nodes (11): check_password(), hash_password(), log_login(), login_wait(), main(), new_session(), _now_iso(), serve() (+3 more)

### Community 21 - "run-caddy.sh"
Cohesion: 0.20
Nodes (18): busy_phone_ports(), current(), do_reload(), fallback_config(), gateway_ip(), gateway_mac(), lan_bind(), listening_lan() (+10 more)

### Community 22 - "find_secret"
Cohesion: 0.40
Nodes (3): find_secret(), _walk_strict(), fail()

### Community 23 - "mini-deploy: notes for agents"
Cohesion: 0.20
Nodes (9): Code map (graphify), Commands, Environment, Git, Handoff (start of the next session, updated 2026-10-15, end of session), mini-deploy: notes for agents, Owner's decisions (from the Obsidian note), Owner's working style (+1 more)

### Community 24 - "db"
Cohesion: 0.24
Nodes (5): audit(), db(), _now_iso(), _private(), disconnect()

### Community 25 - "test-admin.sh"
Cohesion: 0.60
Nodes (3): bad(), ok(), test-admin.sh script

### Community 26 - "The demo site, explained"
Cohesion: 0.25
Nodes (7): Files, Releases: keep a few, move one arrow, The demo site, explained, The stamp: before and after, Try it, What it is, What the build box is not allowed to do

### Community 27 - "logs/app.js"
Cohesion: 0.87
Nodes (5): card(), el(), render(), show(), when()

### Community 28 - "test-ci.sh"
Cohesion: 0.83
Nodes (3): bad(), ok(), test-ci.sh script

### Community 32 - "The landing page, explained"
Cohesion: 0.25
Nodes (7): Files, How the look is made, One theme, many copies, The landing page, explained, The layout, Try it, What it is

### Community 33 - "Running commands in WSL"
Cohesion: 0.29
Nodes (6): 1. Simple command: pass arguments directly, 2. Anything with pipes, variables, loops or quotes: use a script file, 3. Long-running servers: systemd services (Caddy, the webhook), 4. Installs and destructive commands: run them directly, never inside a script, 5. Paths, Running commands in WSL

### Community 34 - "Server"
Cohesion: 0.25
Nodes (3): Server, cut(), extend()

### Community 40 - "webhook.py"
Cohesion: 0.05
Nodes (37): Security rules (the reviewers check these), safe_branch(), check_checkout_size(), check_disk(), ConfigError, db_lookup(), find_repo(), find_repo_for_app() (+29 more)

### Community 41 - "Usage"
Cohesion: 0.12
Nodes (3): seconds_to_midnight(), Server, Usage

### Community 42 - "_build_locked"
Cohesion: 0.22
Nodes (5): all_forms(), _build_locked(), chown_tree(), EnvBuildError, load_env()

### Community 43 - "state"
Cohesion: 0.25
Nodes (4): phone_base(), state(), tailnet_urls(), token_status()

## Knowledge Gaps
- **47 isolated node(s):** `probe.sh script`, `fs`, `path`, `srcDir`, `outDir` (+42 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 301 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **14 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Security rules (the reviewers check these)` connect `webhook.py` to `deploy.py`, `os`, `re`, `repos.py`, `backup.py`, `_build_locked`, `state`, `admin/app.js`, `upload.py`, `find_secret`, `mini-deploy: notes for agents`, `db`?**
  _High betweenness centrality (0.093) - this node is a cross-community bridge._
- **What connects `probe.sh script`, `fs`, `path` to the rest of the system?**
  _47 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `deploy.py` be split into smaller, more focused modules?**
  _Cohesion score 0.056790123456790124 - nodes in this community are weakly interconnected._
- **Why does `renderTrack()` connect `admin/app.js` to `webhook.py`?**
  _High betweenness centrality (0.034) - this node is a cross-community bridge._
- **Should `time` be split into smaller, more focused modules?**
  _Cohesion score 0.14153846153846153 - nodes in this community are weakly interconnected._
- **Why does `Handler` connect `Handler` to `db`, `admin.py`, `_clean`?**
  _High betweenness centrality (0.031) - this node is a cross-community bridge._
- **Should `test-webhook.sh` be split into smaller, more focused modules?**
  _Cohesion score 0.1073170731707317 - nodes in this community are weakly interconnected._