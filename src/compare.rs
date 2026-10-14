//! Deciding whether two files are the same (task 3).
//!
//! Pure functions over paths: no walking, no threads. The caller passes a
//! cancellation check that is polled between 64 KiB blocks and before line
//! counting.
//!
//! Line counts are byte-exact: lines are split at `\n` (terminator kept) and
//! diffed as byte slices with `similar::capture_diff_slices_deadline`, so
//! invalid UTF-8 needs no lossy conversion (the `bytes` feature of `similar`
//! is not enabled). The diff has a budget of 0.5 s; past it, no line counts.

use std::fs::File;
use std::io::{self, Read};
use std::path::Path;
use std::time::{Duration, Instant};

use similar::{Algorithm, DiffOp, capture_diff_slices_deadline};

use crate::service::By;

/// Size of the blocks read while comparing contents.
const BLOCK: usize = 64 * 1024;
/// Number of leading bytes inspected for a NUL byte.
const SNIFF: usize = 8 * 1024;
/// Largest file (in bytes) that is whitespace-compared or line-counted.
const TEXT_LIMIT: u64 = 4 * 1024 * 1024;
/// Time a line diff may take; a pair that needs longer gets no line counts.
const DIFF_BUDGET: Duration = Duration::from_millis(500);

/// How to compare a pair of files.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Options {
    /// Comparison method.
    pub by: By,
    /// Treat files that differ only in whitespace as the same (`By::Content` only).
    pub whitespace: bool,
}

/// File metadata as provided by the walk.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FileMeta {
    /// Size in bytes.
    pub size: u64,
    /// Modification time, seconds since the epoch.
    pub mtime: f64,
}

/// Result of comparing two files.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// The files are the same under the chosen options.
    Same,
    /// The files differ. `lines` is `(added, removed)` of B against A when
    /// compared by content, both are text files of at most 4 MiB and the
    /// line diff finishes within its time budget; otherwise `None`.
    Changed {
        /// Added and removed line counts.
        lines: Option<(u32, u32)>,
    },
}

/// Why a comparison produced no outcome.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CompareError {
    /// The cancellation check returned true.
    Cancelled,
    /// An I/O error, with the OS message.
    Io(String),
}

impl From<io::Error> for CompareError {
    fn from(e: io::Error) -> Self {
        CompareError::Io(e.to_string())
    }
}

/// Compare two regular files. `cancelled` returns true once the work should stop.
pub fn compare_files(
    a: &Path,
    b: &Path,
    ma: &FileMeta,
    mb: &FileMeta,
    opts: &Options,
    cancelled: &dyn Fn() -> bool,
) -> Result<Outcome, CompareError> {
    if cancelled() {
        return Err(CompareError::Cancelled);
    }
    let differs = match opts.by {
        // Nothing is read: no text check, no line counts.
        By::SizeTime => {
            let differs = ma.size != mb.size || ma.mtime.floor() != mb.mtime.floor();
            return Ok(if differs { Outcome::Changed { lines: None } } else { Outcome::Same });
        }
        By::Content => ma.size != mb.size || !same_bytes(a, b, cancelled)?,
    };
    if !differs {
        return Ok(Outcome::Same);
    }
    let small = ma.size <= TEXT_LIMIT && mb.size <= TEXT_LIMIT;
    if !small || !is_text(a)? || !is_text(b)? {
        return Ok(Outcome::Changed { lines: None });
    }
    if cancelled() {
        return Err(CompareError::Cancelled);
    }
    // The files may have grown since they were listed.
    let (Some(da), Some(db)) = (read_limited(a)?, read_limited(b)?) else {
        return Ok(Outcome::Changed { lines: None });
    };
    if opts.whitespace && strip_whitespace(&da) == strip_whitespace(&db) {
        return Ok(Outcome::Same);
    }
    Ok(Outcome::Changed { lines: count_lines(&da, &db, cancelled)? })
}

/// The whole file, or `None` when it is larger than [`TEXT_LIMIT`]; reads
/// at most one byte more than the limit.
fn read_limited(path: &Path) -> io::Result<Option<Vec<u8>>> {
    let mut data = Vec::new();
    File::open(path)?.take(TEXT_LIMIT + 1).read_to_end(&mut data)?;
    Ok((data.len() as u64 <= TEXT_LIMIT).then_some(data))
}

/// Compare two symbolic links by target, without resolving. True means same.
pub fn compare_links(a: &Path, b: &Path) -> Result<bool, CompareError> {
    Ok(std::fs::read_link(a)? == std::fs::read_link(b)?)
}

