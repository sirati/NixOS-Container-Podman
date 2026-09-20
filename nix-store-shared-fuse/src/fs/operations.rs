use std::ffi::OsStr;
use std::path::Path;
use std::time::{Duration, SystemTime};

use fuser::{
    consts, FileType, Filesystem, KernelConfig, ReplyAttr, ReplyData, ReplyDirectory, ReplyEmpty,
    ReplyEntry, ReplyOpen, ReplyStatfs, Request,
};
use libc::{EACCES, EINVAL, EIO, EISDIR, ENOENT, ENOTDIR, EROFS};
use log::debug;

use super::mutations::read_only_operations;
use super::{Backing, Node, NodeKind, StoreFs};

const TTL: Duration = Duration::from_secs(1);

impl Filesystem for StoreFs {
    fn init(
        &mut self,
        _req: &Request<'_>,
        config: &mut KernelConfig,
    ) -> Result<(), std::ffi::c_int> {
        // Passthrough-only: the kernel serves all file content straight
        // from the backing files. Fail the mount if the kernel cannot do
        // it rather than silently falling back to userspace read-through.
        if let Err(unsupported) = config.add_capabilities(consts::FUSE_PASSTHROUGH) {
            log::error!("kernel lacks FUSE_PASSTHROUGH (unsupported bits: {unsupported:#x})");
            return Err(EIO);
        }
        if let Err(nearest) = config.set_max_stack_depth(2) {
            log::error!("kernel rejects max_stack_depth 2 (nearest: {nearest})");
            return Err(EIO);
        }
        Ok(())
    }

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

    fn getattr(&mut self, _req: &Request<'_>, ino: u64, _fh: Option<u64>, reply: ReplyAttr) {
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
        let node = match self.nodes.get(&ino) {
            Some(n) if n.kind == NodeKind::File => n.clone(),
            Some(n) if matches!(n.kind, NodeKind::Dir | NodeKind::RealizedDir) => {
                reply.error(EISDIR);
                return;
            }
            Some(_) => {
                reply.error(EINVAL);
                return;
            }
            None => {
                reply.error(ENOENT);
                return;
            }
        };
        // Passthrough-only: hand the kernel the backing file. All reads,
        // mmaps and execs then bypass this process entirely.
        match self.backing_get_or(ino, &node, &reply) {
            Ok((fh, id)) => reply.opened_passthrough(fh, 0, &id),
            Err(e) => {
                debug!(
                    "open ino {ino} ({}): passthrough setup failed: {e}",
                    node.rel.display()
                );
                reply.error(e.raw_os_error().unwrap_or(EIO))
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn read(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        _fh: u64,
        _offset: i64,
        _size: u32,
        _flags: i32,
        _lock_owner: Option<u64>,
        reply: ReplyData,
    ) {
        // Unreachable: every successful open uses passthrough, so the kernel
        // serves content itself and never issues read requests. Fail loudly
        // if that ever changes.
        reply.error(EIO);
    }

    fn release(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        fh: u64,
        _flags: i32,
        _lock_owner: Option<u64>,
        _flush: bool,
        reply: ReplyEmpty,
    ) {
        self.backing_put(fh);
        reply.ok();
    }

    fn statfs(&mut self, _req: &Request<'_>, _ino: u64, reply: ReplyStatfs) {
        // Synthetic, read-only: report a large pseudo-filesystem with no space.
        reply.statfs(0, 0, 0, 0, 0, 512, 255, 512);
    }

    read_only_operations!();

    fn access(&mut self, _req: &Request<'_>, ino: u64, _mask: i32, reply: ReplyEmpty) {
        if self.nodes.contains_key(&ino) {
            reply.ok();
        } else {
            reply.error(EACCES);
        }
    }
}
