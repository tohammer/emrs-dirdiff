//! One comparison: the parallel walk over both trees, the result store and
//! cancellation (task 4).
//!
//! [`run`] is called on a thread of its own (the service starts it with
//! `Context::spawn`) and is the only thread that talks to the stream. The
//! work runs as tasks on the instance's own pool ([`new_pool`]), so tasks
//! of one instance blocked on a full channel never hold up another
//! instance: one task lists a directory level of both sides, one task
//! compares a file pair, one task counts the files of a directory present
//! on one side. Tasks hand their items to `run` through a bounded channel;
//! `run` only drains it, everything else (also the start of a rescan of a
//! single entry) runs as a task.
//!
//! A task that panics sends one `error` item for its path (`:kind` `"dir"`
//! for a directory listing, the entry's kind otherwise) and completes its
//! owner; a directory whose listing panicked gets no `done`.
//!
//! Completion: every directory present on both sides has a [`DirNode`]
//! with a counter of outstanding work (its own listing, each file task,
//! each subdirectory) and a link to its parent. The task that brings a
//! counter to zero emits the directory's `done` item, adds its identical
//! files to the parent and completes the parent in turn, so no task waits
//! for another. When the root of the comparison completes, `run` sends the
//! summary and ends the stream.
//!
//! Cancellation: a comparison stops when its stream call is cancelled or
//! the instance stops (the call's `CancelToken`), or when the service sets
//! its `stop` flag (`:cancel`, a newer `:compare`). Tasks check both before
//! they start and while they compare; `run` checks them while it waits and
//! drops the channel, so tasks blocked on it return at once.

use std::collections::{BTreeMap, HashMap};
use std::ffi::{OsStr, OsString};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, SyncSender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use emrs::{CancelToken, Error, StreamSender, TrySendError};
use serde::Serialize;

use crate::compare::{self, CompareError, FileMeta, Outcome};
use crate::walk::{self, EntrySide, Kind, Meta, Pair, Rules, join_rel};

/// A directory or file of this name makes its task panic (tests only).
#[cfg(test)]
pub const TEST_PANIC: &str = "emrs-dirdiff-test-panic";

#[cfg(test)]
fn test_panic(rel: &Path) {
    if rel.file_name().is_some_and(|n| n == TEST_PANIC) {
        panic!("test panic at {rel:?}");
    }
}

/// Items that may wait for Emacs at any time (the stream's capacity), and
/// items that may wait in the channel between the tasks and [`run`].
pub const CAPACITY: usize = 256;
/// How often [`run`] checks for cancellation while nothing arrives.
const POLL: Duration = Duration::from_millis(5);
/// The message of the error that ends a stream stopped by the service.
pub const CANCELLED: &str = "cancelled";

/// `:status` values.
pub mod status {
    pub const CHANGED: &str = "changed";
    pub const ONLY_A: &str = "only-a";
    pub const ONLY_B: &str = "only-b";
    pub const KIND: &str = "kind";
    pub const ERROR: &str = "error";
    pub const DONE: &str = "done";
    pub const SAME: &str = "same";
}

/// Size and modification time of one side of an entry: `(:size N :mtime F)`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Side {
    pub size: u64,
    pub mtime: f64,
}

impl From<&Meta> for Side {
    fn from(m: &Meta) -> Side {
        Side { size: m.size, mtime: m.mtime }
    }
}

/// A stream item, an entry of a `:same` answer, or the final summary.
/// Absent fields are left out of the plist.
#[derive(Debug, Clone, PartialEq, Default, Serialize)]
pub struct Item {
    // `kind` and `status` are strings because emrs encodes enum values as
    // one-element lists (spec "The service").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub a: Option<Side>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub b: Option<Side>,
    /// Added and removed lines: the list `(ADDED REMOVED)`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lines: Option<(u32, u32)>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub files: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub same: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seconds: Option<f64>,
}

fn kind_name(kind: Kind) -> &'static str {
    match kind {
        Kind::File => "file",
        Kind::Dir => "dir",
        Kind::Link => "link",
        Kind::Other(_) => "other",
    }
}

fn lisp_path(rel: &Path) -> String {
    rel.to_string_lossy().into_owned()
}

fn side_of(side: &EntrySide) -> Option<Side> {
    match side {
        EntrySide::Present(m) => Some(m.into()),
        _ => None,
    }
}

