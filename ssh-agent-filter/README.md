# ssh-agent-filter

A filtering proxy for the SSH agent protocol. It listens on a unix socket,
forwards to an upstream agent, and applies a policy in between:

- **Key policy.** `--allow` (whitelist) or `--deny` (blacklist), matched
  against a key's SHA256 fingerprint or its comment (globs allowed in
  comments). Filtered keys are removed from `REQUEST_IDENTITIES` answers and
  refused for `SIGN_REQUEST`, so a client cannot use — or even see — them.
- **Read-only.** Everything that would *change* the upstream agent is refused
  outright: adding or removing identities, smartcard keys, locking and
  unlocking. A restricted client must not be able to lock the agent of the
  user it borrows keys from, and never needs to add one.
- **Extensions** are refused by default (their semantics are unknown to the
  filter, so they cannot be policed); `--allow-extensions` opts in.

The point is that the proxy runs **outside** whatever it is protecting the
agent from — for nix-dev-container, on the host, so a container only ever
sees the filtered socket.
