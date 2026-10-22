# Graph Report - mini-deploy  (2026-10-23)

## Corpus Check
- 42 files · ~87,224 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 22 file(s) not represented in the graph (top: .css 11, .service 6, (none) 3)

## Summary
- 779 nodes · 1794 edges · 49 communities (35 shown, 14 thin omitted)
- Extraction: 96% EXTRACTED · 4% INFERRED · 0% AMBIGUOUS · INFERRED: 63 edges (avg confidence: 0.92)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `95086003`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- deploy.py
- admin.py
- build.py
- buildlog.py
- test-webhook.sh
- appenv.py
- re
- ci_forwarder.py
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
- run-caddy.sh
- os
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
- _read_private_json
- README.md
- test-all.sh
- webhook.py
- Usage
- write_pending
- process
- Handler
- test-upload.sh
- Seen
- json
- Server
- main

## God Nodes (most connected - your core abstractions)
1. `test-webhook.sh script` - 31 edges
2. `Handler` - 23 edges
3. `run_job()` - 23 edges
4. `Security rules (the reviewers check these)` - 22 edges
5. `make()` - 20 edges
6. `mini-deploy status log` - 20 edges
7. `db()` - 19 edges
8. `DeployError` - 17 edges
9. `remove_preview()` - 16 edges
10. `load()` - 15 edges

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

## Communities (49 total, 14 thin omitted)

### Community 0 - "deploy.py"
Cohesion: 0.05
Nodes (50): Security rules (the reviewers check these), Stages, mini-deploy status log, main(), collect(), collect_apps(), parse_log(), public_detail() (+42 more)

### Community 1 - "admin.py"
Cohesion: 0.05
Nodes (27): check_password(), _clean(), find_session(), Handler, hash_password(), log_login(), login_wait(), main() (+19 more)

### Community 2 - "build.py"
Cohesion: 0.09
Nodes (16): all_forms(), build_and_deploy(), _build_locked(), BuildError, chown_tree(), client_env(), docker_build(), EnvBuildError (+8 more)

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
Cohesion: 0.14
Nodes (11): connected_apps(), is_test_name(), main(), plan(), css_variables(), export(), main(), resolve() (+3 more)

### Community 7 - "ci_forwarder.py"
Cohesion: 0.15
Nodes (4): BodyError, check_body(), _count(), _no_duplicates()

### Community 8 - "repos.py"
Cohesion: 0.14
Nodes (11): _config(), _full_row(), hook_base(), list_repos(), read_token(), repo_by_hook(), repo_by_name(), repo_for_app() (+3 more)

### Community 9 - "backup.py"
Cohesion: 0.09
Nodes (20): app_lock(), apply(), _apps(), BackupError, _check_app(), check_archive(), env_names(), _filter() (+12 more)

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

### Community 21 - "run-caddy.sh"
Cohesion: 0.20
Nodes (18): busy_phone_ports(), current(), do_reload(), fallback_config(), gateway_ip(), gateway_mac(), lan_bind(), listening_lan() (+10 more)

### Community 22 - "os"
Cohesion: 0.17
Nodes (8): _private(), find_secret(), _walk_strict(), fail(), _check_private(), strip_special_modes(), _private_file(), set_token()

### Community 23 - "mini-deploy: notes for agents"
Cohesion: 0.20
Nodes (9): Code map (graphify), Commands, Environment, Git, Handoff (start of the next session, updated 2026-10-15, end of session), mini-deploy: notes for agents, Owner's decisions (from the Obsidian note), Owner's working style (+1 more)

### Community 24 - "main"
Cohesion: 0.18
Nodes (6): ConfigError, init_env(), main(), QueueFull, read_secret(), read_secret_from_file()

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

### Community 34 - "_read_private_json"
Cohesion: 0.22
Nodes (5): clean_days(), load_limits(), _read_private_json(), usage_today(), usage_warning()

### Community 40 - "webhook.py"
Cohesion: 0.18
Nodes (12): sweep_stale(), check_checkout_size(), check_disk(), git(), GitError, job_token(), read_deployed(), remote_tip() (+4 more)

### Community 41 - "Usage"
Cohesion: 0.12
Nodes (3): seconds_to_midnight(), Server, Usage

### Community 42 - "write_pending"
Cohesion: 0.20
Nodes (3): save_pending(), State, write_pending()

### Community 44 - "process"
Cohesion: 0.20
Nodes (6): db_lookup(), find_repo(), process(), RepoDBError, sweep_hook_dirs(), worker()

### Community 48 - "json"
Cohesion: 0.24
Nodes (5): safe_branch(), load_config(), load_pending(), revive(), make_job()

### Community 50 - "main"
Cohesion: 0.15
Nodes (9): ConfigError, day_key(), load_upstream(), main(), save_upstream(), serve(), valid_limits(), valid_upstream() (+1 more)

## Knowledge Gaps
- **47 isolated node(s):** `probe.sh script`, `fs`, `path`, `srcDir`, `outDir` (+42 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 295 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **14 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Security rules (the reviewers check these)` connect `deploy.py` to `admin.py`, `build.py`, `repos.py`, `backup.py`, `webhook.py`, `admin/app.js`, `upload.py`, `json`, `os`, `mini-deploy: notes for agents`?**
  _High betweenness centrality (0.085) - this node is a cross-community bridge._
- **What connects `probe.sh script`, `fs`, `path` to the rest of the system?**
  _47 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `deploy.py` be split into smaller, more focused modules?**
  _Cohesion score 0.05343320848938826 - nodes in this community are weakly interconnected._
- **Why does `renderTrack()` connect `admin/app.js` to `deploy.py`?**
  _High betweenness centrality (0.034) - this node is a cross-community bridge._
- **Should `admin.py` be split into smaller, more focused modules?**
  _Cohesion score 0.053998632946001365 - nodes in this community are weakly interconnected._
- **Should `build.py` be split into smaller, more focused modules?**
  _Cohesion score 0.09411764705882353 - nodes in this community are weakly interconnected._
- **Should `buildlog.py` be split into smaller, more focused modules?**
  _Cohesion score 0.10037878787878787 - nodes in this community are weakly interconnected._