# 0003 — Rescans run one at a time

Date: 2026-10-14
Status: accepted

## Context

An instance runs one `:compare` at a time, and a new `:compare` cancels
the running one. After an action, each affected path is rescanned with a
`:compare :path`. Started at once, the rescans would cancel one another,
and a rescan during a full comparison would cancel it. The review of
version 1 found the worst case: a subtree rescan (`C-u g`) that cancelled
a full comparison left a truncated result labelled done.

## Decision

Rescans after actions are queued and run one at a time; the next starts
when the previous stream ends. A subtree rescan (`C-u g`) is refused while
any stream runs, instead of cancelling a full comparison. Plain `g`
cancels the running comparison and starts over, and a full comparison
clears the queue because it covers everything. Stop (`C-c C-k`) clears
the queue.

## Consequences

- Rescans after an action wait for a running full comparison to end.
- The view may lag behind the disk after a burst of actions, until the
  queue is empty.
- No comparison is ever cut short without the user asking for it.
