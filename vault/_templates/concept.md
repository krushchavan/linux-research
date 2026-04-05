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

> Why does this mechanism exist? What problem would occur without it? Keep it to 2–3 sentences.

## Mental Model

> One analogy or conceptual frame that makes the whole thing click before diving into details.

## How It Works

> Walk through the mechanism as a narrative — what triggers it, what decisions it makes, what it produces. Explain the *why* at each step, not just the *what*. Plain English first; introduce technical terms only after the concept is clear.

## Key Data Structures

> The structures that carry the state for this mechanism. For each: one sentence on what it represents and why it exists, followed by the most important fields and what they control. Include the header file path.
>
> Example format:
> **`struct foo`** (`include/linux/foo.h`) — represents X so that Y can happen.
> - `field_a` — controls the rate at which ...
> - `field_b` — tracks whether ...

## Key Functions / Entry Points

> The functions a reader would encounter first when tracing this mechanism in the source. For each: what it does, what calls it, and what it returns or triggers next.
>
> Example format:
> **`foo_do_thing()`** (`mm/foo.c`) — called by the page fault handler when ...; allocates a ... and hands it to ...

## Important Flags & Config Options

> Kconfig options, sysctl knobs, module parameters, or GFP/page flags that meaningfully change the behaviour of this mechanism. For each: what it does when set and when you would change it.

## Interactions with Other Subsystems

> How this mechanism connects to the rest of the kernel. Structure as named relationships:
> - **↑ Userspace**: what userspace calls or observes that drives this mechanism
> - **→ [Subsystem]**: what this mechanism asks of each peer subsystem and why
> - **← [Subsystem]**: what peer subsystems ask of this mechanism

## Design Decisions & Tradeoffs

> The most consequential design choices: what was chosen, what was explicitly rejected, and what the designers gave up in exchange. Ground these in real history where possible.

## How It Has Evolved

> Major shifts in approach across kernel versions — what changed, which version introduced it, and what problem forced the change.

## Further Reading

> Ranked list — LWN articles first, then kernel.org docs, then blogs and conference talks.

## LKML Highlights

> 2–3 threads that reveal real design debates or turning points, each summarised in 1–2 sentences with the message-id.
