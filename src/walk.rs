//! Listing and pairing one directory level of both sides (task 2).
//!
//! The caller recurses: it lists one level of a directory pair with
//! [`list_level`], then descends into directories present on both sides
//! with [`Rules::child`]. Everything here is `Send + Sync` and cheap to
//! clone, so levels can be processed concurrently.

use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::UNIX_EPOCH;

use ignore::Match;
use ignore::gitignore::{Gitignore, GitignoreBuilder};

/// Walk options that affect listing.
#[derive(Clone, Copy, Debug)]
pub struct Options {
    /// Apply `.gitignore`, `.ignore` and the global git excludes.
    pub ignore_files: bool,
    /// List names starting with `.`.
    pub hidden: bool,
}

/// The kind of a directory entry, symbolic links not followed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// A regular file.
    File,
    /// A directory.
    Dir,
    /// A symbolic link.
    Link,
    /// A special file: a fifo, socket or device.
    Other(Special),
}

/// The kind of a special file. Two special files are the same when their
/// kinds are; different kinds compare as a kind difference.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Special {
    Fifo,
    Socket,
    BlockDevice,
    CharDevice,
    /// Anything else, and every special file on platforms other than Unix.
    Unknown,
}

#[cfg(unix)]
fn special(ft: &fs::FileType) -> Special {
    use std::os::unix::fs::FileTypeExt;
    if ft.is_fifo() {
        Special::Fifo
    } else if ft.is_socket() {
        Special::Socket
    } else if ft.is_block_device() {
        Special::BlockDevice
    } else if ft.is_char_device() {
        Special::CharDevice
    } else {
        Special::Unknown
    }
}

#[cfg(not(unix))]
fn special(_: &fs::FileType) -> Special {
    Special::Unknown
}

/// Metadata of one entry.
#[derive(Clone, Debug, PartialEq)]
pub struct Meta {
    /// What the entry is.
    pub kind: Kind,
    /// Size in bytes; 0 for directories.
    pub size: u64,
    /// Modification time in seconds since the Unix epoch.
    pub mtime: f64,
    /// Target of a symbolic link (unresolved), `None` for other kinds.
    pub link_target: Option<PathBuf>,
}

/// One side of a [`Pair`].
#[derive(Clone, Debug, PartialEq)]
pub enum EntrySide {
    /// No entry of this name on this side.
    Absent,
    /// The entry and its metadata.
    Present(Meta),
    /// The entry exists but its metadata could not be read (OS message).
    Unreadable(String),
}

/// An entry name with what each side has under it.
#[derive(Clone, Debug, PartialEq)]
pub struct Pair {
    /// The entry name, without any directory part.
    pub name: OsString,
    /// Side A.
    pub a: EntrySide,
    /// Side B.
    pub b: EntrySide,
}

/// The result of listing one directory level of both sides.
#[derive(Clone, Debug, Default)]
pub struct Level {
    /// Paired entries sorted by name (byte order).
    pub pairs: Vec<Pair>,
    /// Why directory A could not be read, if it could not.
    pub error_a: Option<String>,
    /// Why directory B could not be read, if it could not.
    pub error_b: Option<String>,
    /// Why some entries of directory A could not be read; the others are paired.
    pub partial_a: Option<String>,
    /// Why some entries of directory B could not be read; the others are paired.
    pub partial_b: Option<String>,
}

struct Node {
    parent: Option<Arc<Node>>,
    matcher: Gitignore,
}

/// Ignore rules in force for one directory: the global excludes and the
/// ignore files of the root down to that directory. Cheap to clone.
#[derive(Clone, Default)]
pub struct Rules {
    head: Option<Arc<Node>>,
}

impl Rules {
    /// Rules for the root directory: global git excludes plus the root's
    /// own ignore files. Empty when `opts.ignore_files` is false.
    pub fn root(root: &Path, opts: &Options) -> Rules {
        Self::root_with(root, opts, true)
    }

