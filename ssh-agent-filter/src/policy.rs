//! Which keys a client may see and use.
//!
//! A key is named the way `ssh-add -l` names it: by SHA256 fingerprint, or
//! by its comment. Both are accepted so a policy can be written either
//! precisely (a fingerprint pins one key forever) or legibly (a comment
//! reads like the label in the agent, at the cost of the owner being able
//! to rename it).

/// SHA-256. Implemented here rather than pulled in so the crate builds from
/// one dependency: the digest is 60 lines of a fully specified algorithm,
/// and `fingerprint_matches_ssh_add` checks it against what OpenSSH prints.
fn sha256(data: &[u8]) -> [u8; 32] {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];

    let mut msg = data.to_vec();
    let bits = (data.len() as u64) * 8;
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bits.to_be_bytes());

    for chunk in msg.chunks_exact(64) {
        let mut w = [0u32; 64];
        for (i, word) in chunk.chunks_exact(4).enumerate() {
            w[i] = u32::from_be_bytes(word.try_into().unwrap());
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let (mut a, mut b, mut c, mut d) = (h[0], h[1], h[2], h[3]);
        let (mut e, mut f, mut g, mut hh) = (h[4], h[5], h[6], h[7]);
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (i, v) in [a, b, c, d, e, f, g, hh].into_iter().enumerate() {
            h[i] = h[i].wrapping_add(v);
        }
    }

    let mut out = [0u8; 32];
    for (i, v) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&v.to_be_bytes());
    }
    out
}

