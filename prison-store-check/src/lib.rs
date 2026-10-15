//! Does the running store view serve the closure this unit was built for?
//!
//! A store view's FUSE daemon is started with `--bind-target <farm>/nix/store`.
//! A start that lands in a switch's window, after the switch compared units
//! and before its daemon-reload, runs the OLD unit file: the view then serves
//! the old farm while systemd already holds the new definition, and the switch,
//! finding the view active, never restarts it. A service started afterwards
//! runs new argv against the old /nix/store.
//!
//! The daemon's own command line is the ground truth for what it serves, so
//! this reads `/proc/<MainPID>/cmdline` rather than any unit property, which
//! after a daemon-reload describes the new definition and not the process.

use std::ffi::OsString;
use std::fmt;
use std::os::unix::ffi::OsStringExt;
use std::path::{Path, PathBuf};

pub const BIND_TARGET: &str = "--bind-target";

/// One store view this unit depends on, and the bind target it must serve.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct View {
    pub unit: String,
    pub target: OsString,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Served {
    /// The daemon serves exactly the expected bind target.
    Expected,
    /// No main process: the view is not running.
    NotRunning,
    /// The daemon serves another bind target, or none it can name.
    Other(Option<OsString>),
}

impl fmt::Display for Served {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Served::Expected => write!(f, "the expected store"),
            Served::NotRunning => write!(f, "nothing (not running)"),
            Served::Other(Some(t)) => write!(f, "{}", Path::new(t).display()),
            Served::Other(None) => write!(f, "an unnamed store (no {BIND_TARGET})"),
        }
    }
}

/// What the check needs from the host. The real one asks systemd and reads
/// procfs; tests substitute both.
pub trait Host {
    /// The unit's MainPID; 0 when it has none.
    fn main_pid(&self, unit: &str) -> Result<u32, String>;
    /// The process's argv, or None once it is gone.
    fn cmdline(&self, pid: u32) -> Option<Vec<OsString>>;
    /// Queue a restart of these units without waiting for it.
    fn restart(&self, units: &[&str]) -> Result<(), String>;
}

/// The value following `--bind-target` (or given as `--bind-target=...`).
pub fn bind_target(argv: &[OsString]) -> Option<OsString> {
    let flag = BIND_TARGET.as_bytes();
    let mut it = argv.iter();
    while let Some(arg) = it.next() {
        let bytes = arg.as_encoded_bytes();
        if bytes == flag {
            return it.next().cloned();
        }
        if bytes.len() > flag.len() && bytes.starts_with(flag) && bytes[flag.len()] == b'=' {
            return Some(OsString::from_vec(bytes[flag.len() + 1..].to_vec()));
        }
    }
    None
}

pub fn served<H: Host>(host: &H, view: &View) -> Result<Served, String> {
    let pid = host.main_pid(&view.unit)?;
    if pid == 0 {
        return Ok(Served::NotRunning);
    }
    // A process that exits between the two reads is as good as not running.
    let Some(argv) = host.cmdline(pid) else {
        return Ok(Served::NotRunning);
    };
    Ok(match bind_target(&argv) {
        Some(t) if t == view.target => Served::Expected,
        other => Served::Other(other),
    })
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Every view serves this unit's closure: go ahead.
    Fresh,
    /// These views were stale; a restart of them and of this unit is queued.
    Restarting(Vec<String>),
}

/// Check every view. If any is stale, queue one restart of the stale views
/// together with `unit`, so the restart re-runs this unit (and, through the
/// views' BindsTo owner, the namespace owner) against fresh views.
pub fn check<H: Host>(
    host: &H,
    unit: &str,
    views: &[View],
    log: &mut dyn FnMut(String),
) -> Result<Outcome, String> {
    let mut stale = Vec::new();
    for view in views {
        let served = served(host, view)?;
        if served != Served::Expected {
            log(format!(
                "{} serves {served}; {unit} expects {}",
                view.unit,
                Path::new(&view.target).display()
            ));
            stale.push(view.unit.as_str());
        }
    }
    if stale.is_empty() {
        return Ok(Outcome::Fresh);
    }
    let mut units = stale.clone();
    units.push(unit);
    host.restart(&units)?;
    log(format!("restart queued for {}", units.join(" ")));
    Ok(Outcome::Restarting(stale.into_iter().map(String::from).collect()))
}

