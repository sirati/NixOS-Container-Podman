// app-runner: starts one entry of a sandboxed app from a plan that
// nix/app/plan.nix rendered. Everything the sandbox policy says is already in
// the plan, validated by the podman model; this binary only fills in what is
// unknown until the app is launched: where the compositor socket is, which GPU
// device nodes exist, whether the network namespace holder is up.
//
// It is Rust and not shell because it decides what the confined process can
// see. A path that reaches `podman run --mount` is rejected if it could be
// read as more than one option, and nothing is ever passed through a shell.
//
//   app-runner PLANDIR [ARGS...]  PLANDIR holds one `<uid>.plan` per user; ARGS
//                                 go to the sandboxed command unchanged
//
// The entries of one app share a network namespace owned by a holder
// container. The holder lives exactly as long as some entry does: each entry
// keeps a lease on it while it runs and the last one to end removes it (see
// acquire_lease). An entry that needs no clean-up afterwards, because it has
// no holder and no D-Bus proxy, still replaces this process with podman.
//
// Plan format: see parse_plan. Standard library only.

use std::collections::BTreeMap;
use std::fs::{File, OpenOptions, TryLockError};
use std::io::IsTerminal;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::{Duration, Instant};
use std::{env, fs};

#[derive(Debug, Clone, PartialEq)]
enum Item {
    Lit(String),
    Var { name: String, prefix: String, suffix: String },
    Splice(String),
}

#[derive(Debug, Clone, PartialEq)]
enum Rule {
    /// Every existing match of `pattern`, bound at the same path.
    Mount { pattern: String, options: String },
    /// One source, bound at a fixed destination, when it exists.
    MountAs { source: String, destination: String, options: String },
}

#[derive(Debug, Default, PartialEq)]
struct Plan {
    name: String,
    podman: String,
    holder: Option<String>,
    tty_auto: bool,
    require: Vec<(String, String)>,
    derived: Vec<(String, String)>,
    ensure_dirs: Vec<(u32, String)>,
    providers: BTreeMap<String, Vec<Rule>>,
    dbus: Option<Dbus>,
    /// Options for every podman call, before its subcommand, and its
    /// environment; templates until `resolve_podman` fills them in.
    podman_args: Vec<String>,
    podman_env: Vec<(String, String)>,
    holder_argv: Vec<Item>,
    run_argv: Vec<Item>,
}

/// A filtered view of the session bus, served by xdg-dbus-proxy for as long as
/// the app runs. The app gets portals (file dialogs, opening links,
/// notifications) and the names the policy lists, not the bus.
#[derive(Debug, Default, PartialEq)]
struct Dbus {
    proxy: String,
    upstream: String,
    socket: String,
    args: Vec<String>,
}

type Vars = BTreeMap<String, String>;

#[derive(PartialEq, Clone, Copy)]
enum Section {
    None,
    Meta,
    Vars,
    Require,
    EnsureDir,
    Provider,
    DbusSection,
    PodmanSection,
    Holder,
    Run,
}

/// The plan is line oriented, fields separated by TAB, `#` starts a comment.
///
///   plan 1
///   [meta]              name / podman / holder / tty  (key TAB value)
///   [vars]              name TAB template -- derived from the host's, in order
///   [require]           var TAB message   -- the runtime variable must be non-empty
///   [ensure-dir]        octal-mode TAB template
///   [provider NAME]     mount TAB pattern TAB options
///                       mount-as TAB source TAB destination TAB options
///   [dbus]              proxy / upstream / socket TAB value, arg TAB option
///                       -- a filtered session bus for the app's lifetime; the
///                       socket is `{dbus_socket}` to the providers
///   [podman]            arg TAB option -- a global option of every podman call
///                       (templates), env TAB name TAB value -- its environment
///   [holder] [run]      s TAB text | r TAB var TAB prefix TAB suffix | a TAB provider
fn parse_plan(text: &str) -> Result<Plan, String> {
    let mut plan = Plan::default();
    let mut section = Section::None;
    let mut provider = String::new();
    let mut saw_header = false;
    for (index, raw) in text.lines().enumerate() {
        let at = |message: &str| format!("plan line {}: {message}", index + 1);
        if raw.is_empty() || raw.starts_with('#') {
            continue;
        }
        if raw.starts_with('[') {
            let inner = raw.strip_prefix('[').and_then(|s| s.strip_suffix(']')).ok_or_else(|| at("unterminated section header"))?;
            let (head, rest) = inner.split_once(' ').unwrap_or((inner, ""));
            section = match head {
                "meta" => Section::Meta,
                "vars" => Section::Vars,
                "require" => Section::Require,
                "ensure-dir" => Section::EnsureDir,
                "holder" => Section::Holder,
                "podman" => Section::PodmanSection,
                "dbus" => {
                    plan.dbus.get_or_insert_with(Dbus::default);
                    Section::DbusSection
                }
                "run" => Section::Run,
                "provider" => {
                    if rest.is_empty() {
                        return Err(at("provider without a name"));
                    }
                    provider = rest.to_string();
                    plan.providers.entry(provider.clone()).or_default();
                    Section::Provider
                }
                other => return Err(at(&format!("unknown section {other}"))),
            };
            continue;
        }
        if section == Section::None {
            if raw == "plan 1" {
                saw_header = true;
                continue;
            }
            return Err(at("expected `plan 1` before any section"));
        }
        let fields: Vec<&str> = raw.split('\t').collect();
        match section {
            Section::Meta => match fields.as_slice() {
                ["name", v] => plan.name = v.to_string(),
                ["podman", v] => plan.podman = v.to_string(),
                // The name becomes part of two file names in the runtime directory.
                ["holder", v] if !v.is_empty() && !v.contains('/') && !v.contains('\0') => plan.holder = Some(v.to_string()),
                ["holder", _] => return Err(at("a holder name is not empty and has no `/`")),
                ["tty", "auto"] => plan.tty_auto = true,
                ["tty", "never"] => plan.tty_auto = false,
                _ => return Err(at("bad meta line")),
            },
            Section::Vars => match fields.as_slice() {
                [name, template] if !name.is_empty() => plan.derived.push((name.to_string(), template.to_string())),
                _ => return Err(at("bad vars line")),
            },
            Section::Require => match fields.as_slice() {
                [var, message] => plan.require.push((var.to_string(), message.to_string())),
                _ => return Err(at("bad require line")),
            },
            Section::EnsureDir => match fields.as_slice() {
                [mode, template] => {
                    let mode = u32::from_str_radix(mode, 8).map_err(|_| at("bad octal mode"))?;
                    plan.ensure_dirs.push((mode, template.to_string()));
                }
                _ => return Err(at("bad ensure-dir line")),
            },
            Section::Provider => {
                let rule = match fields.as_slice() {
                    ["mount", pattern, options] => {
                        let (dir, _) = pattern.rsplit_once('/').ok_or_else(|| at("mount pattern must be absolute"))?;
                        if dir.contains('*') || dir.contains('?') {
                            return Err(at("only the last path component may contain a wildcard"));
                        }
                        Rule::Mount { pattern: pattern.to_string(), options: options.to_string() }
                    }
                    ["mount-as", source, destination, options] => Rule::MountAs {
                        source: source.to_string(),
                        destination: destination.to_string(),
                        options: options.to_string(),
                    },
                    _ => return Err(at("bad provider rule")),
                };
                plan.providers.get_mut(&provider).expect("section header inserted it").push(rule);
            }
            Section::DbusSection => {
                let dbus = plan.dbus.as_mut().expect("section header inserted it");
                match fields.as_slice() {
                    ["proxy", v] => dbus.proxy = v.to_string(),
                    ["upstream", v] => dbus.upstream = v.to_string(),
                    ["socket", v] => dbus.socket = v.to_string(),
                    ["arg", v] => dbus.args.push(v.to_string()),
                    _ => return Err(at("bad dbus line")),
                }
            }
            Section::PodmanSection => match fields.as_slice() {
                ["arg", v] => plan.podman_args.push(v.to_string()),
                ["env", name, v] if !name.is_empty() && !name.contains('=') && !name.contains('\0') => {
                    plan.podman_env.push((name.to_string(), v.to_string()))
                }
                _ => return Err(at("bad podman line")),
            },
            Section::Holder | Section::Run => {
                let item = match fields.as_slice() {
                    ["s", text] => Item::Lit(text.to_string()),
                    ["s"] => Item::Lit(String::new()),
                    ["r", name, prefix, suffix] => Item::Var { name: name.to_string(), prefix: prefix.to_string(), suffix: suffix.to_string() },
                    ["a", name] => Item::Splice(name.to_string()),
                    _ => return Err(at("bad argv item")),
                };
                if section == Section::Holder { plan.holder_argv.push(item) } else { plan.run_argv.push(item) }
            }
            Section::None => unreachable!(),
        }
    }
    if !saw_header {
        return Err("not a plan: missing `plan 1`".into());
    }
    if let Some(d) = &plan.dbus {
        if !d.proxy.starts_with('/') || d.upstream.is_empty() || d.socket.is_empty() {
            return Err("[dbus] needs an absolute proxy, an upstream and a socket".into());
        }
    }
    if plan.podman.is_empty() || !plan.podman.starts_with('/') {
        return Err("plan has no absolute podman path".into());
    }
    if plan.run_argv.is_empty() {
        return Err("plan has an empty [run] section".into());
    }
    if plan.holder.is_some() && plan.holder_argv.len() < 2 {
        return Err("plan names a holder but has no [holder] command to create it".into());
    }
    Ok(plan)
}