fn kind_of(side: &EntrySide) -> Option<Kind> {
    match side {
        EntrySide::Present(m) => Some(m.kind),
        _ => None,
    }
}

impl Item {
    fn entry(rel: &Path, kind: Option<Kind>, status: &'static str, a: Option<Side>, b: Option<Side>) -> Item {
        Item { path: Some(lisp_path(rel)), kind: kind.map(kind_name), status: Some(status), a, b, ..Item::default() }
    }

    fn done(rel: &Path, same: u64) -> Item {
        Item { same: Some(same), ..Item::entry(rel, Some(Kind::Dir), status::DONE, None, None) }
    }

    fn summary(files: u64, seconds: f64) -> Item {
        Item { summary: Some(true), files: Some(files), seconds: Some(seconds), ..Item::default() }
    }
}

/// The identical entries (other than directories) found so far, per
/// directory, for `:same`.
#[derive(Default)]
pub struct Store {
    dirs: HashMap<PathBuf, BTreeMap<OsString, Item>>,
}

impl Store {
    /// The identical entries directly in `dir`, sorted by name.
    pub fn same_in(&self, dir: &Path) -> Vec<Item> {
        self.dirs.get(dir).map(|entries| entries.values().cloned().collect()).unwrap_or_default()
    }

    /// Forget everything stored for `rel` and below it.
    pub fn drop_at(&mut self, rel: &Path) {
        self.dirs.retain(|dir, _| !dir.starts_with(rel));
        if let (Some(parent), Some(name)) = (rel.parent(), rel.file_name())
            && let Some(entries) = self.dirs.get_mut(parent)
        {
            entries.remove(name);
        }
    }

    fn insert(&mut self, dir: &Path, name: &OsStr, item: Item) {
        self.dirs.entry(dir.to_path_buf()).or_default().insert(name.to_os_string(), item);
    }
}

/// Parse a relative path from Lisp (`/` separated, `""` for the roots).
/// Empty and `.` components are dropped; `..` and absolute paths are refused.
pub fn parse_rel(path: &str) -> Result<PathBuf, Error> {
    let mut rel = PathBuf::new();
    for component in Path::new(path).components() {
        match component {
            Component::Normal(name) => rel.push(name),
            Component::CurDir => {}
            _ => return Err(Error::new(format!("not a relative path below the roots: {path:?}"))),
        }
    }
    Ok(rel)
}

/// The two roots of a comparison.
pub struct Roots {
    pub a: PathBuf,
    pub b: PathBuf,
}

/// What a comparison applies.
#[derive(Clone, Copy, Debug)]
pub struct Settings {
    pub walk: walk::Options,
    pub compare: compare::Options,
}

/// The thread pool of one instance: one thread per CPU. Its threads end
/// once it is dropped and the tasks queued on it have returned.
pub fn new_pool() -> Result<rayon::ThreadPool, Error> {
    rayon::ThreadPoolBuilder::new()
        .num_threads(std::thread::available_parallelism().map_or(4, |n| n.get()))
        .thread_name(|i| format!("emrs-dirdiff-{i}"))
        // Tasks catch their own panics; this only keeps rayon from aborting.
        .panic_handler(|_| {})
        .build()
        .map_err(|e| Error::new(format!("cannot start the emrs-dirdiff thread pool: {e}")))
}

enum Msg {
    Item(Item),
    /// The root of the comparison is complete; no item follows.
    Finished,
}

struct Job {
    pool: Arc<rayon::ThreadPool>,
    roots: Arc<Roots>,
    settings: Settings,
    token: CancelToken,
    stop: Arc<AtomicBool>,
    tx: SyncSender<Msg>,
    store: Arc<Mutex<Store>>,
    examined: AtomicU64,
}

impl Job {
    fn cancelled(&self) -> bool {
        self.stop.load(Ordering::Relaxed) || self.token.is_cancelled()
    }

    fn emit(&self, item: Item) {
        // Fails only once `run` has given up on the stream.
        let _ = self.tx.send(Msg::Item(item));
    }

    /// Count an identical non-directory entry of `node` and store it.
    fn same(&self, node: &DirNode, name: &OsStr, rel: &Path, kind: Kind, a: &Meta, b: &Meta) {
        node.same.fetch_add(1, Ordering::AcqRel);
        let item = Item::entry(rel, Some(kind), status::SAME, Some(a.into()), Some(b.into()));
        let mut store = self.store.lock().unwrap();
        // Checked under the lock: once the service has set `stop` and
        // cleared the store for a newer comparison, nothing more is added.
        if !self.stop.load(Ordering::SeqCst) {
            store.insert(&node.rel, name, item);
        }
    }