/// systemd and procfs.
pub struct System {
    pub systemctl: PathBuf,
    pub proc_root: PathBuf,
}

impl System {
    fn systemctl(&self, args: &[&str]) -> Result<Vec<u8>, String> {
        let out = std::process::Command::new(&self.systemctl)
            .args(args)
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::inherit())
            .output()
            .map_err(|e| format!("cannot run {}: {e}", self.systemctl.display()))?;
        if !out.status.success() {
            return Err(format!("systemctl {} failed: {}", args.join(" "), out.status));
        }
        Ok(out.stdout)
    }
}

impl Host for System {
    fn main_pid(&self, unit: &str) -> Result<u32, String> {
        let out = self.systemctl(&["show", "--property=MainPID", "--value", "--", unit])?;
        let text = String::from_utf8(out).map_err(|_| format!("MainPID of {unit} is not text"))?;
        text.trim()
            .parse()
            .map_err(|_| format!("MainPID of {unit} is not a number: {:?}", text.trim()))
    }

    fn cmdline(&self, pid: u32) -> Option<Vec<OsString>> {
        let raw = std::fs::read(self.proc_root.join(pid.to_string()).join("cmdline")).ok()?;
        if raw.is_empty() {
            // A zombie or kernel thread: nothing that serves a store.
            return None;
        }
        let raw = raw.strip_suffix(&[0]).unwrap_or(&raw);
        Some(raw.split(|b| *b == 0).map(|a| OsString::from_vec(a.to_vec())).collect())
    }

