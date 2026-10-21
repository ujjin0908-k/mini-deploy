# Graph Report - mini-deploy  (2026-10-21)

## Corpus Check
- 42 files · ~78,116 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 22 file(s) not represented in the graph (top: .css 11, .service 6, (none) 3)

## Summary
- 721 nodes · 1652 edges · 42 communities (31 shown, 11 thin omitted)
- Extraction: 97% EXTRACTED · 3% INFERRED · 0% AMBIGUOUS · INFERRED: 52 edges (avg confidence: 0.92)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `81a4478a`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- deploy.py
- Handler
- build.py
- buildlog.py
- test-webhook.sh
- appenv.py
- re
- upload.py
- repos.py
- os
- Jobs
- ci_forwarder.py
- test-build.sh
- admin/app.js
- admin.py
- test-sites.sh
- test-backup.sh
- package.json
- test-deploy.sh
- build.js
- Server
- run-caddy.sh
- db
- mini-deploy: notes for agents
- state
- test-admin.sh
- The demo site, explained
- logs/app.js
- test-ci.sh
- probe.sh
- run-webhook.sh
- sync-theme.sh
- The landing page, explained
- Running commands in WSL
- _clean
- README.md
- test-all.sh
- webhook.py
- test-upload.sh

## God Nodes (most connected - your core abstractions)
1. `test-webhook.sh script` - 31 edges
2. `Handler` - 23 edges
3. `run_job()` - 23 edges
4. `db()` - 19 edges
5. `make()` - 18 edges
6. `Security rules (the reviewers check these)` - 18 edges
7. `DeployError` - 17 edges
8. `remove_preview()` - 16 edges
9. `load()` - 15 edges
10. `run-caddy.sh script` - 15 edges

## Surprising Connections (you probably didn't know these)
- `Environment` --references--> `git()`  [INFERRED]
  CLAUDE.md → scripts/webhook.py
- `Security rules (the reviewers check these)` --references--> `tailnet_urls()`  [INFERRED]
  CLAUDE.md → scripts/admin.py
- `Security rules (the reviewers check these)` --references--> `app_lock()`  [INFERRED]
  CLAUDE.md → scripts/backup.py
- `mini-deploy status log` --references--> `find_secret()`  [INFERRED]
  docs/status-log.md → scripts/build.py
- `Security rules (the reviewers check these)` --references--> `EnvBuildError`  [INFERRED]
  CLAUDE.md → scripts/build.py

## Import Cycles
- None detected.

## Communities (42 total, 11 thin omitted)

### Community 0 - "deploy.py"
Cohesion: 0.06
Nodes (47): Security rules (the reviewers check these), Stages, mini-deploy status log, main(), collect_apps(), app_paths(), append_private(), _check_expected() (+39 more)

### Community 2 - "build.py"
Cohesion: 0.08
Nodes (18): all_forms(), build_and_deploy(), _build_locked(), BuildError, chown_tree(), client_env(), docker_build(), EnvBuildError (+10 more)

### Community 3 - "buildlog.py"
Cohesion: 0.10
Nodes (14): Capture, clean(), _key(), _locked(), logs_of(), _new_id(), prune(), read_header() (+6 more)

### Community 4 - "test-webhook.sh"
Cohesion: 0.11
Nodes (36): bad(), body(), bpush(), break_build(), check_code(), code_of(), commit_page(), expect() (+28 more)

### Community 5 - "appenv.py"
Cohesion: 0.17
Nodes (15): check_key(), _check_private(), check_root(), check_value(), env_file(), EnvError, file_for_build(), for_build() (+7 more)

### Community 6 - "re"
Cohesion: 0.09
Nodes (15): connected_apps(), is_test_name(), main(), plan(), collect(), parse_log(), public_detail(), read_log_tail() (+7 more)

### Community 7 - "upload.py"
Cohesion: 0.17
Nodes (10): _check_kind(), _check_toc(), _make_dirs(), _parts(), _plan(), _shown(), _site_root(), unpack() (+2 more)

