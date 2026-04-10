---
title: "XArray"
category: concept
tags: [mm, data-structures, radix-tree, page-cache, rcu]
subsystem: mm
kernel_version: "4.20"
researched: 2026-04-10
status: complete
sources:
  - https://www.kernel.org/doc/html/latest/core-api/xarray.html
  - https://docs.kernel.org/core-api/xarray.html
  - https://lwn.net/Articles/745073/
  - https://lwn.net/Articles/715948/
  - https://lwn.net/Articles/757342/
  - https://lwn.net/Articles/750540/
---

# XArray

## Purpose

XArray is an abstract data type that behaves like a very large sparse array of pointers, indexed by an `unsigned long`. It was created to replace the kernel's old [[radix-tree]] API, which required callers to manage their own locking, maintain complex preload pools, and deal with implementation-leaking internals — problems that caused multiple subsystems to write bespoke alternatives. XArray unifies these use cases under a single, locking-integrated interface without changing the underlying radix-tree data structure itself.

## Mental Model

Think of XArray as a hash table and resizable array hybrid, but implemented as a radix tree. Like a hash you can jump directly to any index; like an array you can iterate sequentially with no overhead per gap; like a resizable array it grows automatically without copying. The key insight is that the old radix tree *was* all of these things — the problem was the API, not the data structure, so Wilcox kept the tree and replaced the API.

## How It Works

### Entry Representation and the Slot Encoding

Every slot in the XArray holds a pointer-sized value, but not all values are raw kernel pointers. The XArray uses the bottom two bits of each slot value to encode the type of what is stored there:

- **Pointer entries** (bits `00`): a normal 4-byte-aligned kernel pointer from `kmalloc()` or `alloc_page()`. The low two bits are guaranteed zero by the allocator.
- **Value entries** (bit `1` set): small integers in the range `0..LONG_MAX` stored with `xa_mk_value(n)` and retrieved as integers with `xa_to_value()`. The high bits hold the integer; the low bit distinguishes value from pointer.
- **Internal entries** (bit `2` set): used only by the XArray itself for bookkeeping. Callers using the normal API never see these. They include:
  - *Sibling entries* — mark a slot as part of a multi-index range, pointing at the canonical slot
  - *Retry entries* — indicate a concurrent modification is in progress; the lookup must restart
  - *Zero entries* — a slot that is reserved but appears `NULL` to normal readers

This encoding means storing an `IS_ERR()` pointer is forbidden — those have bit 0 set and would look like a value entry.

### `struct xarray` and `struct xa_node`

The top-level object `struct xarray` (`include/linux/xarray.h`) contains two fields that matter:

```c
struct xarray {
    spinlock_t  xa_lock;   /* protects all mutations */
    void       *xa_head;   /* NULL | xa_node* | value entry */
};
```

`xa_head` starts as `NULL` (empty array), becomes a direct pointer when the array holds exactly one entry at index 0, and becomes a pointer to an `xa_node` when a second entry is added or any entry exceeds index 63.

An `xa_node` is a 64-slot radix tree node:

```c
struct xa_node {
    unsigned char  shift;     /* bits covered below this node */
    unsigned char  offset;    /* slot index in parent */
    unsigned char  count;     /* non-NULL child slots */
    unsigned char  nr_values; /* value-entry count */
    struct xa_node *parent;
    struct xarray  *array;
    union {
        struct list_head private_list;
        struct rcu_head  rcu_head;
    };
    void __rcu *slots[XA_CHUNK_SIZE]; /* 64 slots */
    unsigned long marks[XA_MAX_MARKS][XA_MARK_LONGS]; /* 3 bitmaps */
};
```

Each node covers `XA_CHUNK_SIZE` (64) indices at its level. The `shift` field says how many index bits are handled by the subtree rooted here — a leaf node has `shift == 0`, meaning each slot directly represents one index. A node one level up has `shift == 6` (covering 64 leaves below it), two levels up `shift == 12`, and so on. For a 64-bit kernel, at most 10–11 levels are ever needed to cover all of `ULONG_MAX`.

### Normal API: Locking-Transparent Operations

The normal API (`xa_load`, `xa_store`, `xa_erase`, `xa_insert`, `xa_cmpxchg`, `xa_for_each`) is designed so callers never touch the lock directly.

