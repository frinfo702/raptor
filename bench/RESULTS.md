# rap server memory

Measured with `bench/rap-memory.sh`: the `phys_footprint` of the server
process (`proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint`), the metric
behind Rex's published charts. Each workload starts a fresh server.

- Apple M4, 24 GB, macOS 27.0 (26A428)
- `zig build rap -Doptimize=ReleaseFast`, Zig 0.17.0 from the nix dev shell
- Blocks are 80x24 and run `/bin/sh` that then `exec`s `cat`, so they stay
  idle. The filled ones first `cat` 10,000 lines of `NNNNN` plus words from
  a 56-word list, padded with `.` to 72 columns.

## Results

Five runs:

| Workload | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 | Target | Rex |
|---|---|---|---|---|---|---|---|
| Server start, one session | 3.3 MiB | 3.3 MiB | 3.3 MiB | 3.3 MiB | 3.3 MiB | <= 12 MiB | 10.6 MiB |
| Per empty block (avg of 100) | 34.2 KiB | 34.1 KiB | 34.6 KiB | 33.9 KiB | 34.6 KiB | <= 100 KiB | 68 KiB |
| Per block with 10k lines, idle (avg of 20) | 1,936.8 KiB | 1,934.4 KiB | 1,933.6 KiB | 1,934.4 KiB | 1,937.6 KiB | <= 2,252.8 KiB (2.2 MiB) | 407 KiB |
| Per client, 50 filled blocks (avg of 10) | 80.0 KiB | 28.8 KiB | 33.6 KiB | 28.8 KiB | 30.4 KiB | <= 150 KiB | 85 KiB |

All four targets are met.

The per-client target is judged on the marginal cost of each client after
the first one. The first subscriber's cost is reported on its own line
(see the note on clients). Three later runs, with that line added:

| Workload | Run 6 | Run 7 | Run 8 |
|---|---|---|---|
| First subscriber, 50 filled blocks (rings, snapshot decode) | 2,512.0 KiB | 2,528.0 KiB | 2,576.0 KiB |
| Per client, 50 filled blocks (avg of 10) | 72.0 KiB | 72.0 KiB | 116.8 KiB |

## Notes

- **Filled blocks.** The server compresses a block's cold scrollback once
  its terminal has been quiet for a 250 ms tick, one bounded
  `compress(.incremental)` step per millisecond, as the renderer does.
  `rap server stats` then shows 16 of 17 pages compressed, 1,476 KiB of
  LZ4 data. The rest is the resident active page and the block itself.
  Without compression a filled block costs 6,539 KiB.
- **Forks hide memory from madvise.** Starting a block forks the server. On
  macOS, a page written after a fork sits on a shadow of its old contents,
  and `madvise(MADV_FREE_REUSABLE)` does not release it. So a page that was
  resident at some fork and compressed later stayed charged twice: raw and
  encoded. Blocks created while others were printing then cost 2,100 to
  2,350 KiB each, varying from run to run. The server now marks every
  resident page `VM_INHERIT_NONE` before it forks
  (`Block.hidePagesFromChildren`), which brings them back to 1,934 KiB.
  The Ghostty app forks each new surface the same way.
- **Clients.** Each additional client costs about 30 KiB in runs 2 to 5
  (runs 6 to 8 measured 72 to 117 KiB, with malloc high-water noise on
  top): its 16 KiB read
  buffer, 50 stream records, and its outbox. The first subscriber of a
  block also pays once for the block's replay ring, and decoding compressed
  pages for its snapshots raises the allocator's high-water mark once. The
  ring is per-block state shared by all clients (design report 6.3), so,
  following Rex's "additional memory per client connection", the
  benchmark has one client subscribe before it starts the per-client
  baseline, and reports that first subscriber's cost separately: about
  2.5 MiB for 50 blocks, of which 800 KiB are the 50 16 KiB rings.
  Counted as one of 11 clients, it would put the average near 300 KiB,
  over the 150 KiB target. Snapshots are encoded in an arena on the page
  allocator, so their decode buffers go back to the OS rather than to
  malloc. Before that change, runs averaged 170 to 210 KiB per client,
  from malloc high-water jumps of about 1 MiB. A smaller jump still shows
  up now and then, as in run 1.
- **Gap to Rex on filled blocks.** 1.9 MiB against Rex's 407 KiB is the
  limit of LZ4 on raw page memory. The compact cold-page codec (a later
  milestone) re-encodes rows before compressing them, and the design
  report measured about 343 KiB with it.