/// `{name}` is replaced from `vars`; anything else is literal.
fn expand(template: &str, vars: &Vars) -> Result<String, String> {
    let mut out = String::new();
    let mut rest = template;
    while let Some(open) = rest.find('{') {
        out.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        let close = after.find('}').ok_or_else(|| format!("unterminated `{{` in `{template}`"))?;
        let name = &after[..close];
        let value = vars.get(name).ok_or_else(|| format!("unknown variable `{name}` in `{template}`"))?;
        out.push_str(value);
        rest = &after[close + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

/// `*` and `?` only; the name is one path component. As in a shell, a name
/// that starts with `.` is matched only by a pattern that starts with `.`:
/// `~/*` is how "everything in the home directory except its hidden files"
/// is written, and it has to stay that way.
fn glob_match(pattern: &str, name: &str) -> bool {
    if name.starts_with('.') && !pattern.starts_with('.') {
        return false;
    }
    let (p, n): (Vec<char>, Vec<char>) = (pattern.chars().collect(), name.chars().collect());
    fn go(p: &[char], n: &[char]) -> bool {
        match p.split_first() {
            None => n.is_empty(),
            Some(('*', rest)) => (0..=n.len()).any(|skip| go(rest, &n[skip..])),
            Some(('?', rest)) => !n.is_empty() && go(rest, &n[1..]),
            Some((c, rest)) => n.first() == Some(c) && go(rest, &n[1..]),
        }
    }
    go(&p, &n)
}

/// More than this from one wildcard is a mistake (or a hostile directory), not
/// a home folder.
const MAX_BINDS: usize = 512;

/// Something a bind mount can stand for: after following symlinks, a
/// directory, a regular file, or a character device (the GPU's nodes are
/// those). A dangling link would make podman refuse every mount at once, and a
/// socket, fifo or block device is not content to hand to an app.
fn bindable(path: &str) -> bool {
    use std::os::unix::fs::FileTypeExt;
    fs::metadata(path)
        .map(|m| {
            let t = m.file_type();
            t.is_dir() || t.is_file() || t.is_char_device()
        })
        .unwrap_or(false)
}

/// A comma would end the value of a `--mount` option and start another one,
/// so a file name containing one could add mount options of its own.
fn mount_safe(path: &str) -> Result<(), String> {
    if path.contains(',') || path.contains('\0') || path.contains('\n') || !path.starts_with('/') {
        return Err(format!("refusing to bind `{path}`: not an absolute path free of `,`"));
    }
    Ok(())
}

fn bind(source: &str, destination: &str, options: &str) -> Result<Vec<String>, String> {
    mount_safe(source)?;
    mount_safe(destination)?;
    let tail = if options.is_empty() { String::new() } else { format!(",{options}") };
    Ok(vec!["--mount".into(), format!("type=bind,source={source},destination={destination}{tail}")])
}

fn expand_rule(rule: &Rule, vars: &Vars) -> Result<Vec<String>, String> {
    match rule {
        Rule::Mount { pattern, options } => {
            let pattern = expand(pattern, vars)?;
            let (dir, name) = pattern.rsplit_once('/').ok_or("mount pattern must be absolute")?;
            let dir = if dir.is_empty() { "/" } else { dir };
            let mut found: Vec<String> = Vec::new();
            if name.contains('*') || name.contains('?') {
                if let Ok(entries) = fs::read_dir(dir) {
                    for entry in entries.flatten() {
                        let file = entry.file_name().to_string_lossy().into_owned();
                        let path = format!("{}/{}", dir.trim_end_matches('/'), file);
                        if glob_match(name, &file) && bindable(&path) {
                            found.push(path);
                        }
                    }
                }
            } else if Path::new(&pattern).exists() {
                found.push(pattern.clone());
            }
            found.sort();
            if found.len() > MAX_BINDS {
                return Err(format!("`{pattern}` matches {} entries; refusing to bind more than {MAX_BINDS}", found.len()));
            }
            let mut args = Vec::new();
            for path in found {
                args.extend(bind(&path, &path, options)?);
            }
            Ok(args)
        }
        Rule::MountAs { source, destination, options } => {
            let source = expand(source, vars)?;
            if !Path::new(&source).exists() {
                return Ok(Vec::new());
            }
            bind(&source, &expand(destination, vars)?, options)
        }
    }
}

/// The `destination=` of a `--mount` value.
fn mount_destination(spec: &str) -> Option<&str> {
    spec.split(',').find_map(|part| part.strip_prefix("destination="))
}

/// Two mounts at one destination make podman refuse to start. Overlapping
/// rules are normal (the whole home directory and one folder in it), so the
/// first mount of a destination wins, and the plan's own come before any
/// spliced in.
fn drop_duplicate_mounts(argv: Vec<String>) -> Vec<String> {
    let mut seen = std::collections::BTreeSet::new();
    let mut out = Vec::with_capacity(argv.len());
    let mut i = 0;
    while i < argv.len() {
        if argv[i] == "--mount" && i + 1 < argv.len() {
            let fresh = mount_destination(&argv[i + 1]).map(|d| seen.insert(d.to_string())).unwrap_or(true);
            if fresh {
                out.push(argv[i].clone());
                out.push(argv[i + 1].clone());
            }
            i += 2;
        } else {
            out.push(argv[i].clone());
            i += 1;
        }
    }
    out
}

fn resolve(items: &[Item], plan: &Plan, vars: &Vars) -> Result<Vec<String>, String> {
    let mut argv = Vec::new();
    for item in items {
        match item {
            Item::Lit(text) => argv.push(text.clone()),
            Item::Var { name, prefix, suffix } => {
                let value = vars.get(name).ok_or_else(|| format!("plan uses unknown runtime value `{name}`"))?;
                argv.push(format!("{prefix}{value}{suffix}"));
            }
            Item::Splice(name) => {
                let rules = plan.providers.get(name).ok_or_else(|| format!("plan splices unknown provider `{name}`"))?;
                for rule in rules {
                    argv.extend(expand_rule(rule, vars)?);
                }
            }
        }
    }
    Ok(drop_duplicate_mounts(argv))
}

fn host_vars(plan: &Plan) -> Result<Vars, String> {
    let meta = fs::metadata("/proc/self").map_err(|e| format!("cannot read /proc/self: {e}"))?;
    let (uid, gid) = (meta.uid(), meta.gid());
    let home = env::var("HOME").map_err(|_| "HOME is not set".to_string())?;
    let runtime = match env::var("XDG_RUNTIME_DIR") {
        Ok(v) if v.starts_with('/') => v,
        _ => format!("/run/user/{uid}"),
    };
    let display = env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "wayland-0".into());
    let socket = if display.starts_with('/') { display } else { format!("{runtime}/{display}") };
    let socket = if Path::new(&socket).exists() { socket } else { String::new() };
    let cwd = env::current_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|_| "/".into());
    let mut vars = Vars::new();
    for (k, v) in [
        ("uid", uid.to_string()),
        ("gid", gid.to_string()),
        ("home", home),
        ("xdg_runtime_dir", runtime),
        ("wayland_socket", socket),
        ("cwd", cwd),
        ("pid", std::process::id().to_string()),
        ("dbus_socket", String::new()),
    ] {
        vars.insert(k.to_string(), v);
    }
    derive(plan, &mut vars)?;
    Ok(vars)
}

/// Each derived variable may use the host's and the ones before it.
fn derive(plan: &Plan, vars: &mut Vars) -> Result<(), String> {
    for (name, template) in &plan.derived {
        let value = expand(template, vars)?;
        vars.insert(name.clone(), value);
    }
    Ok(())
}

fn ensure_dir(mode: u32, path: &str) -> Result<(), String> {
    mount_safe(path)?;
    let p = Path::new(path);
    if !p.is_dir() {
        fs::DirBuilder::new().recursive(true).mode(mode).create(p).map_err(|e| format!("cannot create {path}: {e}"))?;
    }
    let meta = fs::metadata(p).map_err(|e| format!("cannot stat {path}: {e}"))?;
    if meta.permissions().mode() & 0o777 != mode {
        fs::set_permissions(p, fs::Permissions::from_mode(mode)).map_err(|e| format!("cannot chmod {path}: {e}"))?;
    }
    Ok(())
}

/// Rootless podman maps ids through the setuid `newuidmap` and `newgidmap`,
/// which NixOS puts in /run/wrappers/bin. A session started from a menu entry
/// does not always have that directory on its PATH, so podman gets it first.
fn with_wrappers(path: &str) -> String {
    if path.split(':').any(|p| p == "/run/wrappers/bin") {
        return path.to_string();
    }
    if path.is_empty() { "/run/wrappers/bin".to_string() } else { format!("/run/wrappers/bin:{path}") }
}

/// Fill in the templates of the `[podman]` section, now that the launch's
/// values are known.
fn resolve_podman(plan: &mut Plan, vars: &Vars) -> Result<(), String> {
    for arg in &mut plan.podman_args {
        *arg = expand(arg, vars)?;
    }
    for (_, value) in &mut plan.podman_env {
        *value = expand(value, vars)?;
    }
    Ok(())
}

fn podman_command(plan: &Plan) -> Command {
    let mut command = Command::new(&plan.podman);
    command.env("PATH", with_wrappers(&env::var("PATH").unwrap_or_default()));
    command.envs(plan.podman_env.iter().map(|(k, v)| (k, v)));
    command.args(&plan.podman_args);
    command
}

/// How long podman gets for the calls that prepare or take down the holder.
/// They take a second at most; one that takes much longer is stuck behind a
/// lock some other podman process holds, and waiting longer only piles up
/// another stuck process with every launch the user retries.
const MANAGE_TIMEOUT: Duration = Duration::from_secs(30);

/// How long a launch waits for another launch of the same app that is busy
/// preparing the holder: long enough for that one to hit its own timeouts.
const GUARD_TIMEOUT: Duration = Duration::from_secs(75);

/// Run `command` to its end, or give up on it after `limit`: `None` means it
/// was stopped for taking too long.
fn status_within(command: &mut Command, limit: Duration) -> Result<Option<std::process::ExitStatus>, String> {
    let mut child = command.spawn().map_err(|e| format!("cannot run {}: {e}", command.get_program().to_string_lossy()))?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(Some(status)),
            Ok(None) if started.elapsed() >= limit => {
                let _ = child.kill();
                let _ = child.wait();
                return Ok(None);
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            Err(e) => return Err(format!("cannot wait for {}: {e}", command.get_program().to_string_lossy())),
        }
    }
}

