//! SSH agent wire format, and just enough of the message set to police it.
//!
//! Framing is uniform: a big-endian u32 length, then that many bytes, of
//! which the first is the message type. Inside a payload, a "string" is
//! itself a length-prefixed byte run - not text, and not NUL-terminated.

use std::io::{self, Read, Write};

// Client -> agent.
pub const SSH_AGENTC_REQUEST_IDENTITIES: u8 = 11;
pub const SSH_AGENTC_SIGN_REQUEST: u8 = 13;

// Agent -> client.
pub const SSH_AGENT_FAILURE: u8 = 5;
pub const SSH_AGENT_IDENTITIES_ANSWER: u8 = 12;

/// Every request that mutates the upstream agent or its availability.
///
/// All refused, always. A borrowed agent is someone else's: a client that
/// may use a key still has no business adding one, dropping one, or taking
/// the whole agent offline with a lock - which would be a denial of service
/// against the owner, from inside a sandbox that is supposed to be contained.
pub fn is_mutating(kind: u8) -> bool {
    matches!(
        kind,
        17 | 25 // ADD_IDENTITY, ADD_ID_CONSTRAINED
        | 18 | 19 // REMOVE_IDENTITY, REMOVE_ALL_IDENTITIES
        | 20 | 21 | 26 // ADD/REMOVE_SMARTCARD_KEY, ADD_SMARTCARD_KEY_CONSTRAINED
        | 22 | 23 // LOCK, UNLOCK
    )
}

pub const SSH_AGENTC_EXTENSION: u8 = 27;

/// A whole message, without its length prefix: `body[0]` is the type.
pub struct Message(pub Vec<u8>);

impl Message {
    pub fn kind(&self) -> u8 {
        // A zero-length message has no type byte. Report it as a type that
        // is neither known nor mutating; the caller refuses it either way.
        self.0.first().copied().unwrap_or(0)
    }

    pub fn payload(&self) -> &[u8] {
        self.0.get(1..).unwrap_or(&[])
    }

    pub fn failure() -> Message {
        Message(vec![SSH_AGENT_FAILURE])
    }

    pub fn read(r: &mut impl Read) -> io::Result<Option<Message>> {
        let mut len = [0u8; 4];
        match r.read_exact(&mut len) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
            Err(e) => return Err(e),
        }
        let len = u32::from_be_bytes(len) as usize;
        // The agent protocol caps a message at 256 KiB. Refusing anything
        // larger keeps a hostile client from asking us to allocate freely.
        if len == 0 || len > 256 * 1024 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("implausible agent message length {len}"),
            ));
        }
        let mut body = vec![0u8; len];
        r.read_exact(&mut body)?;
        Ok(Some(Message(body)))
    }

    pub fn write(&self, w: &mut impl Write) -> io::Result<()> {
        w.write_all(&(self.0.len() as u32).to_be_bytes())?;
        w.write_all(&self.0)?;
        w.flush()
    }
}

/// Cursor over a message payload.
pub struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        Reader { buf, pos: 0 }
    }

    pub fn u32(&mut self) -> Option<u32> {
        let end = self.pos.checked_add(4)?;
        let v = u32::from_be_bytes(self.buf.get(self.pos..end)?.try_into().ok()?);
        self.pos = end;
        Some(v)
    }

    pub fn string(&mut self) -> Option<&'a [u8]> {
        let n = self.u32()? as usize;
        let end = self.pos.checked_add(n)?;
        let s = self.buf.get(self.pos..end)?;
        self.pos = end;
        Some(s)
    }
}

pub fn put_string(out: &mut Vec<u8>, s: &[u8]) {
    out.extend_from_slice(&(s.len() as u32).to_be_bytes());
    out.extend_from_slice(s);
}

/// One entry of an IDENTITIES_ANSWER.
pub struct Identity {
    pub blob: Vec<u8>,
    pub comment: Vec<u8>,
}

/// Parse an IDENTITIES_ANSWER payload.
///
/// `None` means the answer did not parse, and the caller must then fail
/// closed rather than pass it through: an answer we cannot read is one we
/// cannot filter, and forwarding it would leak exactly the keys the policy
/// exists to hide.
pub fn parse_identities(payload: &[u8]) -> Option<Vec<Identity>> {
    let mut r = Reader::new(payload);
    let n = r.u32()? as usize;
    // Bound the count against the bytes left: 8 is the smallest an entry can
    // be (two empty strings), so a huge count in a short message is a lie.
    if n > payload.len() / 8 + 1 {
        return None;
    }
    let mut out = Vec::with_capacity(n);
    for _ in 0..n {
        let blob = r.string()?.to_vec();
        let comment = r.string()?.to_vec();
        out.push(Identity { blob, comment });
    }
    Some(out)
}

pub fn build_identities(ids: &[&Identity]) -> Message {
    let mut body = vec![SSH_AGENT_IDENTITIES_ANSWER];
    body.extend_from_slice(&(ids.len() as u32).to_be_bytes());
    for id in ids {
        put_string(&mut body, &id.blob);
        put_string(&mut body, &id.comment);
    }
    Message(body)
}

/// The key blob a SIGN_REQUEST is asking to sign with.
pub fn sign_request_key(payload: &[u8]) -> Option<&[u8]> {
    Reader::new(payload).string()
}
