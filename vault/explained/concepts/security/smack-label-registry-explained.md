---
title: "Smack Label Registry — Explained"
category: explained
original: "[[smack-label-registry]]"
subsystem: security
tags: [explained, security, smack, labels, interning]
converted: 2026-09-25
---

# The Smack label registry, explained

> Plain-language companion to [[smack-label-registry|the technical note]]. Same facts, fewer identifiers.

## The problem

A Smack label is a short text string. Access checks happen on nearly every system call, and comparing strings each time, or re-reading labels from file attributes, would be slow. Labels also arrive from many directions: file attributes, rule files written by administrators, even labelled network packets. They all need to end up as the same thing.

## The idea in one paragraph

The registry is a **string-interning table**. The first time the system sees a label, say "app", from anywhere, it creates exactly **one** canonical entry for it and hands back that entry's address. Every later mention of "app" gets the same address. Two files labelled "app" point at the same memory, so the access engine compares labels with a single pointer comparison instead of a string comparison.

## Step by step

### Step 1: Built-in labels exist from boot
At start-up, Smack creates entries for its five reserved labels: star (\*), hat (^), floor (\_), invalid/unset (?), and internet (@). Code that needs one refers to its fixed entry directly, never by string lookup, so the hottest paths skip even the hash lookup.

### Step 2: Look up an arriving label
Whenever a label arrives (a rule written through smackfs, a file's label attribute being read, a decoded network packet), it goes through one import routine. That routine hashes the string and checks a global hash table. If an entry exists, its address comes straight back, with no allocation.

### Step 3: Create it once
This is the key step. On a miss, the registry builds a new entry and does all the expensive work **once**:
- copies the label string (up to 255 characters; 23 or fewer is recommended for older interfaces)
- assigns a unique number, a **security ID**, used by audit
- pre-computes the label's **CIPSO network form**, so labelling outgoing packets never has to convert strings again
- sets up an empty rule tree for rules where this label is the subject, with a lock for adding rules

The entry goes into the hash table, for fast lookup, and into a list, so smackfs can enumerate every known label.

### Step 4: Everyone uses the pointer
From then on, [[smack-inode-and-task-labeling-explained|files and processes]] store only the pointer, the [[smack-access-engine-explained|access engine]] compares pointers and walks the subject entry's rule tree, and the network code uses the pre-computed CIPSO form.

## The picture

```text
 xattr "app" ──┐
 rule  "app" ──┼─▶ import: hash("app") → table hit? ── yes ──▶ &entry(app)
 packet "app" ─┘                             │ no
                                             ▼
                     new entry { "app", security ID 17, CIPSO form, rule tree }
                     → hash table + list          → &entry(app)

 access check: subject == object ?  → one pointer comparison, no strcmp
```

## Tradeoffs

- **What it gives you:** access checks as cheap as a pointer comparison; string work pushed to import time, which is rare; network labels computed once.
- **What it costs / requires:** labels are **never deleted**. Once imported, a label occupies memory until the kernel shuts down.
- **Where it bites:** that's fine for embedded systems with bounded policy sets, but a system generating many labels dynamically would grow the registry without limit.

## How it got here

- **2.6.25:** the first registry was a plain list searched linearly.
- **3.x:** a hash table for constant-time lookup, as production deployments such as Tizen grew to hundreds of labels.
- **4.x:** security IDs assigned with an atomic counter instead of a protected global one, reducing contention when policy loads in parallel on multi-core systems.

## Related

- Technical version: [[smack-label-registry]]
- [[smack|Smack]], [[smack-access-engine-explained|Access engine]], [[smack-inode-and-task-labeling-explained|Inode and task labelling]], [[smack-network-labeling-explained|Network labelling]], [[smackfs|smackfs]]
- [[netlabel-explained|NetLabel]], [[cipso-ipv4-engine-explained|CIPSO engine]], [[linux-audit-explained|Audit]]
