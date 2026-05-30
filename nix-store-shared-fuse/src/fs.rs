//! The FUSE filesystem implementation.
//!
//! Confinement model: ALL filesystem I/O goes through two `cap_std::fs::Dir`
//! capability handles (`bind_dir` and `redirect_dir`). Every path we touch is
//! relative to one of those handles and is opened with `*at`-style operations,
//! so even a symlink target containing `..` cannot escape the two roots.
//! `resolution_root` is purely logical (a path prefix) and is never opened.

use std::collections::HashMap;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cap_std::fs::{Dir, Metadata, MetadataExt};
use fuser::{
    FileAttr, FileType, Filesystem, ReplyAttr, ReplyData, ReplyDirectory, ReplyEmpty, ReplyEntry,
    ReplyOpen, ReplyStatfs, Request,
};
use libc::{EACCES, EINVAL, EIO, EISDIR, ENOENT, ENOTDIR, EROFS};
use log::debug;

use crate::realize::{self, Realization};

const TTL: Duration = Duration::from_secs(1);
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
        }
    }

    fn dir_for(&self, backing: Backing) -> &Dir {
        match backing {
            Backing::Bind => &self.bind_dir,
            Backing::Redirect => &self.redirect_dir,
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

    /// Decide the node for a child `name` under bind-backed `parent_rel`.
    /// Returns None if the child does not exist.
    fn resolve_bind_child(&self, parent_rel: &Path, name: &OsStr) -> Option<Node> {
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

            match realize::classify(&abs_target, &self.resolution_root, &self.bind_target_logical) {
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
        } else {
            NodeKind::File
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
    fn resolve_redirect_child(&self, parent_rel: &Path, name: &OsStr) -> Option<Node> {
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
        } else {
            NodeKind::File
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

    fn attr_for(&self, ino: u64, node: &Node) -> Option<FileAttr> {
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
    // For realized dirs the underlying object is a symlink; force a sane
    // directory mode derived from the redirect-root dir we will serve.
    let perm = (md.mode() & 0o7777) as u16;
    let perm = if matches!(kind, NodeKind::RealizedDir) && (md.mode() & libc::S_IFMT) != libc::S_IFDIR
    {
        // Underlying was a symlink (lstat); present a read+exec dir mode.
        0o555
    } else {
        perm
    };

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

impl Filesystem for StoreFs {
    fn lookup(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEntry) {
        let parent_node = match self.nodes.get(&parent) {
            Some(n) => n.clone(),
            None => {
                reply.error(ENOENT);
                return;
            }
        };
        if !matches!(parent_node.kind, NodeKind::Dir | NodeKind::RealizedDir) {
            reply.error(ENOTDIR);
            return;
        }

        let child = match parent_node.backing {
            Backing::Bind => self.resolve_bind_child(&parent_node.rel, name),
            Backing::Redirect => self.resolve_redirect_child(&parent_node.rel, name),
        };
        let child = match child {
            Some(c) => c,
            None => {
                reply.error(ENOENT);
                return;
            }
        };

        let attr = match self.attr_for(0, &child) {
            Some(a) => a,
            None => {
                reply.error(EIO);
                return;
            }
        };
        let ino = self.intern(parent, name, child);
        let mut attr = attr;
        attr.ino = ino;
        reply.entry(&TTL, &attr, 0);
    }

    fn getattr(&mut self, _req: &Request<'_>, ino: u64, reply: ReplyAttr) {
        let node = match self.nodes.get(&ino) {
            Some(n) => n.clone(),
            None => {
                reply.error(ENOENT);
                return;
            }
        };
        match self.attr_for(ino, &node) {
            Some(attr) => reply.attr(&TTL, &attr),
            None => reply.error(EIO),
        }
    }

    fn readlink(&mut self, _req: &Request<'_>, ino: u64, reply: ReplyData) {
        let node = match self.nodes.get(&ino) {
            Some(n) => n.clone(),
            None => {
                reply.error(ENOENT);
                return;
            }
        };
        if node.kind != NodeKind::Symlink {
            reply.error(EINVAL);
            return;
        }
        let dir = self.dir_for(node.backing);
        match dir.read_link_contents(&node.rel) {
            Ok(target) => reply.data(target.as_os_str().as_encoded_bytes()),
            Err(e) => reply.error(e.raw_os_error().unwrap_or(EIO)),
        }
    }

    fn opendir(&mut self, _req: &Request<'_>, ino: u64, _flags: i32, reply: ReplyOpen) {
        match self.nodes.get(&ino) {
            Some(n) if matches!(n.kind, NodeKind::Dir | NodeKind::RealizedDir) => {
                reply.opened(0, 0)
            }
            Some(_) => reply.error(ENOTDIR),
            None => reply.error(ENOENT),
        }
    }

    fn readdir(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        _fh: u64,
        offset: i64,
        mut reply: ReplyDirectory,
    ) {
        let node = match self.nodes.get(&ino) {
            Some(n) => n.clone(),
            None => {
                reply.error(ENOENT);
                return;
            }
        };
        if !matches!(node.kind, NodeKind::Dir | NodeKind::RealizedDir) {
            reply.error(ENOTDIR);
            return;
        }

        // Collect synthetic "." and ".." plus real entries, then page by offset.
        let mut entries: Vec<(u64, FileType, std::ffi::OsString)> = Vec::new();
        entries.push((ino, FileType::Directory, std::ffi::OsString::from(".")));
        entries.push((ino, FileType::Directory, std::ffi::OsString::from("..")));

        let dir = self.dir_for(node.backing);
        let read_dir = if node.rel.as_os_str().is_empty() {
            dir.read_dir(".")
        } else {
            dir.read_dir(&node.rel)
        };
        let read_dir = match read_dir {
            Ok(rd) => rd,
            Err(e) => {
                reply.error(e.raw_os_error().unwrap_or(EIO));
                return;
            }
        };

        // We must allocate inodes for entries so the kernel can later lookup;
        // gather names first, then intern (intern needs &mut self).
        let mut pending: Vec<(std::ffi::OsString, Node)> = Vec::new();
        for entry in read_dir {
            let entry = match entry {
                Ok(e) => e,
                Err(_) => continue,
            };
            let name = entry.file_name();
            let child = match node.backing {
                Backing::Bind => self.resolve_bind_child(&node.rel, &name),
                Backing::Redirect => self.resolve_redirect_child(&node.rel, &name),
            };
            if let Some(child) = child {
                pending.push((name, child));
            }
        }

        for (name, child) in pending {
            let ft = match child.kind {
                NodeKind::Dir | NodeKind::RealizedDir => FileType::Directory,
                NodeKind::File => FileType::RegularFile,
                NodeKind::Symlink => FileType::Symlink,
            };
            let child_ino = self.intern(ino, &name, child);
            entries.push((child_ino, ft, name));
        }

        for (i, (e_ino, e_kind, e_name)) in entries.into_iter().enumerate().skip(offset as usize) {
            // offset passed to reply.add is the NEXT entry's offset.
            if reply.add(e_ino, (i + 1) as i64, e_kind, &e_name) {
                break;
            }
        }
        reply.ok();
    }

    fn releasedir(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        _fh: u64,
        _flags: i32,
        reply: ReplyEmpty,
    ) {
        reply.ok();
    }

    fn open(&mut self, _req: &Request<'_>, ino: u64, flags: i32, reply: ReplyOpen) {
        // Read-only filesystem: reject any write-intent open.
        let acc = flags & libc::O_ACCMODE;
        if acc != libc::O_RDONLY {
            reply.error(EROFS);
            return;
        }
        match self.nodes.get(&ino) {
            Some(n) if n.kind == NodeKind::File => reply.opened(0, 0),
            Some(n) if matches!(n.kind, NodeKind::Dir | NodeKind::RealizedDir) => {
                reply.error(EISDIR)
            }
            Some(_) => reply.error(EINVAL),
            None => reply.error(ENOENT),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn read(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        _fh: u64,
        offset: i64,
        size: u32,
        _flags: i32,
        _lock_owner: Option<u64>,
        reply: ReplyData,
    ) {
        let node = match self.nodes.get(&ino) {
            Some(n) => n.clone(),
            None => {
                reply.error(ENOENT);
                return;
            }
        };
        if node.kind != NodeKind::File {
            reply.error(EISDIR);
            return;
        }
        if offset < 0 {
            reply.error(EINVAL);
            return;
        }

        let dir = self.dir_for(node.backing);
        // Open via capability dir and read the requested window. Store files
        // are small enough that a full read + slice is acceptable; we still
        // bound the returned slice to `size`.
        match dir.read(&node.rel) {
            Ok(data) => {
                let start = (offset as usize).min(data.len());
                let end = start.saturating_add(size as usize).min(data.len());
                reply.data(&data[start..end]);
            }
            Err(e) => reply.error(e.raw_os_error().unwrap_or(EIO)),
        }
    }

    fn release(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        _fh: u64,
        _flags: i32,
        _lock_owner: Option<u64>,
        _flush: bool,
        reply: ReplyEmpty,
    ) {
        reply.ok();
    }

    fn statfs(&mut self, _req: &Request<'_>, _ino: u64, reply: ReplyStatfs) {
        // Synthetic, read-only: report a large pseudo-filesystem with no space.
        reply.statfs(0, 0, 0, 0, 0, 512, 255, 512);
    }

    // ---- Mutating operations: rejected (read-only filesystem) ----

    fn setattr(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        _mode: Option<u32>,
        _uid: Option<u32>,
        _gid: Option<u32>,
        _size: Option<u64>,
        _atime: Option<fuser::TimeOrNow>,
        _mtime: Option<fuser::TimeOrNow>,
        _ctime: Option<SystemTime>,
        _fh: Option<u64>,
        _crtime: Option<SystemTime>,
        _chgtime: Option<SystemTime>,
        _bkuptime: Option<SystemTime>,
        _flags: Option<u32>,
        reply: ReplyAttr,
    ) {
        reply.error(EROFS);
    }

    fn mknod(
        &mut self,
        _req: &Request<'_>,
        _parent: u64,
        _name: &OsStr,
        _mode: u32,
        _umask: u32,
        _rdev: u32,
        reply: ReplyEntry,
    ) {
        reply.error(EROFS);
    }

    fn mkdir(
        &mut self,
        _req: &Request<'_>,
        _parent: u64,
        _name: &OsStr,
        _mode: u32,
        _umask: u32,
        reply: ReplyEntry,
    ) {
        reply.error(EROFS);
    }

    fn unlink(&mut self, _req: &Request<'_>, _parent: u64, _name: &OsStr, reply: ReplyEmpty) {
        reply.error(EROFS);
    }

    fn rmdir(&mut self, _req: &Request<'_>, _parent: u64, _name: &OsStr, reply: ReplyEmpty) {
        reply.error(EROFS);
    }

    fn symlink(
        &mut self,
        _req: &Request<'_>,
        _parent: u64,
        _link_name: &OsStr,
        _target: &Path,
        reply: ReplyEntry,
    ) {
        reply.error(EROFS);
    }

    fn rename(
        &mut self,
        _req: &Request<'_>,
        _parent: u64,
        _name: &OsStr,
        _newparent: u64,
        _newname: &OsStr,
        _flags: u32,
        reply: ReplyEmpty,
    ) {
        reply.error(EROFS);
    }

    fn link(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        _newparent: u64,
        _newname: &OsStr,
        reply: ReplyEntry,
    ) {
        reply.error(EROFS);
    }

    #[allow(clippy::too_many_arguments)]
    fn write(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        _fh: u64,
        _offset: i64,
        _data: &[u8],
        _write_flags: u32,
        _flags: i32,
        _lock_owner: Option<u64>,
        reply: fuser::ReplyWrite,
    ) {
        reply.error(EROFS);
    }

    fn create(
        &mut self,
        _req: &Request<'_>,
        _parent: u64,
        _name: &OsStr,
        _mode: u32,
        _umask: u32,
        _flags: i32,
        reply: fuser::ReplyCreate,
    ) {
        reply.error(EROFS);
    }

    fn setxattr(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        _name: &OsStr,
        _value: &[u8],
        _flags: i32,
        _position: u32,
        reply: ReplyEmpty,
    ) {
        reply.error(EROFS);
    }

    fn access(&mut self, _req: &Request<'_>, ino: u64, _mask: i32, reply: ReplyEmpty) {
        if self.nodes.contains_key(&ino) {
            reply.ok();
        } else {
            reply.error(EACCES);
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
