//! Drives `serve` over a real socket pair against a stub agent, so the
//! protocol path is exercised the way a client exercises it - including the
//! requests a well-behaved client never sends, which are the interesting
//! ones for a filter.

use ssh_agent_filter::policy::Policy;
use ssh_agent_filter::proto::{self, Message};
use ssh_agent_filter::serve;
use std::io::Write;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::thread;

static N: AtomicU32 = AtomicU32::new(0);

fn tmp(tag: &str) -> PathBuf {
    let n = N.fetch_add(1, Ordering::SeqCst);
    let mut p = std::env::temp_dir();
    p.push(format!("saf-test-{}-{tag}-{n}.sock", std::process::id()));
    let _ = std::fs::remove_file(&p);
    p
}

const KEYS: &[(&[u8], &[u8])] = &[
    (b"blob-github", b"Github 1password SSH Key"),
    (b"blob-sudo", b"Sudo Servers"),
    (b"blob-lrz", b"GitLab LRZ SSH Key"),
];

/// A stub agent: answers identity requests with KEYS, and claims success for
/// any signature or mutation asked of it. Anything the filter lets through
/// therefore shows up as a success the client can observe.
fn stub_agent(path: PathBuf) -> thread::JoinHandle<Vec<u8>> {
    let listener = UnixListener::bind(&path).unwrap();
    thread::spawn(move || {
        let mut seen = Vec::new();
        let (mut sock, _) = listener.accept().unwrap();
        while let Ok(Some(req)) = Message::read(&mut sock) {
            seen.push(req.kind());
            let resp = match req.kind() {
                proto::SSH_AGENTC_REQUEST_IDENTITIES => {
                    let mut body = vec![proto::SSH_AGENT_IDENTITIES_ANSWER];
                    body.extend_from_slice(&(KEYS.len() as u32).to_be_bytes());
                    for (blob, comment) in KEYS {
                        proto::put_string(&mut body, blob);
                        proto::put_string(&mut body, comment);
                    }
                    Message(body)
                }
                // 14 = SIGN_RESPONSE, 6 = SUCCESS. Either way: "it worked",
                // so the test can tell forwarded from refused.
                proto::SSH_AGENTC_SIGN_REQUEST => Message(vec![14]),
                _ => Message(vec![6]),
            };
            if resp.write(&mut sock).is_err() {
                break;
            }
        }
        seen
    })
}

struct Harness {
    client: UnixStream,
    upstream_seen: thread::JoinHandle<Vec<u8>>,
    filter: thread::JoinHandle<()>,
}

fn start(policy: Policy) -> Harness {
    let up = tmp("up");
    let upstream_seen = stub_agent(up.clone());
    let (client, filter_side) = UnixStream::pair().unwrap();
    let filter = thread::spawn(move || {
        let _ = serve(filter_side, &up, &policy, false, false);
    });
    Harness { client, upstream_seen, filter }
}

impl Harness {
    fn ask(&mut self, msg: Message) -> Message {
        msg.write(&mut self.client).unwrap();
        Message::read(&mut self.client).unwrap().unwrap()
    }

    fn identities(&mut self) -> Vec<String> {
        let resp = self.ask(Message(vec![proto::SSH_AGENTC_REQUEST_IDENTITIES]));
        assert_eq!(resp.kind(), proto::SSH_AGENT_IDENTITIES_ANSWER);
        proto::parse_identities(resp.payload())
            .unwrap()
            .into_iter()
            .map(|i| String::from_utf8_lossy(&i.comment).into_owned())
            .collect()
    }

    fn sign_with(&mut self, blob: &[u8]) -> u8 {
        let mut body = vec![proto::SSH_AGENTC_SIGN_REQUEST];
        proto::put_string(&mut body, blob);
        proto::put_string(&mut body, b"data");
        body.extend_from_slice(&0u32.to_be_bytes());
        self.ask(Message(body)).kind()
    }

    /// What the stub agent actually received, once the filter is done.
    fn upstream_saw(self) -> Vec<u8> {
        drop(self.client);
        let _ = self.filter.join();
        self.upstream_seen.join().unwrap()
    }
}

fn allow(specs: &[&str]) -> Policy {
    Policy::new(specs.iter().map(|s| s.to_string()).collect(), vec![]).unwrap()
}

fn deny(specs: &[&str]) -> Policy {
    Policy::new(vec![], specs.iter().map(|s| s.to_string()).collect()).unwrap()
}

#[test]
fn listing_is_filtered_to_the_allow_list() {
    let mut h = start(allow(&["Github*"]));
    assert_eq!(h.identities(), vec!["Github 1password SSH Key"]);
}