    fn abs(root: &Path, rel: &Path) -> PathBuf {
        if rel.as_os_str().is_empty() { root.to_path_buf() } else { root.join(rel) }
    }
}

/// A directory whose completion is counted: one present on both sides, or
/// the parent of a single entry being compared.
struct DirNode {
    rel: PathBuf,
    parent: Option<Arc<DirNode>>,
    /// Emit `done` on completion (false for the parent of a single entry,
    /// and for a directory that could not be read).
    report: AtomicBool,
    /// Outstanding work: the listing, file tasks, count tasks, subdirectories.
    pending: AtomicUsize,
    /// Identical non-directory entries below this directory.
    same: AtomicU64,
    a: Option<Side>,
    b: Option<Side>,
}

impl DirNode {
    fn new(rel: PathBuf, parent: Option<Arc<DirNode>>, report: bool, a: Option<Side>, b: Option<Side>) -> Arc<DirNode> {
        Arc::new(DirNode {
            rel,
            parent,
            report: AtomicBool::new(report),
            pending: AtomicUsize::new(1),
            same: AtomicU64::new(0),
            a,
            b,
        })
    }
}

/// Finish one unit of `node`'s work; on its last, report the directory
/// and continue with its parent.
fn complete(job: &Job, node: &Arc<DirNode>) {
    let mut node = node.clone();
    loop {
        if node.pending.fetch_sub(1, Ordering::AcqRel) != 1 {
            return;
        }
        let same = node.same.load(Ordering::Acquire);
        if node.report.load(Ordering::Acquire) {
            job.emit(Item::done(&node.rel, same));
        }
        match &node.parent {
            Some(parent) => {
                parent.same.fetch_add(same, Ordering::AcqRel);
                node = parent.clone();
            }
            None => {
                let _ = job.tx.send(Msg::Finished);
                return;
            }
        }
    }
}

/// What a task works on, for the error item it sends if it panics.
#[derive(Clone, Copy)]
enum Task {
    /// The listing of its owner directory, which then gets no `done`.
    Listing,
    /// An entry of its owner directory, of this kind if known.
    Entry(Option<Kind>),
}

/// Run `work` on the pool for `owner`, whose counter already includes it.
/// `work` returns false when it stopped because of cancellation; `owner`
/// is then left incomplete, which no longer matters.
fn submit(
    job: &Arc<Job>,
    owner: Arc<DirNode>,
    rel: PathBuf,
    task: Task,
    work: impl FnOnce(&Arc<Job>) -> bool + Send + 'static,
) {
    let job = job.clone();
    let pool = job.pool.clone();
    pool.spawn(move || {
        if job.cancelled() {
            return;
        }
        match catch_unwind(AssertUnwindSafe(|| work(&job))) {
            Ok(true) => complete(&job, &owner),
            Ok(false) => {}
            Err(_) => {
                let mut item = match task {
                    Task::Listing => {
                        owner.report.store(false, Ordering::Release);
                        Item::entry(&rel, Some(Kind::Dir), status::ERROR, owner.a, owner.b)
                    }
                    Task::Entry(kind) => Item::entry(&rel, kind, status::ERROR, None, None),
                };
                item.message = Some("internal error in emrs-dirdiff".into());
                job.emit(item);
                complete(&job, &owner);
            }
        }
    });
}

/// List one directory level of both sides and dispatch its entries.
///
/// A side that cannot be listed at all makes the directory one `error`
/// item without `done`. Entries that fail individually are left out: the
/// directory gets an `error` item saying so, its other entries are
/// compared, and it still gets its `done`.
fn dir_task(job: &Arc<Job>, node: &Arc<DirNode>, dir_a: &Path, dir_b: &Path, rules_a: &Rules, rules_b: &Rules) -> bool {
    #[cfg(test)]
    test_panic(&node.rel);
    let level = walk::list_level(dir_a, dir_b, rules_a, rules_b, &job.settings.walk);
    if job.cancelled() {
        return false;
    }
    if let Some(message) = level.error_a.or(level.error_b) {
        node.report.store(false, Ordering::Release);
        let mut item = Item::entry(&node.rel, Some(Kind::Dir), status::ERROR, node.a, node.b);
        item.message = Some(message);
        job.emit(item);
        return true;
    }
    if let Some(message) = level.partial_a.or(level.partial_b) {
        let mut item = Item::entry(&node.rel, Some(Kind::Dir), status::ERROR, node.a, node.b);
        item.message = Some(format!("some entries could not be read: {message}"));
        job.emit(item);
    }
    for pair in &level.pairs {
        if job.cancelled() {
            return false;
        }
        pair_task(job, node, dir_a, dir_b, rules_a, rules_b, pair);
    }
    true
}

