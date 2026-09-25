# Linux Kernel Research

A living knowledge base built by the Claude Code research agent.

## Browse by Category

- [[concepts/|Concepts]] — Core kernel mechanisms (scheduling, memory, locking, IPC…)
- [[subsystems/|Subsystems]] — Deep dives per subsystem (mm, net, fs, drivers…)
- [[patches/|Patches]] — Notable patch analyses and LKML thread summaries
- [[people/|People]] — Key contributors and their areas of focus
- [[explained/|Explained]] — Plain-language, step-by-step companions to the technical notes (e.g. [[io-uring-zero-copy-networking-explained|io_uring zero-copy networking, explained]])

## How to Add a Note

Open Claude Code and run:

```
/research-kernel <topic>
```

**Examples:**
```
/research-kernel CFS scheduler
/research-kernel io_uring internals
/research-kernel mm: page fault handling
/research-kernel subsystem: netfilter
/research-kernel patch: 20251111105634.1684751-1-lzampier@redhat.com
/research-kernel person: Linus Torvalds
```

The agent researches across LKML, kernel.org docs, and the web, then saves a structured note here and commits it.

## Stats

> Use Obsidian's **Dataview** plugin to auto-populate stats here.
