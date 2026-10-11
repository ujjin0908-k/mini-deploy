---
description: Run one mini-deploy stage - explain, build, owner tests, log to Obsidian
argument-hint: "<stage number 0-6>"
---

Run **stage $ARGUMENTS** of mini-deploy (see the Stages table in CLAUDE.md). Mode: **teach + build**.

1. **Where are we.** Read the Status section in CLAUDE.md and the Log in `Obsidian/Projects/Mini Deploy/Mini Deploy.md`. If an earlier stage isn't done, say so and ask whether to continue anyway.
2. **Read the owner's study note** for this stage (the "Read first" column in CLAUDE.md, in `Obsidian/Projects/Mini Deploy/Notes/`). Then **explain** the stage's main idea in 3-5 plain sentences, in the same words the note uses, with one small diagram if it helps. Don't edit the study notes.
3. **Plan.** List the files you'll create or change, any installs needed (name + why + size), and the "done when" test. **Stop and wait for "go".**
4. **Build** after go. Small steps. Use the `wsl-run` skill for every command. Put short "why" comments in the code.
5. **Owner tests.** Give the exact test command(s) for the owner to run, and what they should see. You may run them too to confirm.
6. **Check yourself.** If the stage touched the deploy script, the webhook or anything that takes outside input, suggest `/deploy-review`.
7. **Log.** Update the CLAUDE.md Status line. In `Obsidian/Projects/Mini Deploy/Mini Deploy.md` (append and update only): tick the stage under Tasks, add a `## Log` line, and add any new open questions. Give 2-3 "what you learned" bullets in chat.

Never open anything to the public internet, and never install without a yes.
