//! Integration test exercising the realization decision against a real
//! on-disk farm + store layout via cap-std capability handles.
//!
//! This does NOT mount a FUSE filesystem (that requires `/dev/fuse` and is not
//! available in the build sandbox); it verifies the load-bearing interaction
//! between the pure path logic and cap-std, in particular that an absolute
//! farm-symlink target is readable with `read_link_contents` (plain
//! `read_link` refuses absolute targets) and that the realized location is
//! reachable through the redirect capability dir.
//!
//! Run with: `cargo test -- --ignored`.

#[path = "../src/realize.rs"]
mod realize;

use std::fs;
use std::os::unix::fs::symlink;
use std::path::PathBuf;

use cap_std::ambient_authority;
use cap_std::fs::Dir;

use realize::{classify, resolve_target, Realization};

fn unique_tmp(tag: &str) -> PathBuf {
    let mut p = std::env::temp_dir();
    p.push(format!(
        "nix-store-shared-fuse-{}-{}-{}",
        tag,
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    p
}

#[test]
#[ignore = "requires filesystem write access; run with --ignored"]
fn realize_through_cap_dirs() {
    let base = unique_tmp("e2e");
    let store = base.join("store"); // resolution_root AND physical store here
    let farm = base.join("farm"); // bind_target

    // Build a relocated store: <store>/AAAA-htop/bin/htop
    fs::create_dir_all(store.join("AAAA-htop/bin")).unwrap();
    fs::write(store.join("AAAA-htop/bin/htop"), b"ELF").unwrap();
    // A store-internal symlink that must remain a symlink when served verbatim.
    let dep_target = store.join("BBBB-dep/lib/libfoo.so");
    symlink(&dep_target, store.join("AAAA-htop/bin/lib.so")).unwrap();

    // Build the farm: AAAA-htop -> <store>/AAAA-htop (qualifies),
    // plus a non-qualifying symlink and a loop-back symlink. Targets use the
    // real absolute paths so the logical roots (= the real paths here) match.
    fs::create_dir_all(&farm).unwrap();
    symlink(store.join("AAAA-htop"), farm.join("AAAA-htop")).unwrap();
    symlink("/etc/hosts", farm.join("outsider")).unwrap();
    symlink(farm.join("AAAA-htop"), farm.join("loopback")).unwrap();

    // Logical roots (note: here resolution_root == redirect_root == <store>).
    let resolution_root = store.clone();
    let bind_target_logical = farm.clone();

    let bind_dir = Dir::open_ambient_dir(&farm, ambient_authority()).unwrap();
    let redirect_dir = Dir::open_ambient_dir(&store, ambient_authority()).unwrap();

    // --- qualifying farm symlink -> realized as directory ---
    let raw = bind_dir.read_link_contents("AAAA-htop").unwrap();
    assert_eq!(raw, store.join("AAAA-htop"));
    let abs = resolve_target(&bind_target_logical, &raw);
    match classify(&abs, &resolution_root, &bind_target_logical) {
        Realization::Realize { rel } => {
            assert_eq!(rel, PathBuf::from("AAAA-htop"));
            // Reachable through the redirect capability dir.
            assert!(redirect_dir.metadata(&rel).unwrap().is_dir());
            assert_eq!(
                redirect_dir.read("AAAA-htop/bin/htop").unwrap(),
                b"ELF".to_vec()
            );
            // Store-internal symlink stays a symlink, read verbatim.
            let inner = redirect_dir
                .read_link_contents("AAAA-htop/bin/lib.so")
                .unwrap();
            assert_eq!(inner, dep_target);
        }
        Realization::KeepSymlink => panic!("expected realize"),
    }

    // --- non-qualifying symlink (target outside resolution_root) ---
    let raw = bind_dir.read_link_contents("outsider").unwrap();
    let abs = resolve_target(&bind_target_logical, &raw);
    assert_eq!(
        classify(&abs, &resolution_root, &bind_target_logical),
        Realization::KeepSymlink
    );

    // --- loop-back symlink (target inside bind_target) stays a symlink ---
    let raw = bind_dir.read_link_contents("loopback").unwrap();
    let abs = resolve_target(&bind_target_logical, &raw);
    assert_eq!(
        classify(&abs, &resolution_root, &bind_target_logical),
        Realization::KeepSymlink
    );

    fs::remove_dir_all(&base).ok();
}