**Reads** acquire the RCU read lock internally via `rcu_read_lock()`. The walk descends through `xa_node` slots following the index bits from most-significant to least-significant, six bits at a time. Because stores publish new nodes via `rcu_assign_pointer()` and reads dereference via `rcu_dereference()`, a reader will always see either the old tree or the new tree — never a torn intermediate state. The reader drops `rcu_read_lock()` before returning; the returned pointer is only valid for the duration the caller holds the lock (or a reference to the object).

**Writes** take `xa_lock` (the embedded spinlock). A store that requires a new node must allocate it first. Under the normal API, `xa_store()` uses `GFP_NOWAIT` to try an atomic allocation. If that fails, it drops the lock, does a `GFP_KERNEL` blocking allocation, re-acquires the lock, and retries the store. The pre-allocated node is released at the end if it turned out not to be needed.

### Advanced API: `xa_state` Cursor

When a caller needs to compose multiple XArray operations without restarting from the root each time — the page cache needs this constantly — it uses `xa_state`. You declare one on the stack:

```c
XA_STATE(xas, &mapping->i_pages, start_index);
```

`xa_state` remembers exactly where in the tree the last operation landed — which node, which slot, what index was last accessed. This means `xas_next()` does not need to re-walk from the root; it increments the leaf slot pointer and handles the carry to parent nodes inline. For sequential scans of the page cache (e.g., reading 128 pages of a file), this eliminates thousands of redundant root-to-leaf descents.

`xa_state` also acts as an error accumulator. Internal operations set `xas->xa_node = XAS_RESTART` or `XAS_BOUNDS` to flag conditions requiring a restart. The helpers `xas_retry()` and `xas_error()` let callers check state without exposing the internals.

Memory allocation in the advanced API is split: `xas_nomem()` pre-allocates a node into `xas->xa_alloc`, then the locked operation uses that node directly without calling the allocator under the lock.

### Marks

Each `xa_node` carries three independent bitmaps (`XA_MARK_0`, `XA_MARK_1`, `XA_MARK_2`), each with one bit per slot. A mark on an entry is visible in its parent's bitmap, which is visible in *its* parent's bitmap, and so on up to the root. This makes "find the next marked entry" a matter of scanning the current node's bitmap to the next set bit, then ascending only if the rest of the current node is unmarked — O(log n) worst case but O(1) amortized for dense workloads.

The page cache uses `XA_MARK_DIRTY` (mark 0) to track dirty pages and `XA_MARK_WRITEBACK` (mark 1) to track pages under writeback, enabling `xa_for_each_marked()` to efficiently enumerate only those pages without scanning the entire cache.

### Multi-Index Entries

A range of aligned power-of-two consecutive indices can be tied to a single entry. The canonical entry lives in the lowest-indexed slot; all other slots in the range hold sibling entries pointing back at the canonical slot. Any lookup within the range returns the canonical entry. Any store to any slot within the range stores to all of them. This is how the page cache represents huge pages: a 2 MiB huge page covers 512 4 KiB indices, requiring only one real entry instead of 512 separate entries.

### Allocation Mode

When initialized with `XA_FLAGS_ALLOC`, the XArray switches to allocation-ID semantics: `xa_alloc()` atomically finds the first unused index in a given range and stores the entry there in one operation. This replaces the old `idr` (ID Radix) allocator. PIDs, file descriptors, and many other ID spaces now use XArray in allocation mode.

## Key Data Structures

**`struct xarray`** (`include/linux/xarray.h`) — the public handle, embedded in objects like `struct address_space`.
- `xa_lock` — protects writes; RCU covers reads
- `xa_head` — root of the tree; `NULL` for empty, direct pointer for single-entry optimization, `xa_node *` otherwise

**`struct xa_node`** (`lib/xarray.c`) — a 64-way radix tree node.
- `shift` — index bits delegated to children; 0 at leaves
- `count` / `nr_values` — non-null slot counts used to prune empty nodes
- `slots[]` — 64 `void __rcu *` child pointers (to more nodes or to final entries)
- `marks[]` — three 64-bit bitmaps tracking mark bits across all slots