/// Take an exclusive lock on `file`, waiting at most `limit` for whoever holds it.
fn lock_within(file: &File, limit: Duration) -> Result<(), String> {
    let started = Instant::now();
    loop {
        match file.try_lock() {
            Ok(()) => return Ok(()),
            Err(TryLockError::WouldBlock) if started.elapsed() < limit => std::thread::sleep(Duration::from_millis(20)),
            Err(TryLockError::WouldBlock) => return Err(format!("still locked after {}s", limit.as_secs())),
            Err(TryLockError::Error(e)) => return Err(e.to_string()),
        }
    }
}

fn stalled(what: &str, limit: Duration) -> String {
    format!(
        "podman did not finish `{what}` within {}s. A podman process left by an earlier launch may still hold this app's lock; \
         `ps -u $USER -o pid,etime,args | grep podman` shows it.",
        limit.as_secs()
    )
}

/// Runs podman for its exit status, for at most `MANAGE_TIMEOUT`; `stderr` is
/// where its complaints go.
fn podman_with(plan: &Plan, args: &[&str], stderr: Stdio) -> Result<bool, String> {
    let mut command = podman_command(plan);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(stderr);
    match status_within(&mut command, MANAGE_TIMEOUT)? {
        Some(status) => Ok(status.success()),
        None => Err(stalled(&args.join(" "), MANAGE_TIMEOUT)),
    }
}

fn podman(plan: &Plan, args: &[&str]) -> Result<bool, String> {
    podman_with(plan, args, Stdio::inherit())
}

/// For calls whose failure is an answer and not a problem.
fn podman_quiet(plan: &Plan, args: &[&str]) -> Result<bool, String> {
    podman_with(plan, args, Stdio::null())
}