/// Decide one entry of `node`, or start the task that will.
fn pair_task(
    job: &Arc<Job>,
    node: &Arc<DirNode>,
    dir_a: &Path,
    dir_b: &Path,
    rules_a: &Rules,
    rules_b: &Rules,
    pair: &Pair,
) {
    job.examined.fetch_add(1, Ordering::Relaxed);
    let rel = join_rel(&node.rel, &pair.name);
    let (pa, pb) = (dir_a.join(&pair.name), dir_b.join(&pair.name));
    match (&pair.a, &pair.b) {
        (EntrySide::Unreadable(message), other) | (other, EntrySide::Unreadable(message)) => {
            let mut item = Item::entry(&rel, kind_of(other), status::ERROR, side_of(&pair.a), side_of(&pair.b));
            item.message = Some(message.clone());
            job.emit(item);
        }
        (EntrySide::Present(ma), EntrySide::Absent) => one_sided(job, node, rel, pa, rules_a, ma, status::ONLY_A),
        (EntrySide::Absent, EntrySide::Present(mb)) => one_sided(job, node, rel, pb, rules_b, mb, status::ONLY_B),
        (EntrySide::Present(ma), EntrySide::Present(mb)) if ma.kind != mb.kind => {
            job.emit(Item::entry(&rel, Some(ma.kind), status::KIND, Some(ma.into()), Some(mb.into())));
        }
        (EntrySide::Present(ma), EntrySide::Present(mb)) => match ma.kind {
            Kind::Dir => {
                let child = DirNode::new(rel.clone(), Some(node.clone()), true, Some(ma.into()), Some(mb.into()));
                node.pending.fetch_add(1, Ordering::AcqRel);
                let (ra, rb) = (rules_a.clone(), rules_b.clone());
                let owner = child.clone();
                submit(job, owner, rel, Task::Listing, move |job| {
                    let opts = &job.settings.walk;
                    let (ca, cb) = (ra.child(&pa, opts), rb.child(&pb, opts));
                    dir_task(job, &child, &pa, &pb, &ca, &cb)
                });
            }
            Kind::File => {
                node.pending.fetch_add(1, Ordering::AcqRel);
                let (ma, mb, name) = (ma.clone(), mb.clone(), pair.name.clone());
                let owner = node.clone();
                let n = node.clone();
                let task = Task::Entry(Some(Kind::File));
                submit(job, owner, rel.clone(), task, move |job| file_task(job, &n, &name, &rel, &pa, &pb, &ma, &mb));
            }
            Kind::Link => {
                let same = match (&ma.link_target, &mb.link_target) {
                    (Some(ta), Some(tb)) => Ok(ta == tb),
                    _ => compare::compare_links(&pa, &pb),
                };
                match same {
                    Ok(true) => job.same(node, &pair.name, &rel, Kind::Link, ma, mb),
                    Ok(false) => {
                        job.emit(Item::entry(&rel, Some(Kind::Link), status::CHANGED, Some(ma.into()), Some(mb.into())))
                    }
                    Err(e) => error_item(job, &rel, Kind::Link, ma, mb, e),
                }
            }
            // Same kind of special file (different kinds were handled above).
            Kind::Other(special) => job.same(node, &pair.name, &rel, Kind::Other(special), ma, mb),
        },
        (EntrySide::Absent, EntrySide::Absent) => {}
    }
}

fn error_item(job: &Job, rel: &Path, kind: Kind, ma: &Meta, mb: &Meta, error: CompareError) {
    let message = match error {
        CompareError::Io(message) => message,
        CompareError::Cancelled => return,
    };
    let mut item = Item::entry(rel, Some(kind), status::ERROR, Some(ma.into()), Some(mb.into()));
    item.message = Some(message);
    job.emit(item);
}

