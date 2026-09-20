use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cap_std::fs::{Metadata, MetadataExt};
use fuser::{FileAttr, FileType};

use crate::realize::{self, Realization};

use super::{Backing, Node, NodeKind, StoreFs};

impl StoreFs {
    /// Decide the node for a child `name` under bind-backed `parent_rel`.
    /// Returns None if the child does not exist.
    pub(super) fn resolve_bind_child(&self, parent_rel: &Path, name: &OsStr) -> Option<Node> {
        let child_rel = if parent_rel.as_os_str().is_empty() {
            PathBuf::from(name)
        } else {
            parent_rel.join(name)
        };

        let md = self.bind_dir.symlink_metadata(&child_rel).ok()?;
        let ft = md.file_type();

        if ft.is_symlink() {
            // Read the RAW target (read_link_contents allows absolute targets;
            // plain read_link refuses them).
            let raw_target = self.bind_dir.read_link_contents(&child_rel).ok()?;
            let link_dir = self.bind_logical(parent_rel);
            let abs_target = realize::resolve_target(&link_dir, &raw_target);

            match realize::classify(
                &abs_target,
                &self.resolution_root,
                &self.bind_target_logical,
            ) {
                Realization::Realize { rel } => {
                    // Verify the realized location is actually a directory,
                    // read through the redirect capability dir.
                    let realized_is_dir = if rel.as_os_str().is_empty() {
                        // redirect root itself.
                        true
                    } else {
                        self.redirect_dir
                            .metadata(&rel)
                            .map(|m| m.is_dir())
                            .unwrap_or(false)
                    };
                    if realized_is_dir {
                        return Some(Node {
                            backing: Backing::Redirect,
                            rel,
                            kind: NodeKind::RealizedDir,
                        });
                    }
                    // Falls through to plain symlink.
                }
                Realization::KeepSymlink => {}
            }

            return Some(Node {
                backing: Backing::Bind,
                rel: child_rel,
                kind: NodeKind::Symlink,
            });
        }

        let kind = if ft.is_dir() {
            NodeKind::Dir
        } else if ft.is_file() {
            NodeKind::File
        } else {
            // Nix stores contain directories, regular files and symlinks.
            // Never pass sockets, devices or FIFOs through as regular files.
            return None;
        };
        Some(Node {
            backing: Backing::Bind,
            rel: child_rel,
            kind,
        })
    }

    /// Resolve a child `name` under a redirect-backed `parent_rel`. Content
    /// reached through a realized node is served verbatim: symlinks stay
    /// symlinks, no further realization.
    pub(super) fn resolve_redirect_child(&self, parent_rel: &Path, name: &OsStr) -> Option<Node> {
        let child_rel = if parent_rel.as_os_str().is_empty() {
            PathBuf::from(name)
        } else {
            parent_rel.join(name)
        };
        let md = self.redirect_dir.symlink_metadata(&child_rel).ok()?;
        let ft = md.file_type();
        let kind = if ft.is_symlink() {
            NodeKind::Symlink
        } else if ft.is_dir() {
            NodeKind::Dir
        } else if ft.is_file() {
            NodeKind::File
        } else {
            return None;
        };
        Some(Node {
            backing: Backing::Redirect,
            rel: child_rel,
            kind,
        })
    }

    /// Fetch metadata (following the realized-dir mapping) for a node.
    fn node_metadata(&self, node: &Node) -> std::io::Result<Metadata> {
        let dir = self.dir_for(node.backing);
        match node.kind {
            NodeKind::Symlink => {
                if node.rel.as_os_str().is_empty() {
                    dir.symlink_metadata(".")
                } else {
                    dir.symlink_metadata(&node.rel)
                }
            }
            // RealizedDir, Dir, File: stat the target itself.
            _ => {
                if node.rel.as_os_str().is_empty() {
                    dir.metadata(".")
                } else {
                    dir.metadata(&node.rel)
                }
            }
        }
    }