    /// Like [`Rules::root`], choosing whether the global excludes are read
    /// (tests turn them off to be independent of the user's git config).
    pub(crate) fn root_with(root: &Path, opts: &Options, global: bool) -> Rules {
        if !opts.ignore_files {
            return Rules::default();
        }
        let mut rules = Rules::default();
        if global {
            let (matcher, _err) = Gitignore::global();
            rules.head = Some(Arc::new(Node { parent: None, matcher }));
        }
        rules.child(root, opts)
    }

    /// Rules for `dir`: these rules plus `dir/.gitignore` and
    /// `dir/.ignore` (the latter wins). Unparsable lines are ignored.
    pub fn child(&self, dir: &Path, opts: &Options) -> Rules {
        if !opts.ignore_files {
            return self.clone();
        }
        let mut builder = GitignoreBuilder::new(dir);
        for file in [".gitignore", ".ignore"] {
            let path = dir.join(file);
            if path.is_file() {
                let _ = builder.add(path);
            }
        }
        match builder.build() {
            Ok(matcher) if !matcher.is_empty() => {
                Rules { head: Some(Arc::new(Node { parent: self.head.clone(), matcher })) }
            }
            _ => self.clone(),
        }
    }

    /// Whether `path` (absolute, below the directory these rules were
    /// built for) is ignored. The deepest matching rule decides.
    fn is_ignored(&self, path: &Path, is_dir: bool) -> bool {
        let mut node = self.head.as_deref();
        while let Some(n) = node {
            match n.matcher.matched(path, is_dir) {
                Match::Ignore(_) => return true,
                Match::Whitelist(_) => return false,
                Match::None => {}
            }
            node = n.parent.as_deref();
        }
        false
    }
}

/// Join a relative path (`/` separated, empty for the root) and an entry
/// name without loss for non-UTF-8 names.
pub fn join_rel(parent: &Path, name: &OsStr) -> PathBuf {
    if parent.as_os_str().is_empty() {
        return PathBuf::from(name);
    }
    let mut s = parent.as_os_str().to_os_string();
    s.push("/");
    s.push(name);
    PathBuf::from(s)
}

fn read_meta(path: &Path) -> EntrySide {
    let md = match fs::symlink_metadata(path) {
        Ok(md) => md,
        Err(e) => return EntrySide::Unreadable(e.to_string()),
    };
    let ft = md.file_type();
    let kind = if ft.is_symlink() {
        Kind::Link
    } else if ft.is_dir() {
        Kind::Dir
    } else if ft.is_file() {
        Kind::File
    } else {
        Kind::Other(special(&ft))
    };
    let mtime = match md.modified() {
        Ok(t) => match t.duration_since(UNIX_EPOCH) {
            Ok(d) => d.as_secs_f64(),
            Err(e) => -e.duration().as_secs_f64(),
        },
        Err(_) => 0.0,
    };
    let link_target = if kind == Kind::Link { fs::read_link(path).ok() } else { None };
    EntrySide::Present(Meta { kind, size: if kind == Kind::Dir { 0 } else { md.len() }, mtime, link_target })
}

fn kind_of(side: &EntrySide) -> Option<Kind> {
    match side {
        EntrySide::Present(m) => Some(m.kind),
        _ => None,
    }
}

/// One side of a directory level as listed.
#[derive(Default)]
struct Listing {
    entries: BTreeMap<OsString, EntrySide>,
    /// Why the directory could not be read at all.
    error: Option<String>,
    /// Why some entries could not be read (the first such error); the
    /// entries that could be read are in `entries`.
    partial: Option<String>,
}

/// List one side: name -> entry. Skips `.git` and, unless `opts.hidden`,
/// dot names.
fn list_side(dir: &Path, opts: &Options) -> Listing {
    match fs::read_dir(dir) {
        Ok(rd) => collect_side(rd.map(|entry| entry.map(|e| (e.file_name(), e.path()))), opts),
        Err(e) => Listing { error: Some(e.to_string()), ..Listing::default() },
    }
}