/// An entry present on one side; a directory gets the count of its files.
fn one_sided(
    job: &Arc<Job>,
    node: &Arc<DirNode>,
    rel: PathBuf,
    path: PathBuf,
    rules: &Rules,
    meta: &Meta,
    status: &'static str,
) {
    let side = Some(Side::from(meta));
    let (a, b) = if status == status::ONLY_A { (side, None) } else { (None, side) };
    let mut item = Item::entry(&rel, Some(meta.kind), status, a, b);
    if meta.kind != Kind::Dir {
        job.emit(item);
        return;
    }
    node.pending.fetch_add(1, Ordering::AcqRel);
    let rules = rules.clone();
    submit(job, node.clone(), rel, Task::Entry(Some(Kind::Dir)), move |job| {
        let opts = &job.settings.walk;
        let files = walk::count_files(&path, &rules.child(&path, opts), opts, &|| job.cancelled());
        if job.cancelled() {
            return false;
        }
        item.files = Some(files);
        job.emit(item);
        true
    });
}

#[allow(clippy::too_many_arguments)]
fn file_task(
    job: &Arc<Job>,
    node: &DirNode,
    name: &OsStr,
    rel: &Path,
    pa: &Path,
    pb: &Path,
    ma: &Meta,
    mb: &Meta,
) -> bool {
    #[cfg(test)]
    test_panic(rel);
    let fa = FileMeta { size: ma.size, mtime: ma.mtime };
    let fb = FileMeta { size: mb.size, mtime: mb.mtime };
    match compare::compare_files(pa, pb, &fa, &fb, &job.settings.compare, &|| job.cancelled()) {
        Ok(Outcome::Same) => job.same(node, name, rel, Kind::File, ma, mb),
        Ok(Outcome::Changed { lines }) => {
            let mut item = Item::entry(rel, Some(Kind::File), status::CHANGED, Some(ma.into()), Some(mb.into()));
            item.lines = lines;
            job.emit(item);
        }
        Err(CompareError::Cancelled) => return false,
        Err(error) => error_item(job, rel, Kind::File, ma, mb, error),
    }
    true
}

/// Start the work for `rel`: the whole comparison for `""`, otherwise the
/// one entry `rel` in its parent directory. Only submits tasks, so `run`
/// drains the channel from the start.
fn begin(job: &Arc<Job>, rel: &Path) {
    let Some(name) = rel.file_name() else {
        let root = DirNode::new(PathBuf::new(), None, true, None, None);
        let roots = job.roots.clone();
        submit(job, root.clone(), PathBuf::new(), Task::Listing, move |job| {
            let opts = &job.settings.walk;
            let (ra, rb) = (Rules::root(&roots.a, opts), Rules::root(&roots.b, opts));
            dir_task(job, &root, &roots.a, &roots.b, &ra, &rb)
        });
        return;
    };
    let parent = rel.parent().unwrap_or(Path::new("")).to_path_buf();
    let top = DirNode::new(parent, None, false, None, None);
    let (rel, name) = (rel.to_path_buf(), name.to_os_string());
    let owner = top.clone();
    submit(job, owner, rel.clone(), Task::Entry(None), move |job| begin_entry(job, &top, &rel, &name));
}

/// List the parent `top` of the single entry `rel` (named `name`) and
/// decide the entry. A side whose path to the parent passes through
/// anything but real directories (a symbolic link, a file, a missing
/// component) is not read: the entry is absent there.
fn begin_entry(job: &Arc<Job>, top: &Arc<DirNode>, rel: &Path, name: &OsStr) -> bool {
    let opts = job.settings.walk;
    let roots = &job.roots;
    let (ra, real_a) = walk::rules_along(&roots.a, &top.rel, &opts);
    let (rb, real_b) = walk::rules_along(&roots.b, &top.rel, &opts);
    if job.cancelled() {
        return false;
    }
    let (pa, pb) = (Job::abs(&roots.a, &top.rel), Job::abs(&roots.b, &top.rel));
    let level = walk::list_level_in(&pa, &pb, real_a, real_b, &ra, &rb, &opts);
    if job.cancelled() {
        return false;
    }
    let pair = level.pairs.iter().find(|p| p.name == name);
    let absent = |side: fn(&Pair) -> &EntrySide| pair.is_none_or(|p| matches!(side(p), EntrySide::Absent));
    // A real parent that cannot be read, or whose failing entries may
    // include this one, makes the entry unknown on that side.
    let unreadable = level
        .error_a
        .or(level.error_b)
        .or(level.partial_a.filter(|_| absent(|p| &p.a)))
        .or(level.partial_b.filter(|_| absent(|p| &p.b)));
    if let Some(message) = unreadable {
        job.examined.fetch_add(1, Ordering::Relaxed);
        let kind = pair.and_then(|p| kind_of(&p.a).or(kind_of(&p.b)));
        let mut item = Item::entry(rel, kind, status::ERROR, None, None);
        item.message = Some(message);
        job.emit(item);
    } else if let Some(pair) = pair {
        pair_task(job, top, &pa, &pb, &ra, &rb, pair);
    }
    true
}

