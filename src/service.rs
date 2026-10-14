//! The `dirdiff` service. One instance per comparison buffer, started with
//! `(:a "/abs/dir/a" :b "/abs/dir/b")`; both must be existing directories,
//! otherwise the start fails with a message naming the path.
//!
//! Requests (spec, "The service"): `:compare` answers with a stream run by
//! [`session::run`] on a thread of its own, so `handle` returns at once;
//! `:same` answers from the instance's result store; `:cancel` stops the
//! running comparison. A new `:compare`, `:cancel` and stopping the
//! instance stop the running comparison.

use emrs::{Context, Error, Reply, Service};
use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use crate::session::{self, Roots, Settings, Store};
use crate::{compare, walk};

/// Start arguments: `(:a "/abs/dir/a" :b "/abs/dir/b")`.
#[derive(Debug, Clone, Deserialize)]
pub struct Args {
    /// Existing directory: side A.
    pub a: String,
    /// Existing directory: side B.
    pub b: String,
}

/// How a pair of files is compared: bare keywords `:content` and `:size-time`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Default)]
pub enum By {
    #[default]
    Content,
    SizeTime,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Deserialize)]
pub enum Request {
    /// `(:compare :path P :by content|size-time :ignore-files BOOL :whitespace BOOL :hidden BOOL)`.
    Compare {
        #[serde(default)]
        path: String,
        #[serde(default)]
        by: By,
        #[serde(default = "default_true")]
        ignore_files: bool,
        #[serde(default)]
        whitespace: bool,
        #[serde(default = "default_true")]
        hidden: bool,
    },
    /// `(:same :dir P)`.
    Same { dir: String },
    /// `(:cancel)`.
    Cancel,
}

pub struct DirdiffService {
    roots: Arc<Roots>,
    /// Identical entries of the comparisons so far, for `:same`.
    store: Arc<Mutex<Store>>,
    /// The stop flag of the comparison started last.
    running: Option<Arc<AtomicBool>>,
    /// This instance's thread pool, dropped when the instance stops.
    pool: Option<Arc<rayon::ThreadPool>>,
}

impl DirdiffService {
    fn stop_running(&mut self) {
        if let Some(stop) = self.running.take() {
            stop.store(true, Ordering::SeqCst);
        }
    }
}

fn check_dir(side: &str, path: &str) -> Result<(), Error> {
    if Path::new(path).is_dir() {
        Ok(())
    } else {
        Err(Error::new(format!("directory {side} is not an existing directory: {path}")))
    }
}

impl Service for DirdiffService {
    const NAME: &'static str = "dirdiff";
    type Args = Args;
    type Request = Request;
    type Event = ();

    fn start(args: Args, _: &Context<Self>) -> Result<Self, Error> {
        check_dir("A", &args.a)?;
        check_dir("B", &args.b)?;
        let roots = Roots { a: PathBuf::from(args.a), b: PathBuf::from(args.b) };
        let pool = Arc::new(session::new_pool()?);
        Ok(DirdiffService { roots: Arc::new(roots), store: Arc::default(), running: None, pool: Some(pool) })
    }

    fn handle(&mut self, request: Request, reply: Reply, ctx: &Context<Self>) {
        match request {
            Request::Compare { path, by, ignore_files, whitespace, hidden } => {
                let rel = match session::parse_rel(&path) {
                    Ok(rel) => rel,
                    Err(error) => return reply.err(error),
                };
                let Some(pool) = self.pool.clone() else {
                    return reply.err(Error::new("the instance is stopping"));
                };
                self.stop_running();
                // After the old comparison's flag is set, so it adds nothing more.
                self.store.lock().unwrap().drop_at(&rel);
                let stop = Arc::new(AtomicBool::new(false));
                self.running = Some(stop.clone());
                let settings = Settings {
                    walk: walk::Options { ignore_files, hidden },
                    compare: compare::Options { by, whitespace },
                };
                let out = reply.stream(session::CAPACITY);
                let (roots, store) = (self.roots.clone(), self.store.clone());
                ctx.spawn(move |_| session::run(pool, roots, rel, settings, store, stop, out));
            }
            Request::Same { dir } => match session::parse_rel(&dir) {
                Ok(rel) => reply.ok(self.store.lock().unwrap().same_in(&rel)),
                Err(error) => reply.err(error),
            },
            Request::Cancel => {
                self.stop_running();
                reply.ok(());
            }
        }
    }

