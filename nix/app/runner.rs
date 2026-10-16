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
// Plan format: see parse_plan. Standard library only.

use std::collections::BTreeMap;
use std::io::IsTerminal;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
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
                ["holder", v] => plan.holder = Some(v.to_string()),
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

fn podman_command(plan: &Plan) -> Command {
    let mut command = Command::new(&plan.podman);
    command.env("PATH", with_wrappers(&env::var("PATH").unwrap_or_default()));
    command
}

fn podman(plan: &Plan, args: &[&str]) -> Result<bool, String> {
    podman_command(plan)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .status()
        .map(|s| s.success())
        .map_err(|e| format!("cannot run {}: {e}", plan.podman))
}

/// The holder owns the network namespace the app and its MCP server share.
/// Created on first use, started again if it was stopped; losing a creation
/// race to another launch is fine as long as the container exists after.
fn ensure_holder(plan: &Plan, vars: &Vars) -> Result<(), String> {
    let Some(name) = &plan.holder else { return Ok(()) };
    if !podman(plan, &["container", "exists", name])? {
        let argv = resolve(&plan.holder_argv, plan, vars)?;
        let created = podman_command(plan)
            .args(&argv[1..])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .status()
            .map_err(|e| format!("cannot run {}: {e}", plan.podman))?;
        if !created.success() && !podman(plan, &["container", "exists", name])? {
            return Err(format!("could not create network holder `{name}`"));
        }
    }
    if !podman(plan, &["start", name])? {
        return Err(format!("could not start network holder `{name}`"));
    }
    Ok(())
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
    let plan = parse_plan(&text)?;
    let mut vars = host_vars(&plan)?;
    for (var, message) in &plan.require {
        if vars.get(var).map(String::is_empty).unwrap_or(true) {
            return Err(message.clone());
        }
    }
    for (mode, template) in &plan.ensure_dirs {
        ensure_dir(*mode, &expand(template, &vars)?)?;
    }
    ensure_holder(&plan, &vars)?;
    let proxy = start_dbus_proxy(&plan, &mut vars)?;
    let mut argv = resolve(&plan.run_argv, &plan, &vars)?;
    if plan.tty_auto && std::io::stdin().is_terminal() && std::io::stdout().is_terminal() && argv.len() > 1 {
        argv.insert(2, "-t".into());
    }
    argv.extend(user_args);
    let Some(guard) = proxy else {
        let err = podman_command(&plan).args(&argv[1..]).exec();
        return Err(format!("cannot exec {}: {err}", plan.podman));
    };
    // The proxy has to be cleaned up when the app ends, so podman is a child
    // here and not a replacement of this process.
    let status = podman_command(&plan).args(&argv[1..]).status().map_err(|e| format!("cannot run {}: {e}", plan.podman));
    drop(guard);
    std::process::exit(status?.code().unwrap_or(1));
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