/// Queue `item` on the stream, waiting while it is full. False once the
/// call is cancelled or the comparison stopped.
fn forward(out: &StreamSender<Item>, mut item: Item, job: &Job) -> bool {
    loop {
        match out.try_send(item) {
            Ok(()) => return true,
            Err(TrySendError::Closed(_)) => return false,
            Err(TrySendError::Full(back)) => {
                if job.stop.load(Ordering::Relaxed) || job.token.wait_timeout(Duration::from_millis(1)) {
                    return false;
                }
                item = back;
            }
        }
    }
}

/// Compare the subtree or entry at `rel` and answer on `out`: the items,
/// then the summary. Blocks until the comparison is complete or stopped.
/// Stopped through `stop`, the stream ends failed with the message
/// [`CANCELLED`]; cancelled through its call, it is left to emrs.
pub fn run(
    pool: Arc<rayon::ThreadPool>,
    roots: Arc<Roots>,
    rel: PathBuf,
    settings: Settings,
    store: Arc<Mutex<Store>>,
    stop: Arc<AtomicBool>,
    out: StreamSender<Item>,
) {
    let started = Instant::now();
    let (tx, rx) = mpsc::sync_channel(CAPACITY);
    let job = Arc::new(Job { pool, roots, settings, token: out.token(), stop, tx, store, examined: AtomicU64::new(0) });
    begin(&job, &rel);
    let finished = loop {
        if job.cancelled() {
            break false;
        }
        match rx.recv_timeout(POLL) {
            Ok(Msg::Item(item)) => {
                if !forward(&out, item, &job) {
                    break false;
                }
            }
            Ok(Msg::Finished) => break true,
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break false,
        }
    };
    // Unblocks tasks waiting to send; they see the cancellation and stop.
    drop(rx);
    if finished {
        let summary = Item::summary(job.examined.load(Ordering::Relaxed), started.elapsed().as_secs_f64());
        if forward(&out, summary, &job) {
            out.finish();
            return;
        }
    }
    if !job.token.is_cancelled() {
        out.fail(Error::new(CANCELLED));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn same(path: &str) -> Item {
        Item::entry(Path::new(path), Some(Kind::File), status::SAME, None, None)
    }

    #[test]
    fn parse_rel_normalizes_and_refuses_escapes() {
        assert_eq!(parse_rel("").unwrap(), PathBuf::new());
        assert_eq!(parse_rel("a/./b/").unwrap(), PathBuf::from("a/b"));
        assert!(parse_rel("../x").is_err());
        assert!(parse_rel("a/../../x").is_err());
        assert!(parse_rel("/etc").is_err());
    }

    #[test]
    fn store_lists_sorted_and_drops_at_and_below() {
        let mut store = Store::default();
        for (dir, name) in [("", "z"), ("", "a"), ("", "sub"), ("sub", "x"), ("sub/deep", "y"), ("subx", "w")] {
            let rel = join_rel(Path::new(dir), OsStr::new(name));
            store.insert(Path::new(dir), OsStr::new(name), same(rel.to_str().unwrap()));
        }
        let paths = |items: Vec<Item>| items.into_iter().map(|i| i.path.unwrap()).collect::<Vec<_>>();
        assert_eq!(paths(store.same_in(Path::new(""))), ["a", "sub", "z"]);
        assert!(store.same_in(Path::new("nowhere")).is_empty());
        store.drop_at(Path::new("sub"));
        assert_eq!(paths(store.same_in(Path::new(""))), ["a", "z"], "the entry itself in its parent");
        assert!(store.same_in(Path::new("sub")).is_empty());
        assert!(store.same_in(Path::new("sub/deep")).is_empty());
        assert_eq!(paths(store.same_in(Path::new("subx"))), ["subx/w"], "a sibling with a common prefix stays");
        store.drop_at(Path::new(""));
        assert!(store.same_in(Path::new("")).is_empty() && store.same_in(Path::new("subx")).is_empty());
    }
}