    fn stop(&mut self) {
        self.stop_running();
        // Its threads end once the stopped comparison's tasks have returned.
        self.pool = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use emrs::State;
    use emrs::testing::Host;
    use tempfile::TempDir;

    fn args(a: &Path, b: &Path) -> Args {
        Args { a: a.to_str().unwrap().into(), b: b.to_str().unwrap().into() }
    }

    #[test]
    fn start_on_missing_directory_fails_naming_the_path() {
        let t = TempDir::new().unwrap();
        let missing = t.path().join("missing");
        for (a, b) in [(missing.as_path(), t.path()), (t.path(), missing.as_path())] {
            let mut host = Host::<DirdiffService>::start(args(a, b));
            let (state, error) = host.wait_exit();
            assert_eq!(state, State::Failed);
            let message = error.expect("a start error").to_string();
            assert!(message.contains(missing.to_str().unwrap()), "{message}");
        }
    }

    use crate::session::Item;
    use emrs::StreamEnd;
    use emrs::testing::StreamResult;
    use std::collections::HashMap;
    use std::fs;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::time::{Duration, Instant};

    struct Trees {
        _tmp: TempDir,
        a: PathBuf,
        b: PathBuf,
    }

    impl Trees {
        fn new() -> Trees {
            let tmp = TempDir::new().unwrap();
            let (a, b) = (tmp.path().join("a"), tmp.path().join("b"));
            fs::create_dir(&a).unwrap();
            fs::create_dir(&b).unwrap();
            Trees { _tmp: tmp, a, b }
        }

        fn host(&self) -> Host<DirdiffService> {
            Host::<DirdiffService>::start(args(&self.a, &self.b))
        }
    }

    fn put(dir: &Path, rel: &str, content: &str) {
        let p = dir.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, content).unwrap();
    }

    fn both(t: &Trees, rel: &str, content: &str) {
        put(&t.a, rel, content);
        put(&t.b, rel, content);
    }

    /// A tree with one entry of every status, nested directories and links.
    fn fixture() -> Trees {
        let t = Trees::new();
        both(&t, "same.txt", "same\n");
        put(&t.a, "changed.txt", "a\nb\nc\n");
        put(&t.b, "changed.txt", "a\nB\nc\nd\n");
        put(&t.a, "only_a.txt", "x");
        for f in ["onlyb_dir/f1", "onlyb_dir/f2", "onlyb_dir/g/f3"] {
            put(&t.b, f, "x");
        }
        put(&t.a, "kind", "k");
        put(&t.b, "kind/inner", "k");
        for d in [&t.a, &t.b] {
            symlink("same.txt", d.join("link_same")).unwrap();
        }
        symlink("same.txt", t.a.join("link_diff")).unwrap();
        symlink("changed.txt", t.b.join("link_diff")).unwrap();
        both(&t, "sub/same2", "s");
        put(&t.a, "sub/changed2", "1");
        put(&t.b, "sub/changed2", "2");
        both(&t, "sub/deep/same3", "d");
        t
    }

    fn compare(path: &str) -> Request {
        Request::Compare { path: path.into(), by: By::Content, ignore_files: true, whitespace: false, hidden: true }
    }

    fn same(dir: &str) -> Request {
        Request::Same { dir: dir.into() }
    }

