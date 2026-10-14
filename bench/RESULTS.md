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

| Workload                                                    | Run 1       | Run 2       | Run 3       | Run 4       | Run 5       | Target                   | Rex      |
| ----------------------------------------------------------- | ----------- | ----------- | ----------- | ----------- | ----------- | ------------------------ | -------- |
| Server start, one session                                   | 3.6 MiB     | 3.6 MiB     | 3.5 MiB     | 3.5 MiB     | 3.5 MiB     | <= 12 MiB                | 10.6 MiB |
| Per empty block (avg of 100)                                | 34.4 KiB    | 34.7 KiB    | 34.2 KiB    | 34.1 KiB    | 35.0 KiB    | <= 100 KiB               | 68 KiB   |
| Per block with 10k lines, idle (avg of 20)                  | 847.2 KiB   | 844.8 KiB   | 844.8 KiB   | 847.2 KiB   | 846.4 KiB   | <= 2,252.8 KiB (2.2 MiB) | 407 KiB  |
| First subscriber, 50 filled blocks (rings, snapshot decode) | 3,328.0 KiB | 3,312.0 KiB | 3,328.0 KiB | 3,296.0 KiB | 2,496.0 KiB | (reported)               |          |
| Per client, 50 filled blocks (avg of 10)                    | 32.0 KiB    | 30.4 KiB    | 32.0 KiB    | 25.6 KiB    | 62.4 KiB    | <= 150 KiB               | 85 KiB   |

All four targets are met. The per-client target is judged on the marginal
cost of each client after the first one; the first subscriber's cost is
reported on its own line (see the note on clients).

Before the row-packing codec (see the note on filled blocks), the same
build measured 1,934.4 to 1,936.8 KiB per filled block.

## Notes

- **Filled blocks.** The server compresses a block's cold scrollback once
  its terminal has been quiet for a 250 ms tick, one bounded
  `compress(.incremental)` step per millisecond, as the renderer does.
  Each cold page's cells are first re-packed the way snapshot grid rows
  are (`src/terminal/compress/rowpack.zig`: trailing blank cells dropped,
  the rest stored at 1, 2, 4, or 8 bytes each), then LZ4-compressed.
  `rap server stats` then shows 16 of 17 pages compressed into 405 KiB
  (LZ4 on raw page memory needed 1,476 KiB). The rest is the resident
  active page and the block itself. Without compression a filled block
  costs 6,539 KiB.
- **Forks hide memory from madvise.** Starting a block forks the server. On
  macOS, a page written after a fork sits on a shadow of its old contents,
  and `madvise(MADV_FREE_REUSABLE)` does not release it. So a page that was
  resident at some fork and compressed later stayed charged twice: raw and
  encoded. Blocks created while others were printing then cost 2,100 to
  2,350 KiB each, varying from run to run. The server now marks every
  resident page `VM_INHERIT_NONE` before it forks
  (`Block.hidePagesFromChildren`), which brought them back to 1,934 KiB
  (before the row-packing codec).
  The Ghostty app forks each new surface the same way.
- **Clients.** Each additional client costs about 30 KiB (run 5 measured
  62 KiB, with malloc high-water noise on top): its 16 KiB read buffer, 50
  stream records, and its outbox. The first subscriber of a
  block also pays once for the block's replay ring, and decoding compressed
  pages for its snapshots raises the allocator's high-water mark once. The
  ring is per-block state shared by all clients (design report 6.3), so,
  following Rex's "additional memory per client connection", the
  benchmark has one client subscribe before it starts the per-client
  baseline, and reports that first subscriber's cost separately: 2.5 to
  3.3 MiB for 50 blocks, of which 800 KiB are the 50 16 KiB rings.
  Counted as one of 11 clients, it would put the average near 300 KiB,
  over the 150 KiB target. Snapshots are encoded in an arena on the page
  allocator, so their decode buffers go back to the OS rather than to
  malloc. Before that change, runs averaged 170 to 210 KiB per client,
  from malloc high-water jumps of about 1 MiB. A smaller jump still shows
  up now and then, as in run 5.
- **Gap to Rex on filled blocks.** 845 KiB against Rex's 407 KiB. The
  compressed history is 405 KiB; the other ~440 KiB is the block and the
  page holding the active area, which is never compressed and after
  10,000 lines holds over 500 written rows. The design report's 343 KiB
  estimate counted only an empty terminal's 24 KiB as live memory, so it
  missed that page. Getting closer to Rex means compressing the history
  rows of that page too, a PageList policy change.
