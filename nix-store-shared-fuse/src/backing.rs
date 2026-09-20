//! Capability-confined opening of passthrough backing files.

use std::path::Path;

use cap_std::fs::{Dir, File, OpenOptions, OpenOptionsExt};
use libc::EIO;

/// Open one regular-file backing handle relative to an already-opened
/// capability directory. `O_NOFOLLOW` makes the final component race-safe;
/// cap-std confines every intermediate traversal to `dir`.
pub fn open_readonly(dir: &Dir, rel: &Path) -> std::io::Result<File> {
    if rel.as_os_str().is_empty() || rel.is_absolute() {
        return Err(std::io::Error::from_raw_os_error(EIO));
    }
    let mut options = OpenOptions::new();
    options.read(true);
    options.custom_flags(libc::O_NOFOLLOW);
    dir.open_with(rel, &options)
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::symlink;
    use std::path::PathBuf;

    use cap_std::ambient_authority;

    use super::*;

    fn fixture() -> (PathBuf, Dir) {
        let base = std::env::temp_dir().join(format!(
            "nix-store-shared-fuse-backing-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock after epoch")
                .as_nanos()
        ));
        fs::create_dir_all(base.join("root/in")).expect("create capability root");
        fs::create_dir_all(base.join("outside")).expect("create outside dir");
        fs::write(base.join("root/in/file"), b"inside").expect("write inside file");
        fs::write(base.join("outside/file"), b"outside").expect("write outside file");
        let dir = Dir::open_ambient_dir(base.join("root"), ambient_authority())
            .expect("open capability root");
        (base, dir)
    }

    #[test]
    fn opens_only_relative_regular_files() {
        let (base, dir) = fixture();
        assert!(open_readonly(&dir, Path::new("in/file")).is_ok());
        assert!(open_readonly(&dir, Path::new("/etc/passwd")).is_err());
        assert!(open_readonly(&dir, Path::new("")).is_err());
        drop(dir);
        fs::remove_dir_all(base).expect("remove fixture");
    }

    #[test]
    fn refuses_final_and_intermediate_symlink_escape() {
        let (base, dir) = fixture();
        symlink(base.join("outside/file"), base.join("root/final")).expect("create final symlink");
        symlink(base.join("outside"), base.join("root/escape"))
            .expect("create intermediate symlink");
        assert!(open_readonly(&dir, Path::new("final")).is_err());
        assert!(open_readonly(&dir, Path::new("escape/file")).is_err());
        assert!(open_readonly(&dir, Path::new("../outside/file")).is_err());
        drop(dir);
        fs::remove_dir_all(base).expect("remove fixture");
    }
}
