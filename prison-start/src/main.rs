//! Runs a prison service's `podman run` for its forking unit, and tells a
//! start the unit's own stop interrupted apart from a start that failed.
//!
//! A stop that lands while `podman run` is still starting the container makes
//! podman exit 1, the same status as a real failure. systemd signals the
//! control process before the rest of the unit's cgroup, so this process
//! receives the stop's SIGTERM before podman does. Only then does it end as
//! SIGTERM would have ended it, which systemd counts as a clean stop. Without
//! that signal, podman's own status is passed on unchanged.

use std::os::raw::c_int;
use std::os::unix::process::ExitStatusExt;
use std::process::{exit, Command};
use std::sync::atomic::{AtomicBool, Ordering};

const SIGTERM: c_int = 15;
const SIG_DFL: usize = 0;

extern "C" {
    fn signal(signum: c_int, handler: usize) -> usize;
    fn raise(sig: c_int) -> c_int;
}

static STOPPING: AtomicBool = AtomicBool::new(false);

extern "C" fn on_term(_: c_int) {
    STOPPING.store(true, Ordering::SeqCst);
}

fn die_by(sig: c_int) -> ! {
    unsafe {
        signal(sig, SIG_DFL);
        raise(sig);
    }
    exit(128 + sig)
}

fn main() {
    let mut args = std::env::args_os().skip(1);
    let Some(program) = args.next() else {
        eprintln!("prison-start: usage: prison-start <program> [args...]");
        exit(2);
    };
    unsafe {
        signal(SIGTERM, on_term as extern "C" fn(c_int) as usize);
    }
    let status = match Command::new(&program).args(args).status() {
        Ok(status) => status,
        Err(e) => {
            eprintln!("prison-start: cannot run {}: {e}", program.to_string_lossy());
            exit(127);
        }
    };
    if status.success() {
        exit(0);
    }
    if STOPPING.load(Ordering::SeqCst) {
        die_by(SIGTERM);
    }
    match (status.code(), status.signal()) {
        (Some(code), _) => exit(code),
        (None, Some(sig)) => die_by(sig),
        _ => exit(1),
    }
}
