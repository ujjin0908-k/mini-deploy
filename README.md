# mini-deploy
fun little deployment project hhe

A tiny self-hosted deploy platform, built step by step to learn how deploys work.

`git push` → GitHub webhook → verify + clone → Docker build → new release folder → `current` link flips → Caddy serves it.

Runs inside WSL2 (Ubuntu). See `CLAUDE.md` for the stage plan.