/// Standard base64, unpadded - the form OpenSSH prints after `SHA256:`.
fn base64_nopad(data: &[u8]) -> String {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for c in data.chunks(3) {
        let b = [c[0], *c.get(1).unwrap_or(&0), *c.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        let take = c.len() + 1;
        for i in 0..take {
            out.push(A[((n >> (18 - 6 * i)) & 0x3f) as usize] as char);
        }
    }
    out
}

/// `SHA256:...`, exactly as `ssh-add -l` reports it.
pub fn fingerprint(blob: &[u8]) -> String {
    format!("SHA256:{}", base64_nopad(&sha256(blob)))
}

/// `*` matches any run, including empty. No other metacharacters, so a
/// comment containing regex punctuation cannot surprise anyone.
fn glob(pattern: &str, text: &str) -> bool {
    let mut parts = pattern.split('*');
    let first = parts.next().unwrap_or("");
    if !text.starts_with(first) {
        return false;
    }
    let mut rest = &text[first.len()..];
    let mut last: Option<&str> = None;
    for part in parts {
        last = Some(part);
        if part.is_empty() {
            continue;
        }
        match rest.find(part) {
            Some(i) => rest = &rest[i + part.len()..],
            None => return false,
        }
    }
    // A pattern with no `*` must match the whole string; one ending in `*`
    // may leave a tail.
    match last {
        None => rest.is_empty(),
        Some(p) if !p.is_empty() => rest.is_empty() || pattern.ends_with('*'),
        Some(_) => true,
    }
}

#[derive(Clone, Copy, PartialEq)]
pub enum Mode {
    /// No list given: every key passes (mutating requests are still refused).
    PassAll,
    Allow,
    Deny,
}

pub struct Policy {
    pub mode: Mode,
    pub specs: Vec<String>,
}

impl Policy {
    pub fn new(allow: Vec<String>, deny: Vec<String>) -> Result<Policy, String> {
        match (allow.is_empty(), deny.is_empty()) {
            (true, true) => Ok(Policy { mode: Mode::PassAll, specs: vec![] }),
            (false, true) => Ok(Policy { mode: Mode::Allow, specs: allow }),
            (true, false) => Ok(Policy { mode: Mode::Deny, specs: deny }),
            // Refused rather than resolved by precedence: with both lists the
            // reader cannot tell whether an unlisted key is permitted, and
            // guessing wrong about an ssh key is not a small mistake.
            (false, false) => Err("--allow and --deny are mutually exclusive".into()),
        }
    }

    fn matches(&self, blob: &[u8], comment: &[u8]) -> bool {
        let fp = fingerprint(blob);
        let comment = String::from_utf8_lossy(comment);
        self.specs.iter().any(|s| {
            let s = s.as_str();
            s == fp
                || format!("SHA256:{s}") == fp
                || (s.contains('*') && glob(s, &comment))
                || s == comment
        })
    }

    /// May the client see and use this key?
    pub fn permits(&self, blob: &[u8], comment: &[u8]) -> bool {
        match self.mode {
            Mode::PassAll => true,
            Mode::Allow => self.matches(blob, comment),
            Mode::Deny => !self.matches(blob, comment),
        }
    }

    /// A SIGN_REQUEST names a key by blob only - no comment travels with it.
    /// Comment-based specs therefore need the comment looked up from the
    /// identity list; `known` is that mapping, refreshed on every
    /// REQUEST_IDENTITIES. A blob we have never seen listed gets an empty
    /// comment, which is what makes an allow-list fail closed here.
    pub fn permits_blob(&self, blob: &[u8], known: &[(Vec<u8>, Vec<u8>)]) -> bool {
        let comment = known
            .iter()
            .find(|(b, _)| b == blob)
            .map(|(_, c)| c.clone())
            .unwrap_or_default();
        self.permits(blob, &comment)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_known_vectors() {
        assert_eq!(
            base64_nopad(&sha256(b"")),
            "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU"
        );
        assert_eq!(
            base64_nopad(&sha256(b"abc")),
            "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0"
        );
        // Crosses the 55/56-byte padding boundary, i.e. forces a second block.
        assert_eq!(
            base64_nopad(&sha256(
                b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
            )),
            "JI1qYdIGOLjlwCaTDD5gOaM85Flk/yFn9uzt1BnbBsE"
        );
    }

    #[test]
    fn base64_pads_by_length() {
        assert_eq!(base64_nopad(b"a"), "YQ");
        assert_eq!(base64_nopad(b"ab"), "YWI");
        assert_eq!(base64_nopad(b"abc"), "YWJj");
    }

    #[test]
    fn globs() {
        assert!(glob("Github*", "Github 1password SSH Key"));
        assert!(glob("*SSH Key", "Github 1password SSH Key"));
        assert!(glob("*1password*", "Github 1password SSH Key"));
        assert!(glob("exact", "exact"));
        assert!(!glob("exact", "exact tail"));
        assert!(!glob("Gitlab*", "Github 1password SSH Key"));
    }

    #[test]
    fn allow_list_hides_everything_else() {
        let p = Policy::new(vec!["wanted".into()], vec![]).unwrap();
        assert!(p.permits(b"blob-a", b"wanted"));
        assert!(!p.permits(b"blob-b", b"other"));
    }

    #[test]
    fn deny_list_hides_only_matches() {
        let p = Policy::new(vec![], vec!["banned".into()]).unwrap();
        assert!(!p.permits(b"blob-a", b"banned"));
        assert!(p.permits(b"blob-b", b"other"));
    }

    #[test]
    fn both_lists_is_an_error() {
        assert!(Policy::new(vec!["a".into()], vec!["b".into()]).is_err());
    }

    #[test]
    fn sign_for_an_unlisted_blob_fails_closed_under_allow() {
        let p = Policy::new(vec!["wanted".into()], vec![]).unwrap();
        // Never seen in an identity answer, so it has no comment to match.
        assert!(!p.permits_blob(b"blob-x", &[]));
        let known = vec![(b"blob-x".to_vec(), b"wanted".to_vec())];
        assert!(p.permits_blob(b"blob-x", &known));
    }

    #[test]
    fn fingerprint_spec_matches_with_or_without_prefix() {
        let fp = fingerprint(b"blob");
        let bare = fp.strip_prefix("SHA256:").unwrap().to_string();
        assert!(Policy::new(vec![fp.clone()], vec![])
            .unwrap()
            .permits(b"blob", b""));
        assert!(Policy::new(vec![bare], vec![])
            .unwrap()
            .permits(b"blob", b""));
    }
}