/// The holder owns the network namespace the app and its MCP server share.
/// Created if it is missing, started if it is stopped; losing a creation race
/// to another launch is fine as long as the container exists after.
fn start_holder(plan: &Plan, vars: &Vars, name: &str) -> Result<(), String> {
    if !podman_quiet(plan, &["container", "exists", name])? {
        let argv = resolve(&plan.holder_argv, plan, vars)?;
        let mut create = podman_command(plan);
        create.args(&argv[1..]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::inherit());
        let created = status_within(&mut create, MANAGE_TIMEOUT)?.ok_or_else(|| stalled("run (the network holder)", MANAGE_TIMEOUT))?;
        if !created.success() && !podman_quiet(plan, &["container", "exists", name])? {
            return Err(format!("could not create network holder `{name}`"));
        }
    }
    if !podman(plan, &["start", name])? {
        return Err(format!("could not start network holder `{name}`"));
    }
    Ok(())
}

/// An entry's claim on the holder, for as long as it runs. It is a shared
/// `flock` on a file in the runtime directory, so it ends with the process
/// however that happens, a `kill -9` included, and no bookkeeping can go stale.
struct Lease {
    _claim: File,
}

fn lock_file(path: &str) -> Result<File, String> {
    OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o600).open(path).map_err(|e| format!("cannot open {path}: {e}"))
}

/// The guard serialises the moments the holder is made or removed; the lease
/// file carries the claims themselves.
fn lock_paths(holder: &str, vars: &Vars) -> Result<(String, String), String> {
    let runtime = vars.get("xdg_runtime_dir").ok_or("no runtime directory to keep the holder's locks in")?;
    Ok((format!("{runtime}/{holder}.guard"), format!("{runtime}/{holder}.lease")))
}

fn lock_error(path: &str, e: std::io::Error) -> String {
    format!("cannot lock {path}: {e}")
}
/// Take a claim on the app's holder, making the holder first if no entry is
/// using one.
///
/// With no claim anywhere, a holder that exists is a leftover: from a reboot,
/// from a runner that was killed, or from before the app was updated. The
/// last of these is the one that matters, because a holder made from an older
/// root filesystem cannot start once that store path is collected. So it is
/// never reused; it is removed and made again from this launch's plan. If it
/// cannot be removed, because a container that still runs joins it, that one
/// is the holder the entry needs and it is used as it is.
fn acquire_lease(plan: &Plan, vars: &Vars) -> Result<Option<Lease>, String> {
    let Some(name) = &plan.holder else { return Ok(None) };
    let (guard_path, lease_path) = lock_paths(name, vars)?;
    let guard = lock_file(&guard_path)?;
    lock_within(&guard, GUARD_TIMEOUT).map_err(|e| format!("another launch of this app is stuck preparing its network holder ({e}); `ps -u $USER -o pid,etime,args | grep podman` shows it"))?;
    let claim = lock_file(&lease_path)?;
    match claim.try_lock() {
        Ok(()) => {
            if podman_quiet(plan, &["container", "exists", name])? {
                let _ = podman_quiet(plan, &["rm", "-f", "-t", "0", name]);
            }
        }
        Err(TryLockError::WouldBlock) => {}
        Err(TryLockError::Error(e)) => return Err(lock_error(&lease_path, e)),
    }
    start_holder(plan, vars, name)?;
    // Held in place of the exclusive lock above; the guard keeps anyone from
    // slipping in between the two.
    claim.lock_shared().map_err(|e| lock_error(&lease_path, e))?;
    Ok(Some(Lease { _claim: claim }))
}

/// End a claim, and remove the holder when it was the last. A holder that
/// cannot be removed, because a container still joins it, is left for the
/// next launch to deal with.
fn release_lease(plan: &Plan, vars: &Vars, lease: Lease) {
    drop(lease);
    let Some(name) = &plan.holder else { return };
    let Ok((guard_path, lease_path)) = lock_paths(name, vars) else { return };
    let Ok(guard) = lock_file(&guard_path) else { return };
    if lock_within(&guard, GUARD_TIMEOUT).is_err() {
        return;
    }
    let Ok(probe) = lock_file(&lease_path) else { return };
    if probe.try_lock().is_ok() {
        let _ = podman_quiet(plan, &["rm", "-f", "-t", "0", name]);
    }
}

// What the app is told when it is asked to stop. The standard library has no
// way to catch a signal; these are the C library's, which every Rust program
// on Linux links already. The numbers are the same on every architecture that
// NixOS runs on.
unsafe extern "C" {
    fn signal(signum: i32, handler: usize) -> usize;
    fn kill(pid: i32, sig: i32) -> i32;
    fn tcgetpgrp(fd: i32) -> i32;
    fn getpgrp() -> i32;
    fn __errno_location() -> *mut i32;
}

const SIGHUP: i32 = 1;
const SIGINT: i32 = 2;
const SIGQUIT: i32 = 3;
const SIGTERM: i32 = 15;

/// podman's pid while it runs, else 0; `EARLY` is a signal that arrived before.
static CHILD: AtomicI32 = AtomicI32::new(0);
static EARLY: AtomicI32 = AtomicI32::new(0);

/// Whether podman has to be told. When a terminal sends Ctrl-C to its
/// foreground group, podman is in that group and already has it; sending it
/// again would make the app see two. Anything else, and a plain SIGTERM from
/// whoever stops the app, reaches only this process.
fn must_forward(sig: i32) -> bool {
    sig == SIGTERM || unsafe { tcgetpgrp(0) != getpgrp() }
}

extern "C" fn relay(sig: i32) {
    // Only async-signal-safe calls in here, and errno put back as it was.
    unsafe {
        let saved = *__errno_location();
        let pid = CHILD.load(Ordering::SeqCst);
        if pid <= 0 {
            EARLY.store(sig, Ordering::SeqCst);
        } else if must_forward(sig) {
            kill(pid, sig);
        }
        *__errno_location() = saved;
    }
}

/// How a process ended, as a shell reports it.
fn exit_code(status: std::process::ExitStatus) -> i32 {
    status.code().unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
}

/// Run `command` as a child and wait for it, passing on the signals that ask
/// it to stop. This process has work to do after it ends, so it cannot hand
/// itself over with exec; and a SIGTERM that reached only this process would
/// otherwise leave podman, and the app, running.
fn supervise(command: &mut Command) -> Result<i32, String> {
    for sig in [SIGHUP, SIGINT, SIGQUIT, SIGTERM] {
        unsafe { signal(sig, relay as extern "C" fn(i32) as usize) };
    }
    let mut child = command.spawn().map_err(|e| format!("cannot run {}: {e}", command.get_program().to_string_lossy()))?;
    let pid = child.id() as i32;
    CHILD.store(pid, Ordering::SeqCst);
    let early = EARLY.swap(0, Ordering::SeqCst);
    if early != 0 && must_forward(early) {
        unsafe { kill(pid, early) };
    }
    let status = child.wait().map_err(|e| format!("cannot wait for {}: {e}", command.get_program().to_string_lossy()));
    CHILD.store(0, Ordering::SeqCst);
    Ok(exit_code(status?))
}

/// The proxy for as long as this exists. Dropping it stops the proxy (its
/// stdin, the pipe it was told to watch, closes with it) and removes the
/// socket, so the bus connection never outlives the app.
struct ProxyGuard {
    child: std::process::Child,
    socket: String,
}

impl Drop for ProxyGuard {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_file(&self.socket);
    }
}