#[test]
fn listing_drops_the_deny_list() {
    let mut h = start(deny(&["Sudo*"]));
    assert_eq!(
        h.identities(),
        vec!["Github 1password SSH Key", "GitLab LRZ SSH Key"]
    );
}

#[test]
fn signing_with_a_permitted_key_reaches_upstream() {
    let mut h = start(allow(&["Github*"]));
    assert_eq!(h.sign_with(b"blob-github"), 14);
    assert!(h.upstream_saw().contains(&proto::SSH_AGENTC_SIGN_REQUEST));
}

#[test]
fn signing_with_a_filtered_key_is_refused() {
    let mut h = start(allow(&["Github*"]));
    assert_eq!(h.sign_with(b"blob-sudo"), proto::SSH_AGENT_FAILURE);
    // Not merely refused to the client - never asked of the agent at all,
    // so a key behind a confirmation prompt does not even flash it up.
    assert!(!h.upstream_saw().contains(&proto::SSH_AGENTC_SIGN_REQUEST));
}

/// The one a well-behaved client never does: sign a blob it already knows,
/// on a fresh connection, without listing first. With no listing there is no
/// blob->comment map, so a comment-based DENY had nothing to match on and
/// let the request through. The filter now resolves the comment from
/// upstream before ruling.
#[test]
fn signing_a_known_blob_without_listing_first_is_still_denied() {
    let mut h = start(deny(&["Sudo*"]));
    assert_eq!(h.sign_with(b"blob-sudo"), proto::SSH_AGENT_FAILURE);
    assert!(!h.upstream_saw().contains(&proto::SSH_AGENTC_SIGN_REQUEST));
}

#[test]
fn the_same_path_still_permits_an_allowed_key() {
    let mut h = start(deny(&["Sudo*"]));
    assert_eq!(h.sign_with(b"blob-github"), 14);
}

#[test]
fn mutating_requests_never_reach_upstream() {
    let mut h = start(allow(&["Github*"]));
    for kind in [17u8, 18, 19, 20, 21, 22, 23, 25, 26] {
        assert_eq!(
            h.ask(Message(vec![kind])).kind(),
            proto::SSH_AGENT_FAILURE,
            "request type {kind} should be refused"
        );
    }
    let seen = h.upstream_saw();
    for kind in [17u8, 18, 19, 20, 21, 22, 23, 25, 26] {
        assert!(!seen.contains(&kind), "type {kind} reached the agent");
    }
}

#[test]
fn extensions_are_refused_by_default() {
    let mut h = start(allow(&["Github*"]));
    let mut body = vec![proto::SSH_AGENTC_EXTENSION];
    proto::put_string(&mut body, b"session-bind@openssh.com");
    assert_eq!(h.ask(Message(body)).kind(), proto::SSH_AGENT_FAILURE);
}

#[test]
fn an_unparseable_identities_answer_fails_closed() {
    // A stub that answers with a key count far beyond what it sends.
    let up = tmp("bad");
    let listener = UnixListener::bind(&up).unwrap();
    let up2 = up.clone();
    thread::spawn(move || {
        let (mut sock, _) = listener.accept().unwrap();
        if Message::read(&mut sock).unwrap().is_some() {
            let mut body = vec![proto::SSH_AGENT_IDENTITIES_ANSWER];
            body.extend_from_slice(&9999u32.to_be_bytes());
            let _ = Message(body).write(&mut sock);
        }
        let _ = up2;
    });
    let (mut client, filter_side) = UnixStream::pair().unwrap();
    let p = allow(&["Github*"]);
    thread::spawn(move || {
        let _ = serve(filter_side, &up, &p, false, false);
    });
    Message(vec![proto::SSH_AGENTC_REQUEST_IDENTITIES])
        .write(&mut client)
        .unwrap();
    let resp = Message::read(&mut client).unwrap().unwrap();
    assert_eq!(resp.kind(), proto::SSH_AGENT_FAILURE);
}

#[test]
fn an_oversized_frame_is_rejected_rather_than_allocated() {
    let (mut client, filter_side) = UnixStream::pair().unwrap();
    let up = tmp("unused");
    let _l = UnixListener::bind(&up).unwrap();
    let p = allow(&["x"]);
    let h = thread::spawn(move || serve(filter_side, &up, &p, false, false));
    client.write_all(&u32::MAX.to_be_bytes()).unwrap();
    drop(client);
    assert!(h.join().unwrap().is_err());
}
