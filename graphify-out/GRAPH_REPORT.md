# Graph Report - mini-deploy  (2026-10-13)

## Corpus Check
- 37 files · ~63,687 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 23 file(s) not represented in the graph (top: .css 14, .service 5, (none) 3)

## Summary
- 634 nodes · 1427 edges · 39 communities (28 shown, 11 thin omitted)
- Extraction: 97% EXTRACTED · 3% INFERRED · 0% AMBIGUOUS · INFERRED: 41 edges (avg confidence: 0.91)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- deploy.py
- os
- build.py
- buildlog.py
- test-webhook.sh
- appenv.py
- re
- safe_branch
- mini-deploy: notes for agents
- webhook.py
- Jobs
- Handler
- test-build.sh
- admin/app.js
- dashboard/app.js
- test-sites.sh
- read_secret
- package.json
- test-deploy.sh
- build.js
- Server
- run-caddy.sh
- The dashboard, explained
- main
- Server
- test-admin.sh
- The demo site, explained
- logs/app.js
- test-ci.sh
- probe.sh
- run-webhook.sh
- sync-theme.sh
- The landing page, explained
- Running commands in WSL
- log_event
- README.md

## God Nodes (most connected - your core abstractions)
1. `test-webhook.sh script` - 31 edges
2. `run_job()` - 23 edges
3. `Handler` - 18 edges
4. `db()` - 17 edges
5. `DeployError` - 17 edges
6. `remove_preview()` - 16 edges
7. `refresh()` - 15 edges
8. `_deploy_locked()` - 15 edges
9. `main()` - 15 edges
10. `main()` - 15 edges

## Surprising Connections (you probably didn't know these)
- `Environment` --references--> `git()`  [INFERRED]
  CLAUDE.md → scripts/webhook.py
- `Status` --references--> `find_secret()`  [INFERRED]
  CLAUDE.md → scripts/build.py
- `Security rules (the reviewers check these)` --references--> `EnvBuildError`  [INFERRED]
  CLAUDE.md → scripts/build.py
- `Handoff (start of the next session, written 2026-10-13)` --references--> `write_index()`  [INFERRED]
  CLAUDE.md → scripts/buildlog.py
- `Status` --references--> `public_detail()`  [INFERRED]
  CLAUDE.md → scripts/dashboard.py

## Import Cycles
- None detected.

## Communities (39 total, 11 thin omitted)

### Community 0 - "deploy.py"
Cohesion: 0.06
Nodes (43): Stages, Status, app_paths(), _check_expected(), check_preview(), check_tree(), cleanup_stale(), clear_hold() (+35 more)

### Community 1 - "os"
Cohesion: 0.05
Nodes (36): check_password(), _clean(), find_session(), Handler, hash_password(), log_login(), login_wait(), main() (+28 more)

### Community 2 - "build.py"
Cohesion: 0.08
Nodes (20): all_forms(), build_and_deploy(), _build_locked(), BuildError, chown_tree(), client_env(), docker_build(), EnvBuildError (+12 more)

### Community 3 - "buildlog.py"
Cohesion: 0.06
Nodes (27): Handoff (start of the next session, written 2026-10-13), Capture, clean(), _key(), _locked(), logs_of(), _new_id(), prune() (+19 more)

### Community 4 - "test-webhook.sh"
Cohesion: 0.10
Nodes (37): bad(), body(), bpush(), break_build(), check_code(), code_of(), commit_page(), expect() (+29 more)

### Community 5 - "appenv.py"
Cohesion: 0.17
Nodes (15): check_key(), _check_private(), check_root(), check_value(), env_file(), EnvError, file_for_build(), for_build() (+7 more)

### Community 6 - "re"
Cohesion: 0.08
Nodes (15): _check_private(), ConfigError, Handler, load_upstream(), main(), save_upstream(), serve(), valid_upstream() (+7 more)

### Community 7 - "safe_branch"
Cohesion: 0.22
Nodes (5): safe_branch(), find_repo(), load_config(), revive(), make_job()

