---
name: research-kernel
description: Research a Linux kernel topic and save a structured note to the vault
---

Research the following Linux kernel topic and save a note to the vault in this repo: **$ARGUMENTS**

If `$ARGUMENTS` contains `--refresh`, strip that flag from the topic name and treat this as a **full refresh**: delete the existing note (if any) and write a completely new one from scratch rather than appending.

## Step 1 — Classify the topic

Determine which category fits:
- **concept** — a core kernel mechanism (e.g. "CFS scheduler", "page fault handling", "RCU locking")
- **subsystem** — a kernel subsystem (e.g. "subsystem: netfilter", "subsystem: btrfs")
- **patch** — a specific LKML patch or thread (e.g. "patch: <message-id>")
- **person** — a kernel contributor (e.g. "person: Greg Kroah-Hartman")

## Step 2 — Research from all available sources

Use all four sources. Gather as much detail as possible before writing.

**kernel-internals.org** (use WebFetch — check first):
- Try `https://kernel-internals.org/<subsystem>/` and `https://kernel-internals.org/<subsystem>/<topic>/`
- Use `https://kernel-internals.org/site-index/` to discover available articles if unsure of the URL
- Focus on extracting *why* decisions were made, what problems the design solves, and what tradeoffs were accepted

**kernel.org docs** (use WebFetch):
- Fetch relevant pages from https://www.kernel.org/doc/html/latest/
- Extract conceptual explanations and design rationale, not just API references

**Web** (use WebSearch):
- Search `site:lwn.net <topic>` for LWN articles
- Search for conference talks, blog posts, academic papers
- Prioritize: LWN > kernelnewbies.org > blogs by known contributors

**LKML** (use lkml_search_patches and lkml_get_thread tools — check last):
- Search for the topic and related keywords
- Fetch full threads for the most relevant 2–3 results
- Extract: what *problem* was being solved, what the tradeoff debate was, how thinking evolved

## Step 3 — Write the note

Use the matching template from `vault/_templates/`. Fill every section — do not leave template placeholders.

**Writing style: blended per-component**
The reader wants to fully understand one thing before moving to the next. Do not sweep across all components conceptually and then sweep again technically — instead, for each component, blend purpose, mechanism, and technical detail together in one place.

**For subsystem notes — each Core Component subsection should contain:**
- *Purpose*: one or two sentences on why this component exists
- *How it works*: a narrative that introduces structs and functions at the moment they become relevant to the story, not in a separate list; explain the fast path, slow path, and any important edge cases
- *Key struct*: the primary data structure with its most important fields annotated
- *Key functions*: the entry points a reader would trace first
- *Config & flags*: Kconfig symbols, sysctl knobs, or flag sets that change this component's behaviour

**For concept notes — the How It Works section should be a single flowing narrative that:**
- Starts with the trigger or entry point
- Introduces each struct and function at the moment it appears in the story
- Explains the *why* at each decision point, not just the *what*
- Covers fast path, slow path, and failure path in sequence
- Leaves Key Data Structures and Key Functions sections as a quick-reference complement, not the primary explanation

**Across both note types:**
- Interactions, Design Decisions, Evolution, and Further Reading remain as top-level sections after all components are covered — these are cross-cutting and belong at the end

Fill in the frontmatter completely:
- `tags`: 3–6 relevant lowercase tags
- `subsystem`: primary kernel subsystem(s)
- `kernel_version`: earliest version where this applies (if determinable)
- `sources`: list all URLs fetched

## Step 4 — Save the note

Determine the file path:
- concept → `vault/concepts/<kebab-case-title>.md`
- subsystem → `vault/subsystems/<name>.md`
- patch → `vault/patches/<slug-from-message-id>.md`
- person → `vault/people/<firstname-lastname>.md`

Write the file:
- **Default**: if a note already exists, append new findings and update the `researched` date
- **`--refresh` mode**: overwrite the file completely with a fresh note from scratch

## Step 5 — Research core components as individual concept notes (subsystem only)

This step applies **only when the topic is a subsystem**.

After writing the subsystem note, extract the list of core components identified in the **Core Components** section. For each component:

1. **Check if a concept note already exists** at `vault/concepts/<kebab-case-component-name>.md`
   - If it exists and this is not a `--refresh` run, skip it (do not overwrite existing research)
   - If it does not exist, research and write it

2. **Research the component** using the same four sources (Steps 2–4), but scoped to that specific component as a concept. Use the `concept.md` template.

3. **Save** to `vault/concepts/<kebab-case-component-name>.md`

4. After all components are done, do a **single combined commit**:

```bash
git -C "C:/Users/krush/source/repos/Linux Research Topics" add vault/
git -C "C:/Users/krush/source/repos/Linux Research Topics" commit -m "research: $ARGUMENTS — subsystem note + N concept notes"
git -C "C:/Users/krush/source/repos/Linux Research Topics" push origin master
```

**Pacing**: research each component sequentially (not all at once) so each note gets full source coverage. Announce each component before starting it so the user can see progress.

**Scope judgement**: if a component is extremely narrow (e.g. a single sysctl, a trivial wrapper), fold it into the subsystem note rather than creating a shallow standalone note. Aim for concept notes that would stand alone as useful references.

## Step 6 — Resolve all [[wiki links]]

After all notes have been written, scan every note created in this session for `[[wiki link]]` patterns.

For each unique link found:
1. Derive the expected vault path — `vault/concepts/<kebab-case-name>.md` for concepts, `vault/subsystems/<name>.md` for subsystems
2. Check whether that file exists on disk
3. If it **does not exist**, add it to `queue.md` as a new `- [ ]` entry (append under `## Queue`, do not duplicate entries already in the queue)

This ensures no `[[link]]` is ever left as a permanently empty page — every referenced topic will eventually be researched.

**Do not** add to the queue:
- Links that already have a file on disk
- Links already present in `queue.md` (pending, in-progress, or complete)
- Trivial one-off references that are clearly just inline mentions (e.g. a kernel version number or a syscall name used in passing)

---

## Step 7 — Commit and push

```bash
git -C "C:/Users/krush/source/repos/Linux Research Topics" add vault/ queue.md
git -C "C:/Users/krush/source/repos/Linux Research Topics" commit -m "research: $ARGUMENTS"
git -C "C:/Users/krush/source/repos/Linux Research Topics" push origin master
```

If the repo has no remote yet, skip the push and inform the user.

After saving, confirm:
- The note(s) saved and their paths
- How many concept notes were written and which were skipped (already existed)
- How many unresolved `[[links]]` were added to the queue
- Key sources used
