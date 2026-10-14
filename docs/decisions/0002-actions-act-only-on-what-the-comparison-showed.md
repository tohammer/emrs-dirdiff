# 0002 — Actions act only on what the comparison showed

Date: 2026-10-14
Status: accepted

## Context

The first implementation of copy and delete merged whole directories
with `copy-directory`, joined relative paths with `expand-file-name` and
acted on disk state as found. The review of version 1 showed what that
allows: an entry named `~` resolved to the home directory and `D` deleted
it; a merge wrote through symbolic links inside the target to places
outside both roots; it overwrote ignored files the user never saw listed;
a nested kind clash aborted part way with a report of "0 done"; a
directory that had replaced a compared file was deleted recursively; and
a kind-clash replacement was a recursive delete announced as "overwritten
or merged".

## Decision

An action works only on entries the comparison showed, entry by entry,
after checking that each entry on disk still matches the comparison and
that the target lies in a real directory inside its root. Copying a
directory present on both sides copies the differences listed below it,
never the directory as a whole. Paths are joined to the roots without `~`
expansion. The confirmation names every kind of operation separately,
deletions in particular. Details: spec section "Actions".

## Consequences

- Ignored, hidden and identical files under a copied directory are never
  touched; to copy them, compare with ignore files off or hidden files on.
- An entry that changed on disk after the comparison is skipped with a
  message; `g` brings the view up to date.
- An action may skip some entries and do others; the report says which.
- More checks per operation; negligible next to the copy itself.
