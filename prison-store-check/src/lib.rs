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
//!
//! A skipped start relies on the restart it queued. That job can be
//! cancelled, by a conflicting job or a stop, and then the unit sits inactive
//! with nothing to report it. So every skip also arms a recheck timer that
//! starts the unit again if it is still not running, and the skips are
//! counted: past `MAX_SKIPS` in a row the check fails the start, which the
//! unit's failure handling reports.

use std::ffi::OsString;
use std::fmt;
use std::os::unix::ffi::OsStringExt;
use std::path::{Path, PathBuf};

pub const BIND_TARGET: &str = "--bind-target";

/// Consecutive skipped starts after which the check fails the start.
pub const MAX_SKIPS: u32 = 3;

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
    /// The unit's ActiveState.
    fn active_state(&self, unit: &str) -> Result<String, String>;
    /// Queue a start of the unit without waiting for it.
    fn start(&self, unit: &str) -> Result<(), String>;
    /// Arm a one-shot timer that runs the recheck of `unit` later. Arming
    /// a timer that is already armed is not an error.
    fn arm_recheck(&self, unit: &str) -> Result<(), String>;
}

/// Consecutive skipped starts per unit, kept across starts in a runtime
/// directory: a reboot starts every count afresh.
pub struct Skips {
    pub dir: PathBuf,
}

impl Skips {
    fn path(&self, unit: &str) -> Result<PathBuf, String> {
        check_unit_name(unit)?;
        Ok(self.dir.join(format!("{unit}.skips")))
    }

    pub fn count(&self, unit: &str) -> Result<u32, String> {
        match std::fs::read_to_string(self.path(unit)?) {
            Ok(text) => Ok(text.trim().parse().unwrap_or(0)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(0),
            Err(e) => Err(format!("cannot read the skip count of {unit}: {e}")),
        }
    }

    /// One more skip; returns the new count.
    pub fn bump(&self, unit: &str) -> Result<u32, String> {
        let count = self.count(unit)?.saturating_add(1);
        std::fs::create_dir_all(&self.dir).map_err(|e| format!("cannot create {}: {e}", self.dir.display()))?;
        let path = self.path(unit)?;
        let staging = self.dir.join(format!(".{unit}.skips.new"));
        std::fs::write(&staging, format!("{count}\n"))
            .and_then(|()| std::fs::rename(&staging, &path))
            .map_err(|e| format!("cannot record a skip of {unit}: {e}"))?;
        Ok(count)
    }

    pub fn clear(&self, unit: &str) -> Result<(), String> {
        match std::fs::remove_file(self.path(unit)?) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(format!("cannot clear the skip count of {unit}: {e}")),
        }
    }
}

/// A systemd unit name this tool may put into a file name and a transient
/// unit name.
pub fn check_unit_name(unit: &str) -> Result<(), String> {
    let valid = !unit.is_empty() && unit.len() <= 255 && !unit.starts_with('.') && !unit.starts_with('-')
        && unit.bytes().all(|b| b.is_ascii_alphanumeric() || b":_.@-\\".contains(&b));
    if valid { Ok(()) } else { Err(format!("invalid unit name {unit:?}")) }
}

/// The transient timer that rechecks `unit`.
pub fn recheck_unit(unit: &str) -> Result<String, String> {
    check_unit_name(unit)?;
    let stem: String = unit.strip_suffix(".service").unwrap_or(unit).chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '-' })
        .collect();
    Ok(format!("prison-store-recheck-{stem}"))
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
    /// These views were stale; a restart of them and of this unit is queued
    /// and a recheck is armed.
    Restarting(Vec<String>),
    /// Stale again after `MAX_SKIPS` skipped starts in a row: the queued
    /// restarts are not happening. The restart is queued once more, and the
    /// start must fail so the unit's failure handling reports it.
    GaveUp(Vec<String>),
}

