# Graph Report - mini-deploy  (2026-10-15)

## Corpus Check
- 37 files · ~70,177 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 20 file(s) not represented in the graph (top: .css 11, .service 5, (none) 3)

## Summary
- 656 nodes · 1486 edges · 47 communities (34 shown, 13 thin omitted)
- Extraction: 97% EXTRACTED · 3% INFERRED · 0% AMBIGUOUS · INFERRED: 47 edges (avg confidence: 0.91)
- Token cost: 0 input · 0 output

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
- webhook.py
- Jobs
- json
- test-build.sh
- admin/app.js
- safe_branch
- test-sites.sh
- admin.py
- package.json
- test-deploy.sh
- build.js
- Server
- run-caddy.sh
- main
- write_pending
- dashboard.py
- test-admin.sh
- The demo site, explained
- logs/app.js
- test-ci.sh
- probe.sh
- run-webhook.sh
- sync-theme.sh
- The landing page, explained
- Running commands in WSL
- mini-deploy: notes for agents
- README.md
- db
- Handler
- os
- Handler
- find_repo
- Server
- process
- test-upload.sh

## God Nodes (most connected - your core abstractions)
1. `test-webhook.sh script` - 31 edges
2. `Handler` - 23 edges
3. `run_job()` - 23 edges
4. `db()` - 19 edges
5. `DeployError` - 17 edges
6. `remove_preview()` - 16 edges
7. `run-caddy.sh script` - 15 edges
8. `main()` - 15 edges
9. `Security rules (the reviewers check these)` - 15 edges
10. `load()` - 14 edges

## Surprising Connections (you probably didn't know these)
- `Environment` --references--> `git()`  [INFERRED]
  CLAUDE.md → scripts/webhook.py
- `Security rules (the reviewers check these)` --references--> `tailnet_urls()`  [INFERRED]
  CLAUDE.md → scripts/admin.py
- `Status` --references--> `find_secret()`  [INFERRED]
  CLAUDE.md → scripts/build.py
- `Security rules (the reviewers check these)` --references--> `EnvBuildError`  [INFERRED]
  CLAUDE.md → scripts/build.py
- `Handoff (start of the next session, updated 2026-10-15)` --references--> `write_index()`  [INFERRED]
  CLAUDE.md → scripts/buildlog.py

## Import Cycles
- None detected.

## Communities (47 total, 13 thin omitted)

### Community 0 - "deploy.py"
Cohesion: 0.06
Nodes (48): Security rules (the reviewers check these), Stages, Status, main(), collect(), collect_apps(), public_detail(), app_paths() (+40 more)

### Community 1 - "Handler"
Cohesion: 0.14
Nodes (3): find_session(), Handler, login_wait()

### Community 2 - "build.py"
Cohesion: 0.07
Nodes (20): all_forms(), build_and_deploy(), _build_locked(), BuildError, chown_tree(), client_env(), docker_build(), EnvBuildError (+12 more)

### Community 3 - "buildlog.py"
Cohesion: 0.14
Nodes (12): _save(), _key(), _locked(), logs_of(), _new_id(), prune(), read_header(), remove_app() (+4 more)

### Community 4 - "test-webhook.sh"
Cohesion: 0.11
Nodes (36): bad(), body(), bpush(), break_build(), check_code(), code_of(), commit_page(), expect() (+28 more)

### Community 5 - "appenv.py"
Cohesion: 0.17
Nodes (14): check_key(), _check_private(), check_root(), check_value(), env_file(), EnvError, file_for_build(), for_build() (+6 more)

### Community 6 - "re"
Cohesion: 0.18
Nodes (8): _clean(), css_variables(), export(), main(), resolve(), standalone(), svg_rules(), xml_safe()

### Community 7 - "upload.py"
Cohesion: 0.17
Nodes (10): _check_kind(), _check_toc(), _make_dirs(), _parts(), _plan(), _shown(), _site_root(), unpack() (+2 more)

