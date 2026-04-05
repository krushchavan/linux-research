---
title: "{{title}}"
category: concept
tags: []
subsystem:
kernel_version:
researched: {{date}}
status: in-progress
sources:
  -
---

# {{title}}

## Purpose

> Why does this mechanism exist? What problem would occur without it? 2–3 sentences.

## Mental Model

> One analogy or conceptual frame that makes the whole thing click before diving into details.

## How It Works

> The mechanism as a single flowing narrative. Blend conceptual explanation and technical detail together — introduce a struct or function at the moment it becomes relevant to the story, explain what it holds or does in that context, then continue. The goal is that by the end of this section the reader understands both *what happens* and *why*, with the key data structures and functions encountered naturally along the way.
>
> Structure the narrative around the important scenarios or states (e.g. fast path, slow path, failure path) rather than listing fields or functions sequentially.

## Key Data Structures

> Quick-reference complement to the narrative above. List only structures not already fully explained inline. For each: one sentence on what it represents, then the fields that matter most.
>
> **`struct foo`** (`include/linux/foo.h`) — represents X so that Y can happen.
> - `field_a` — controls the rate at which ...
> - `field_b` — tracks whether ...

## Key Functions / Entry Points

> Quick-reference list of the functions a reader would trace first. One line each: what it does and what calls it.
>
> **`foo_do_thing()`** (`mm/foo.c`) — called by X when Y; does Z and hands off to W.

## Important Flags & Config Options

> Kconfig symbols, sysctl knobs, module parameters, or important flag sets (e.g. GFP flags) that meaningfully change behaviour. For each: what it does and when you would change it.

## Interactions with Other Subsystems

> - **↑ Userspace**: what userspace calls or observes that drives this mechanism
> - **→ [Subsystem]**: what this mechanism asks of each peer and why
> - **← [Subsystem]**: what peer subsystems ask of this mechanism

## Design Decisions & Tradeoffs

> The most consequential design choices: what was chosen, what was rejected, what was given up — grounded in real history.

## How It Has Evolved

> Major shifts across kernel versions and the problems that drove each change.

## Further Reading

> Ranked list — LWN articles first, then kernel.org docs, then blogs and talks.

## LKML Highlights

> 2–3 threads that reveal real design debates, each summarised in 1–2 sentences with the message-id.
