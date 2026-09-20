//! The FUSE filesystem implementation.
//!
//! Confinement model: ALL filesystem I/O goes through two `cap_std::fs::Dir`
//! capability handles (`bind_dir` and `redirect_dir`). Every path we touch is
//! relative to one of those handles and is opened with `*at`-style operations,
//! so even a symlink target containing `..` cannot escape the two roots.
//! `resolution_root` is purely logical (a path prefix) and is never opened.
//!
//! File content is served passthrough-only: `open` hands the kernel the
//! backing file and every `read`/`mmap`/`exec` then bypasses this process
//! entirely. There is no userspace read path.

use std::collections::HashMap;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::rc::{Rc, Weak};

use cap_std::fs::Dir;
use fuser::{BackingId, ReplyOpen};
use libc::EMFILE;
use log::debug;

use crate::backing;

mod mutations;
mod nodes;
mod operations;

const FUSE_ROOT_ID: u64 = 1;

/// Which capability root an inode's content is read from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Backing {
    /// Path is relative to the bind_target (the farm) capability dir.
    Bind,
    /// Path is relative to the redirect_root (the relocated store) capability
    /// dir. Reached by following a realized farm symlink.
    Redirect,
}

/// Logical kind of a node as the FS presents it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NodeKind {
    Dir,
    File,
    Symlink,
    /// A farm symlink that was realized: presented as a directory even though
    /// the underlying object is a symlink. Always backed by `Redirect`.
    RealizedDir,
}

#[derive(Debug, Clone)]
struct Node {
    backing: Backing,
    /// Path relative to the backing capability dir (never absolute, never
    /// containing a leading `/`). Empty path means the root of that dir.
    rel: PathBuf,
    kind: NodeKind,
}

pub struct StoreFs {
    bind_dir: Dir,
    redirect_dir: Dir,
    resolution_root: PathBuf,
    bind_target_logical: PathBuf,

    /// inode -> node.
    nodes: HashMap<u64, Node>,
    /// (parent_ino, name) -> child_ino, for stable inode reuse within a session.
    lookup_cache: HashMap<(u64, PathBuf), u64>,
    next_ino: u64,
    /// Passthrough backing-file cache: one kernel backing id per inode,
    /// shared by all open handles of that inode; each open handle holds a
    /// strong ref that is dropped at release.
    backing_by_handle: HashMap<u64, Rc<BackingId>>,
    backing_by_inode: HashMap<u64, Weak<BackingId>>,
    next_fh: u64,
    max_open_files: usize,
}

impl StoreFs {
    /// `bind_dir`/`redirect_dir` are pre-opened capability handles.
    /// `resolution_root` and `bind_target_logical` are the *logical* absolute
    /// paths used only for the realization predicate.
    pub fn new(
        bind_dir: Dir,
        redirect_dir: Dir,
        resolution_root: PathBuf,
        bind_target_logical: PathBuf,
        max_open_files: usize,
    ) -> Self {
        let mut nodes = HashMap::new();
        nodes.insert(
            FUSE_ROOT_ID,
            Node {
                backing: Backing::Bind,
                rel: PathBuf::new(),
                kind: NodeKind::Dir,
            },
        );
        StoreFs {
            bind_dir,
            redirect_dir,
            resolution_root,
            bind_target_logical,
            nodes,
            lookup_cache: HashMap::new(),
            next_ino: FUSE_ROOT_ID + 1,
            backing_by_handle: HashMap::new(),
            backing_by_inode: HashMap::new(),
            next_fh: 0,
            max_open_files,
        }
    }

    fn dir_for(&self, backing: Backing) -> &Dir {
        match backing {
            Backing::Bind => &self.bind_dir,
            Backing::Redirect => &self.redirect_dir,
        }
    }

