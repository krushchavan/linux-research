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
- This site explains *why* design decisions were made — extract that reasoning, not just mechanics

**kernel.org docs** (use WebFetch):
- Fetch relevant pages from https://www.kernel.org/doc/html/latest/
- For subsystems, check the subsystem-specific doc directory

**Web** (use WebSearch):
- Search `site:lwn.net <topic>` for LWN articles
- Search for conference talks, blog posts, academic papers
- Prioritize: LWN > kernelnewbies.org > blogs by known contributors

**LKML** (use lkml_search_patches and lkml_get_thread tools — check last):
- Search for the topic and related keywords
- Fetch full threads for the most relevant 2–3 results
- Extract: what problem was solved, how, who reviewed it, what changed

## Step 3 — Write the note

Use the matching template from `vault/_templates/`. Fill every section — do not leave template placeholders. Write clearly for someone learning the kernel.

Guidelines:
- **Summary**: 2–3 sentences, plain English, no jargon assumed
- **How It Works**: explain the mechanism step by step
- **Key Data Structures**: list with one-line descriptions, link to source file if known (e.g. `include/linux/sched.h`)
- **Key Functions**: entry points with brief descriptions
- **Interactions**: how this connects to other subsystems
- **Notable Patches**: 2–5 significant changes, with LKML message IDs where available
- **Further Reading**: ranked list of sources used
- **LKML Threads**: message IDs and subjects of threads fetched

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

## Step 5 — Commit and push

```bash
git -C "C:/Users/krush/source/repos/Linux Research Topics" add vault/
git -C "C:/Users/krush/source/repos/Linux Research Topics" commit -m "research: $ARGUMENTS"
git -C "C:/Users/krush/source/repos/Linux Research Topics" push origin master
```

If the repo has no remote yet, skip the push and inform the user.

After saving, confirm:
- The file path where the note was saved
- Key sources used
- Whether it was committed/pushed or if a remote needs to be set up