**`struct xa_state`** (`include/linux/xarray.h`) — cursor for advanced API.
- `xa` — back-pointer to the `xarray`
- `xa_index` — current target index
- `xa_shift` — shift of the current node (recalculated after each operation)
- `xa_sibs` — sibling count for multi-index operations
- `xa_offset` — slot within current node
- `xa_node` — current node; `XAS_RESTART` / `XAS_BOUNDS` signal special states
- `xa_alloc` — pre-allocated `xa_node` for use under lock

## Key Functions / Entry Points

**`xa_load(xa, index)`** (`lib/xarray.c`) — rcu-locked tree walk; the hot path for page cache lookups. Returns the stored pointer or `NULL`.

**`xa_store(xa, index, entry, gfp)`** — acquires `xa_lock`, walks to the slot, allocates nodes as needed (with retry on ENOMEM), stores the entry, updates marks, returns the old entry.

**`xa_erase(xa, index)`** — stores `NULL`; if the node becomes empty, it is freed via `call_rcu()`.

**`xa_for_each(xa, index, entry)`** — macro that repeatedly calls `xas_find()` under the RCU read lock; skips `NULL` slots transparently.

**`xa_for_each_marked(xa, index, entry, mark)`** — like `xa_for_each` but uses the mark bitmaps to skip entire unmarked subtrees.

**`xas_load(&xas)`** — advanced read; descends from current `xa_state` position without restarting if the state is fresh.

**`xas_store(&xas, entry)`** — advanced write; assumes `xa_lock` is held by the caller; uses `xas->xa_alloc` if a new node is needed.

**`xas_find(&xas, max)`** — advance cursor to the next present entry at or after `xas->xa_index`, stopping at `max`.

**`xas_nomem(&xas, gfp)`** — called outside the lock when `xas_store()` returned `ENOMEM`; allocates a node into `xas->xa_alloc`.

**`xa_alloc(xa, id, entry, limit, gfp)`** — allocation-mode store; atomically finds the lowest free ID in `limit` and stores `entry` there.

## Important Flags & Config Options

`XA_FLAGS_LOCK_IRQ` — use `xa_lock_irqsave` / `xa_unlock_irqrestore`; required when the XArray is accessed from IRQ context.

`XA_FLAGS_LOCK_BH` — disable BH around mutations; required when accessed from softirq context.

`XA_FLAGS_ALLOC` — enable ID-allocation mode; `xa_alloc()` starts IDs from 0.

`XA_FLAGS_ALLOC1` — same but starts from 1 (avoids returning 0 as a valid ID, useful for systems that treat 0 as "no ID").

`XA_MARK_0` / `XA_MARK_1` / `XA_MARK_2` — the three available per-entry marks. The page cache aliases these to `PAGECACHE_TAG_DIRTY`, `PAGECACHE_TAG_WRITEBACK`, and `PAGECACHE_TAG_TOWRITE`.

## Interactions with Other Subsystems

- **↑ Userspace**: no direct syscall surface; userspace observes XArray effects through `read()`/`write()` on files (page cache), `getpid()` (PID allocator), and file-descriptor operations.
- **→ [[page-cache]]**: `struct address_space.i_pages` is an XArray. Every page lookup, insertion, and writeback scan goes through XArray. The advanced `xa_state` API is used throughout `mm/filemap.c` to compose multi-step cache operations under a single lock acquisition.
- **→ PID allocator**: `struct pid_namespace.idr` was replaced with an XArray in allocation mode; `alloc_pid()` calls `xa_alloc_cyclic()`.
- **→ File descriptors**: `struct files_struct.fdt->fd` is backed by a plain array for small FD numbers, but the overflow table uses XArray.
- **← [[rcu-read-copy-update]]**: all reads are protected by the RCU read lock; mutations publish via `rcu_assign_pointer()` and reclaim nodes via `call_rcu()`. XArray is one of the highest-traffic RCU users in the kernel.
- **← [[slub-slab-allocator]]**: `xa_node` objects are allocated from a dedicated `kmem_cache` (`xarray_node_cachep`) to reduce fragmentation and improve allocation speed.
- **← [[page-reclaim]]**: the workingset shadow-entry mechanism uses `xas_set_update()` to hook into XArray node-update callbacks so it can maintain its LRU list of nodes holding only shadow entries.

## Design Decisions & Tradeoffs

