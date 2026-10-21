# Graph Report - mini-deploy  (2026-10-22)

## Corpus Check
- 42 files · ~83,824 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 22 file(s) not represented in the graph (top: .css 11, .service 6, (none) 3)

## Summary
- 767 nodes · 1759 edges · 51 communities (33 shown, 18 thin omitted)
- Extraction: 97% EXTRACTED · 3% INFERRED · 0% AMBIGUOUS · INFERRED: 61 edges (avg confidence: 0.92)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `b9cc1507`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- deploy.py
- Handler
- build.py
- buildlog.py
- test-webhook.sh
- os
- re
- ci_forwarder.py
- repos.py
- time
- Jobs
- Handler
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
- main
- test-admin.sh
- The demo site, explained
- logs/app.js
- test-ci.sh
- probe.sh
- run-webhook.sh
- sync-theme.sh
- The landing page, explained
- Running commands in WSL
- main
- README.md
- test-all.sh
- webhook.py
- Usage
- write_pending
- Server
- process
- Handler
- test-upload.sh
- Seen
- safe_branch
- Server
- _write_private_json

## God Nodes (most connected - your core abstractions)
1. `test-webhook.sh script` - 31 edges
2. `Handler` - 23 edges
3. `run_job()` - 23 edges
4. `make()` - 20 edges
5. `mini-deploy status log` - 20 edges
6. `db()` - 19 edges
7. `Security rules (the reviewers check these)` - 19 edges
8. `DeployError` - 17 edges
9. `remove_preview()` - 16 edges
10. `load()` - 15 edges

## Surprising Connections (you probably didn't know these)
- `Environment` --references--> `git()`  [INFERRED]
  CLAUDE.md → scripts/webhook.py
- `Handoff (start of the next session, updated 2026-10-15, end of session)` --references--> `git()`  [INFERRED]
  CLAUDE.md → scripts/webhook.py
- `Security rules (the reviewers check these)` --references--> `tailnet_urls()`  [INFERRED]
  CLAUDE.md → scripts/admin.py
- `Security rules (the reviewers check these)` --references--> `app_lock()`  [INFERRED]
  CLAUDE.md → scripts/backup.py
- `mini-deploy status log` --references--> `app_lock()`  [INFERRED]
  docs/status-log.md → scripts/backup.py

## Import Cycles
- None detected.

## Communities (51 total, 18 thin omitted)

### Community 0 - "deploy.py"
Cohesion: 0.05
Nodes (51): Security rules (the reviewers check these), Stages, mini-deploy status log, main(), collect(), collect_apps(), parse_log(), public_detail() (+43 more)

### Community 2 - "build.py"
Cohesion: 0.08
Nodes (19): all_forms(), build_and_deploy(), _build_locked(), BuildError, chown_tree(), client_env(), docker_build(), EnvBuildError (+11 more)

### Community 3 - "buildlog.py"
Cohesion: 0.10
Nodes (14): Capture, clean(), _key(), _locked(), logs_of(), _new_id(), prune(), read_header() (+6 more)

### Community 4 - "test-webhook.sh"
Cohesion: 0.11
Nodes (36): bad(), body(), bpush(), break_build(), check_code(), code_of(), commit_page(), expect() (+28 more)

### Community 5 - "os"
Cohesion: 0.06
Nodes (33): check_key(), _check_private(), check_root(), check_value(), env_file(), EnvError, file_for_build(), for_build() (+25 more)

### Community 6 - "re"
Cohesion: 0.13
Nodes (11): connected_apps(), is_test_name(), main(), plan(), css_variables(), export(), main(), resolve() (+3 more)

### Community 7 - "ci_forwarder.py"
Cohesion: 0.15
Nodes (6): BodyError, check_body(), _count(), _no_duplicates(), seconds_to_midnight(), usage_warning()

### Community 8 - "repos.py"
Cohesion: 0.11
Nodes (14): state(), tailnet_urls(), upload_problem(), _check(), _config(), _full_row(), hook_base(), list_repos() (+6 more)

### Community 9 - "time"
Cohesion: 0.09
Nodes (20): app_lock(), apply(), _apps(), BackupError, _check_app(), check_archive(), env_names(), _filter() (+12 more)

### Community 12 - "test-build.sh"
Cohesion: 0.35
Nodes (10): bad(), expect_error(), get(), link_of(), make_repo(), MINI_DEPLOY_APP_ENV, MINI_DEPLOY_TESTING, newest() (+2 more)

### Community 13 - "admin/app.js"
Cohesion: 0.25
Nodes (20): act(), api(), appCard(), clearSecret(), copyButton(), disconnectRepo(), el(), gitAction() (+12 more)

### Community 14 - "admin.py"
Cohesion: 0.15
Nodes (9): check_password(), _clean(), hash_password(), log_login(), login_wait(), new_session(), _now_iso(), phone_base() (+1 more)

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
Cohesion: 0.21
Nodes (10): main(), serve(), set_password(), audit(), db(), _now_iso(), _private(), connect() (+2 more)

### Community 23 - "mini-deploy: notes for agents"
Cohesion: 0.20
Nodes (9): Code map (graphify), Commands, Environment, Git, Handoff (start of the next session, updated 2026-10-15, end of session), mini-deploy: notes for agents, Owner's decisions (from the Obsidian note), Owner's working style (+1 more)

### Community 24 - "main"
Cohesion: 0.19
Nodes (7): ConfigError, init_env(), load_config(), main(), QueueFull, read_secret(), read_secret_from_file()

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

### Community 34 - "main"
Cohesion: 0.20
Nodes (6): clean_days(), day_key(), load_limits(), main(), usage_today(), valid_limits()

### Community 40 - "webhook.py"
Cohesion: 0.21
Nodes (11): check_checkout_size(), check_disk(), git(), GitError, job_token(), read_deployed(), remote_tip(), run_job() (+3 more)

### Community 42 - "write_pending"
Cohesion: 0.20
Nodes (3): save_pending(), State, write_pending()

### Community 44 - "process"
Cohesion: 0.20
Nodes (6): db_lookup(), find_repo(), process(), RepoDBError, sweep_hook_dirs(), worker()

### Community 48 - "safe_branch"
Cohesion: 0.33
Nodes (4): safe_branch(), load_pending(), revive(), make_job()

## Knowledge Gaps
- **46 isolated node(s):** `probe.sh script`, `fs`, `path`, `srcDir`, `outDir` (+41 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 295 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **18 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Handler` connect `Handler` to `admin.py`?**
  _High betweenness centrality (0.031) - this node is a cross-community bridge._
- **What connects `probe.sh script`, `fs`, `path` to the rest of the system?**
  _46 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `deploy.py` be split into smaller, more focused modules?**
  _Cohesion score 0.050793650793650794 - nodes in this community are weakly interconnected._
- **Why does `Handler` connect `Handler` to `ci_forwarder.py`?**
  _High betweenness centrality (0.022) - this node is a cross-community bridge._
- **Should `build.py` be split into smaller, more focused modules?**
  _Cohesion score 0.07610993657505286 - nodes in this community are weakly interconnected._
- **Why does `Jobs` connect `Jobs` to `webhook.py`, `write_pending`?**
  _High betweenness centrality (0.021) - this node is a cross-community bridge._
- **Should `buildlog.py` be split into smaller, more focused modules?**
  _Cohesion score 0.1028225806451613 - nodes in this community are weakly interconnected._