---
title: "{{title}}"
category: subsystem
tags: []
maintainer:
mailing_list:
source_path:
researched: {{date}}
status: in-progress
sources:
  -
---

# {{title}} Subsystem

## Overview

> 2–3 sentences: what this subsystem is responsible for and why the kernel needs it.

## Mental Model

> One strong analogy or conceptual frame — the single idea that makes the whole subsystem click before diving into details.

## Architecture

> A Mermaid diagram showing the major components and how control/data flows between them. Follow with a short paragraph explaining what the diagram shows and how to read it.

## Core Components

> For each major component: one paragraph on *what it does for the system* and *why it exists*. Explain what would break if it were removed. Introduce the canonical struct or source file as a grounding reference, but keep the focus on purpose and behaviour.
>
> Name each component as an Obsidian wiki-link so it becomes a clickable link to its concept note: `[[component-name]]`

## Key Data Structures

> The structures that carry the subsystem's state. For each: what it represents, why it exists, and its most important fields with a one-line explanation of what each controls. Include the header file path.
>
> Example format:
> **`struct foo`** (`include/linux/foo.h`) — represents X so that Y can happen.
> - `field_a` — controls the rate at which ...
> - `field_b` — tracks whether ...

## Key Functions / Entry Points

> The functions a reader encounters first when tracing the subsystem. For each: what it does, what calls it, and what it triggers next. Organised by the flow they belong to (e.g. allocation path, reclaim path).

## Important Flags & Config Options

> Kconfig symbols, sysctl knobs, and important flags (e.g. GFP flags, VMA flags) that meaningfully change subsystem behaviour. For each: what enabling/setting it does and when you would change it.

## How Components Interact

> Walk through 2–3 concrete scenarios end-to-end (e.g. "a process calls malloc()", "memory pressure triggers reclaim"). At each step, name which component acts, what it decides, and why it hands off to the next component.

## Where It Fits in the Kernel

> How this subsystem connects to the rest of the kernel:
> - **↑ Userspace**: what syscalls or library calls land here
> - **→ [Peer subsystem]**: what this subsystem asks of each peer and why
> - **← [Peer subsystem]**: what peers ask of this subsystem
> - **↓ Hardware**: what hardware abstractions this subsystem sits above

## Design Decisions & Tradeoffs

> The most consequential design choices that shaped the subsystem: what was chosen, what was rejected, and what was given up. Ground each decision in real history where possible.

## How It Has Evolved

> Key shifts over kernel history — what changed, which version introduced it, and what problem forced the change.

## Recent Development Activity

> What is actively being worked on or debated right now? What problems remain unsolved?

## Further Reading

> Ranked list — LWN articles first, then kernel.org docs, then conference talks and blogs.

## LKML Highlights

> 2–3 threads that show real design debates or significant changes, each summarised in 1–2 sentences with the message-id.
