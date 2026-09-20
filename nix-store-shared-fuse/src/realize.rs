//! Pure path-logic for the realization rule.
//!
//! These functions contain NO filesystem I/O. They decide, purely from the
//! symlink target and the three configured roots, whether a farm symlink
//! qualifies to be "realized" as a directory and, if so, what relative subpath
//! under `redirect_root` its content lives at.
//!
//! All paths handled here are treated as logical, absolute, lexically
//! normalized paths. Actual I/O confinement is enforced separately via
//! `cap-std` `Dir` handles in the FUSE layer.

use std::path::{Component, Path, PathBuf};

/// Lexically normalize an absolute path: collapse `.`, resolve `..` against the
/// preceding component (without touching the filesystem), and drop redundant
/// separators. A leading `..` at the root is clamped at the root (matching the
/// behaviour of an absolute path that cannot escape `/`).
///
/// Relative inputs are normalized as-is (kept relative); the FUSE layer only
/// ever feeds absolute symlink targets here, but keeping the function total
/// makes it easy to test.
pub fn normalize(path: &Path) -> PathBuf {
    let mut out: Vec<Component> = Vec::new();
    let is_absolute = path.is_absolute();

    for comp in path.components() {
        match comp {
            Component::CurDir => {}
            Component::ParentDir => {
                match out.last() {
                    Some(Component::Normal(_)) => {
                        out.pop();
                    }
                    Some(Component::RootDir) | Some(Component::Prefix(_)) => {
                        // `..` above root: clamp (drop it).
                    }
                    Some(Component::ParentDir) | None => {
                        // Relative path leading `..`: preserve it.
                        out.push(comp);
                    }
                    Some(Component::CurDir) => unreachable!("CurDir never pushed"),
                }
            }
            other => out.push(other),
        }
    }

    let mut result = PathBuf::new();
    for comp in &out {
        result.push(comp.as_os_str());
    }

    if is_absolute && !result.has_root() {
        // e.g. input was "/" or "/.." -> normalize back to "/".
        return PathBuf::from("/");
    }
    if result.as_os_str().is_empty() {
        return PathBuf::from(if is_absolute { "/" } else { "." });
    }
    result
}

/// True iff `candidate` (already normalized, absolute) is the same path as
/// `base` or lies strictly inside it. `base` is treated as a directory prefix:
/// component-wise containment, so `/nix/store` does NOT contain
/// `/nix/store-extra`.
pub fn is_inside(candidate: &Path, base: &Path) -> bool {
    let cand = normalize(candidate);
    let base = normalize(base);
    cand == base || cand.starts_with(&base)
}

/// Outcome of evaluating a farm symlink against the configured roots.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Realization {
    /// Qualifies: serve content from `redirect_root` joined with this relative
    /// subpath. The subpath is `target` relative to `resolution_root`
    /// (possibly empty, meaning the redirect root itself).
    Realize { rel: PathBuf },
    /// Does not qualify: keep the original symlink as-is.
    KeepSymlink,
}

/// Decide how to treat a farm symlink whose (lexically normalized, absolute)
/// target is `target`.
///
/// Realize as a directory IFF:
///   * `target` is inside `resolution_root`, AND
///   * `target` is NOT inside `bind_target` (loop guard).
///
/// The "is the realized location actually a directory" check is intentionally
/// NOT done here (it requires I/O); the caller verifies that via cap-std and
/// falls back to `KeepSymlink` if the redirect path is missing or not a dir.
///
/// When realizing, the returned `rel` is `target` stripped of the
/// `resolution_root` prefix, so the content location is
/// `redirect_root / rel`.
pub fn classify(target: &Path, resolution_root: &Path, bind_target: &Path) -> Realization {
    let target = normalize(target);
    let resolution_root = normalize(resolution_root);
    let bind_target = normalize(bind_target);

    if !is_inside(&target, &resolution_root) {
        return Realization::KeepSymlink;
    }
    if is_inside(&target, &bind_target) {
        // Loop guard: a farm symlink that points back into the farm.
        return Realization::KeepSymlink;
    }

    // `target` is inside resolution_root, so strip_prefix succeeds.
    let rel = target
        .strip_prefix(&resolution_root)
        .expect("is_inside guarantees prefix")
        .to_path_buf();

    Realization::Realize { rel }
}

/// Resolve a symlink target that may be relative, against the directory that
/// contains the link. `link_dir` is the absolute logical path of the directory
/// holding the symlink (i.e. the symlink's parent within `bind_target`'s
/// logical namespace). Absolute targets are returned normalized; relative
/// targets are joined onto `link_dir` first.
pub fn resolve_target(link_dir: &Path, target: &Path) -> PathBuf {
    if target.is_absolute() {
        normalize(target)
    } else {
        normalize(&link_dir.join(target))
    }
}

#[cfg(test)]
#[path = "realize_tests.rs"]
mod tests;
