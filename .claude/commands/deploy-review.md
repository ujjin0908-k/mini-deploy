---
description: Parallel review of mini-deploy changes - security + deploy safety
argument-hint: "[optional: files or area to focus on]"
---

Review the current mini-deploy changes with two reviewers **in parallel**, then merge their findings.

1. **Work out what changed.** Use `git diff` if git works here; otherwise use this session's edits. If neither shows anything, ask me. Extra focus: $ARGUMENTS
2. **Launch both agents in ONE message**, giving each the changed files with short context:
   - `security-reviewer`
   - `deploy-safety-reviewer`
3. **Merge** into one table sorted HIGH → LOW, duplicates combined:
   `| Level | Where | Problem | Fix |`
   Then add one "learn" line: the most important idea behind the top finding, in plain words.
4. **Don't fix anything yet.** List the fixes and wait for "go".