    fn restart(&self, units: &[&str]) -> Result<(), String> {
        let mut args = vec!["restart", "--no-block", "--"];
        args.extend_from_slice(units);
        self.systemctl(&args).map(drop)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::HashMap;

    #[derive(Default)]
    struct Fake {
        pids: HashMap<String, u32>,
        argv: HashMap<u32, Vec<&'static str>>,
        restarted: RefCell<Vec<Vec<String>>>,
        fail_restart: bool,
    }

    impl Host for Fake {
        fn main_pid(&self, unit: &str) -> Result<u32, String> {
            self.pids.get(unit).copied().ok_or_else(|| format!("no unit {unit}"))
        }
        fn cmdline(&self, pid: u32) -> Option<Vec<OsString>> {
            self.argv.get(&pid).map(|a| a.iter().map(OsString::from).collect())
        }
        fn restart(&self, units: &[&str]) -> Result<(), String> {
            if self.fail_restart {
                return Err("refused".into());
            }
            self.restarted.borrow_mut().push(units.iter().map(|u| u.to_string()).collect());
            Ok(())
        }
    }

    const NEW: &str = "/nix/store/new-farm/nix/store";
    const OLD: &str = "/nix/store/old-farm/nix/store";

    fn view(unit: &str, target: &str) -> View {
        View { unit: unit.into(), target: target.into() }
    }

    fn fake(views: &[(&str, u32, Vec<&'static str>)]) -> Fake {
        let mut f = Fake::default();
        for (unit, pid, argv) in views {
            f.pids.insert(unit.to_string(), *pid);
            if *pid != 0 {
                f.argv.insert(*pid, argv.clone());
            }
        }
        f
    }

    fn daemon(target: &'static str) -> Vec<&'static str> {
        vec!["/nix/store/x-fuse/bin/nix-store-shared-fuse", "--max-open-files", "64",
             "--bind-target", target, "--resolution-root", "/nix/store", "--allow-other", "/m"]
    }

    fn run(f: &Fake, views: &[View]) -> (Result<Outcome, String>, Vec<String>) {
        let mut log = Vec::new();
        let r = check(f, "p-s.service", views, &mut |l| log.push(l));
        (r, log)
    }

    #[test]
    fn bind_target_is_read_in_both_spellings() {
        let a: Vec<OsString> = ["x", "--bind-target", NEW, "m"].iter().map(OsString::from).collect();
        assert_eq!(bind_target(&a), Some(NEW.into()));
        let b: Vec<OsString> = ["x", &format!("--bind-target={NEW}"), "m"].iter().map(OsString::from).collect();
        assert_eq!(bind_target(&b), Some(NEW.into()));
        let c: Vec<OsString> = ["x", "--bind-targets", NEW].iter().map(OsString::from).collect();
        assert_eq!(bind_target(&c), None);
        let d: Vec<OsString> = ["x", "--bind-target"].iter().map(OsString::from).collect();
        assert_eq!(bind_target(&d), None);
    }

    #[test]
    fn a_fresh_view_queues_nothing() {
        let f = fake(&[("p-store-s.service", 10, daemon(NEW))]);
        let (r, log) = run(&f, &[view("p-store-s.service", NEW)]);
        assert_eq!(r, Ok(Outcome::Fresh));
        assert!(log.is_empty());
        assert!(f.restarted.borrow().is_empty());
    }

    // The 2026-10-14 outage: the view still serves the farm the old unit
    // file named, and this unit's definition names the new one.
    #[test]
    fn a_view_serving_the_old_farm_is_restarted_with_this_unit() {
        let f = fake(&[
            ("p-store-infra-net.service", 9, daemon(NEW)),
            ("p-store-s.service", 10, daemon(OLD)),
        ]);
        let (r, log) = run(&f, &[view("p-store-infra-net.service", NEW), view("p-store-s.service", NEW)]);
        assert_eq!(r, Ok(Outcome::Restarting(vec!["p-store-s.service".into()])));
        assert_eq!(*f.restarted.borrow(), vec![vec!["p-store-s.service".to_string(), "p-s.service".into()]]);
        assert!(log[0].contains(OLD) && log[0].contains(NEW), "{log:?}");
    }

    #[test]
    fn every_stale_view_is_restarted_in_one_transaction() {
        let f = fake(&[
            ("p-store-infra-net.service", 9, daemon(OLD)),
            ("p-store-s.service", 10, daemon(OLD)),
        ]);
        let (r, _) = run(&f, &[view("p-store-infra-net.service", NEW), view("p-store-s.service", NEW)]);
        assert!(matches!(r, Ok(Outcome::Restarting(ref v)) if v.len() == 2));
        assert_eq!(f.restarted.borrow().len(), 1);
        assert_eq!(f.restarted.borrow()[0].len(), 3);
    }

    #[test]
    fn a_view_that_is_not_running_is_started_again() {
        let f = fake(&[("p-store-s.service", 0, vec![])]);
        let (r, _) = run(&f, &[view("p-store-s.service", NEW)]);
        assert!(matches!(r, Ok(Outcome::Restarting(_))));
    }

    #[test]
    fn a_daemon_that_exited_between_reads_counts_as_not_running() {
        let mut f = fake(&[("p-store-s.service", 10, daemon(NEW))]);
        f.argv.clear();
        assert_eq!(served(&f, &view("p-store-s.service", NEW)), Ok(Served::NotRunning));
    }

    #[test]
    fn a_main_process_that_names_no_store_is_stale() {
        let f = fake(&[("p-store-s.service", 10, vec!["/bin/true"])]);
        assert_eq!(served(&f, &view("p-store-s.service", NEW)), Ok(Served::Other(None)));
    }

    #[test]
    fn a_prefix_of_the_expected_store_is_not_the_store() {
        let f = fake(&[("p-store-s.service", 10, daemon("/nix/store/new-farm"))]);
        assert!(matches!(served(&f, &view("p-store-s.service", NEW)), Ok(Served::Other(Some(_)))));
    }

    #[test]
    fn errors_are_not_mistaken_for_freshness() {
        let f = Fake::default();
        assert!(run(&f, &[view("p-store-s.service", NEW)]).0.is_err());
        let mut f = fake(&[("p-store-s.service", 10, daemon(OLD))]);
        f.fail_restart = true;
        assert!(run(&f, &[view("p-store-s.service", NEW)]).0.is_err());
    }

    #[test]
    fn procfs_cmdline_is_split_on_nul() {
        let root = std::env::temp_dir().join(format!("prison-store-check-{}", std::process::id()));
        std::fs::create_dir_all(root.join("42")).unwrap();
        std::fs::write(root.join("42/cmdline"), format!("fuse\0--bind-target\0{NEW}\0/m\0")).unwrap();
        std::fs::create_dir_all(root.join("43")).unwrap();
        std::fs::write(root.join("43/cmdline"), "").unwrap();
        let sys = System { systemctl: "/nonexistent".into(), proc_root: root.clone() };
        let argv = sys.cmdline(42).unwrap();
        assert_eq!(bind_target(&argv), Some(NEW.into()));
        assert_eq!(argv.len(), 4);
        assert_eq!(sys.cmdline(43), None);
        assert_eq!(sys.cmdline(44), None);
        std::fs::remove_dir_all(root).unwrap();
    }
}
