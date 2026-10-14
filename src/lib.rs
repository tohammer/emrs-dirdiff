//! emrs-dirdiff: compare two directory trees in Emacs, as an Emacs module
//! built on emrs.
//!
//! The module `emrs-dirdiff-module` provides one service, `dirdiff`
//! ([`service::DirdiffService`]): one instance per comparison buffer, started
//! from Elisp with `(emrs-start 'emrs-dirdiff "dirdiff" (list :a A :b B))`.
//! Requests and stream items are specified in
//! `docs/specs/2026-10-14-emrs-dirdiff-v1.md`: `walk` lists and pairs one
//! directory level, `compare` decides about one file pair, `session` runs
//! a comparison on a thread pool and keeps the identical entries.

mod compare;
mod service;
mod session;
mod walk;

emrs::module!("emrs-dirdiff", [service::DirdiffService]);
