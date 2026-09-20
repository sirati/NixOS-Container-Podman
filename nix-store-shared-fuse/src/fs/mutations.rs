macro_rules! read_only_operations {
    () => {
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
    };
}

pub(super) use read_only_operations;
