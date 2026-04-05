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

> One strong analogy or conceptual frame — the single idea that makes the whole subsystem make sense before diving into details.

## Architecture

> A Mermaid diagram showing the major components and how they relate. Follow with a short paragraph explaining what the diagram shows.

## Core Components

> For each major component: one paragraph on *what it does for the system* and *why it exists*, not a list of its fields or functions.

## How Components Interact

> Describe the key flows through the subsystem. Pick 2–3 important scenarios (e.g. "allocating a page", "a process faults in memory") and walk through what happens step by step, which components are involved, and why.

## Where It Fits in the Kernel

> How this subsystem connects upward to userspace, sideways to peer subsystems (e.g. scheduler, VFS, networking), and downward to hardware. What depends on it? What does it depend on?

## Design Decisions & Tradeoffs

> The most important design choices that shape the subsystem: what was chosen, what was rejected, and what tradeoffs were accepted. Ground these in real history where possible.

## How It Has Evolved

> Key shifts over kernel history — what changed, which version introduced it, and what problem forced the change.

## Recent Development Activity

> What is actively being worked on or debated right now? What problems remain unsolved?

## Further Reading

> Ranked list — LWN articles first, then kernel.org docs, then conference talks and blogs.

## LKML Highlights

> 2–3 threads that show real design debates or significant changes, each summarised in a sentence.