/// True when the first 8 KiB of the file contain no NUL byte.
pub fn is_text(path: &Path) -> io::Result<bool> {
    let mut buf = Vec::with_capacity(SNIFF);
    File::open(path)?.take(SNIFF as u64).read_to_end(&mut buf)?;
    Ok(!buf.contains(&0))
}

/// Block-wise equality; polls `cancelled` before every block.
fn same_bytes(a: &Path, b: &Path, cancelled: &dyn Fn() -> bool) -> Result<bool, CompareError> {
    let (mut fa, mut fb) = (File::open(a)?, File::open(b)?);
    let (mut ba, mut bb) = (vec![0u8; BLOCK], vec![0u8; BLOCK]);
    loop {
        if cancelled() {
            return Err(CompareError::Cancelled);
        }
        let na = read_full(&mut fa, &mut ba)?;
        let nb = read_full(&mut fb, &mut bb)?;
        if na != nb || ba[..na] != bb[..nb] {
            return Ok(false);
        }
        if na < BLOCK {
            return Ok(true);
        }
    }
}

/// Read until `buf` is full or EOF; returns the number of bytes read.
fn read_full(r: &mut impl Read, buf: &mut [u8]) -> io::Result<usize> {
    let mut n = 0;
    while n < buf.len() {
        match r.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(n)
}

/// Remove all whitespace: Unicode whitespace when valid UTF-8, else ASCII bytes.
fn strip_whitespace(data: &[u8]) -> Vec<u8> {
    match std::str::from_utf8(data) {
        Ok(s) => s.chars().filter(|c| !c.is_whitespace()).collect::<String>().into_bytes(),
        Err(_) => data.iter().copied().filter(|b| !b.is_ascii_whitespace()).collect(),
    }
}

/// `(added, removed)` lines of `b` against `a`, diffing lines as bytes;
/// `None` when the diff takes longer than [`DIFF_BUDGET`]. Myers is
/// O(N·D) and cannot be interrupted, so the budget bounds both the time
/// and the cancellation latency.
fn count_lines(a: &[u8], b: &[u8], cancelled: &dyn Fn() -> bool) -> Result<Option<(u32, u32)>, CompareError> {
    if cancelled() {
        return Err(CompareError::Cancelled);
    }
    let la: Vec<&[u8]> = a.split_inclusive(|&c| c == b'\n').collect();
    let lb: Vec<&[u8]> = b.split_inclusive(|&c| c == b'\n').collect();
    let deadline = Instant::now() + DIFF_BUDGET;
    let ops = capture_diff_slices_deadline(Algorithm::Myers, &la, &lb, Some(deadline));
    // Past the deadline the diff gives up with coarse replacements.
    if Instant::now() >= deadline {
        return Ok(None);
    }
    let (mut added, mut removed) = (0usize, 0usize);
    for op in ops {
        match op {
            DiffOp::Equal { .. } => {}
            DiffOp::Delete { old_len, .. } => removed += old_len,
            DiffOp::Insert { new_len, .. } => added += new_len,
            DiffOp::Replace { old_len, new_len, .. } => {
                removed += old_len;
                added += new_len;
            }
        }
    }
    Ok(Some((added as u32, removed as u32)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, UNIX_EPOCH};
    use tempfile::TempDir;

    fn never() -> bool {
        false
    }

    fn write(dir: &TempDir, name: &str, data: &[u8]) -> std::path::PathBuf {
        let p = dir.path().join(name);
        std::fs::write(&p, data).unwrap();
        p
    }

    fn meta(p: &Path) -> FileMeta {
        let m = std::fs::metadata(p).unwrap();
        let t = m.modified().unwrap().duration_since(UNIX_EPOCH).unwrap();
        FileMeta { size: m.len(), mtime: t.as_secs_f64() }
    }

    fn cmp(a: &Path, b: &Path, opts: Options) -> Result<Outcome, CompareError> {
        compare_files(a, b, &meta(a), &meta(b), &opts, &never)
    }

    fn content() -> Options {
        Options::default()
    }

    fn ws() -> Options {
        Options { by: By::Content, whitespace: true }
    }

    fn set_mtime(p: &Path, secs: f64) {
        let f = File::options().write(true).open(p).unwrap();
        f.set_modified(UNIX_EPOCH + Duration::from_secs_f64(secs)).unwrap();
    }

    #[test]
    fn identical_files_are_same() {
        let d = TempDir::new().unwrap();
        for n in [0usize, 10, BLOCK, BLOCK + 1, 3 * BLOCK + 5] {
            let data: Vec<u8> = (0..n).map(|i| (i % 251) as u8).collect();
            let a = write(&d, "a", &data);
            let b = write(&d, "b", &data);
            assert_eq!(cmp(&a, &b, content()), Ok(Outcome::Same), "size {n}");
        }
    }

    #[test]
    fn difference_in_second_block_is_changed() {
        let d = TempDir::new().unwrap();
        let mut x = vec![b'x'; BLOCK + 10];
        let a = write(&d, "a", &x);
        *x.last_mut().unwrap() = b'y';
        let b = write(&d, "b", &x);
        assert!(matches!(cmp(&a, &b, content()), Ok(Outcome::Changed { .. })));
    }

    #[test]
    fn different_sizes_are_changed_without_reading() {
        let d = TempDir::new().unwrap();
        let a = write(&d, "a", b"abc");
        let b = write(&d, "b", b"abcd");
        let (ma, mb) = (meta(&a), meta(&b));
        // Different sizes: changed, and small text files still get line counts.
        assert_eq!(compare_files(&a, &b, &ma, &mb, &content(), &never), Ok(Outcome::Changed { lines: Some((1, 1)) }));
        // Oversized: no file is opened at all (the paths do not exist).
        let gone = d.path().join("gone");
        let big = FileMeta { size: TEXT_LIMIT + 1, mtime: 0.0 };
        let small = FileMeta { size: 1, mtime: 0.0 };
        assert_eq!(compare_files(&gone, &gone, &big, &small, &content(), &never), Ok(Outcome::Changed { lines: None }));
    }

    #[test]
    fn size_time_compares_metadata_only() {
        let d = TempDir::new().unwrap();
        let a = write(&d, "a", b"aaaa");
        let b = write(&d, "b", b"bbbb");
        let st = Options { by: By::SizeTime, whitespace: false };
        set_mtime(&a, 1_000_000.0);
        set_mtime(&b, 1_000_000.0);
        assert_eq!(cmp(&a, &b, st), Ok(Outcome::Same));
        set_mtime(&b, 1_000_000.9);
        assert_eq!(cmp(&a, &b, st), Ok(Outcome::Same));
        set_mtime(&b, 1_000_001.0);
        assert_eq!(cmp(&a, &b, st), Ok(Outcome::Changed { lines: None }), "nothing is read: no line counts");
        // Nothing is opened at all (the paths do not exist).
        let gone = d.path().join("gone");
        let (m1, m2) = (FileMeta { size: 1, mtime: 0.0 }, FileMeta { size: 2, mtime: 0.0 });
        assert_eq!(compare_files(&gone, &gone, &m1, &m2, &st, &never), Ok(Outcome::Changed { lines: None }));
    }

    #[test]
    fn line_diff_has_a_time_budget() {
        let d = TempDir::new().unwrap();
        // Two dissimilar text files of 50k lines each: an unbounded Myers
        // diff takes minutes here.
        let text = |seed: u64| {
            let mut x = seed;
            let mut s = String::new();
            for _ in 0..50_000 {
                x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                s.push_str(&format!("{:x}\n", x >> 40));
            }
            s
        };
        let a = write(&d, "a", text(1).as_bytes());
        let b = write(&d, "b", text(2).as_bytes());
        let started = std::time::Instant::now();
        assert_eq!(cmp(&a, &b, content()), Ok(Outcome::Changed { lines: None }));
        let took = started.elapsed();
        assert!(took < Duration::from_millis(1500), "{took:?}");
    }

    #[test]
    fn line_diff_is_not_started_when_cancelled() {
        let calls = std::cell::Cell::new(0);
        let c = || {
            calls.set(calls.get() + 1);
            false
        };
        assert_eq!(count_lines(b"a\n", b"b\n", &c), Ok(Some((1, 1))));
        assert_eq!(calls.get(), 1, "checked once before the diff");
        assert_eq!(count_lines(b"a\n", b"b\n", &|| true), Err(CompareError::Cancelled));
    }

    #[test]
    fn a_file_that_grew_past_the_limit_is_not_read_whole() {
        let d = TempDir::new().unwrap();
        // The metadata says small, the files are now larger than the limit.
        let mut big = vec![b'x'; TEXT_LIMIT as usize + 10];
        let a = write(&d, "a", &big);
        big.extend_from_slice(b" \n");
        let b = write(&d, "b", &big);
        let small = FileMeta { size: 10, mtime: 0.0 };
        let small2 = FileMeta { size: 11, mtime: 0.0 };
        assert_eq!(compare_files(&a, &b, &small, &small2, &ws(), &never), Ok(Outcome::Changed { lines: None }));
        assert_eq!(read_limited(&a).unwrap(), None);
        assert_eq!(read_limited(&write(&d, "c", b"abc")).unwrap(), Some(b"abc".to_vec()));
    }

    #[test]
    fn whitespace_option() {
        let d = TempDir::new().unwrap();
        let a = write(&d, "a", b"a b\n");
        let b = write(&d, "b", b"a  b\r\n");
        assert_eq!(cmp(&a, &b, ws()), Ok(Outcome::Same));
        assert!(matches!(cmp(&a, &b, content()), Ok(Outcome::Changed { .. })));
    }

    #[test]
    fn whitespace_ignored_for_binary_and_large() {
        let d = TempDir::new().unwrap();
        let a = write(&d, "a", b"a\0 b\n");
        let b = write(&d, "b", b"a\0b\n");
        assert_eq!(cmp(&a, &b, ws()), Ok(Outcome::Changed { lines: None }));

        let mut big = vec![b'x'; TEXT_LIMIT as usize + 1];
        let a = write(&d, "big_a", &big);
        big.extend_from_slice(b"  ");
        let b = write(&d, "big_b", &big);
        assert_eq!(cmp(&a, &b, ws()), Ok(Outcome::Changed { lines: None }));
    }

    #[test]
    fn whitespace_on_invalid_utf8_uses_ascii() {
        let d = TempDir::new().unwrap();
        let a = write(&d, "a", b"a \xff b\n");
        let b = write(&d, "b", b"a\xffb");
        assert_eq!(cmp(&a, &b, ws()), Ok(Outcome::Same));
    }

    #[test]
    fn line_counts() {
        let d = TempDir::new().unwrap();
        let a = write(&d, "a", b"one\ntwo\nthree\nfour\n");
        let b = write(&d, "b", b"one\n2\nthree\nfour\nfive\nsix\n");
        assert_eq!(cmp(&a, &b, content()), Ok(Outcome::Changed { lines: Some((3, 1)) }));
        // Invalid UTF-8 is diffed as bytes.
        let a = write(&d, "c", b"a\n\xff\nz\n");
        let b = write(&d, "e", b"a\n\xfe\nz\n");
        assert_eq!(cmp(&a, &b, content()), Ok(Outcome::Changed { lines: Some((1, 1)) }));
    }

    #[test]
    fn line_counts_none_for_binary_and_large() {
        let d = TempDir::new().unwrap();
        let a = write(&d, "a", b"a\0\n");
        let b = write(&d, "b", b"b\0\n");
        assert_eq!(cmp(&a, &b, content()), Ok(Outcome::Changed { lines: None }));
        let mut big = vec![b'x'; TEXT_LIMIT as usize + 1];
        let a = write(&d, "big_a", &big);
        big[0] = b'y';
        let b = write(&d, "big_b", &big);
        assert_eq!(cmp(&a, &b, content()), Ok(Outcome::Changed { lines: None }));
    }

    #[cfg(unix)]
    #[test]
    fn links_compare_by_target() {
        use std::os::unix::fs::symlink;
        let d = TempDir::new().unwrap();
        let p = |n: &str| d.path().join(n);
        symlink("target", p("l1")).unwrap();
        symlink("target", p("l2")).unwrap();
        symlink("other", p("l3")).unwrap();
        assert_eq!(compare_links(&p("l1"), &p("l2")), Ok(true));
        assert_eq!(compare_links(&p("l1"), &p("l3")), Ok(false));
        assert!(matches!(compare_links(&p("l1"), &p("none")), Err(CompareError::Io(_))));
    }

    #[test]
    fn cancelled_before_reading() {
        let d = TempDir::new().unwrap();
        let gone = d.path().join("gone");
        let m = FileMeta { size: 1, mtime: 0.0 };
        assert_eq!(compare_files(&gone, &gone, &m, &m, &content(), &|| true), Err(CompareError::Cancelled));
    }

    #[test]
    fn cancelled_between_blocks() {
        let d = TempDir::new().unwrap();
        let data = vec![b'x'; 3 * BLOCK];
        let a = write(&d, "a", &data);
        let b = write(&d, "b", &data);
        let calls = std::cell::Cell::new(0);
        let c = || {
            calls.set(calls.get() + 1);
            calls.get() > 2
        };
        assert_eq!(compare_files(&a, &b, &meta(&a), &meta(&b), &content(), &c), Err(CompareError::Cancelled));
    }

    #[test]
    fn vanished_file_is_io_error() {
        let d = TempDir::new().unwrap();
        let a = write(&d, "a", b"abc");
        let gone = d.path().join("gone");
        let m = FileMeta { size: 3, mtime: 0.0 };
        assert!(matches!(compare_files(&a, &gone, &m, &m, &content(), &never), Err(CompareError::Io(_))));
    }
}
