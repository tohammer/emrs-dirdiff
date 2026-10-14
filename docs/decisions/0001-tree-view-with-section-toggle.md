# 0001 — One merged tree, with a toggle to a section view

Date: 2026-10-14
Status: accepted

## Context

ztree-diff shows the comparison as two trees side by side. Three layouts
were drawn (spec mockup `2026-10-14-emrs-dirdiff-v1-mockup.html`):

- A: one merged tree with a status column (changed, only in A, only in B).
- B: two panes in aligned columns, as in ztree and Beyond Compare.
- C: flat lists grouped by kind of difference, as in `magit-status`.

B needs about 70 columns, cuts long names and leaves half of many lines
empty. A keeps the directory structure and full names in a half-width
window and has room for sizes and line counts. C answers "what was added
or removed" fastest but loses the structure.

## Decision

The user chose A and C with a toggle. A is the default view; `v` switches
to C and back. Both are drawn from the same result model. B is not built.

## Consequences

- The side of a one-sided entry is shown by a letter and a face, not by
  position; the header names A and B with their paths.
- Every command works in both views and identifies entries by relative
  path, so toggling keeps point on the same entry.
- Copy direction is named by key (`>` A to B, `<` B to A) rather than by
  pane.