/// Start the proxy and wait for its socket. No session bus, or a proxy that
/// does not come up, is not fatal: the app starts without D-Bus and degrades
/// the way it does on a machine that has none.
fn start_dbus_proxy(plan: &Plan, vars: &mut Vars) -> Result<Option<ProxyGuard>, String> {
    let Some(dbus) = &plan.dbus else { return Ok(None) };
    let upstream = expand(&dbus.upstream, vars)?;
    if !Path::new(&upstream).exists() {
        eprintln!("app-runner: no session bus at {upstream}; starting without D-Bus");
        return Ok(None);
    }
    let socket = expand(&dbus.socket, vars)?;
    mount_safe(&socket)?;
    if let Some(parent) = Path::new(&socket).parent() {
        ensure_dir(0o700, &parent.to_string_lossy())?;
    }
    let _ = fs::remove_file(&socket);
    let mut args = vec![format!("unix:path={upstream}"), socket.clone()];
    for a in &dbus.args {
        args.push(expand(a, vars)?);
    }
    args.push("--fd=0".into());
    let child = Command::new(&dbus.proxy)
        .args(&args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|e| format!("cannot run {}: {e}", dbus.proxy))?;
    let guard = ProxyGuard { child, socket: socket.clone() };
    for _ in 0..50 {
        if Path::new(&socket).exists() {
            vars.insert("dbus_socket".into(), socket);
            return Ok(Some(guard));
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    eprintln!("app-runner: the D-Bus proxy did not come up; starting without D-Bus");
    Ok(None)
}

/// One plan per user: paths inside the sandbox are the host's own, so a plan
/// is only right for the user it was rendered for.
fn plan_file(plan_dir: &str, uid: u32) -> String {
    format!("{}/{uid}.plan", plan_dir.trim_end_matches('/'))
}

fn run(plan_dir: &str, user_args: Vec<String>) -> Result<std::convert::Infallible, String> {
    let uid = fs::metadata("/proc/self").map_err(|e| format!("cannot read /proc/self: {e}"))?.uid();
    let plan_path = plan_file(plan_dir, uid);
    let text = match fs::read_to_string(&plan_path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Err(format!("this app is not set up for uid {uid} (no {plan_path})")),
        Err(e) => return Err(format!("cannot read plan {plan_path}: {e}")),
    };
    let mut plan = parse_plan(&text)?;
    let mut vars = host_vars(&plan)?;
    for (var, message) in &plan.require {
        if vars.get(var).map(String::is_empty).unwrap_or(true) {
            return Err(message.clone());
        }
    }
    for (mode, template) in &plan.ensure_dirs {
        ensure_dir(*mode, &expand(template, &vars)?)?;
    }
    resolve_podman(&mut plan, &vars)?;
    let lease = acquire_lease(&plan, &vars)?;
    let leased = lease.is_some();
    let outcome = launch(&plan, &mut vars, user_args, leased);
    if let Some(lease) = lease {
        release_lease(&plan, &vars, lease);
    }
    std::process::exit(outcome?);
}

/// Start the entry and, unless nothing is left to clean up, stay until it ends.
/// Returns the exit status the runner should end with.
fn launch(plan: &Plan, vars: &mut Vars, user_args: Vec<String>, leased: bool) -> Result<i32, String> {
    let proxy = start_dbus_proxy(plan, vars)?;
    let mut argv = resolve(&plan.run_argv, plan, vars)?;
    if plan.tty_auto && std::io::stdin().is_terminal() && std::io::stdout().is_terminal() && argv.len() > 1 {
        argv.insert(2, "-t".into());
    }
    argv.extend(user_args);
    let mut command = podman_command(plan);
    command.args(&argv[1..]);
    if proxy.is_none() && !leased {
        let err = command.exec();
        return Err(format!("cannot exec {}: {err}", plan.podman));
    }
    // The proxy and the claim on the holder have to be ended when the app does,
    // so podman is a child here and not a replacement of this process.
    let code = supervise(&mut command);
    drop(proxy);
    code
}

fn main() {
    let mut args = env::args().skip(1);
    let Some(plan) = args.next() else {
        eprintln!("usage: app-runner PLANDIR [ARGS...]");
        std::process::exit(2);
    };
    // `run` only returns when it failed: on success the process was replaced.
    let Err(message) = run(&plan, args.collect());
    eprintln!("app-runner: {message}");
    std::process::exit(1);
}

#[cfg(test)]
mod tests {
    use super::*;

    const PLAN: &str = "plan 1\n[meta]\nname\tdemo\npodman\t/bin/podman\nholder\tdemo-net\ntty\tauto\n[require]\nwayland_socket\tno compositor\n[ensure-dir]\n700\t{xdg_runtime_dir}/demo\n[provider gpu]\nmount\t/dev/dri\tnodev\nmount\t/dev/nvidia*\t\nmount-as\t{wayland_socket}\t/run/user/{uid}/wayland-0\tro\n[holder]\ns\tpodman\ns\trun\n[run]\ns\tpodman\ns\trun\nr\tpid\tdemo-\t\na\tgpu\ns\t/app\n";

    fn vars() -> Vars {
        [("uid", "1000"), ("xdg_runtime_dir", "/run/user/1000"), ("wayland_socket", "/run/user/1000/wayland-1"), ("pid", "7")]
            .into_iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = env::temp_dir().join(format!("app-runner-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn parses_a_whole_plan() {
        let plan = parse_plan(PLAN).unwrap();
        assert_eq!(plan.name, "demo");
        assert_eq!(plan.holder.as_deref(), Some("demo-net"));
        assert!(plan.tty_auto);
        assert_eq!(plan.ensure_dirs, vec![(0o700, "{xdg_runtime_dir}/demo".to_string())]);
        assert_eq!(plan.providers["gpu"].len(), 3);
        assert_eq!(plan.run_argv.len(), 5);
    }

    #[test]
    fn rejects_malformed_plans() {
        assert!(parse_plan("[meta]\n").is_err(), "no header");
        assert!(parse_plan("plan 1\n[nope]\n").is_err());
        assert!(parse_plan("plan 1\n[meta]\npodman\tpodman\n[run]\ns\tx\n").is_err(), "relative podman");
        assert!(parse_plan("plan 1\n[meta]\npodman\t/p\n").is_err(), "empty run");
        assert!(parse_plan("plan 1\n[provider p]\nmount\t/dev/*/x\t\n").is_err(), "wildcard in a directory");
    }

    #[test]
    fn the_plan_is_chosen_by_uid() {
        assert_eq!(plan_file("/nix/store/x-plans", 1000), "/nix/store/x-plans/1000.plan");
        assert_eq!(plan_file("/nix/store/x-plans/", 0), "/nix/store/x-plans/0.plan");
    }

    #[test]
    fn derived_variables_build_on_earlier_ones() {
        let plan = parse_plan("plan 1\n[meta]\npodman\t/p\n[vars]\nstate\t{home}/.var/app/x\ntokens\t{state}/tokens\n[run]\ns\tx\n").unwrap();
        let mut v: Vars = [("home".to_string(), "/home/u".to_string())].into_iter().collect();
        derive(&plan, &mut v).unwrap();
        assert_eq!(v["tokens"], "/home/u/.var/app/x/tokens");
        let bad = parse_plan("plan 1\n[meta]\npodman\t/p\n[vars]\na\t{later}\nlater\tx\n[run]\ns\tx\n").unwrap();
        assert!(derive(&bad, &mut Vars::new()).is_err(), "a variable cannot use one defined after it");
    }

    #[test]
    fn expands_templates_and_rejects_unknown_names() {
        assert_eq!(expand("/run/user/{uid}/x", &vars()).unwrap(), "/run/user/1000/x");
        assert!(expand("{missing}", &vars()).is_err());
        assert!(expand("{open", &vars()).is_err());
    }

    #[test]
    fn globs() {
        assert!(glob_match("nvidia*", "nvidia0"));
        assert!(glob_match("nvidia*", "nvidia"));
        assert!(glob_match("render?128", "renderD128"));
        assert!(!glob_match("render?128", "render128"));
        assert!(glob_match("renderD1??", "renderD128"));
        assert!(!glob_match("nvidia*", "xnvidia0"));
    }

    #[test]
    fn a_wildcard_never_matches_a_hidden_name() {
        assert!(glob_match("*", "Documents"));
        assert!(!glob_match("*", ".ssh"));
        assert!(!glob_match("*", ".config"));
        assert!(!glob_match("?ssh", ".ssh"));
        assert!(glob_match(".*", ".ssh"), "asking for dotfiles by name still works");
        assert!(glob_match("*", "a.b"));
    }

    #[test]
    fn overlapping_mounts_keep_the_first_destination() {
        let argv: Vec<String> = [
            "run",
            "--mount",
            "type=tmpfs,destination=/tmp,rw",
            "--mount",
            "type=bind,source=/h/Documents,destination=/h/Documents,rw",
            "--mount",
            "type=bind,source=/other,destination=/h/Documents,ro",
            "--env",
            "A=1",
            "--mount",
            "type=bind,source=/x,destination=/x",
        ]
        .map(String::from)
        .to_vec();
        let kept = drop_duplicate_mounts(argv);
        assert_eq!(kept.iter().filter(|a| *a == "--mount").count(), 3);
        assert!(kept.contains(&"type=bind,source=/h/Documents,destination=/h/Documents,rw".to_string()));
        assert!(!kept.iter().any(|a| a.contains("/other")));
        assert!(kept.contains(&"A=1".to_string()), "other arguments are untouched");
    }

    #[test]
    fn a_dangling_link_or_a_socket_is_not_bound() {
        use std::os::unix::fs::symlink;
        let dir = scratch("odd");
        fs::create_dir(dir.join("real")).unwrap();
        symlink("/nonexistent/target", dir.join("dangling")).unwrap();
        symlink(dir.join("real"), dir.join("alias")).unwrap();
        let _socket = std::os::unix::net::UnixListener::bind(dir.join("sock")).unwrap();
        let rule = Rule::Mount { pattern: format!("{}/*", dir.to_string_lossy()), options: String::new() };
        let joined = expand_rule(&rule, &vars()).unwrap().join(" ");
        assert!(joined.contains("/real") && joined.contains("/alias"), "a link to a directory is bound: {joined}");
        assert!(!joined.contains("dangling") && !joined.contains("/sock"), "{joined}");
        fs::remove_dir_all(dir).unwrap();
    }

    const DBUS_PLAN: &str = "plan 1\n[meta]\npodman\t/bin/podman\n[dbus]\nproxy\t/bin/proxy\nupstream\t{xdg_runtime_dir}/bus\nsocket\t{xdg_runtime_dir}/x/bus-{pid}\narg\t--filter\narg\t--talk=org.freedesktop.portal.*\n[run]\ns\tpodman\n";

    #[test]
    fn parses_the_dbus_section() {
        let plan = parse_plan(DBUS_PLAN).unwrap();
        let d = plan.dbus.unwrap();
        assert_eq!(d.proxy, "/bin/proxy");
        assert_eq!(d.args, vec!["--filter", "--talk=org.freedesktop.portal.*"]);
        assert!(parse_plan("plan 1\n[meta]\npodman\t/p\n[dbus]\nproxy\trelative\n[run]\ns\tx\n").is_err());
        assert!(parse_plan("plan 1\n[meta]\npodman\t/p\n[dbus]\nnonsense\n[run]\ns\tx\n").is_err());
    }

    #[test]
    fn the_dbus_proxy_lives_exactly_as_long_as_its_guard() {
        let dir = scratch("dbus");
        let bus = dir.join("bus");
        fs::write(&bus, "").unwrap();
        // Stands in for xdg-dbus-proxy: makes the socket named by its second
        // argument, then waits until its stdin (the lifetime pipe) closes.
        let fake = dir.join("proxy");
        fs::write(&fake, "#!/bin/sh\n: > \"$2\"\nexec cat > /dev/null\n").unwrap();
        fs::set_permissions(&fake, fs::Permissions::from_mode(0o755)).unwrap();
        let plan = parse_plan(&DBUS_PLAN.replace("/bin/proxy", &fake.to_string_lossy())).unwrap();
        let mut v = vars();
        v.insert("xdg_runtime_dir".into(), dir.to_string_lossy().into_owned());
        v.insert("dbus_socket".into(), String::new());
        let guard = start_dbus_proxy(&plan, &mut v).unwrap().expect("proxy started");
        let socket = v["dbus_socket"].clone();
        assert!(socket.starts_with(&*dir.to_string_lossy()) && Path::new(&socket).exists());
        drop(guard);
        assert!(!Path::new(&socket).exists(), "the socket goes with the guard");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn no_session_bus_means_no_proxy_and_no_failure() {
        let plan = parse_plan(DBUS_PLAN).unwrap();
        let mut v = vars();
        v.insert("xdg_runtime_dir".into(), "/nonexistent".into());
        v.insert("dbus_socket".into(), String::new());
        assert!(start_dbus_proxy(&plan, &mut v).unwrap().is_none());
        assert_eq!(v["dbus_socket"], "");
        let none = parse_plan("plan 1\n[meta]\npodman\t/p\n[run]\ns\tx\n").unwrap();
        assert!(start_dbus_proxy(&none, &mut v).unwrap().is_none());
    }

    #[test]
    fn podman_always_finds_the_setuid_id_mappers() {
        assert_eq!(with_wrappers(""), "/run/wrappers/bin");
        assert_eq!(with_wrappers("/usr/bin:/bin"), "/run/wrappers/bin:/usr/bin:/bin");
        let already = "/usr/bin:/run/wrappers/bin:/bin";
        assert_eq!(with_wrappers(already), already, "an existing entry is left where it is");
    }

    #[test]
    fn a_device_node_is_bound_because_the_gpu_is_one() {
        // /dev/null is a character device on every Linux, like /dev/nvidia0.
        assert!(bindable("/dev/null"));
        assert!(bindable("/dev"));
        let rule = Rule::Mount { pattern: "/dev/nul?".into(), options: "nosuid".into() };
        let args = expand_rule(&rule, &vars()).unwrap();
        assert_eq!(args, vec!["--mount", "type=bind,source=/dev/null,destination=/dev/null,nosuid"]);
        assert!(!bindable("/nonexistent/dev"));
    }

    #[test]
    fn a_wildcard_matching_far_too_much_is_refused() {
        let dir = scratch("many");
        for i in 0..=MAX_BINDS {
            fs::write(dir.join(format!("f{i}")), "").unwrap();
        }
        let rule = Rule::Mount { pattern: format!("{}/f*", dir.to_string_lossy()), options: String::new() };
        assert!(expand_rule(&rule, &vars()).unwrap_err().contains("refusing"));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_home_pattern_skips_dotfiles_and_binds_the_rest() {
        let dir = scratch("home");
        for f in ["Documents", "projects", ".ssh", ".gnupg", ".config"] {
            fs::create_dir(dir.join(f)).unwrap();
        }
        let rule = Rule::Mount { pattern: format!("{}/*", dir.to_string_lossy()), options: "nosuid".into() };
        let args = expand_rule(&rule, &vars()).unwrap();
        let joined = args.join(" ");
        assert!(joined.contains("Documents") && joined.contains("projects"));
        assert!(!joined.contains(".ssh") && !joined.contains(".gnupg") && !joined.contains(".config"));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_comma_in_a_path_cannot_become_a_mount_option() {
        assert!(bind("/dev/x,bind-propagation=shared", "/dev/x", "ro").is_err());
        assert!(bind("/dev/x", "/dev/x,rw", "ro").is_err());
        assert!(bind("relative", "/x", "").is_err());
        assert_eq!(bind("/a", "/b", "ro,nosuid").unwrap(), vec!["--mount", "type=bind,source=/a,destination=/b,ro,nosuid"]);
    }

    #[test]
    fn mount_rule_binds_only_what_exists() {
        let dir = scratch("glob");
        for f in ["nvidia0", "nvidiactl", "other"] {
            fs::write(dir.join(f), "").unwrap();
        }
        let d = dir.to_string_lossy();
        let rule = Rule::Mount { pattern: format!("{d}/nvidia*"), options: String::new() };
        let args = expand_rule(&rule, &vars()).unwrap();
        assert_eq!(args.len(), 4);
        assert!(args[1].contains("nvidia0") && args[3].contains("nvidiactl"));
        let none = Rule::Mount { pattern: format!("{d}/absent*"), options: String::new() };
        assert!(expand_rule(&none, &vars()).unwrap().is_empty());
        let single = Rule::Mount { pattern: format!("{d}/other"), options: "ro".into() };
        assert_eq!(expand_rule(&single, &vars()).unwrap().len(), 2);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_hostile_file_name_is_refused_not_bound() {
        let dir = scratch("hostile");
        fs::write(dir.join("nvidia0,bind-propagation=shared"), "").unwrap();
        let rule = Rule::Mount { pattern: format!("{}/nvidia*", dir.to_string_lossy()), options: String::new() };
        assert!(expand_rule(&rule, &vars()).is_err());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn mount_as_skips_a_missing_source() {
        let rule = Rule::MountAs { source: "/nonexistent/wayland-9".into(), destination: "/run/user/{uid}/wayland-0".into(), options: "ro".into() };
        assert!(expand_rule(&rule, &vars()).unwrap().is_empty());
    }

    #[test]
    fn resolves_literals_variables_and_splices_in_order() {
        let plan = parse_plan(PLAN).unwrap();
        let mut v = vars();
        v.insert("pid".into(), "42".into());
        let argv = resolve(&plan.run_argv, &plan, &v).unwrap();
        assert_eq!(&argv[..3], ["podman", "run", "demo-42"]);
        assert_eq!(argv.last().map(String::as_str), Some("/app"));
        assert!(resolve(&[Item::Splice("nope".into())], &plan, &v).is_err());
        assert!(resolve(&[Item::Var { name: "nope".into(), prefix: String::new(), suffix: String::new() }], &plan, &v).is_err());
    }

    #[test]
    fn a_holder_needs_a_safe_name_and_a_command() {
        let with = |holder: &str, argv: &str| format!("plan 1\n[meta]\npodman\t/p\nholder\t{holder}\n[holder]\n{argv}[run]\ns\tx\n");
        let command = "s\tpodman\ns\trun\n";
        assert!(parse_plan(&with("demo-net", command)).is_ok());
        assert!(parse_plan(&with("../escape", command)).is_err(), "a name that leaves the runtime directory");
        assert!(parse_plan(&with("", command)).is_err());
        assert!(parse_plan(&with("demo-net", "")).is_err(), "nothing to create it with");
    }

    /// A podman whose containers are marker files in `dir`, and whose calls are
    /// written to `dir/log`: a holder exists while `dir/holder` does, `stale`
    /// makes one that cannot start (as when its root filesystem is gone), and
    /// `dependents` makes one that cannot be removed.
    fn fake_podman(dir: &Path) -> Plan {
        let fake = dir.join("podman");
        let script = format!(
            "#!/bin/sh\nd='{d}'\necho \"$*\" >> \"$d/log\"\ncase \"$1\" in\n\
             container) [ -e \"$d/holder\" ] ;;\n\
             rm) [ -e \"$d/dependents\" ] && exit 1; rm -f \"$d/holder\" \"$d/stale\" ;;\n\
             start) [ -e \"$d/holder\" ] && [ ! -e \"$d/stale\" ] ;;\n\
             run) : > \"$d/holder\" ;;\n\
             esac\n",
            d = dir.to_string_lossy()
        );
        fs::write(&fake, script).unwrap();
        fs::set_permissions(&fake, fs::Permissions::from_mode(0o755)).unwrap();
        let f = fake.to_string_lossy();
        parse_plan(&format!("plan 1\n[meta]\nname\tdemo\npodman\t{f}\nholder\tdemo-net\n[holder]\ns\t{f}\ns\trun\ns\t-d\n[run]\ns\tx\n")).unwrap()
    }

    fn state(dir: &Path) -> Vars {
        let mut v = vars();
        v.insert("xdg_runtime_dir".into(), dir.to_string_lossy().into_owned());
        v
    }

    fn calls(dir: &Path, verb: &str) -> usize {
        fs::read_to_string(dir.join("log")).unwrap_or_default().lines().filter(|l| l.starts_with(verb)).count()
    }

    #[test]
    fn the_holder_is_made_for_the_first_entry_and_removed_after_the_last() {
        let dir = scratch("lease");
        let (plan, v) = (fake_podman(&dir), state(&dir));
        let first = acquire_lease(&plan, &v).unwrap().expect("a plan with a holder leases it");
        assert!(dir.join("holder").exists());
        assert_eq!(calls(&dir, "run"), 1);
        let second = acquire_lease(&plan, &v).unwrap().unwrap();
        assert_eq!(calls(&dir, "run"), 1, "the second entry joins the holder that is there");
        release_lease(&plan, &v, first);
        assert!(dir.join("holder").exists(), "an entry is still running");
        release_lease(&plan, &v, second);
        assert!(!dir.join("holder").exists(), "nothing left to hold");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_entry_without_a_holder_takes_no_lease() {
        let dir = scratch("nolease");
        let plan = parse_plan("plan 1\n[meta]\npodman\t/p\n[run]\ns\tx\n").unwrap();
        assert!(acquire_lease(&plan, &state(&dir)).unwrap().is_none());
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 0, "no lock files either");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_leftover_holder_is_replaced_when_nobody_uses_it() {
        // The holder of an older root filesystem, which can no longer start.
        let dir = scratch("stale");
        let (plan, v) = (fake_podman(&dir), state(&dir));
        fs::write(dir.join("holder"), "").unwrap();
        fs::write(dir.join("stale"), "").unwrap();
        let lease = acquire_lease(&plan, &v).expect("the stale holder does not stop the launch").unwrap();
        assert_eq!(calls(&dir, "rm"), 1);
        assert_eq!(calls(&dir, "run"), 1, "made again from this launch's plan");
        assert!(!dir.join("stale").exists());
        release_lease(&plan, &v, lease);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_holder_still_in_use_is_not_replaced() {
        let dir = scratch("busy");
        let (plan, v) = (fake_podman(&dir), state(&dir));
        let first = acquire_lease(&plan, &v).unwrap().unwrap();
        let second = acquire_lease(&plan, &v).unwrap().unwrap();
        assert_eq!(calls(&dir, "rm"), 0, "an entry is running on it");
        release_lease(&plan, &v, first);
        release_lease(&plan, &v, second);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_holder_that_cannot_be_removed_is_used_as_it_is() {
        // A container whose runner was killed still joins it.
        let dir = scratch("dependents");
        let (plan, v) = (fake_podman(&dir), state(&dir));
        fs::write(dir.join("holder"), "").unwrap();
        fs::write(dir.join("dependents"), "").unwrap();
        let lease = acquire_lease(&plan, &v).expect("a refused removal is not an error").unwrap();
        assert_eq!(calls(&dir, "run"), 0, "the holder that is there is the one to use");
        assert_eq!(calls(&dir, "start"), 1);
        release_lease(&plan, &v, lease);
        assert!(dir.join("holder").exists(), "and it stays, with the container that needs it");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_runner_that_dies_leaves_no_claim_behind() {
        let dir = scratch("crash");
        let (plan, v) = (fake_podman(&dir), state(&dir));
        let lost = acquire_lease(&plan, &v).unwrap().unwrap();
        drop(lost); // what the kernel does to a killed process's locks
        let next = acquire_lease(&plan, &v).unwrap().unwrap();
        assert_eq!(calls(&dir, "run"), 2, "nobody holds the old claim, so the holder is made again");
        release_lease(&plan, &v, next);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn every_podman_call_carries_the_plans_global_options_and_environment() {
        let dir = scratch("podman-section");
        let fake = dir.join("podman");
        fs::write(&fake, format!("#!/bin/sh\necho \"$* LOCK=$CONTAINERS_LOCK\" >> '{}/log'\n", dir.to_string_lossy())).unwrap();
        fs::set_permissions(&fake, fs::Permissions::from_mode(0o755)).unwrap();
        let text = format!(
            "plan 1\n[meta]\npodman\t{}\n[podman]\narg\t--root\narg\t{{xdg_runtime_dir}}/p/root\nenv\tCONTAINERS_LOCK\t{{xdg_runtime_dir}}/p.conf\n[run]\ns\tx\n",
            fake.to_string_lossy()
        );
        let mut plan = parse_plan(&text).unwrap();
        assert_eq!(plan.podman_args, vec!["--root", "{xdg_runtime_dir}/p/root"]);
        assert_eq!(plan.podman_env, vec![("CONTAINERS_LOCK".to_string(), "{xdg_runtime_dir}/p.conf".to_string())]);
        resolve_podman(&mut plan, &state(&dir)).unwrap();
        assert!(podman_quiet(&plan, &["container", "exists", "demo-net"]).unwrap());
        let log = fs::read_to_string(dir.join("log")).unwrap();
        let d = dir.to_string_lossy();
        assert_eq!(log.trim(), format!("--root {d}/p/root container exists demo-net LOCK={d}/p.conf"), "options come before the subcommand");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_plan_without_a_podman_section_calls_podman_as_before() {
        let plan = parse_plan("plan 1\n[meta]\npodman\t/p\n[run]\ns\tx\n").unwrap();
        assert!(plan.podman_args.is_empty() && plan.podman_env.is_empty());
        let command = podman_command(&plan);
        assert_eq!(command.get_args().count(), 0);
        assert!(parse_plan("plan 1\n[meta]\npodman\t/p\n[podman]\nenv\tA=B\tv\n[run]\ns\tx\n").is_err(), "a name with `=`");
        assert!(parse_plan("plan 1\n[meta]\npodman\t/p\n[podman]\nnonsense\n[run]\ns\tx\n").is_err());
    }

    #[test]
    fn a_podman_call_that_does_not_come_back_is_stopped() {
        let started = Instant::now();
        let stopped = status_within(Command::new("/bin/sh").args(["-c", "sleep 30"]), Duration::from_millis(200)).unwrap();
        assert!(stopped.is_none(), "reported as stopped");
        assert!(started.elapsed() < Duration::from_secs(10), "and it was not waited for");
        let quick = status_within(Command::new("/bin/sh").args(["-c", "exit 4"]), Duration::from_secs(30)).unwrap().unwrap();
        assert_eq!(quick.code(), Some(4), "a call that finishes keeps its status");
        assert!(status_within(&mut Command::new("/nonexistent/podman"), Duration::from_secs(1)).is_err());
        assert!(stalled("start demo-net", MANAGE_TIMEOUT).contains("start demo-net"));
    }

    #[test]
    fn waiting_for_another_launch_ends() {
        let dir = scratch("lockwait");
        let path = dir.join("guard").to_string_lossy().into_owned();
        let holder = lock_file(&path).unwrap();
        holder.lock().unwrap();
        let waiter = lock_file(&path).unwrap();
        let started = Instant::now();
        assert!(lock_within(&waiter, Duration::from_millis(150)).unwrap_err().contains("still locked"));
        assert!(started.elapsed() < Duration::from_secs(10));
        drop(holder);
        assert!(lock_within(&waiter, Duration::from_millis(150)).is_ok(), "free once the other launch is done");
        fs::remove_dir_all(dir).unwrap();
    }

    /// `supervise` keeps the running child's pid in a static, as the signal
    /// handler has nowhere else to look; tests that start one take turns.
    static ONE_SUPERVISOR: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn a_supervised_command_gives_its_exit_status() {
        let _turn = ONE_SUPERVISOR.lock().unwrap_or_else(|e| e.into_inner());
        let sh = |script: &str| supervise(Command::new("/bin/sh").args(["-c", script]));
        assert_eq!(sh("exit 0").unwrap(), 0);
        assert_eq!(sh("exit 3").unwrap(), 3);
        assert_eq!(sh("kill -9 $$").unwrap(), 128 + 9, "as a shell reports a command that was killed");
        assert!(supervise(&mut Command::new("/nonexistent/podman")).is_err());
    }

    #[test]
    fn sigterm_to_the_runner_reaches_the_app() {
        let _turn = ONE_SUPERVISOR.lock().unwrap_or_else(|e| e.into_inner());
        let dir = scratch("term");
        let ready = dir.join("ready");
        let script = format!("trap 'exit 9' TERM; : > '{}'; while :; do sleep 0.05; done", ready.to_string_lossy());
        let signaller = std::thread::spawn({
            let ready = ready.clone();
            move || {
                for _ in 0..200 {
                    if ready.exists() {
                        break;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                unsafe { kill(std::process::id() as i32, SIGTERM) };
            }
        });
        let code = supervise(Command::new("/bin/sh").args(["-c", &script])).unwrap();
        signaller.join().unwrap();
        assert_eq!(code, 9, "the command saw the signal this process was sent");
        assert!(must_forward(SIGTERM), "a terminate request is always passed on");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn ensure_dir_creates_and_tightens() {
        let dir = scratch("dirs");
        let target = dir.join("a/b");
        ensure_dir(0o700, &target.to_string_lossy()).unwrap();
        assert_eq!(fs::metadata(&target).unwrap().permissions().mode() & 0o777, 0o700);
        fs::set_permissions(&target, fs::Permissions::from_mode(0o755)).unwrap();
        ensure_dir(0o700, &target.to_string_lossy()).unwrap();
        assert_eq!(fs::metadata(&target).unwrap().permissions().mode() & 0o777, 0o700);
        fs::remove_dir_all(dir).unwrap();
    }
}
