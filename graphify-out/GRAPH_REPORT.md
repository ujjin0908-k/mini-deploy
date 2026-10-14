# Graph Report - mini-deploy  (2026-10-15)

## Corpus Check
- 39 files · ~71,321 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 23 file(s) not represented in the graph (top: .css 14, .service 5, (none) 3)

## Summary
- 680 nodes · 1537 edges · 47 communities (32 shown, 15 thin omitted)
- Extraction: 97% EXTRACTED · 3% INFERRED · 0% AMBIGUOUS · INFERRED: 49 edges (avg confidence: 0.91)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- deploy.py
- Handler
- build.py
- buildlog.py
- test-webhook.sh
- os
- re
- upload.py
- mini-deploy: notes for agents
- webhook.py
- Jobs
- Handler
- test-build.sh
- admin/app.js
- dashboard/app.js
- test-sites.sh
- main
- package.json
- test-deploy.sh
- build.js
- Server
- run-caddy.sh
- The dashboard, explained
- write_pending
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
- process
- README.md
- repos.py
- admin.py
- db
- Handler
- Seen
- audit
- _clean
- test-upload.sh

## God Nodes (most connected - your core abstractions)
1. `test-webhook.sh script` - 31 edges
2. `Handler` - 23 edges
3. `run_job()` - 23 edges
4. `db()` - 19 edges
5. `DeployError` - 17 edges
6. `remove_preview()` - 16 edges
7. `refresh()` - 15 edges
8. `_deploy_locked()` - 15 edges
9. `main()` - 15 edges
10. `load()` - 14 edges

## Surprising Connections (you probably didn't know these)
- `Environment` --references--> `git()`  [INFERRED]
  CLAUDE.md → scripts/webhook.py
- `Status` --references--> `find_secret()`  [INFERRED]
  CLAUDE.md → scripts/build.py
- `Security rules (the reviewers check these)` --references--> `EnvBuildError`  [INFERRED]
  CLAUDE.md → scripts/build.py
- `Handoff (start of the next session, updated 2026-10-15)` --references--> `write_index()`  [INFERRED]
  CLAUDE.md → scripts/buildlog.py
- `Status` --references--> `public_detail()`  [INFERRED]
  CLAUDE.md → scripts/dashboard.py

## Import Cycles
- None detected.

## Communities (47 total, 15 thin omitted)

### Community 0 - "deploy.py"
Cohesion: 0.05
Nodes (52): Security rules (the reviewers check these), Stages, Status, main(), app_paths(), _check_expected(), check_preview(), check_tree() (+44 more)

### Community 2 - "build.py"
Cohesion: 0.08
Nodes (19): all_forms(), build_and_deploy(), _build_locked(), BuildError, chown_tree(), client_env(), docker_build(), EnvBuildError (+11 more)

### Community 3 - "buildlog.py"
Cohesion: 0.06
Nodes (27): Handoff (start of the next session, updated 2026-10-15), Capture, clean(), _key(), _locked(), logs_of(), _new_id(), prune() (+19 more)

### Community 4 - "test-webhook.sh"
Cohesion: 0.10
Nodes (37): bad(), body(), bpush(), break_build(), check_code(), code_of(), commit_page(), expect() (+29 more)

### Community 5 - "os"
Cohesion: 0.09
Nodes (25): check_key(), _check_private(), check_root(), check_value(), env_file(), EnvError, file_for_build(), for_build() (+17 more)

### Community 6 - "re"
Cohesion: 0.23
Nodes (7): css_variables(), export(), main(), resolve(), standalone(), svg_rules(), xml_safe()

### Community 7 - "upload.py"
Cohesion: 0.17
Nodes (10): _check_kind(), _check_toc(), _make_dirs(), _parts(), _plan(), _shown(), _site_root(), unpack() (+2 more)

### Community 8 - "mini-deploy: notes for agents"
Cohesion: 0.25
Nodes (7): Code map (graphify), Commands, Environment, Git, mini-deploy: notes for agents, Owner's decisions (from the Obsidian note), Owner's working style

### Community 9 - "webhook.py"
Cohesion: 0.22
Nodes (11): check_checkout_size(), check_disk(), git(), GitError, job_token(), read_deployed(), remote_tip(), run_job() (+3 more)

