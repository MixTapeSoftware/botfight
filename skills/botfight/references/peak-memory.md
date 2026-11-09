# Peak-memory review

Make one pass over the changed code for ways to lower **peak memory**: the most memory live at any one moment, not the total allocated over a run. Peak memory decides whether a process hits its container limit, gets OOM-killed, or forces a larger instance. Report a reduction only when it keeps behaviour identical and costs no significant regression in latency, throughput, or clarity.

## What to look for

Trace what is live at the same time as the input grows. The usual sources:

- **Whole-input loading**: reading an entire file, response body, blob, or query result into memory when the code consumes it piece by piece.
- **Materialized intermediates**: building a full list, map, or string between steps that could stream (a `map` then `filter` then `sum` over eager collections; concatenating then splitting).
- **Unbounded result sets**: queries without pagination or limits, `SELECT *` loading columns the code never reads, eager loading of whole association graphs.
- **Duplicate copies**: cloning, serializing, or re-encoding a large value while the original stays live; holding both a parsed structure and its raw source.
- **Lifetimes longer than use**: large values held by long-lived closures, caches, module-level state, or request contexts after their last use.
- **Unbounded growth**: caches, memo tables, queues, and buffers with no size limit or eviction.
- **Concurrency multiplying buffers**: `N` parallel tasks each holding a full payload, with `N` driven by input size rather than a fixed bound.

## Proposing a reduction

Each suggestion names a concrete change: stream or iterate, paginate or batch, select only the needed fields, process in place, release the reference after last use, bound the cache or queue, or cap concurrency.

State the regression it risks, and check it before posting:

- **Latency and throughput**: more round trips from batching, lost vectorization, repeated work from dropping a cache. A reduction that trades a fixed memory saving for a per-item slowdown on a hot path is a regression.
- **Correctness**: streaming changes error timing (a failure arrives after partial output), ordering, and transactional or snapshot guarantees. Re-reading a source may see different data.
- **Clarity**: a reduction that makes simple code intricate earns its place only when the saving is large.

When the regression is significant or you cannot rule it out, report nothing for that site.

## Reporting

Each inline finding states where peak memory scales and with what (rows, file size, request count), an estimate of the saving at realistic input size, the correction, and the regression checked.

Score memory that grows with unbounded or user-controlled input, where large inputs risk OOM in production, at 6 or above. Score constant-factor savings on small or bounded data below 6, and skip savings too small to matter at realistic sizes.