    /// Open the backing file for a regular-file node, confined to its
    /// capability dir. cap-std opens relative to the dir handle (via
    /// `openat2(RESOLVE_BENEATH)` where the kernel supports it), so the open
    /// cannot escape the root. `O_NOFOLLOW` so a raced-in symlink is never
    /// followed here; the caller maps failure to an errno. The returned file
    /// is registered with the kernel as a passthrough backing file via
    /// fuser's upstream `ReplyOpen::open_backing`, which keeps its own
    /// reference -- this handle is closed when it drops.
    fn open_backing_file(&self, node: &Node) -> std::io::Result<cap_std::fs::File> {
        backing::open_readonly(self.dir_for(node.backing), &node.rel)
    }

    /// One kernel backing id per inode, shared by all its open handles.
    /// Each returned handle holds a strong ref dropped at release.
    fn backing_get_or(
        &mut self,
        ino: u64,
        node: &Node,
        reply: &ReplyOpen,
    ) -> std::io::Result<(u64, Rc<BackingId>)> {
        if self.backing_by_handle.len() >= self.max_open_files {
            return Err(std::io::Error::from_raw_os_error(EMFILE));
        }
        self.next_fh = self
            .next_fh
            .checked_add(1)
            .ok_or_else(|| std::io::Error::from_raw_os_error(EMFILE))?;
        let fh = self.next_fh;
        if let Some(id) = self.backing_by_inode.get(&ino).and_then(Weak::upgrade) {
            self.backing_by_handle.insert(fh, Rc::clone(&id));
            return Ok((fh, id));
        }
        let file = self.open_backing_file(node).map_err(|e| {
            debug!("backing_get_or ino {ino}: open_backing_file failed: {e}");
            e
        })?;
        let id = Rc::new(reply.open_backing(&file).map_err(|e| {
            // The kernel requires CAP_SYS_ADMIN for FUSE_DEV_IOC_BACKING_OPEN;
            // without it every open fails, so say so loudly instead of just
            // handing EPERM back to the reader.
            if e.raw_os_error() == Some(libc::EPERM) {
                log::warn!(
                    "backing_get_or ino {ino}: kernel refused passthrough backing registration (EPERM); the daemon needs CAP_SYS_ADMIN (e.g. systemd AmbientCapabilities=CAP_SYS_ADMIN)"
                );
            } else {
                debug!("backing_get_or ino {ino}: open_backing ioctl failed: {e}");
            }
            e
        })?);
        self.backing_by_inode.insert(ino, Rc::downgrade(&id));
        self.backing_by_handle.insert(fh, Rc::clone(&id));
        Ok((fh, id))
    }

    fn backing_put(&mut self, fh: u64) {
        if self.backing_by_handle.remove(&fh).is_none() {
            debug!("release: unknown fh {fh}");
        }
    }

    /// Allocate (or reuse) an inode for a child node.
    fn intern(&mut self, parent: u64, name: &OsStr, node: Node) -> u64 {
        let key = (parent, PathBuf::from(name));
        if let Some(&ino) = self.lookup_cache.get(&key) {
            // Refresh the stored node (kind/path are stable, but harmless).
            self.nodes.insert(ino, node);
            return ino;
        }
        let ino = self.next_ino;
        self.next_ino += 1;
        self.nodes.insert(ino, node);
        self.lookup_cache.insert(key, ino);
        ino
    }

    /// Compute the logical absolute path of a bind-backed relative path, used
    /// to seed the symlink-parent directory for relative-target resolution.
    fn bind_logical(&self, rel: &Path) -> PathBuf {
        if rel.as_os_str().is_empty() {
            self.bind_target_logical.clone()
        } else {
            self.bind_target_logical.join(rel)
        }
    }
}

/// Trace helper kept out of the hot path; used by main on verbose runs.
pub fn log_config(bind: &Path, resolution: &Path, redirect: &Path, mountpoint: &Path) {
    debug!(
        "bind_target={} resolution_root={} redirect_root={} mountpoint={}",
        bind.display(),
        resolution.display(),
        redirect.display(),
        mountpoint.display()
    );
}
