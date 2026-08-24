//! nix-store-shared-fuse: a read-only FUSE filesystem that serves a Nix
//! "store symlink-farm" directory, transparently realizing qualifying farm
//! symlinks (e.g. `AAAA-htop -> /nix/store/AAAA-htop`) into real directory
//! content read from a possibly-relocated backing store.
//!
//! See README.md for the full model.

mod fs;
mod realize;

use std::path::PathBuf;

use anyhow::{Context, Result};
use cap_std::ambient_authority;
use cap_std::fs::Dir;
use clap::Parser;
use fuser::MountOption;

use crate::fs::StoreFs;
use crate::realize::normalize;

#[derive(Parser, Debug)]
#[command(
    name = "nix-store-shared-fuse",
    about = "Read-only FUSE filesystem that realizes Nix store-farm symlinks against a (relocated) backing store"
)]
struct Args {
    /// Directory served as the FS root (the symlink farm). Real files/subdirs
    /// here are served as-is, read-only.
    #[arg(long)]
    bind_target: PathBuf,

    /// Logical prefix a farm symlink's target must lie within to qualify
    /// (membership + loop check, and to compute the relative subpath),
    /// e.g. /nix/store.
    #[arg(long)]
    resolution_root: PathBuf,

    /// Physical root the realized content is read from (e.g. a nix-portable
    /// relocated store). Defaults to --resolution-root when omitted.
    #[arg(long)]
    redirect_root: Option<PathBuf>,

    /// Pass FUSE allow_other so non-mounting users (e.g. container session
    /// users) can read the mount.
    #[arg(long)]
    allow_other: bool,

    /// Mount with nosuid (strip set-user-ID/set-group-ID bits). Off by
    /// default so set-uid binaries in the served store keep working; opt in
    /// to harden. (Note: unprivileged/user-namespace FUSE mounts are often
    /// forced nosuid by the kernel regardless.)
    #[arg(long)]
    nosuid: bool,

    /// Run in the foreground (do not return until unmounted). This is the
    /// default; the flag exists for explicit systemd/launcher use.
    #[arg(long, short = 'f')]
    foreground: bool,

    /// Mountpoint.
    mountpoint: PathBuf,
}

/// Raise this process's soft RLIMIT_NOFILE to its hard limit.
///
/// Every file held open behind the mount costs a descriptor in *this* process,
/// so the soft limit -- 1024 on a stock login, and whatever systemd hands a
/// unit otherwise -- caps how many files everything served by this mount can
/// have open at once, regardless of the limits the readers themselves run
/// under. Hitting it surfaces as EMFILE from unrelated processes, which is a
/// long way from the cause.
///
/// Raising the soft limit up to the hard limit never requires privilege; only
/// raising the hard limit does. So the hard limit is the policy knob (set by
/// whoever starts this process) and the soft limit is simply wrong to leave
/// below it.
fn raise_nofile_to_hard() -> Result<(u64, u64)> {
    // SAFETY: getrlimit/setrlimit on a zeroed rlimit are well-defined; the
    // pointer is to a live local for the duration of each call.
    unsafe {
        let mut rl: libc::rlimit = std::mem::zeroed();
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut rl) != 0 {
            return Err(anyhow::Error::from(std::io::Error::last_os_error()))
                .context("getrlimit(RLIMIT_NOFILE)");
        }
        let before = rl.rlim_cur;
        if rl.rlim_cur < rl.rlim_max {
            rl.rlim_cur = rl.rlim_max;
            if libc::setrlimit(libc::RLIMIT_NOFILE, &rl) != 0 {
                return Err(anyhow::Error::from(std::io::Error::last_os_error()))
                    .context("setrlimit(RLIMIT_NOFILE): raising the soft limit to the hard limit");
            }
        }
        Ok((before as u64, rl.rlim_max as u64))
    }
}

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    // Before anything opens a descriptor.
    match raise_nofile_to_hard() {
        Ok((before, hard)) if before < hard => {
            log::info!("RLIMIT_NOFILE: raised soft limit {before} -> {hard}")
        }
        Ok((cur, _)) => log::debug!("RLIMIT_NOFILE: soft limit already at the hard limit ({cur})"),
        Err(e) => log::warn!("could not raise RLIMIT_NOFILE: {e:#}"),
    }

    let args = Args::parse();

    let resolution_root = normalize(&args.resolution_root);
    let bind_target_logical = normalize(&args.bind_target);
    let redirect_root = args
        .redirect_root
        .clone()
        .map(|p| normalize(&p))
        .unwrap_or_else(|| resolution_root.clone());

    fs::log_config(
        &bind_target_logical,
        &resolution_root,
        &redirect_root,
        &args.mountpoint,
    );

    // Open the two capability roots. ALL subsequent I/O is confined to these
    // handles via *at-style relative operations.
    let bind_dir = Dir::open_ambient_dir(&args.bind_target, ambient_authority())
        .with_context(|| format!("opening bind_target {}", args.bind_target.display()))?;
    let redirect_dir = Dir::open_ambient_dir(&redirect_root, ambient_authority())
        .with_context(|| format!("opening redirect_root {}", redirect_root.display()))?;

    let filesystem = StoreFs::new(
        bind_dir,
        redirect_dir,
        resolution_root,
        bind_target_logical,
    );

    // nodev is always on: a Nix store legitimately contains no device nodes.
    // nosuid is opt-in (default off) so set-uid binaries in the store keep
    // working unless the user chooses to harden.
    let mut options = vec![
        MountOption::RO,
        MountOption::FSName("nix-store-shared".to_string()),
        MountOption::Subtype("nixstoreshared".to_string()),
        MountOption::NoDev,
    ];
    if args.nosuid {
        options.push(MountOption::NoSuid);
    }
    if args.allow_other {
        options.push(MountOption::AllowOther);
    }

    // We always run in the foreground (the process owns the mount session).
    // `foreground` is accepted for clarity but does not change behaviour.
    let _ = args.foreground;

    log::info!("mounting at {}", args.mountpoint.display());
    fuser::mount2(filesystem, &args.mountpoint, &options)
        .with_context(|| format!("mounting FUSE at {}", args.mountpoint.display()))?;

    Ok(())
}