### Community 8 - "mini-deploy: notes for agents"
Cohesion: 0.25
Nodes (7): Code map (graphify), Commands, Environment, Git, mini-deploy: notes for agents, Owner's decisions (from the Obsidian note), Owner's working style

### Community 9 - "webhook.py"
Cohesion: 0.21
Nodes (12): Security rules (the reviewers check these), check_checkout_size(), check_disk(), git(), GitError, job_token(), read_deployed(), remote_tip() (+4 more)

### Community 12 - "test-build.sh"
Cohesion: 0.30
Nodes (11): bad(), expect_error(), get(), link_of(), make_repo(), MINI_DEPLOY_APP_ENV, MINI_DEPLOY_NO_DASHBOARD, MINI_DEPLOY_TESTING (+3 more)

### Community 13 - "admin/app.js"
Cohesion: 0.32
Nodes (16): act(), api(), appCard(), copyButton(), disconnectRepo(), el(), gitAction(), load() (+8 more)

### Community 14 - "dashboard/app.js"
Cohesion: 0.38
Nodes (11): appCard(), command(), copyText(), fallback(), manual(), say(), el(), load() (+3 more)

### Community 15 - "test-sites.sh"
Cohesion: 0.31
Nodes (8): at_home(), bad(), get(), jq_py(), lcode(), live_json(), ok(), test-sites.sh script

### Community 16 - "read_secret"
Cohesion: 0.20
Nodes (6): ConfigError, db_lookup(), QueueFull, read_secret(), read_secret_from_file(), RepoDBError

### Community 17 - "package.json"
Cohesion: 0.22
Nodes (8): description, engines, node, name, private, scripts, build, version

### Community 18 - "test-deploy.sh"
Cohesion: 0.44
Nodes (8): bad(), expect_error(), host_get(), link_of(), live_id(), MINI_DEPLOY_NO_DASHBOARD, ok(), test-deploy.sh script

### Community 19 - "build.js"
Cohesion: 0.25
Nodes (5): fs, outDir, path, srcDir, WEB_FILES

### Community 21 - "run-caddy.sh"
Cohesion: 0.54
Nodes (7): do_reload(), gateway_ip(), gateway_mac(), lan_bind(), listening_lan(), saved(), run-caddy.sh script

### Community 22 - "The dashboard, explained"
Cohesion: 0.25
Nodes (7): A bug worth knowing, Files, The dashboard, explained, The six parts of the page, Try it, What it is, Why it is safe

### Community 23 - "main"
Cohesion: 0.18
Nodes (5): load_pending(), main(), save_pending(), State, write_pending()

### Community 25 - "test-admin.sh"
Cohesion: 0.47
Nodes (4): bad(), MINI_DEPLOY_NO_DASHBOARD, ok(), test-admin.sh script

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

### Community 34 - "log_event"
Cohesion: 0.33
Nodes (4): log_event(), process(), sweep_hook_dirs(), worker()

## Knowledge Gaps
- **53 isolated node(s):** `probe.sh script`, `fs`, `path`, `srcDir`, `outDir` (+48 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 239 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **11 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Jobs` connect `Jobs` to `webhook.py`?**
  _High betweenness centrality (0.024) - this node is a cross-community bridge._
- **What connects `probe.sh script`, `fs`, `path` to the rest of the system?**
  _53 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `deploy.py` be split into smaller, more focused modules?**
  _Cohesion score 0.06018018018018018 - nodes in this community are weakly interconnected._
- **Why does `Server` connect `Server` to `os`?**
  _High betweenness centrality (0.015) - this node is a cross-community bridge._
- **Should `os` be split into smaller, more focused modules?**
  _Cohesion score 0.05266106442577031 - nodes in this community are weakly interconnected._
- **Should `build.py` be split into smaller, more focused modules?**
  _Cohesion score 0.07678075855689177 - nodes in this community are weakly interconnected._
- **Should `buildlog.py` be split into smaller, more focused modules?**
  _Cohesion score 0.06110102843315184 - nodes in this community are weakly interconnected._