/// Check every view. If any is stale, queue one restart of the stale views
/// together with `unit`, so the restart re-runs this unit (and, through the
/// views' BindsTo owner, the namespace owner) against fresh views.
pub fn check<H: Host>(
    host: &H,
    skips: &Skips,
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
        skips.clear(unit)?;
        return Ok(Outcome::Fresh);
    }
    let count = skips.bump(unit)?;
    let mut units = stale.clone();
    units.push(unit);
    host.restart(&units)?;
    log(format!("restart queued for {}", units.join(" ")));
    let stale: Vec<String> = stale.into_iter().map(String::from).collect();
    if count > MAX_SKIPS {
        log(format!("{unit} was skipped {count} times in a row; its queued restarts are not taking effect"));
        return Ok(Outcome::GaveUp(stale));
    }
    // Arming is part of the skip: without it a cancelled restart is silent,
    // so a failure to arm fails the start instead.
    host.arm_recheck(unit)?;
    Ok(Outcome::Restarting(stale))
}

/// The armed timer's job: start the unit again unless it is running, so a
/// skip whose restart was cancelled is checked again rather than forgotten.
pub fn recheck<H: Host>(host: &H, unit: &str, log: &mut dyn FnMut(String)) -> Result<(), String> {
    let state = host.active_state(unit)?;
    if matches!(state.as_str(), "active" | "activating" | "reloading" | "refreshing") {
        return Ok(());
    }
    log(format!("{unit} is {state} after a skipped start; starting it again"));
    host.start(unit)
}

/// systemd and procfs.
pub struct System {
    pub systemctl: PathBuf,
    pub systemd_run: Option<PathBuf>,
    pub proc_root: PathBuf,
}

impl System {
    fn run(program: &Path, args: &[&str]) -> Result<Vec<u8>, String> {
        let out = std::process::Command::new(program)
            .args(args)
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::inherit())
            .output()
            .map_err(|e| format!("cannot run {}: {e}", program.display()))?;
        if !out.status.success() {
            return Err(format!("{} {} failed: {}", program.display(), args.join(" "), out.status));
        }
        Ok(out.stdout)
    }

    fn systemctl(&self, args: &[&str]) -> Result<Vec<u8>, String> {
        Self::run(&self.systemctl, args)
    }

    fn property(&self, unit: &str, name: &str) -> Result<String, String> {
        let out = self.systemctl(&["show", &format!("--property={name}"), "--value", "--", unit])?;
        Ok(String::from_utf8(out).map_err(|_| format!("{name} of {unit} is not text"))?.trim().to_owned())
    }
}

impl Host for System {
    fn main_pid(&self, unit: &str) -> Result<u32, String> {
        let text = self.property(unit, "MainPID")?;
        text.parse().map_err(|_| format!("MainPID of {unit} is not a number: {text:?}"))
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

    fn active_state(&self, unit: &str) -> Result<String, String> {
        self.property(unit, "ActiveState")
    }

    fn start(&self, unit: &str) -> Result<(), String> {
        self.systemctl(&["start", "--no-block", "--", unit]).map(drop)
    }

    fn arm_recheck(&self, unit: &str) -> Result<(), String> {
        let systemd_run = self.systemd_run.as_deref().ok_or("no --systemd-run to arm the recheck with")?;
        let name = recheck_unit(unit)?;
        if self.active_state(&format!("{name}.timer"))? == "active" {
            return Ok(());
        }
        let program = std::env::current_exe().map_err(|e| format!("cannot locate this program: {e}"))?;
        let program = program.to_str().ok_or("this program's path is not UTF-8")?;
        let systemctl = self.systemctl.to_str().ok_or("the systemctl path is not UTF-8")?;
        Self::run(systemd_run, &[
            "--quiet", "--collect", &format!("--unit={name}"),
            &format!("--on-active={}", RECHECK_AFTER_SECONDS),
            "--timer-property=AccuracySec=5s",
            "--", program, "--recheck", "--systemctl", systemctl, "--unit", unit,
        ]).map(drop)
    }
}

/// How long the queued restart has before the recheck looks again.
pub const RECHECK_AFTER_SECONDS: u32 = 120;

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::HashMap;

