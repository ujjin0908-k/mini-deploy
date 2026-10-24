# Graph Report - mini-deploy  (2026-10-24)

## Corpus Check
- 39 files · ~87,887 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 16 file(s) not represented in the graph (top: .service 6, .css 5, (none) 3)

## Summary
- 778 nodes · 1835 edges · 50 communities (34 shown, 16 thin omitted)
- Extraction: 96% EXTRACTED · 4% INFERRED · 0% AMBIGUOUS · INFERRED: 75 edges (avg confidence: 0.92)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `a2478c01`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- deploy.py
- Handler
- build.py
- buildlog.py
- test-webhook.sh
- appenv.py
- Server
- repos.py
- os
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
- dashboard.py
- run-caddy.sh
- _read_private_json
- mini-deploy: notes for agents
- clean_days
- test-admin.sh
- time
- logs/app.js
- test-ci.sh
- probe.sh
- Security rules (the reviewers check these)
- sync-theme.sh
- ci_forwarder.py
- Running commands in WSL
- Server
- mini-deploy
- test-all.sh
- webhook.py
- Usage
- test-smoke.sh
- revive
- state
- Handler
- test-upload.sh
- Server
- _write_private_json
- db_lookup

## God Nodes (most connected - your core abstractions)
1. `test-webhook.sh script` - 31 edges
2. `Security rules (the reviewers check these)` - 30 edges
3. `Handler` - 24 edges
4. `run_job()` - 24 edges
5. `mini-deploy status log` - 23 edges
6. `db()` - 21 edges
7. `make()` - 20 edges
8. `DeployError` - 20 edges
9. `remove_preview()` - 16 edges
10. `take_redeploy_requests()` - 16 edges

## Surprising Connections (you probably didn't know these)
- `Environment` --references--> `git()`  [INFERRED]
  CLAUDE.md → scripts/webhook.py
- `Security rules (the reviewers check these)` --references--> `tailnet_urls()`  [INFERRED]
  CLAUDE.md → scripts/admin.py
- `Security rules (the reviewers check these)` --references--> `app_lock()`  [INFERRED]
  CLAUDE.md → scripts/backup.py
- `mini-deploy status log` --references--> `app_lock()`  [INFERRED]
  docs/status-log.md → scripts/backup.py
- `mini-deploy status log` --references--> `make()`  [INFERRED]
  docs/status-log.md → scripts/backup.py

## Import Cycles
- None detected.

## Communities (50 total, 16 thin omitted)

### Community 0 - "deploy.py"
Cohesion: 0.05
Nodes (50): Stages, mini-deploy status log, collect_apps(), app_paths(), append_private(), _check_expected(), check_preview(), check_tree() (+42 more)

### Community 1 - "Handler"
Cohesion: 0.12
Nodes (4): find_session(), Handler, login_wait(), audit()

### Community 2 - "build.py"
Cohesion: 0.08
Nodes (20): all_forms(), build_and_deploy(), _build_locked(), BuildError, chown_tree(), client_env(), docker_build(), EnvBuildError (+12 more)

### Community 3 - "buildlog.py"
Cohesion: 0.08
Nodes (18): Capture, clean(), _key(), _locked(), logs_of(), _new_id(), prune(), read_header() (+10 more)

### Community 4 - "test-webhook.sh"
Cohesion: 0.11
Nodes (36): bad(), body(), bpush(), break_build(), check_code(), code_of(), commit_page(), expect() (+28 more)

### Community 5 - "appenv.py"
Cohesion: 0.17
Nodes (15): check_key(), _check_private(), check_root(), check_value(), env_file(), EnvError, file_for_build(), for_build() (+7 more)

### Community 8 - "repos.py"
Cohesion: 0.08
Nodes (21): upload_problem(), _now_iso(), _check(), _config(), connect(), disconnect(), _full_row(), git_auth() (+13 more)

### Community 9 - "os"
Cohesion: 0.06
Nodes (35): check_password(), _clean(), hash_password(), log_login(), main(), new_session(), _now_iso(), phone_base() (+27 more)

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

### Community 20 - "dashboard.py"
Cohesion: 0.31
Nodes (4): collect(), parse_log(), public_detail(), read_log_tail()

### Community 21 - "run-caddy.sh"
Cohesion: 0.20
Nodes (18): busy_phone_ports(), current(), do_reload(), fallback_config(), gateway_ip(), gateway_mac(), lan_bind(), listening_lan() (+10 more)

