//! ExecCondition of every prison service unit:
//!
//!   prison-store-check --systemctl <path> --systemd-run <path> --unit <this.service>
//!                      [--skips <dir>] --view <view.service> <bind target> [--view ...]
//!
//! Exit 0: every view serves this unit's closure. Exit 1: some did not; a
//! restart of those views and of this unit is queued, a recheck is armed,
//! and this start is skipped rather than failed, so it neither runs against
//! the old store nor reports a failure for something that heals itself.
//! Exit 255: the check itself could not run, or the unit was skipped too
//! often in a row, which ExecCondition treats as a failure.
//!
//!   prison-store-check --recheck --systemctl <path> --unit <this.service>
//!
//! Run by the armed timer: starts the unit again unless it is running.

use prison_store_check::{check, recheck, Outcome, Skips, System, View};
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::exit;

const STALE: i32 = 1;
const ERROR: i32 = 255;
const SKIPS: &str = "/run/prison-store-check";

fn usage(msg: &str) -> ! {
    eprintln!("prison-store-check: {msg}");
    eprintln!(
        "usage: prison-store-check --systemctl <path> --systemd-run <path> --unit <unit> [--skips <dir>] --view <unit> <bind target> [--view ...]\n       prison-store-check --recheck --systemctl <path> --unit <unit>"
    );
    exit(ERROR)
}

fn utf8(arg: Option<OsString>, what: &str) -> String {
    arg.unwrap_or_else(|| usage(&format!("missing {what}")))
        .into_string()
        .unwrap_or_else(|_| usage(&format!("{what} is not UTF-8")))
}

fn main() {
    let mut args = std::env::args_os().skip(1);
    let mut systemctl = None;
    let mut systemd_run = None;
    let mut unit = None;
    let mut skips = PathBuf::from(SKIPS);
    let mut rechecking = false;
    let mut views = Vec::new();
    while let Some(flag) = args.next() {
        match flag.to_str() {
            Some("--systemctl") => systemctl = Some(args.next().unwrap_or_else(|| usage("missing systemctl path"))),
            Some("--systemd-run") => systemd_run = Some(args.next().unwrap_or_else(|| usage("missing systemd-run path"))),
            Some("--unit") => unit = Some(utf8(args.next(), "unit")),
            Some("--skips") => skips = args.next().unwrap_or_else(|| usage("missing skips directory")).into(),
            Some("--recheck") => rechecking = true,
            Some("--view") => {
                let unit = utf8(args.next(), "view unit");
                let target = args.next().unwrap_or_else(|| usage("missing bind target"));
                views.push(View { unit, target });
            }
            _ => usage(&format!("unknown argument {}", flag.to_string_lossy())),
        }
    }
    let systemctl = systemctl.unwrap_or_else(|| usage("missing --systemctl"));
    let unit = unit.unwrap_or_else(|| usage("missing --unit"));
    let mut log = |line: String| eprintln!("prison-store-check: {line}");
    if rechecking {
        if !views.is_empty() || systemd_run.is_some() {
            usage("--recheck takes only --systemctl and --unit");
        }
        let host = System { systemctl: systemctl.into(), systemd_run: None, proc_root: "/proc".into() };
        if let Err(e) = recheck(&host, &unit, &mut log) {
            eprintln!("prison-store-check: {e}");
            exit(ERROR);
        }
        exit(0);
    }
    let systemd_run = systemd_run.unwrap_or_else(|| usage("missing --systemd-run"));
    if views.is_empty() {
        usage("no --view given");
    }
    let host = System { systemctl: systemctl.into(), systemd_run: Some(systemd_run.into()), proc_root: "/proc".into() };
    match check(&host, &Skips { dir: skips }, &unit, &views, &mut log) {
        Ok(Outcome::Fresh) => exit(0),
        Ok(Outcome::Restarting(_)) => exit(STALE),
        Ok(Outcome::GaveUp(_)) => exit(ERROR),
        Err(e) => {
            eprintln!("prison-store-check: {e}");
            exit(ERROR)
        }
    }
}