    #[derive(Default)]
    struct Fake {
        pids: HashMap<String, u32>,
        argv: HashMap<u32, Vec<&'static str>>,
        states: HashMap<String, &'static str>,
        restarted: RefCell<Vec<Vec<String>>>,
        started: RefCell<Vec<String>>,
        armed: RefCell<Vec<String>>,
        fail_restart: bool,
        fail_arm: bool,
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
        fn active_state(&self, unit: &str) -> Result<String, String> {
            Ok(self.states.get(unit).copied().unwrap_or("inactive").to_owned())
        }
        fn start(&self, unit: &str) -> Result<(), String> {
            self.started.borrow_mut().push(unit.to_owned());
            Ok(())
        }
        fn arm_recheck(&self, unit: &str) -> Result<(), String> {
            if self.fail_arm {
                return Err("systemd-run refused".into());
            }
            self.armed.borrow_mut().push(unit.to_owned());
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

    struct Scratch(PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); }
    }
    fn scratch(name: &str) -> (Scratch, Skips) {
        let dir = std::env::temp_dir().join(format!("prison-store-check-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        (Scratch(dir.clone()), Skips { dir })
    }

    fn run(f: &Fake, skips: &Skips, views: &[View]) -> (Result<Outcome, String>, Vec<String>) {
        let mut log = Vec::new();
        let r = check(f, skips, "p-s.service", views, &mut |l| log.push(l));
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
        let (_s, skips) = scratch("fresh");
        let f = fake(&[("p-store-s.service", 10, daemon(NEW))]);
        let (r, log) = run(&f, &skips, &[view("p-store-s.service", NEW)]);
        assert_eq!(r, Ok(Outcome::Fresh));
        assert!(log.is_empty());
        assert!(f.restarted.borrow().is_empty());
        assert!(f.armed.borrow().is_empty());
    }

    // The 2026-10-14 outage: the view still serves the farm the old unit
    // file named, and this unit's definition names the new one.
    #[test]
    fn a_view_serving_the_old_farm_is_restarted_with_this_unit() {
        let (_s, skips) = scratch("old");
        let f = fake(&[
            ("p-store-infra-net.service", 9, daemon(NEW)),
            ("p-store-s.service", 10, daemon(OLD)),
        ]);
        let (r, log) = run(&f, &skips, &[view("p-store-infra-net.service", NEW), view("p-store-s.service", NEW)]);
        assert_eq!(r, Ok(Outcome::Restarting(vec!["p-store-s.service".into()])));
        assert_eq!(*f.restarted.borrow(), vec![vec!["p-store-s.service".to_string(), "p-s.service".into()]]);
        assert!(log[0].contains(OLD) && log[0].contains(NEW), "{log:?}");
    }

    #[test]
    fn every_stale_view_is_restarted_in_one_transaction() {
        let (_s, skips) = scratch("every");
        let f = fake(&[
            ("p-store-infra-net.service", 9, daemon(OLD)),
            ("p-store-s.service", 10, daemon(OLD)),
        ]);
        let (r, _) = run(&f, &skips, &[view("p-store-infra-net.service", NEW), view("p-store-s.service", NEW)]);
        assert!(matches!(r, Ok(Outcome::Restarting(ref v)) if v.len() == 2));
        assert_eq!(f.restarted.borrow().len(), 1);
        assert_eq!(f.restarted.borrow()[0].len(), 3);
    }

    #[test]
    fn a_view_that_is_not_running_is_started_again() {
        let (_s, skips) = scratch("notrunning");
        let f = fake(&[("p-store-s.service", 0, vec![])]);
        let (r, _) = run(&f, &skips, &[view("p-store-s.service", NEW)]);
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
        let (_s, skips) = scratch("errors");
        let f = Fake::default();
        assert!(run(&f, &skips, &[view("p-store-s.service", NEW)]).0.is_err());
        let mut f = fake(&[("p-store-s.service", 10, daemon(OLD))]);
        f.fail_restart = true;
        assert!(run(&f, &skips, &[view("p-store-s.service", NEW)]).0.is_err());
    }

    // The escalation gap: a skip queues a restart, and if that job is
    // cancelled the unit stays inactive. Every skip arms a recheck, and a
    // skip that cannot arm one fails the start instead of going silent.
    #[test]
    fn a_skip_arms_a_recheck_or_fails() {
        let (_s, skips) = scratch("arm");
        let mut f = fake(&[("p-store-s.service", 10, daemon(OLD))]);
        let (r, _) = run(&f, &skips, &[view("p-store-s.service", NEW)]);
        assert!(matches!(r, Ok(Outcome::Restarting(_))));
        assert_eq!(*f.armed.borrow(), ["p-s.service"]);
        f.fail_arm = true;
        assert!(run(&f, &skips, &[view("p-store-s.service", NEW)]).0.unwrap_err().contains("refused"));
    }

    #[test]
    fn repeated_skips_give_up_and_a_fresh_start_resets_the_count() {
        let (_s, skips) = scratch("repeat");
        let mut f = fake(&[("p-store-s.service", 10, daemon(OLD))]);
        let views = [view("p-store-s.service", NEW)];
        for _ in 0..MAX_SKIPS {
            assert!(matches!(run(&f, &skips, &views).0, Ok(Outcome::Restarting(_))));
        }
        let (r, log) = run(&f, &skips, &views);
        assert!(matches!(r, Ok(Outcome::GaveUp(_))), "{r:?}");
        assert!(log.last().unwrap().contains("skipped 4 times"), "{log:?}");
        // The restart is still queued while the start fails.
        assert_eq!(f.restarted.borrow().len(), MAX_SKIPS as usize + 1);
        f.argv.insert(10, daemon(NEW));
        assert_eq!(run(&f, &skips, &views).0, Ok(Outcome::Fresh));
        assert_eq!(skips.count("p-s.service").unwrap(), 0);
        f.argv.insert(10, daemon(OLD));
        assert!(matches!(run(&f, &skips, &views).0, Ok(Outcome::Restarting(_))));
    }

    #[test]
    fn the_recheck_starts_only_a_unit_that_is_not_running() {
        let mut f = Fake::default();
        for state in ["active", "activating", "reloading"] {
            f.states.insert("p-s.service".into(), state);
            recheck(&f, "p-s.service", &mut |_| {}).unwrap();
        }
        assert!(f.started.borrow().is_empty());
        for state in ["inactive", "failed"] {
            f.states.insert("p-s.service".into(), state);
            recheck(&f, "p-s.service", &mut |_| {}).unwrap();
        }
        assert_eq!(*f.started.borrow(), ["p-s.service", "p-s.service"]);
    }

    #[test]
    fn unit_names_are_checked_before_use_in_paths_and_units() {
        assert_eq!(recheck_unit("authoritative-dns-prepare.service").unwrap(), "prison-store-recheck-authoritative-dns-prepare");
        assert_eq!(recheck_unit("a@b.service").unwrap(), "prison-store-recheck-a-b");
        for bad in ["", "../x", "a/b.service", ".hidden", "-x", "a b"] {
            assert!(check_unit_name(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn procfs_cmdline_is_split_on_nul() {
        let root = std::env::temp_dir().join(format!("prison-store-check-{}", std::process::id()));
        std::fs::create_dir_all(root.join("42")).unwrap();
        std::fs::write(root.join("42/cmdline"), format!("fuse\0--bind-target\0{NEW}\0/m\0")).unwrap();
        std::fs::create_dir_all(root.join("43")).unwrap();
        std::fs::write(root.join("43/cmdline"), "").unwrap();
        let sys = System { systemctl: "/nonexistent".into(), systemd_run: None, proc_root: root.clone() };
        let argv = sys.cmdline(42).unwrap();
        assert_eq!(bind_target(&argv), Some(NEW.into()));
        assert_eq!(argv.len(), 4);
        assert_eq!(sys.cmdline(43), None);
        assert_eq!(sys.cmdline(44), None);
        std::fs::remove_dir_all(root).unwrap();
    }
}
