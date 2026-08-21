//! Filtering ssh-agent proxy. See `serve` for the policed conversation.

pub mod policy;
pub mod proto;

use policy::Policy;
use proto::Message;
use std::io;
use std::os::unix::net::UnixStream;
use std::path::Path;

/// Proxy one client connection, applying `policy`.
///
/// Refusals are `SSH_AGENT_FAILURE`, which is what an agent sends when it
/// will not do something - so a filtered client behaves exactly as if the
/// key were simply not there, rather than learning that a filter exists.
pub fn serve(
    mut client: UnixStream,
    upstream_path: &Path,
    policy: &Policy,
    verbose: bool,
    allow_ext: bool,
) -> io::Result<()> {
    let mut upstream = UnixStream::connect(upstream_path)?;
    // blob -> comment, so a SIGN_REQUEST (which carries a blob and nothing
    // else) can still be judged by a comment-based policy.
    let mut known: Vec<(Vec<u8>, Vec<u8>)> = Vec::new();

    while let Some(req) = Message::read(&mut client)? {
        let kind = req.kind();

        if proto::is_mutating(kind) || (kind == proto::SSH_AGENTC_EXTENSION && !allow_ext) {
            if verbose {
                eprintln!("ssh-agent-filter: refused request type {kind}");
            }
            Message::failure().write(&mut client)?;
            continue;
        }

        if kind == proto::SSH_AGENTC_SIGN_REQUEST {
            let blob = proto::sign_request_key(req.payload()).map(|b| b.to_vec());
            // A client is not obliged to list before it signs, and one that
            // already knows a blob has no reason to. Without the comment for
            // that blob a comment-based DENY would sail straight through, so
            // ask upstream for the identities before ruling on a blob we have
            // not seen. Costs one round trip, once per connection.
            if let Some(b) = &blob {
                if !known.iter().any(|(kb, _)| kb == b) {
                    known = fetch_identities(&mut upstream).unwrap_or_default();
                }
            }
            match &blob {
                Some(b) if policy.permits_blob(b, &known) => {}
                other => {
                    if verbose {
                        let what = match other {
                            Some(b) => policy::fingerprint(b),
                            None => "<unparseable>".into(),
                        };
                        eprintln!("ssh-agent-filter: refused signature with {what}");
                    }
                    Message::failure().write(&mut client)?;
                    continue;
                }
            }
        }

        req.write(&mut upstream)?;
        let Some(resp) = Message::read(&mut upstream)? else {
            return Ok(());
        };

        if kind == proto::SSH_AGENTC_REQUEST_IDENTITIES
            && resp.kind() == proto::SSH_AGENT_IDENTITIES_ANSWER
        {
            let Some(ids) = proto::parse_identities(resp.payload()) else {
                // Fail closed: an answer we cannot parse is one we cannot
                // filter, and forwarding it would leak the very keys the
                // policy exists to hide.
                eprintln!("ssh-agent-filter: unparseable identities answer, refusing");
                Message::failure().write(&mut client)?;
                continue;
            };
            // Recorded BEFORE filtering: the map exists to judge blobs, and a
            // blob that was filtered out is exactly the one worth judging.
            known = ids
                .iter()
                .map(|i| (i.blob.clone(), i.comment.clone()))
                .collect();
            let kept: Vec<_> = ids
                .iter()
                .filter(|i| policy.permits(&i.blob, &i.comment))
                .collect();
            if verbose {
                eprintln!(
                    "ssh-agent-filter: identities {} of {} shown",
                    kept.len(),
                    ids.len()
                );
            }
            proto::build_identities(&kept).write(&mut client)?;
            continue;
        }

        resp.write(&mut client)?;
    }
    Ok(())
}

/// Ask upstream for its identities on our own behalf.
fn fetch_identities(upstream: &mut UnixStream) -> io::Result<Vec<(Vec<u8>, Vec<u8>)>> {
    Message(vec![proto::SSH_AGENTC_REQUEST_IDENTITIES]).write(upstream)?;
    let Some(resp) = Message::read(upstream)? else {
        return Ok(Vec::new());
    };
    if resp.kind() != proto::SSH_AGENT_IDENTITIES_ANSWER {
        return Ok(Vec::new());
    }
    Ok(proto::parse_identities(resp.payload())
        .unwrap_or_default()
        .into_iter()
        .map(|i| (i.blob, i.comment))
        .collect())
}