    /// Check that the stream ended well with the summary last; return the
    /// other items by path (each path at most once) and the summary.
    fn split(result: StreamResult<Item>) -> (HashMap<String, Item>, Item) {
        assert_eq!(result.status, StreamEnd::Done, "{:?}", result.error.map(|e| e.to_string()));
        let mut items = result.items;
        let summary = items.pop().expect("a summary");
        assert_eq!(summary.summary, Some(true));
        assert!(summary.seconds.is_some_and(|s| s >= 0.0));
        let mut by_path = HashMap::new();
        for item in items {
            assert_eq!(item.summary, None);
            let path = item.path.clone().expect("a path");
            assert!(by_path.insert(path.clone(), item).is_none(), "{path} sent twice");
        }
        (by_path, summary)
    }

    fn status(items: &HashMap<String, Item>, path: &str) -> &'static str {
        items.get(path).unwrap_or_else(|| panic!("no item for {path}")).status.unwrap()
    }

    fn paths(items: &[Item]) -> Vec<&str> {
        items.iter().map(|i| i.path.as_deref().unwrap()).collect()
    }

    #[test]
    fn compare_reports_every_status_and_done_counts() {
        let t = fixture();
        let mut host = t.host();
        let result = host.call_stream::<Item>(compare("")).unwrap();
        let last_but_one = result.items[result.items.len() - 2].clone();
        let (items, summary) = split(result);
        assert_eq!(last_but_one.path.as_deref(), Some(""), "the root's done comes right before the summary");

        let changed = &items["changed.txt"];
        assert_eq!((changed.kind, changed.status), (Some("file"), Some("changed")));
        assert_eq!(changed.lines, Some((2, 1)));
        assert_eq!(changed.a.map(|s| s.size), Some(6));
        assert_eq!(changed.b.map(|s| s.size), Some(8));
        assert!(changed.a.unwrap().mtime > 1.0e9);

        let only_a = &items["only_a.txt"];
        assert_eq!((only_a.kind, only_a.status), (Some("file"), Some("only-a")));
        assert!(only_a.a.is_some() && only_a.b.is_none());

        let only_b = &items["onlyb_dir"];
        assert_eq!((only_b.kind, only_b.status, only_b.files), (Some("dir"), Some("only-b"), Some(3)));
        assert!(only_b.a.is_none() && only_b.b.is_some());
        assert!(!items.keys().any(|p| p.starts_with("onlyb_dir/")), "no items below a one-sided directory");

        let kind = &items["kind"];
        assert_eq!((kind.kind, kind.status), (Some("file"), Some("kind")));
        assert!(!items.contains_key("kind/inner"));

        assert_eq!((items["link_diff"].kind, status(&items, "link_diff")), (Some("link"), "changed"));
        assert_eq!(status(&items, "sub/changed2"), "changed");
        assert_eq!(items["sub/changed2"].lines, Some((1, 1)));

        for (dir, n) in [("", 4), ("sub", 2), ("sub/deep", 1)] {
            let done = &items[dir];
            assert_eq!((done.kind, done.status, done.same), (Some("dir"), Some("done"), Some(n)), "{dir}");
        }
        for identical in ["same.txt", "link_same", "sub/same2", "sub/deep/same3"] {
            assert!(!items.contains_key(identical), "{identical} is identical and must not be sent");
        }
        assert_eq!(items.len(), 9);
        // root: 8 entries, sub: 3, sub/deep: 1
        assert_eq!(summary.files, Some(12));
    }

    #[test]
    fn same_lists_the_identical_entries_of_a_directory_sorted() {
        let t = fixture();
        both(&t, "a_first", "1");
        let mut host = t.host();
        assert!(host.call::<Vec<Item>>(same("")).unwrap().is_empty(), "nothing known before a comparison");
        split(host.call_stream::<Item>(compare("")).unwrap());

        let root = host.call::<Vec<Item>>(same("")).unwrap();
        assert_eq!(paths(&root), ["a_first", "link_same", "same.txt"]);
        let s = &root[2];
        assert_eq!((s.kind, s.status), (Some("file"), Some("same")));
        assert_eq!(s.a.map(|m| m.size), Some(5));
        assert!(s.b.is_some());
        assert_eq!(root[1].kind, Some("link"));
        assert_eq!(paths(&host.call::<Vec<Item>>(same("sub")).unwrap()), ["sub/same2"]);
        assert_eq!(paths(&host.call::<Vec<Item>>(same("sub/deep/")).unwrap()), ["sub/deep/same3"]);
        assert!(host.call::<Vec<Item>>(same("nowhere")).unwrap().is_empty());
        assert!(host.call::<Vec<Item>>(same("../x")).is_err());
    }

    #[test]
    fn unreadable_directory_is_one_error_item() {
        let t = fixture();
        both(&t, "locked/f", "x");
        let locked = t.a.join("locked");
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
        if fs::read_dir(&locked).is_ok() {
            // running as root: permissions are not enforced
            fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
            return;
        }
        let mut host = t.host();
        let result = host.call_stream::<Item>(compare(""));
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
        let (items, _) = split(result.unwrap());
        let error = &items["locked"];
        assert_eq!((error.kind, error.status), (Some("dir"), Some("error")));
        assert!(error.message.as_deref().is_some_and(|m| !m.is_empty()));
        assert!(error.a.is_some() && error.b.is_some());
        assert!(!items.contains_key("locked/f"));
        assert_eq!(items[""].same, Some(4), "the root still completes");
    }

    #[test]
    fn size_time_and_whitespace_options_reach_the_comparison() {
        let t = Trees::new();
        put(&t.a, "ws.txt", "a b\n");
        put(&t.b, "ws.txt", "a  b\n");
        let mut host = t.host();
        let (items, _) = split(host.call_stream::<Item>(compare("")).unwrap());
        assert_eq!(status(&items, "ws.txt"), "changed");
        let ws =
            Request::Compare { path: "".into(), by: By::Content, ignore_files: true, whitespace: true, hidden: true };
        let (items, _) = split(host.call_stream::<Item>(ws).unwrap());
        assert!(!items.contains_key("ws.txt"));
        let hidden = Request::Compare {
            path: "".into(),
            by: By::SizeTime,
            ignore_files: true,
            whitespace: false,
            hidden: false,
        };
        put(&t.a, ".h", "1");
        let (items, summary) = split(host.call_stream::<Item>(hidden).unwrap());
        assert!(!items.contains_key(".h"));
        assert_eq!(status(&items, "ws.txt"), "changed", "sizes differ");
        assert_eq!(summary.files, Some(1));
    }

    #[test]
    fn rescan_of_a_directory_replaces_its_results() {
        let t = fixture();
        let mut host = t.host();
        split(host.call_stream::<Item>(compare("")).unwrap());
        put(&t.b, "sub/same2", "now different");
        put(&t.a, "sub/new", "n");
        put(&t.b, "sub/changed2", "1");

        let (items, summary) = split(host.call_stream::<Item>(compare("sub")).unwrap());
        assert_eq!(status(&items, "sub/same2"), "changed");
        assert_eq!(status(&items, "sub/new"), "only-a");
        assert!(!items.contains_key("sub/changed2"), "now identical");
        assert_eq!((items["sub"].status, items["sub"].same), (Some("done"), Some(2)));
        assert_eq!(items["sub/deep"].same, Some(1));
        assert!(items.keys().all(|p| p.starts_with("sub")), "{:?}", items.keys());
        assert_eq!(items.len(), 4);
        // sub itself, its 4 entries, and deep/same3
        assert_eq!(summary.files, Some(6));

        assert_eq!(paths(&host.call::<Vec<Item>>(same("sub")).unwrap()), ["sub/changed2"]);
        assert_eq!(paths(&host.call::<Vec<Item>>(same("sub/deep")).unwrap()), ["sub/deep/same3"]);
        assert_eq!(paths(&host.call::<Vec<Item>>(same("")).unwrap()), ["link_same", "same.txt"]);
    }

    #[test]
    fn rescan_of_single_entries() {
        let t = fixture();
        let mut host = t.host();
        split(host.call_stream::<Item>(compare("")).unwrap());

        // An identical file that changed: replaced in the store.
        put(&t.b, "same.txt", "other\n");
        let (items, summary) = split(host.call_stream::<Item>(compare("same.txt")).unwrap());
        assert_eq!(items.keys().collect::<Vec<_>>(), ["same.txt"]);
        assert_eq!(status(&items, "same.txt"), "changed");
        assert_eq!(summary.files, Some(1));
        assert_eq!(paths(&host.call::<Vec<Item>>(same("")).unwrap()), ["link_same"]);

        // A changed file made identical (as after a copy): stored, not sent.
        fs::copy(t.a.join("sub/changed2"), t.b.join("sub/changed2")).unwrap();
        let (items, _) = split(host.call_stream::<Item>(compare("sub/changed2")).unwrap());
        assert!(items.is_empty());
        assert_eq!(paths(&host.call::<Vec<Item>>(same("sub")).unwrap()), ["sub/changed2", "sub/same2"]);

        // An entry gone from both sides: nothing.
        fs::remove_file(t.a.join("only_a.txt")).unwrap();
        let (items, summary) = split(host.call_stream::<Item>(compare("only_a.txt")).unwrap());
        assert!(items.is_empty());
        assert_eq!(summary.files, Some(0));

        // A one-sided directory: one item with its file count, no done.
        let (items, _) = split(host.call_stream::<Item>(compare("onlyb_dir")).unwrap());
        assert_eq!(items.len(), 1);
        assert_eq!((status(&items, "onlyb_dir"), items["onlyb_dir"].files), ("only-b", Some(3)));

        // A one-sided directory copied over: compared as a directory.
        for f in ["onlyb_dir/f1", "onlyb_dir/f2", "onlyb_dir/g/f3"] {
            put(&t.a, f, "x");
        }
        let (items, _) = split(host.call_stream::<Item>(compare("onlyb_dir")).unwrap());
        assert_eq!(items.len(), 2);
        assert_eq!((items["onlyb_dir"].status, items["onlyb_dir"].same), (Some("done"), Some(3)));
        assert_eq!(items["onlyb_dir/g"].same, Some(1));
        assert_eq!(paths(&host.call::<Vec<Item>>(same("onlyb_dir")).unwrap()), ["onlyb_dir/f1", "onlyb_dir/f2"]);

        let bad = host.call_stream::<Item>(compare("../escape")).unwrap();
        assert_eq!(bad.status, StreamEnd::Failed);
    }

    /// Trees with `n` changed files in directories of 100, so that the
    /// stream fills up and the comparison waits for the host to drain it.
    fn many_changed(n: usize) -> Trees {
        let t = Trees::new();
        for i in 0..n {
            let rel = format!("d{}/f{i}", i / 100);
            put(&t.a, &rel, "a\n");
            put(&t.b, &rel, "b\n");
        }
        t
    }

    fn assert_cancelled(result: &StreamResult<Item>) {
        assert_eq!(result.status, StreamEnd::Failed);
        assert_eq!(result.error.as_ref().map(|e| e.message().to_string()).as_deref(), Some(session::CANCELLED));
        assert!(result.items.iter().all(|i| i.summary.is_none()));
    }

    #[test]
    fn a_second_compare_cancels_the_first() {
        let t = many_changed(2000);
        let mut host = t.host();
        // Nothing drains before both are queued: the first is still running.
        let first = host.begin_stream(compare("")).unwrap();
        let second = host.begin_stream(compare("")).unwrap();
        assert_cancelled(&host.finish_stream::<Item>(first));
        let (items, summary) = split(host.finish_stream::<Item>(second));
        assert_eq!(items.values().filter(|i| i.status == Some("changed")).count(), 2000);
        assert_eq!(summary.files, Some(2020));
    }

    #[test]
    fn cancel_ends_the_running_stream() {
        let t = many_changed(2000);
        let mut host = t.host();
        assert!(host.call::<()>(Request::Cancel).is_ok(), "nothing running: answered nil");
        let call = host.begin_stream(compare("")).unwrap();
        host.send(Request::Cancel);
        assert_cancelled(&host.finish_stream::<Item>(call));
        // The instance keeps working.
        let (items, _) = split(host.call_stream::<Item>(compare("d0")).unwrap());
        assert_eq!(items.len(), 101);
    }

    #[test]
    fn emrs_cancel_and_stop_end_the_work() {
        let t = many_changed(2000);
        let mut host = t.host();
        let call = host.begin_stream(compare("")).unwrap();
        host.cancel(call);
        let (items, _) = split(host.call_stream::<Item>(compare("d1")).unwrap());
        assert_eq!(items.len(), 101);

        let call = host.begin_stream(compare("")).unwrap();
        let started = Instant::now();
        assert_eq!(host.stop(), State::Stopped);
        assert!(started.elapsed() < Duration::from_secs(1));
        let result = host.finish_stream::<Item>(call);
        assert_eq!(result.status, StreamEnd::Failed);
        assert_eq!(result.error.map(|e| e.kind()), Some(emrs::ErrorKind::Stopped));
    }

    /// Two trees of `n` files, 1 % of them changed, 4 KiB each.
    fn generated(n: usize) -> Trees {
        let t = Trees::new();
        let body = "0123456789abcdef\n".repeat(240);
        for i in 0..n {
            let rel = format!("d{}/e{}/f{i}.txt", i / 2000, (i / 100) % 20);
            put(&t.a, &rel, &body);
            if i % 100 == 0 {
                put(&t.b, &rel, &format!("{body}changed\n"));
            } else {
                put(&t.b, &rel, &body);
            }
        }
        t
    }

    #[test]
    fn cancel_latency_on_a_large_tree() {
        let t = generated(20_000);
        let mut host = t.host();
        let call = host.begin_stream(compare("")).unwrap();
        let running = Instant::now();
        while running.elapsed() < Duration::from_millis(30) {
            host.items_received(call);
            std::thread::sleep(Duration::from_millis(1));
        }
        let received = host.items_received(call);
        let started = Instant::now();
        host.send(Request::Cancel);
        let result = host.finish_stream::<Item>(call);
        let latency = started.elapsed();
        // Ended by the cancel, so it was still running.
        assert_cancelled(&result);
        eprintln!("cancel latency: {latency:?} after {received} items");
        assert!(latency < Duration::from_millis(100), "{latency:?}");
    }

    #[test]
    fn a_blocked_instance_does_not_hold_up_another() {
        // More changed files than the stream and the channel hold: while
        // nothing drains the first stream, its tasks block on the channel.
        let big = many_changed(2000);
        let mut first = big.host();
        let call = first.begin_stream(compare("")).unwrap();
        std::thread::sleep(Duration::from_millis(300));
        let small = fixture();
        let mut second = small.host();
        let started = Instant::now();
        let (items, _) = split(second.call_stream::<Item>(compare("")).unwrap());
        let took = started.elapsed();
        assert_eq!(items.len(), 9);
        assert!(took < Duration::from_secs(2), "{took:?}");
        // The first was still waiting: at most what the stream holds arrived.
        let received = first.items_received(call);
        assert!(received <= session::CAPACITY, "{received}");
        assert_eq!(first.stop(), State::Stopped);
    }

    #[test]
    fn rescans_do_not_read_through_symlinked_parents() {
        let t = fixture();
        let outside = TempDir::new().unwrap();
        put(outside.path(), "secret", "s");
        put(outside.path(), "sub/inner", "i");
        symlink(outside.path(), t.a.join("link")).unwrap();
        let mut host = t.host();
        let (items, _) = split(host.call_stream::<Item>(compare("")).unwrap());
        assert_eq!((items["link"].kind, items["link"].status), (Some("link"), Some("only-a")));
        assert!(!items.keys().any(|p| p.starts_with("link/")));
        for path in ["link/secret", "link/sub", "link/sub/inner", "same.txt/x"] {
            let (items, summary) = split(host.call_stream::<Item>(compare(path)).unwrap());
            assert!(items.is_empty(), "{path}: {:?}", items.keys());
            assert_eq!(summary.files, Some(0), "{path}");
        }
        // B has a real directory there: the entry is only in B, A is not read.
        put(&t.b, "link/secret", "b");
        put(&t.b, "link/sub/inner", "i");
        let (items, _) = split(host.call_stream::<Item>(compare("link/secret")).unwrap());
        assert_eq!(items.keys().collect::<Vec<_>>(), ["link/secret"]);
        assert_eq!(status(&items, "link/secret"), "only-b");
        let (items, _) = split(host.call_stream::<Item>(compare("link/sub")).unwrap());
        assert_eq!((status(&items, "link/sub"), items["link/sub"].files), ("only-b", Some(1)));
    }

    #[test]
    fn a_panicking_task_sends_one_error_item() {
        let t = fixture();
        let dir = format!("sub/{}", session::TEST_PANIC);
        both(&t, &format!("{dir}/f"), "x");
        put(&t.a, session::TEST_PANIC, "1");
        put(&t.b, session::TEST_PANIC, "2");
        let mut host = t.host();
        // `split` also checks that no path is sent twice.
        let (items, _) = split(host.call_stream::<Item>(compare("")).unwrap());
        let error = &items[&dir];
        assert_eq!((error.kind, error.status), (Some("dir"), Some("error")));
        assert!(error.message.is_some());
        let error = &items[session::TEST_PANIC];
        assert_eq!((error.kind, error.status), (Some("file"), Some("error")));
        assert!(!items.contains_key(&format!("{dir}/f")));
        assert_eq!((items["sub"].status, items["sub"].same), (Some("done"), Some(2)), "the parent completes");
        assert_eq!(items[""].status, Some("done"));
    }

    fn mkfifo(path: &Path) {
        assert!(std::process::Command::new("mkfifo").arg(path).status().unwrap().success());
    }

    #[test]
    fn special_files_compare_by_kind() {
        let t = Trees::new();
        mkfifo(&t.a.join("fifo"));
        mkfifo(&t.b.join("fifo"));
        mkfifo(&t.a.join("mixed"));
        let _socket = std::os::unix::net::UnixListener::bind(t.b.join("mixed")).unwrap();
        let mut host = t.host();
        let (items, _) = split(host.call_stream::<Item>(compare("")).unwrap());
        assert!(!items.contains_key("fifo"), "two fifos are the same");
        assert_eq!((items["mixed"].kind, items["mixed"].status), (Some("other"), Some("kind")));
        let same = host.call::<Vec<Item>>(same("")).unwrap();
        assert_eq!(paths(&same), ["fifo"]);
        assert_eq!(same[0].kind, Some("other"));
    }

    /// Times a full comparison of two existing trees, given as
    /// DIRDIFF_BENCH_A and DIRDIFF_BENCH_B (see bench/make-trees.sh):
    /// `cargo test --release --lib bench_compare -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn bench_compare() {
        let (Ok(a), Ok(b)) = (std::env::var("DIRDIFF_BENCH_A"), std::env::var("DIRDIFF_BENCH_B")) else {
            panic!("set DIRDIFF_BENCH_A and DIRDIFF_BENCH_B");
        };
        let by = match std::env::var("DIRDIFF_BENCH_BY").as_deref() {
            Ok("size-time") => By::SizeTime,
            _ => By::Content,
        };
        for run in 1..=2 {
            let mut host = Host::<DirdiffService>::start(Args { a: a.clone(), b: b.clone() })
                .with_timeout(Duration::from_secs(600));
            let started = Instant::now();
            let request = Request::Compare { path: "".into(), by, ignore_files: true, whitespace: false, hidden: true };
            let (items, summary) = split(host.call_stream::<Item>(request).unwrap());
            let mut counts: HashMap<&str, usize> = HashMap::new();
            for item in items.values() {
                *counts.entry(item.status.unwrap()).or_default() += 1;
            }
            eprintln!(
                "run {run}: {:.3} s wall, {:.3} s in the module, {} entries, {counts:?}",
                started.elapsed().as_secs_f64(),
                summary.seconds.unwrap(),
                summary.files.unwrap()
            );
        }
    }
}