### Community 8 - "repos.py"
Cohesion: 0.16
Nodes (10): upload_problem(), _config(), _full_row(), hook_base(), list_repos(), repo_by_hook(), repo_by_name(), repo_for_app() (+2 more)

### Community 9 - "os"
Cohesion: 0.09
Nodes (23): app_lock(), apply(), _apps(), BackupError, _check_app(), check_archive(), env_names(), _filter() (+15 more)

### Community 10 - "Jobs"
Cohesion: 0.09
Nodes (3): Jobs, Seen, State

### Community 11 - "ci_forwarder.py"
Cohesion: 0.09
Nodes (9): _check_private(), ConfigError, Handler, load_upstream(), main(), save_upstream(), serve(), Server (+1 more)

### Community 12 - "test-build.sh"
Cohesion: 0.35
Nodes (10): bad(), expect_error(), get(), link_of(), make_repo(), MINI_DEPLOY_APP_ENV, MINI_DEPLOY_TESTING, newest() (+2 more)

### Community 13 - "admin/app.js"
Cohesion: 0.25
Nodes (20): act(), api(), appCard(), clearSecret(), copyButton(), disconnectRepo(), el(), gitAction() (+12 more)

### Community 14 - "admin.py"
Cohesion: 0.17
Nodes (11): check_password(), find_session(), hash_password(), log_login(), login_wait(), main(), new_session(), _now_iso() (+3 more)

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

### Community 20 - "Server"
Cohesion: 0.25
Nodes (3): Server, cut(), extend()

### Community 21 - "run-caddy.sh"
Cohesion: 0.20
Nodes (18): busy_phone_ports(), current(), do_reload(), fallback_config(), gateway_ip(), gateway_mac(), lan_bind(), listening_lan() (+10 more)

### Community 22 - "db"
Cohesion: 0.19
Nodes (8): audit(), db(), _now_iso(), _private(), _check(), connect(), disconnect(), rotate()

### Community 23 - "mini-deploy: notes for agents"
Cohesion: 0.20
Nodes (9): Code map (graphify), Commands, Environment, Git, Handoff (start of the next session, updated 2026-10-15, end of session), mini-deploy: notes for agents, Owner's decisions (from the Obsidian note), Owner's working style (+1 more)

### Community 24 - "state"
Cohesion: 0.25
Nodes (4): phone_base(), state(), tailnet_urls(), token_status()

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

### Community 40 - "webhook.py"
Cohesion: 0.05
Nodes (34): sweep_stale(), safe_branch(), check_checkout_size(), check_disk(), ConfigError, db_lookup(), find_repo(), git() (+26 more)

## Knowledge Gaps
- **47 isolated node(s):** `probe.sh script`, `fs`, `path`, `srcDir`, `outDir` (+42 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 275 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **11 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Handler` connect `Handler` to `_clean`, `admin.py`?**
  _High betweenness centrality (0.031) - this node is a cross-community bridge._
- **What connects `probe.sh script`, `fs`, `path` to the rest of the system?**
  _47 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `deploy.py` be split into smaller, more focused modules?**
  _Cohesion score 0.05721168322794339 - nodes in this community are weakly interconnected._
- **Why does `Security rules (the reviewers check these)` connect `deploy.py` to `build.py`, `re`, `upload.py`, `repos.py`, `os`, `webhook.py`, `mini-deploy: notes for agents`, `state`?**
  _High betweenness centrality (0.022) - this node is a cross-community bridge._
- **Should `build.py` be split into smaller, more focused modules?**
  _Cohesion score 0.07897793263646923 - nodes in this community are weakly interconnected._
- **Why does `Jobs` connect `Jobs` to `webhook.py`?**
  _High betweenness centrality (0.022) - this node is a cross-community bridge._
- **Should `buildlog.py` be split into smaller, more focused modules?**
  _Cohesion score 0.1028225806451613 - nodes in this community are weakly interconnected._