### Community 11 - "Handler"
Cohesion: 0.15
Nodes (6): db_lookup(), find_repo(), Handler, QueueFull, RepoDBError, verify_signature()

### Community 12 - "test-build.sh"
Cohesion: 0.30
Nodes (11): bad(), expect_error(), get(), link_of(), make_repo(), MINI_DEPLOY_APP_ENV, MINI_DEPLOY_NO_DASHBOARD, MINI_DEPLOY_TESTING (+3 more)

### Community 13 - "admin/app.js"
Cohesion: 0.25
Nodes (20): act(), api(), appCard(), clearSecret(), copyButton(), disconnectRepo(), el(), gitAction() (+12 more)

### Community 14 - "dashboard/app.js"
Cohesion: 0.38
Nodes (11): appCard(), command(), copyText(), fallback(), manual(), say(), el(), load() (+3 more)

### Community 15 - "test-sites.sh"
Cohesion: 0.31
Nodes (8): at_home(), bad(), get(), jq_py(), lcode(), live_json(), ok(), test-sites.sh script

### Community 16 - "main"
Cohesion: 0.21
Nodes (6): ConfigError, init_env(), load_config(), main(), read_secret(), read_secret_from_file()

### Community 17 - "package.json"
Cohesion: 0.22
Nodes (8): description, engines, node, name, private, scripts, build, version

### Community 18 - "test-deploy.sh"
Cohesion: 0.44
Nodes (8): bad(), expect_error(), host_get(), link_of(), live_id(), MINI_DEPLOY_NO_DASHBOARD, ok(), test-deploy.sh script

### Community 19 - "build.js"
Cohesion: 0.25
Nodes (5): fs, outDir, path, srcDir, WEB_FILES

### Community 20 - "Server"
Cohesion: 0.25
Nodes (3): Server, cut(), extend()

### Community 21 - "run-caddy.sh"
Cohesion: 0.54
Nodes (7): do_reload(), gateway_ip(), gateway_mac(), lan_bind(), listening_lan(), saved(), run-caddy.sh script

### Community 22 - "The dashboard, explained"
Cohesion: 0.25
Nodes (7): A bug worth knowing, Files, The dashboard, explained, The six parts of the page, Try it, What it is, Why it is safe

### Community 23 - "write_pending"
Cohesion: 0.20
Nodes (3): save_pending(), State, write_pending()

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

### Community 34 - "process"
Cohesion: 0.40
Nodes (3): process(), sweep_hook_dirs(), worker()

### Community 39 - "repos.py"
Cohesion: 0.13
Nodes (12): state(), upload_problem(), _config(), _full_row(), hook_base(), list_repos(), repo_by_hook(), repo_by_name() (+4 more)

### Community 40 - "admin.py"
Cohesion: 0.16
Nodes (11): check_password(), hash_password(), log_login(), login_wait(), main(), new_session(), _now_iso(), phone_base() (+3 more)

### Community 44 - "audit"
Cohesion: 0.40
Nodes (5): audit(), _now_iso(), connect(), disconnect(), rotate()

## Knowledge Gaps
- **55 isolated node(s):** `probe.sh script`, `fs`, `path`, `srcDir`, `outDir` (+50 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 257 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **15 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Handler` connect `Handler` to `admin.py`, `_clean`?**
  _High betweenness centrality (0.032) - this node is a cross-community bridge._
- **What connects `probe.sh script`, `fs`, `path` to the rest of the system?**
  _55 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `deploy.py` be split into smaller, more focused modules?**
  _Cohesion score 0.05128205128205128 - nodes in this community are weakly interconnected._
- **Why does `Jobs` connect `Jobs` to `webhook.py`, `write_pending`?**
  _High betweenness centrality (0.022) - this node is a cross-community bridge._
- **Should `build.py` be split into smaller, more focused modules?**
  _Cohesion score 0.07610993657505286 - nodes in this community are weakly interconnected._
- **Why does `db()` connect `db` to `admin.py`, `Handler`, `os`, `repos.py`?**
  _High betweenness centrality (0.017) - this node is a cross-community bridge._
- **Should `buildlog.py` be split into smaller, more focused modules?**
  _Cohesion score 0.06312098188194039 - nodes in this community are weakly interconnected._