### Community 8 - "repos.py"
Cohesion: 0.14
Nodes (11): upload_problem(), _check(), _config(), _full_row(), hook_base(), list_repos(), repo_by_hook(), repo_by_name() (+3 more)

### Community 9 - "webhook.py"
Cohesion: 0.18
Nodes (12): sweep_stale(), check_checkout_size(), check_disk(), git(), GitError, job_token(), read_deployed(), remote_tip() (+4 more)

### Community 11 - "json"
Cohesion: 0.21
Nodes (7): _check_private(), ConfigError, load_upstream(), main(), save_upstream(), serve(), valid_upstream()

### Community 12 - "test-build.sh"
Cohesion: 0.35
Nodes (10): bad(), expect_error(), get(), link_of(), make_repo(), MINI_DEPLOY_APP_ENV, MINI_DEPLOY_TESTING, newest() (+2 more)

### Community 13 - "admin/app.js"
Cohesion: 0.25
Nodes (20): act(), api(), appCard(), clearSecret(), copyButton(), disconnectRepo(), el(), gitAction() (+12 more)

### Community 14 - "safe_branch"
Cohesion: 0.33
Nodes (4): safe_branch(), load_pending(), revive(), make_job()

### Community 15 - "test-sites.sh"
Cohesion: 0.31
Nodes (8): at_home(), bad(), get(), lcode(), listed(), ok(), test-sites.sh script, tget()

### Community 16 - "admin.py"
Cohesion: 0.15
Nodes (10): check_password(), hash_password(), log_login(), new_session(), _now_iso(), phone_base(), _sha(), state() (+2 more)

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

### Community 22 - "main"
Cohesion: 0.19
Nodes (6): ConfigError, init_env(), load_config(), main(), read_secret(), read_secret_from_file()

### Community 23 - "write_pending"
Cohesion: 0.22
Nodes (3): save_pending(), State, write_pending()

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

### Community 34 - "mini-deploy: notes for agents"
Cohesion: 0.17
Nodes (9): Code map (graphify), Commands, Environment, Git, Handoff (start of the next session, updated 2026-10-15), mini-deploy: notes for agents, Owner's decisions (from the Obsidian note), Owner's working style (+1 more)

### Community 39 - "db"
Cohesion: 0.23
Nodes (9): main(), serve(), set_password(), audit(), db(), _now_iso(), _private(), connect() (+1 more)

### Community 41 - "os"
Cohesion: 0.32
Nodes (4): _private_file(), read_token(), set_token(), token_status()

### Community 43 - "find_repo"
Cohesion: 0.29
Nodes (4): db_lookup(), find_repo(), QueueFull, RepoDBError

### Community 45 - "process"
Cohesion: 0.40
Nodes (3): process(), sweep_hook_dirs(), worker()

## Knowledge Gaps
- **44 isolated node(s):** `probe.sh script`, `fs`, `path`, `srcDir`, `outDir` (+39 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 244 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **13 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Handler` connect `Handler` to `admin.py`, `re`?**
  _High betweenness centrality (0.033) - this node is a cross-community bridge._
- **What connects `probe.sh script`, `fs`, `path` to the rest of the system?**
  _44 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `deploy.py` be split into smaller, more focused modules?**
  _Cohesion score 0.05789009697325889 - nodes in this community are weakly interconnected._
- **Why does `Jobs` connect `Jobs` to `webhook.py`?**
  _High betweenness centrality (0.023) - this node is a cross-community bridge._
- **Should `Handler` be split into smaller, more focused modules?**
  _Cohesion score 0.13709677419354838 - nodes in this community are weakly interconnected._
- **Why does `db()` connect `db` to `Handler`, `buildlog.py`, `repos.py`, `os`, `admin.py`?**
  _High betweenness centrality (0.018) - this node is a cross-community bridge._
- **Should `build.py` be split into smaller, more focused modules?**
  _Cohesion score 0.0666049953746531 - nodes in this community are weakly interconnected._