    pub(super) fn attr_for(&self, ino: u64, node: &Node) -> Option<FileAttr> {
        let md = self.node_metadata(node).ok()?;
        Some(metadata_to_attr(ino, node.kind, &md))
    }
}
fn system_time(secs: i64, nsec: i64) -> SystemTime {
    if secs >= 0 {
        UNIX_EPOCH + Duration::new(secs as u64, nsec.max(0) as u32)
    } else {
        UNIX_EPOCH - Duration::new((-secs) as u64, nsec.max(0) as u32)
    }
}

fn metadata_to_attr(ino: u64, kind: NodeKind, md: &Metadata) -> FileAttr {
    let (file_type, size) = match kind {
        NodeKind::RealizedDir | NodeKind::Dir => (FileType::Directory, md.size()),
        NodeKind::File => (FileType::RegularFile, md.size()),
        NodeKind::Symlink => (FileType::Symlink, md.size()),
    };

    // Preserve the underlying permission bits (e.g. 0444/0555 store modes).
    // For a realized dir `md` is the real target directory's metadata
    // (node_metadata stats through the redirect capability, see fs.rs), so
    // this carries the target's own mode/uid/gid/mtime - not a synthesized one.
    let perm = (md.mode() & 0o7777) as u16;

    FileAttr {
        ino,
        size,
        blocks: md.blocks(),
        atime: system_time(md.atime(), md.atime_nsec()),
        mtime: system_time(md.mtime(), md.mtime_nsec()),
        ctime: system_time(md.ctime(), md.ctime_nsec()),
        crtime: UNIX_EPOCH,
        kind: file_type,
        perm,
        nlink: md.nlink().max(1) as u32,
        uid: md.uid(),
        gid: md.gid(),
        rdev: md.rdev() as u32,
        blksize: md.blksize().max(512) as u32,
        flags: 0,
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::symlink;
    use std::os::unix::net::UnixListener;

    use cap_std::ambient_authority;
    use cap_std::fs::Dir;

    use super::*;

    fn fixture() -> (PathBuf, StoreFs) {
        let base = std::env::temp_dir().join(format!(
            "nix-store-shared-fuse-nodes-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock after epoch")
                .as_nanos()
        ));
        let bind = base.join("bind");
        let redirect = base.join("redirect");
        fs::create_dir_all(&bind).expect("create bind root");
        fs::create_dir_all(&redirect).expect("create redirect root");
        fs::write(redirect.join("file"), b"regular").expect("write regular file");
        fs::create_dir(redirect.join("dir")).expect("create directory");
        symlink("file", redirect.join("link")).expect("create symlink");
        UnixListener::bind(redirect.join("socket")).expect("create Unix socket");

        let fs = StoreFs::new(
            Dir::open_ambient_dir(&bind, ambient_authority()).expect("open bind root"),
            Dir::open_ambient_dir(&redirect, ambient_authority()).expect("open redirect root"),
            PathBuf::from("/nix/store"),
            PathBuf::from("/farm"),
            16,
        );
        (base, fs)
    }

    #[test]
    fn redirect_exposes_only_store_file_types() {
        let (base, fs) = fixture();
        assert_eq!(
            fs.resolve_redirect_child(Path::new(""), OsStr::new("file"))
                .map(|node| node.kind),
            Some(NodeKind::File)
        );
        assert_eq!(
            fs.resolve_redirect_child(Path::new(""), OsStr::new("dir"))
                .map(|node| node.kind),
            Some(NodeKind::Dir)
        );
        assert_eq!(
            fs.resolve_redirect_child(Path::new(""), OsStr::new("link"))
                .map(|node| node.kind),
            Some(NodeKind::Symlink)
        );
        assert!(fs
            .resolve_redirect_child(Path::new(""), OsStr::new("socket"))
            .is_none());
        drop(fs);
        fs::remove_dir_all(base).expect("remove fixture");
    }
}
