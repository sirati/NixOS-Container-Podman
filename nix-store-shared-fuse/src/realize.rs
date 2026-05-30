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
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn normalize_collapses_dot_and_dotdot() {
        assert_eq!(normalize(Path::new("/nix/store/./a/../b")), PathBuf::from("/nix/store/b"));
        assert_eq!(normalize(Path::new("/a/b/c/../../d")), PathBuf::from("/a/d"));
        assert_eq!(normalize(Path::new("/a//b///c")), PathBuf::from("/a/b/c"));
    }

    #[test]
    fn normalize_clamps_dotdot_at_root() {
        assert_eq!(normalize(Path::new("/..")), PathBuf::from("/"));
        assert_eq!(normalize(Path::new("/../../etc")), PathBuf::from("/etc"));
        assert_eq!(normalize(Path::new("/")), PathBuf::from("/"));
    }

    #[test]
    fn normalize_preserves_relative_leading_dotdot() {
        assert_eq!(normalize(Path::new("../a")), PathBuf::from("../a"));
        assert_eq!(normalize(Path::new("a/../../b")), PathBuf::from("../b"));
        assert_eq!(normalize(Path::new(".")), PathBuf::from("."));
    }

    #[test]
    fn is_inside_basic() {
        assert!(is_inside(Path::new("/nix/store/abc"), Path::new("/nix/store")));
        assert!(is_inside(Path::new("/nix/store"), Path::new("/nix/store")));
        assert!(!is_inside(Path::new("/nix"), Path::new("/nix/store")));
    }

    #[test]
    fn is_inside_rejects_sibling_prefix() {
        // component-wise containment: store-extra is NOT inside store.
        assert!(!is_inside(Path::new("/nix/store-extra/x"), Path::new("/nix/store")));
        assert!(!is_inside(Path::new("/nix/storex"), Path::new("/nix/store")));
    }

    #[test]
    fn is_inside_normalizes_first() {
        assert!(is_inside(Path::new("/nix/store/../store/abc"), Path::new("/nix/store")));
        assert!(!is_inside(Path::new("/nix/store/../../etc"), Path::new("/nix/store")));
    }

    #[test]
    fn classify_realizes_target_inside_resolution_root() {
        let r = classify(
            Path::new("/nix/store/AAAA-htop"),
            Path::new("/nix/store"),
            Path::new("/var/farm"),
        );
        assert_eq!(r, Realization::Realize { rel: PathBuf::from("AAAA-htop") });
    }

    #[test]
    fn classify_realizes_nested_subpath() {
        let r = classify(
            Path::new("/nix/store/AAAA-htop/bin/htop"),
            Path::new("/nix/store"),
            Path::new("/var/farm"),
        );
        assert_eq!(r, Realization::Realize { rel: PathBuf::from("AAAA-htop/bin/htop") });
    }

    #[test]
    fn classify_target_outside_resolution_root_keeps_symlink() {
        let r = classify(
            Path::new("/usr/bin/htop"),
            Path::new("/nix/store"),
            Path::new("/var/farm"),
        );
        assert_eq!(r, Realization::KeepSymlink);
    }

    #[test]
    fn classify_target_equals_resolution_root() {
        // target == resolution_root => inside, rel is empty (the redirect root itself).
        let r = classify(
            Path::new("/nix/store"),
            Path::new("/nix/store"),
            Path::new("/var/farm"),
        );
        assert_eq!(r, Realization::Realize { rel: PathBuf::from("") });
    }

    #[test]
    fn classify_loop_guard_target_inside_bind_target() {
        // bind_target lies inside resolution_root and the link points back in:
        // must stay a symlink.
        let r = classify(
            Path::new("/nix/store/farm/other-entry"),
            Path::new("/nix/store"),
            Path::new("/nix/store/farm"),
        );
        assert_eq!(r, Realization::KeepSymlink);
    }

    #[test]
    fn classify_normalizes_dotdot_target() {
        // target uses .. but normalizes to inside resolution_root.
        let r = classify(
            Path::new("/nix/store/x/../AAAA-htop"),
            Path::new("/nix/store"),
            Path::new("/var/farm"),
        );
        assert_eq!(r, Realization::Realize { rel: PathBuf::from("AAAA-htop") });
    }

    #[test]
    fn classify_dotdot_escape_keeps_symlink() {
        // target escapes resolution_root via .. -> keep symlink.
        let r = classify(
            Path::new("/nix/store/../../etc/passwd"),
            Path::new("/nix/store"),
            Path::new("/var/farm"),
        );
        assert_eq!(r, Realization::KeepSymlink);
    }

    #[test]
    fn resolve_target_absolute() {
        assert_eq!(
            resolve_target(Path::new("/var/farm"), Path::new("/nix/store/x")),
            PathBuf::from("/nix/store/x")
        );
    }

    #[test]
    fn resolve_target_relative_joined_against_link_dir() {
        assert_eq!(
            resolve_target(Path::new("/var/farm/sub"), Path::new("../other")),
            PathBuf::from("/var/farm/other")
        );
    }

    #[test]
    fn classify_redirect_rel_is_independent_of_redirect_root() {
        // The rel is computed only against resolution_root; redirect_root is
        // applied by the caller. Verify rel for a deep path.
        let r = classify(
            Path::new("/nix/store/hash-pkg/lib/x.so"),
            Path::new("/nix/store"),
            Path::new("/farm"),
        );
        assert_eq!(r, Realization::Realize { rel: PathBuf::from("hash-pkg/lib/x.so") });
    }
}
