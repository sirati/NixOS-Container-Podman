//! ExecCondition of every prison service unit:
//!
//!   prison-store-check --systemctl <path> --unit <this.service>
//!                      --view <view.service> <bind target> [--view ...]
//!
//! Exit 0: every view serves this unit's closure. Exit 1: some did not; a
//! restart of those views and of this unit is queued, and this start is
//! skipped rather than failed, so it neither runs against the old store nor
//! reports a failure for something that heals itself. Exit 255: the check
//! itself could not run, which ExecCondition treats as a failure.

use prison_store_check::{check, Outcome, System, View};
use std::ffi::OsString;
use std::process::exit;

const STALE: i32 = 1;
const ERROR: i32 = 255;

fn usage(msg: &str) -> ! {
    eprintln!("prison-store-check: {msg}");
    eprintln!(
        "usage: prison-store-check --systemctl <path> --unit <unit> --view <unit> <bind target> [--view ...]"
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
    let mut unit = None;
    let mut views = Vec::new();
    while let Some(flag) = args.next() {
        match flag.to_str() {
            Some("--systemctl") => systemctl = Some(args.next().unwrap_or_else(|| usage("missing systemctl path"))),
            Some("--unit") => unit = Some(utf8(args.next(), "unit")),
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
    if views.is_empty() {
        usage("no --view given");
    }
    let host = System { systemctl: systemctl.into(), proc_root: "/proc".into() };
    let mut log = |line: String| eprintln!("prison-store-check: {line}");
    match check(&host, &unit, &views, &mut log) {
        Ok(Outcome::Fresh) => exit(0),
        Ok(Outcome::Restarting(_)) => exit(STALE),
        Err(e) => {
            eprintln!("prison-store-check: {e}");
            exit(ERROR)
        }
    }
}
