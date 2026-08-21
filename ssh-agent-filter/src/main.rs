//! A filtering ssh-agent proxy.
//!
//! Meant to run OUTSIDE whatever it protects the agent from: for
//! nix-dev-container that means on the host, with only the filtered socket
//! reaching the container.

use clap::Parser;
use ssh_agent_filter::policy::{Mode, Policy};
use ssh_agent_filter::serve;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Parser)]
#[command(about = "Expose a restricted view of an ssh-agent on another socket")]
struct Args {
    /// Upstream agent socket (what SSH_AUTH_SOCK points at).
    #[arg(long)]
    upstream: PathBuf,

    /// Socket to create and serve the filtered view on.
    #[arg(long)]
    listen: PathBuf,

    /// Permit ONLY these keys, by SHA256 fingerprint or comment (`*` globs
    /// comments). Repeatable. Mutually exclusive with --deny.
    #[arg(long)]
    allow: Vec<String>,

    /// Permit everything EXCEPT these keys. Repeatable. Mutually exclusive
    /// with --allow.
    #[arg(long)]
    deny: Vec<String>,

    /// Forward agent extension requests. Off by default: an extension's
    /// semantics are unknown here, so it cannot be policed, and forwarding
    /// one blind would be a hole straight through the policy.
    #[arg(long)]
    allow_extensions: bool,

    /// Log each decision to stderr.
    #[arg(long)]
    verbose: bool,
}

fn main() -> io::Result<()> {
    let args = Args::parse();
    let policy = Policy::new(args.allow.clone(), args.deny.clone())
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;

    // Replace a socket left behind by a previous run; a stale one would
    // otherwise make bind fail with EADDRINUSE forever.
    if args.listen.exists() {
        std::fs::remove_file(&args.listen)?;
    }
    let listener = UnixListener::bind(&args.listen)?;
    // 0600 before anyone can connect: the socket hands out the use of
    // someone's ssh keys, so it must not be reachable by other users on the
    // host even briefly.
    std::fs::set_permissions(&args.listen, std::fs::Permissions::from_mode(0o600))?;

    if args.verbose {
        let what = match policy.mode {
            Mode::PassAll => "all keys (mutating requests still refused)".to_string(),
            Mode::Allow => format!("allow {:?}", policy.specs),
            Mode::Deny => format!("deny {:?}", policy.specs),
        };
        eprintln!(
            "ssh-agent-filter: {} -> {}: {what}",
            args.listen.display(),
            args.upstream.display()
        );
    }

    let policy = Arc::new(policy);
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(s) => s,
            Err(e) => {
                eprintln!("ssh-agent-filter: accept: {e}");
                continue;
            }
        };
        let policy = policy.clone();
        let upstream = args.upstream.clone();
        let verbose = args.verbose;
        let allow_ext = args.allow_extensions;
        std::thread::spawn(move || {
            if let Err(e) = serve(stream, &upstream, &policy, verbose, allow_ext) {
                if verbose {
                    eprintln!("ssh-agent-filter: connection: {e}");
                }
            }
        });
    }
    Ok(())
}
