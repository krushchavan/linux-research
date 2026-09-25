# Linux Kernel Research — Claude Code Context

This repo is a self-growing Linux kernel knowledge base. The Claude Code desktop agent acts as the research engine.

## What This Repo Is

- **`vault/`** — Obsidian-compatible Markdown notes, organized by category
- **`vault/concepts/`** — Core kernel mechanisms (scheduling, memory, locking, etc.)
- **`vault/subsystems/`** — Per-subsystem deep dives
- **`vault/patches/`** — Analyses of notable LKML patches and threads
- **`vault/people/`** — Key contributors and their areas of focus
- **`vault/_templates/`** — Note templates; use these when creating new notes
- **`vault/explained/`** — Plain-language companions of the technical notes (step-by-step, concept-first, few code identifiers). Mirrors `concepts/` and `subsystems/`; files are named `<name>-explained.md`. Each original links to its companion (`explained:` frontmatter + banner) and each companion links back (`original:`).

## Plain-Language Companions

Use the `/explain-kernel` skill to convert notes (default batch of 4, resumable):

```
/explain-kernel            # next 4 notes from explain-queue.md
/explain-kernel 10         # next 10
/explain-kernel vault/concepts/mm/folio.md   # one specific note
```

Progress is tracked in `explain-queue.md` (`[ ]` / `[>]` / `[x]`, same conventions as `queue.md`). A scheduled task (`kernel-explain-queue`) runs a batch hourly. `scripts/crossref-explained.sh` adds the cross-links. New research notes are picked up automatically by the skill's sync step.

## How to Research a Topic

Use the `/research-kernel` skill from Claude Code:

```
/research-kernel CFS scheduler
/research-kernel io_uring internals
/research-kernel subsystem: netfilter
/research-kernel patch: <lkml-message-id>
/research-kernel person: Greg Kroah-Hartman
```

The skill will:
1. Determine the appropriate category (concept / subsystem / patch / person)
2. Search LKML via lore.kernel.org for relevant patches and discussions
3. Fetch relevant kernel.org documentation
4. Search the web for LWN articles, blogs, and papers
5. Synthesize a structured Markdown note using the matching template
6. Save it to the correct `vault/<category>/` folder
7. Commit and push the note to git

## Research Sources (in order of priority)

1. **kernel-internals.org** — design rationale and internals at https://kernel-internals.org/
2. **kernel.org** — official docs at https://www.kernel.org/doc/html/latest/
3. **LWN.net** — web search for `site:lwn.net <topic>`
4. **General web** — blogs, papers, conference talks
5. **LKML** — `lkml_search_patches`, `lkml_get_thread` tools (last resort)

## Note Naming Convention

- Concepts: `vault/concepts/<kebab-case-title>.md`
- Subsystems: `vault/subsystems/<subsystem-name>.md`
- Patches: `vault/patches/<lkml-message-id-slug>.md`
- People: `vault/people/<firstname-lastname>.md`

## Git Workflow

After saving a note, commit and push:

```bash
git add vault/
git commit -m "research: <topic>"
git push origin master
```

This keeps the vault in sync with GitHub so it's accessible from any machine.

## Opening in Obsidian

Open Obsidian → "Open folder as vault" → select the `vault/` directory in this repo.
Recommended plugins: Dataview, Templater, Graph Analysis.