### Community 22 - "_read_private_json"
Cohesion: 0.27
Nodes (5): _check_private(), ConfigError, load_upstream(), _read_private_json(), valid_upstream()

### Community 23 - "mini-deploy: notes for agents"
Cohesion: 0.20
Nodes (9): Code map (graphify), Commands, Environment, Git, Handoff (start of the next session, updated 2026-10-24), mini-deploy: notes for agents, Owner's decisions (from the Obsidian note), Owner's working style (+1 more)

### Community 25 - "test-admin.sh"
Cohesion: 0.60
Nodes (3): bad(), ok(), test-admin.sh script

### Community 26 - "time"
Cohesion: 0.21
Nodes (6): request_redeploy(), process(), _read_request(), sweep_hook_dirs(), take_redeploy_requests(), worker()

### Community 27 - "logs/app.js"
Cohesion: 0.87
Nodes (5): card(), el(), render(), show(), when()

### Community 28 - "test-ci.sh"
Cohesion: 0.83
Nodes (3): bad(), ok(), test-ci.sh script

### Community 30 - "Security rules (the reviewers check these)"
Cohesion: 0.18
Nodes (11): Security rules (the reviewers check these), drop_empty_releases(), check_checkout_size(), check_disk(), git(), GitError, job_token(), remote_tip() (+3 more)

### Community 32 - "ci_forwarder.py"
Cohesion: 0.19
Nodes (4): BodyError, check_body(), _count(), _no_duplicates()

### Community 33 - "Running commands in WSL"
Cohesion: 0.29
Nodes (6): 1. Simple command: pass arguments directly, 2. Anything with pipes, variables, loops or quotes: use a script file, 3. Long-running servers: systemd services (Caddy, the webhook), 4. Installs and destructive commands: run them directly, never inside a script, 5. Paths, Running commands in WSL

### Community 34 - "Server"
Cohesion: 0.25
Nodes (3): Server, cut(), extend()

### Community 35 - "mini-deploy"
Cohesion: 0.33
Nodes (5): Everyday commands (in WSL, from the repo), mini-deploy, What happens when you push, What it can do, Where things are

### Community 40 - "webhook.py"
Cohesion: 0.16
Nodes (12): safe_branch(), ConfigError, load_config(), load_pending(), main(), read_deployed(), read_secret(), read_secret_from_file() (+4 more)

### Community 43 - "revive"
Cohesion: 0.40
Nodes (3): find_repo(), revive(), make_job()

### Community 44 - "state"
Cohesion: 0.20
Nodes (7): state(), day_key(), load_limits(), main(), usage_today(), usage_warning(), valid_limits()

### Community 50 - "db_lookup"
Cohesion: 0.25
Nodes (4): db_lookup(), find_repo_for_app(), QueueFull, RepoDBError

## Knowledge Gaps
- **38 isolated node(s):** `probe.sh script`, `fs`, `path`, `srcDir`, `outDir` (+33 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 290 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **16 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Security rules (the reviewers check these)` connect `Security rules (the reviewers check these)` to `deploy.py`, `Handler`, `build.py`, `repos.py`, `os`, `webhook.py`, `admin/app.js`, `upload.py`, `db_lookup`, `dashboard.py`, `mini-deploy: notes for agents`, `time`?**
  _High betweenness centrality (0.096) - this node is a cross-community bridge._
- **Are the 29 inferred relationships involving `Security rules (the reviewers check these)` (e.g. with `._redeploy()` and `tailnet_urls()`) actually correct?**
  _`Security rules (the reviewers check these)` has 29 INFERRED edges - model-reasoned connections that need verification._
- **What connects `probe.sh script`, `fs`, `path` to the rest of the system?**
  _38 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `deploy.py` be split into smaller, more focused modules?**
  _Cohesion score 0.050187265917602995 - nodes in this community are weakly interconnected._
- **Why does `renderTrack()` connect `admin/app.js` to `Security rules (the reviewers check these)`?**
  _High betweenness centrality (0.035) - this node is a cross-community bridge._
- **Should `Handler` be split into smaller, more focused modules?**
  _Cohesion score 0.12380952380952381 - nodes in this community are weakly interconnected._
- **Why does `Handler` connect `Handler` to `os`?**
  _High betweenness centrality (0.032) - this node is a cross-community bridge._