/// The entries of a listing; an entry that fails is skipped and its error
/// kept as `partial`.
fn collect_side(entries: impl Iterator<Item = io::Result<(OsString, PathBuf)>>, opts: &Options) -> Listing {
    let mut out = Listing::default();
    for entry in entries {
        let (name, path) = match entry {
            Ok(entry) => entry,
            Err(e) => {
                out.partial.get_or_insert_with(|| e.to_string());
                continue;
            }
        };
        if name == ".git" {
            continue;
        }
        if !opts.hidden && name.as_encoded_bytes().first() == Some(&b'.') {
            continue;
        }
        let side = read_meta(&path);
        out.entries.insert(name, side);
    }
    out
}

/// List one directory level of both sides and pair the entries by name.
///
/// An entry ignored on both sides is dropped; one ignored on a single side
/// stays. A side whose directory cannot be read has no entries and its
/// error is reported in the [`Level`]; entries that fail individually are
/// left out and the first such error is reported as partial.
pub fn list_level(dir_a: &Path, dir_b: &Path, rules_a: &Rules, rules_b: &Rules, opts: &Options) -> Level {
    list_level_in(dir_a, dir_b, true, true, rules_a, rules_b, opts)
}

/// Like [`list_level`], but a side whose `read_*` is false is not read at
/// all: it has no entries and no error. Its rules still decide whether an
/// entry is ignored there.
pub fn list_level_in(
    dir_a: &Path,
    dir_b: &Path,
    read_a: bool,
    read_b: bool,
    rules_a: &Rules,
    rules_b: &Rules,
    opts: &Options,
) -> Level {
    let side = |dir: &Path, read: bool| if read { list_side(dir, opts) } else { Listing::default() };
    let (mut side_a, mut side_b) = (side(dir_a, read_a), side(dir_b, read_b));
    let mut names: Vec<OsString> = side_a.entries.keys().chain(side_b.entries.keys()).cloned().collect();
    names.sort();
    names.dedup();
    let mut pairs = Vec::with_capacity(names.len());
    for name in names {
        let a = side_a.entries.remove(&name).unwrap_or(EntrySide::Absent);
        let b = side_b.entries.remove(&name).unwrap_or(EntrySide::Absent);
        if opts.ignore_files {
            let is_dir_a = kind_of(&a).or(kind_of(&b)) == Some(Kind::Dir);
            let is_dir_b = kind_of(&b).or(kind_of(&a)) == Some(Kind::Dir);
            if rules_a.is_ignored(&dir_a.join(&name), is_dir_a) && rules_b.is_ignored(&dir_b.join(&name), is_dir_b) {
                continue;
            }
        }
        pairs.push(Pair { name, a, b });
    }
    Level { pairs, error_a: side_a.error, error_b: side_b.error, partial_a: side_a.partial, partial_b: side_b.partial }
}

/// The rules for `root/rel`, built only from directories that are really
/// directories: each component of `rel` is checked with `symlink_metadata`
/// and nothing is read through a symbolic link, a file or a missing
/// component. The flag is true when every component of `rel` is a real
/// directory, so `root/rel` may be listed; when false, the rules stop at
/// the last real directory. A root that is not a directory (any more)
/// gives false and no rules.
pub fn rules_along(root: &Path, rel: &Path, opts: &Options) -> (Rules, bool) {
    rules_along_with(root, rel, opts, true)
}

/// [`rules_along`], choosing whether the global excludes are read.
pub(crate) fn rules_along_with(root: &Path, rel: &Path, opts: &Options, global: bool) -> (Rules, bool) {
    // The root itself may be a link to a directory; it must still be one.
    if !root.is_dir() {
        return (Rules::default(), false);
    }
    let mut rules = Rules::root_with(root, opts, global);
    let mut dir = root.to_path_buf();
    for component in rel.components() {
        dir.push(component);
        match fs::symlink_metadata(&dir) {
            Ok(md) if md.file_type().is_dir() => rules = rules.child(&dir, opts),
            _ => return (rules, false),
        }
    }
    (rules, true)
}

