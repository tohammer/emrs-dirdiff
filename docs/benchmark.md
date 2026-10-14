# Benchmark: a full comparison against `diff -rq`

Recorded for task 4 of the v1 spec (2026-10-14).

## Setup

- Machine: Intel Core i5-8365U (4 cores, 8 threads, 1.6 GHz), 14 GiB RAM,
  Linux 7.0.0, trees on tmpfs (`/tmp`), so warm cache throughout.
- Trees: `bench/make-trees.sh DIR` (100,000 files per side in 1,000
  directories, 1 to 4 KiB of text each, 894 MiB for both trees on tmpfs).
  In B, 1,000 files (1 %) have one changed line, 50 files are missing and
  50 extra files exist.
- Module: release build, run through `emrs::testing::Host` (the real
  pool, mailbox and stream code, without the Lisp conversion of the items
  in Emacs), comparison by content, ignore files on, hidden files on.
  The pool has 8 threads (`available_parallelism`).
- `diff -rq`: GNU diffutils 3.12, output to `/dev/null`.

Each was run twice; the table gives the second run.

## Commands

```sh
bench/make-trees.sh "$DIR"
diff -rq "$DIR/a" "$DIR/b" > /dev/null          # under /usr/bin/time, twice
DIRDIFF_BENCH_A="$DIR/a" DIRDIFF_BENCH_B="$DIR/b" \
  cargo test --release --lib bench_compare -- --ignored --nocapture   # runs twice
DIRDIFF_BENCH_BY=size-time DIRDIFF_BENCH_A="$DIR/a" DIRDIFF_BENCH_B="$DIR/b" \
  cargo test --release --lib bench_compare -- --ignored --nocapture
rm -rf "$DIR"
```

## Results

| Comparison | Wall time (second run) | First run |
|---|---|---|
| `diff -rq` | 0.82 s (0.27 s user, 0.54 s sys) | 0.82 s |
| emrs-dirdiff, `content` | 0.43 s | 0.39 s |
| emrs-dirdiff, `size-time` | 0.18 s | 0.19 s |

The module examined 101,150 entries and reported 1,000 `changed`, 50
`only-a`, 50 `only-b` and 1,101 `done` items, the same differences as
`diff -rq` (1,000 "Files … differ", 100 "Only in"). With `size-time`,
5 more files were `changed`: the generator wrote their two copies in
different seconds.

The `content` comparison also computes line counts for every changed
file. Not measured here: the time Emacs spends converting and handling the
items (task 5), and trees on a disk with a cold cache.
