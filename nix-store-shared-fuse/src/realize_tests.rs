use super::*;
use std::path::Path;

#[test]
fn normalize_collapses_dot_and_dotdot() {
    assert_eq!(
        normalize(Path::new("/nix/store/./a/../b")),
        PathBuf::from("/nix/store/b")
    );
    assert_eq!(
        normalize(Path::new("/a/b/c/../../d")),
        PathBuf::from("/a/d")
    );
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
    assert!(is_inside(
        Path::new("/nix/store/abc"),
        Path::new("/nix/store")
    ));
    assert!(is_inside(Path::new("/nix/store"), Path::new("/nix/store")));
    assert!(!is_inside(Path::new("/nix"), Path::new("/nix/store")));
}

#[test]
fn is_inside_rejects_sibling_prefix() {
    // component-wise containment: store-extra is NOT inside store.
    assert!(!is_inside(
        Path::new("/nix/store-extra/x"),
        Path::new("/nix/store")
    ));
    assert!(!is_inside(
        Path::new("/nix/storex"),
        Path::new("/nix/store")
    ));
}

#[test]
fn is_inside_normalizes_first() {
    assert!(is_inside(
        Path::new("/nix/store/../store/abc"),
        Path::new("/nix/store")
    ));
    assert!(!is_inside(
        Path::new("/nix/store/../../etc"),
        Path::new("/nix/store")
    ));
}

#[test]
fn classify_realizes_target_inside_resolution_root() {
    let r = classify(
        Path::new("/nix/store/AAAA-htop"),
        Path::new("/nix/store"),
        Path::new("/var/farm"),
    );
    assert_eq!(
        r,
        Realization::Realize {
            rel: PathBuf::from("AAAA-htop")
        }
    );
}

#[test]
fn classify_realizes_nested_subpath() {
    let r = classify(
        Path::new("/nix/store/AAAA-htop/bin/htop"),
        Path::new("/nix/store"),
        Path::new("/var/farm"),
    );
    assert_eq!(
        r,
        Realization::Realize {
            rel: PathBuf::from("AAAA-htop/bin/htop")
        }
    );
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
    assert_eq!(
        r,
        Realization::Realize {
            rel: PathBuf::from("")
        }
    );
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
    assert_eq!(
        r,
        Realization::Realize {
            rel: PathBuf::from("AAAA-htop")
        }
    );
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
    assert_eq!(
        r,
        Realization::Realize {
            rel: PathBuf::from("hash-pkg/lib/x.so")
        }
    );
}