/// Count the entries other than directories below `dir`, one side only,
/// listed as [`list_level`] lists them (`.git` skipped, hidden names per
/// `opts`) and filtered by that side's ignore rules; `rules` are those of
/// `dir` itself. Unreadable directories contribute nothing. Stops early,
/// returning the count so far, once `cancelled` returns true.
pub fn count_files(dir: &Path, rules: &Rules, opts: &Options, cancelled: &dyn Fn() -> bool) -> u64 {
    let mut count = 0;
    for (name, side) in list_side(dir, opts).entries {
        if cancelled() {
            break;
        }
        let path = dir.join(&name);
        let is_dir = kind_of(&side) == Some(Kind::Dir);
        if opts.ignore_files && rules.is_ignored(&path, is_dir) {
            continue;
        }
        if is_dir {
            count += count_files(&path, &rules.child(&path, opts), opts, cancelled);
        } else {
            count += 1;
        }
    }
    count
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use tempfile::TempDir;

    const OPTS: Options = Options { ignore_files: true, hidden: true };

    fn touch(dir: &Path, rel: &str, content: &str) {
        let p = dir.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, content).unwrap();
    }

    fn level(a: &Path, b: &Path, opts: &Options) -> Level {
        let ra = Rules::root_with(a, opts, false);
        let rb = Rules::root_with(b, opts, false);
        list_level(a, b, &ra, &rb, opts)
    }

    fn names(l: &Level) -> Vec<String> {
        l.pairs.iter().map(|p| p.name.to_string_lossy().into_owned()).collect()
    }

    fn pair<'a>(l: &'a Level, n: &str) -> &'a Pair {
        l.pairs.iter().find(|p| p.name == n).unwrap()
    }

    fn present(s: &EntrySide) -> bool {
        matches!(s, EntrySide::Present(_))
    }

    fn kind(s: &EntrySide) -> Kind {
        kind_of(s).unwrap()
    }

    #[test]
    fn pairs_identical_and_one_sided() {
        let (a, b) = (TempDir::new().unwrap(), TempDir::new().unwrap());
        touch(a.path(), "both", "x");
        touch(b.path(), "both", "xy");
        touch(a.path(), "only_a", "x");
        touch(b.path(), "only_b", "x");
        let l = level(a.path(), b.path(), &OPTS);
        assert_eq!(names(&l), ["both", "only_a", "only_b"]);
        let p = pair(&l, "both");
        match (&p.a, &p.b) {
            (EntrySide::Present(x), EntrySide::Present(y)) => {
                assert_eq!((x.size, y.size), (1, 2));
                assert!(x.mtime > 1.0e9);
            }
            _ => panic!(),
        }
        assert_eq!(pair(&l, "only_a").b, EntrySide::Absent);
        assert_eq!(pair(&l, "only_b").a, EntrySide::Absent);
        assert!(l.error_a.is_none() && l.error_b.is_none());
    }

    #[test]
    fn file_and_dir_of_same_name_pair() {
        let (a, b) = (TempDir::new().unwrap(), TempDir::new().unwrap());
        touch(a.path(), "x", "1");
        fs::create_dir(b.path().join("x")).unwrap();
        let l = level(a.path(), b.path(), &OPTS);
        assert_eq!(l.pairs.len(), 1);
        assert_eq!(kind(&l.pairs[0].a), Kind::File);
        assert_eq!(kind(&l.pairs[0].b), Kind::Dir);
        match &l.pairs[0].b {
            EntrySide::Present(m) => assert_eq!(m.size, 0),
            _ => panic!(),
        }
    }

    #[test]
    fn ignore_on_one_side_keeps_entries_paired() {
        let (a, b) = (TempDir::new().unwrap(), TempDir::new().unwrap());
        for d in [a.path(), b.path()] {
            touch(d, "build/x", "");
            touch(d, "x.log", "");
            touch(d, "src", "");
        }
        touch(a.path(), ".gitignore", "build/\n*.log\n");
        let l = level(a.path(), b.path(), &OPTS);
        for n in ["build", "x.log", "src"] {
            let p = pair(&l, n);
            assert!(present(&p.a) && present(&p.b), "{n}");
        }
    }

    #[test]
    fn ignore_on_both_sides_drops() {
        let (a, b) = (TempDir::new().unwrap(), TempDir::new().unwrap());
        for d in [a.path(), b.path()] {
            touch(d, ".gitignore", "*.tmp\nbuild/\n");
            touch(d, "a.tmp", "");
            touch(d, "keep", "");
            fs::create_dir(d.join("build")).unwrap();
        }
        touch(a.path(), "only.tmp", "");
        let l = level(a.path(), b.path(), &OPTS);
        assert_eq!(names(&l), [".gitignore", "keep"]);
    }

    #[test]
    fn directory_only_pattern_does_not_match_file() {
        let (a, b) = (TempDir::new().unwrap(), TempDir::new().unwrap());
        for d in [a.path(), b.path()] {
            touch(d, ".gitignore", "build/\n");
            touch(d, "build", "i am a file");
        }
        let l = level(a.path(), b.path(), &OPTS);
        assert!(names(&l).contains(&"build".to_string()));
    }

    #[test]
    fn negation_works() {
        let (a, b) = (TempDir::new().unwrap(), TempDir::new().unwrap());
        for d in [a.path(), b.path()] {
            touch(d, ".gitignore", "*.log\n!keep.log\n");
            touch(d, "drop.log", "");
            touch(d, "keep.log", "");
        }
        let l = level(a.path(), b.path(), &OPTS);
        assert_eq!(names(&l), [".gitignore", "keep.log"]);
    }

    #[test]
    fn dot_ignore_file_applies_and_wins() {
        let (a, b) = (TempDir::new().unwrap(), TempDir::new().unwrap());
        for d in [a.path(), b.path()] {
            touch(d, ".gitignore", "*.log\n");
            touch(d, ".ignore", "!x.log\ny.txt\n");
            touch(d, "x.log", "");
            touch(d, "z.log", "");
            touch(d, "y.txt", "");
        }
        let l = level(a.path(), b.path(), &OPTS);
        assert_eq!(names(&l), [".gitignore", ".ignore", "x.log"]);
    }

    #[test]
    fn nested_gitignore_applies_via_child() {
        let (a, b) = (TempDir::new().unwrap(), TempDir::new().unwrap());
        for d in [a.path(), b.path()] {
            touch(d, ".gitignore", "*.log\n");
            touch(d, "sub/.gitignore", "!keep.log\nsecret\n");
            touch(d, "sub/keep.log", "");
            touch(d, "sub/other.log", "");
            touch(d, "sub/secret", "");
            touch(d, "sub/ok", "");
        }
        let ra = Rules::root_with(a.path(), &OPTS, false);
        let rb = Rules::root_with(b.path(), &OPTS, false);
        let (sa, sb) = (a.path().join("sub"), b.path().join("sub"));
        let ca = ra.child(&sa, &OPTS);
        let cb = rb.child(&sb, &OPTS);
        let l = list_level(&sa, &sb, &ca, &cb, &OPTS);
        assert_eq!(names(&l), [".gitignore", "keep.log", "ok"]);
        // The parent's rules alone would drop keep.log.
        let l = list_level(&sa, &sb, &ra, &rb, &OPTS);
        assert!(!names(&l).contains(&"keep.log".to_string()));
    }

    #[test]
    fn ignore_files_false_disables_rules() {
        let (a, b) = (TempDir::new().unwrap(), TempDir::new().unwrap());
        for d in [a.path(), b.path()] {
            touch(d, ".gitignore", "*.tmp\n");
            touch(d, "a.tmp", "");
        }
        let opts = Options { ignore_files: false, hidden: true };
        let l = level(a.path(), b.path(), &opts);
        assert_eq!(names(&l), [".gitignore", "a.tmp"]);
    }

    #[test]
    fn git_dir_always_skipped_and_hidden_option() {
        let (a, b) = (TempDir::new().unwrap(), TempDir::new().unwrap());
        for d in [a.path(), b.path()] {
            touch(d, ".git/config", "");
            touch(d, ".hidden", "");
            touch(d, "plain", "");
        }
        let l = level(a.path(), b.path(), &OPTS);
        assert_eq!(names(&l), [".hidden", "plain"]);
        let opts = Options { ignore_files: true, hidden: false };
        let l = level(a.path(), b.path(), &opts);
        assert_eq!(names(&l), ["plain"]);
    }

    #[test]
    fn symlinks_are_not_followed() {
        let (a, b) = (TempDir::new().unwrap(), TempDir::new().unwrap());
        fs::create_dir(a.path().join("real")).unwrap();
        symlink("real", a.path().join("dirlink")).unwrap();
        symlink("missing/target", a.path().join("dangling")).unwrap();
        let l = level(a.path(), b.path(), &OPTS);
        for (n, t) in [("dirlink", "real"), ("dangling", "missing/target")] {
            match &pair(&l, n).a {
                EntrySide::Present(m) => {
                    assert_eq!(m.kind, Kind::Link, "{n}");
                    assert_eq!(m.link_target.as_deref(), Some(Path::new(t)));
                }
                other => panic!("{n}: {other:?}"),
            }
        }
        assert_eq!(kind(&pair(&l, "real").a), Kind::Dir);
    }

    #[test]
    fn unreadable_directory_reports_error() {
        let (a, b) = (TempDir::new().unwrap(), TempDir::new().unwrap());
        touch(b.path(), "f", "");
        let locked = a.path().join("locked");
        fs::create_dir(&locked).unwrap();
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
        if fs::read_dir(&locked).is_ok() {
            // running as root: permissions are not enforced
            fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
            return;
        }
        let l = level(&locked, b.path(), &OPTS);
        assert!(l.error_a.is_some());
        assert!(l.error_b.is_none());
        assert_eq!(names(&l), ["f"]);
        let l = level(b.path(), &locked, &OPTS);
        assert!(l.error_a.is_none() && l.error_b.is_some());
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[test]
    fn pairs_are_sorted_by_bytes() {
        let (a, b) = (TempDir::new().unwrap(), TempDir::new().unwrap());
        for n in ["b", "B", "a", "_z", "10", "2"] {
            touch(a.path(), n, "");
        }
        touch(b.path(), "A", "");
        let l = level(a.path(), b.path(), &OPTS);
        assert_eq!(names(&l), ["10", "2", "A", "B", "_z", "a", "b"]);
    }

    #[test]
    fn count_files_applies_the_rules_of_its_side() {
        let a = TempDir::new().unwrap();
        let d = a.path().join("d");
        touch(&d, "x", "");
        touch(&d, "sub/y", "");
        touch(&d, "sub/deeper/z", "");
        touch(&d, "sub/skip.tmp", "");
        touch(&d, "sub/.gitignore", "*.tmp\n");
        touch(&d, ".hidden", "");
        touch(&d, ".git/config", "");
        symlink("x", d.join("link")).unwrap();
        let rules = Rules::root_with(a.path(), &OPTS, false).child(&d, &OPTS);
        let never = || false;
        // x, link, .hidden, sub/y, sub/.gitignore, sub/deeper/z
        assert_eq!(count_files(&d, &rules, &OPTS, &never), 6);
        let opts = Options { ignore_files: true, hidden: false };
        assert_eq!(count_files(&d, &rules, &opts, &never), 4);
        let opts = Options { ignore_files: false, hidden: true };
        assert_eq!(count_files(&d, &Rules::default(), &opts, &never), 7);
        assert_eq!(count_files(&d, &rules, &OPTS, &|| true), 0);
    }

    #[test]
    fn a_failing_entry_keeps_the_others() {
        let d = TempDir::new().unwrap();
        touch(d.path(), "x", "");
        touch(d.path(), "y", "");
        let entry = |n: &str| Ok((OsString::from(n), d.path().join(n)));
        let entries = vec![entry("x"), Err(io::Error::other("bad entry")), entry("y"), Err(io::Error::other("later"))];
        let listing = collect_side(entries.into_iter(), &OPTS);
        assert_eq!(listing.entries.keys().collect::<Vec<_>>(), ["x", "y"]);
        assert_eq!(listing.partial.as_deref(), Some("bad entry"));
        assert!(listing.error.is_none());
        let l = level(d.path(), d.path(), &OPTS);
        assert!(l.partial_a.is_none() && l.partial_b.is_none());
    }

    #[test]
    fn special_files_have_their_kind() {
        let (a, b) = (TempDir::new().unwrap(), TempDir::new().unwrap());
        let status = std::process::Command::new("mkfifo").arg(a.path().join("fifo")).status().unwrap();
        assert!(status.success());
        let _socket = std::os::unix::net::UnixListener::bind(b.path().join("sock")).unwrap();
        let l = level(a.path(), b.path(), &OPTS);
        assert_eq!(kind(&pair(&l, "fifo").a), Kind::Other(Special::Fifo));
        assert_eq!(kind(&pair(&l, "sock").b), Kind::Other(Special::Socket));
        let l = level(Path::new("/dev"), b.path(), &OPTS);
        assert_eq!(kind(&pair(&l, "null").a), Kind::Other(Special::CharDevice));
    }

    #[test]
    fn rules_along_stops_at_anything_but_a_real_directory() {
        let (a, outside) = (TempDir::new().unwrap(), TempDir::new().unwrap());
        touch(a.path(), "real/sub/f", "");
        touch(a.path(), "file", "");
        touch(outside.path(), "sub/.gitignore", "*\n");
        symlink(outside.path(), a.path().join("link")).unwrap();
        let opts = Options { ignore_files: false, hidden: true };
        assert!(rules_along_with(a.path(), Path::new(""), &opts, false).1);
        assert!(!rules_along_with(&a.path().join("missing"), Path::new(""), &opts, false).1);
        assert!(rules_along_with(a.path(), Path::new("real/sub"), &opts, false).1);
        for rel in ["link", "link/sub", "file", "file/x", "missing", "real/missing/x"] {
            assert!(!rules_along_with(a.path(), Path::new(rel), &opts, false).1, "{rel}");
        }
        // The ignore file beyond the link is not read.
        let (rules, real) = rules_along_with(a.path(), Path::new("link/sub"), &OPTS, false);
        assert!(!real);
        assert!(!rules.is_ignored(&a.path().join("link/sub/x"), false));
    }

    #[test]
    fn a_side_not_to_read_has_no_entries() {
        let (a, b) = (TempDir::new().unwrap(), TempDir::new().unwrap());
        touch(a.path(), "x", "");
        touch(b.path(), "y", "");
        let rules = Rules::default();
        let l = list_level_in(a.path(), b.path(), false, true, &rules, &rules, &OPTS);
        assert_eq!(names(&l), ["y"]);
        assert!(l.error_a.is_none());
    }

    #[test]
    fn join_rel_is_slash_separated() {
        assert_eq!(join_rel(Path::new(""), OsStr::new("x")), Path::new("x"));
        assert_eq!(join_rel(Path::new("a/b"), OsStr::new("x")), Path::new("a/b/x"));
    }
}