**Keep the radix tree, replace the API.** The performance characteristics of a 64-way radix tree were known to be good. The problem was ergonomics and correctness. Wilcox's key decision was to keep the proven core and invest in a new API surface rather than experimenting with alternative data structures (skip lists, B-trees, etc.).

**Integrated locking over caller-managed locking.** The old radix tree required every caller to wrap operations in their own lock, which led to inconsistencies (some callers forgot, some over-locked). By embedding a spinlock in `struct xarray` and making the normal API take/release it automatically, callers cannot accidentally skip locking. The cost is that users who already hold a lock must use the advanced API — but that is the minority case.

**Two-tier API split.** The normal API (simple, opaque) satisfies ~80% of users. The advanced API (cursor-based, explicit locking) satisfies the page cache and other complex users. Putting all the complexity in the advanced tier means normal callers never see it, while expert callers get the full power they need without any abstraction cost.

**Eliminating preloading.** The old radix tree required callers to call `radix_tree_preload()` before inserting under a spinlock, tying up per-CPU caches of pre-allocated nodes. XArray eliminates this in the normal API: `xa_store()` drops the lock, allocates, and retries if it runs out of nodes. This is slightly slower in the common case but eliminates a class of bugs and simplifies callers dramatically.

**Multi-index entries for huge pages.** Representing a 2 MiB huge page as 512 separate page cache slots would waste memory and make marks (dirty/writeback) expensive to set and clear. Multi-index entries solve this neatly by making all 512 slots aliases of one canonical slot — one mark flip covers all of them.

**Not supporting `IS_ERR()` pointers.** This was a deliberate exclusion. Storing error pointers conflates error handling with storage, which is a common source of bugs. Callers must handle errors before storing.

## How It Has Evolved

**4.20 (Dec 2018)**: XArray and the `lib/xarray.c` implementation merged. The old `lib/radix-tree.c` remained as a thin compatibility shim calling into `lib/xarray.c`. The page cache (`mm/filemap.c`) was converted as the flagship demonstration.

**5.x series**: Approximately 50–60 in-tree users of the old radix-tree API were individually converted by their respective subsystem maintainers. IDR/IDR (ID Radix) API was deprecated; XArray allocation mode replaced it.

**5.6+**: `struct address_space.page_tree` (the old radix tree field) was renamed to `i_pages` and made an embedded `struct xarray`.

**6.x series**: Ongoing cleanup of remaining raw radix-tree users; `xas_try_split()` added for incremental huge-page splitting without holding the lock for the whole operation.

## Further Reading

1. [The XArray data structure — LWN.net (2018)](https://lwn.net/Articles/745073/) — Matthew Wilcox's detailed design walkthrough; best single-document introduction
2. [Introducing the eXtensible Array — LWN.net (2017)](https://lwn.net/Articles/715948/) — early design discussion covering motivation and API choices
3. [XArray and the mainline — LWN.net (2018)](https://lwn.net/Articles/757342/) — merge history, post-merge bugs, and conversion strategy
4. [Convert page cache to XArray — LWN.net (2018)](https://lwn.net/Articles/750540/) — walkthrough of the 62-patch page cache conversion
5. [XArray — kernel.org docs](https://www.kernel.org/doc/html/latest/core-api/xarray.html) — official API reference; authoritative on current semantics
6. [Replacing the Radix Tree — linux.conf.au 2018 slides](https://lca-kernel.ozlabs.org/2018-Wilcox-Replacing-the-Radix-Tree.pdf) — original presentation by Matthew Wilcox

## LKML Highlights

**XArray v8 series (2018)** — `lwn.net/Articles/748680/` — the version accepted by Andrew Morton for 4.20; discussion reveals the debate over whether the two-tier API added too much complexity for marginal gain, and Wilcox's defence that the page cache genuinely requires cursor semantics.

**PID: replace IDR API with XArray (2021)** — `lwn.net/Articles/901383/` — shows how PID allocation was migrated; reveals that the `xa_alloc_cyclic()` semantics required a small API extension to handle the wrap-around correctly for PID reuse.

**Convert page cache to XArray v10 (2018)** — the 62-patch series that demonstrated correctness: two post-merge bugs in the page cache conversion and one in the DAX conversion were found and fixed within a single release cycle, validating the approach.
