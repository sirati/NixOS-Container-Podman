# ssh-agent-filter

A filtering proxy for the SSH agent protocol. It listens on a unix socket,
forwards requests to an upstream agent and applies a policy in between.

- **Key policy.** `--allow` (allow list) or `--deny` (deny list) matches a key's
  SHA256 fingerprint or its comment, with globs allowed in comments. Filtered
  keys are left out of `REQUEST_IDENTITIES` answers and refused for
  `SIGN_REQUEST`, so a client can neither see nor use them.
- **Read-only.** Every request that changes the upstream agent is refused:
  adding or removing identities, smartcard keys, locking and unlocking. A client
  using the filter cannot lock the user's agent or add keys to it.
- **Extensions.** They are refused by default because the filter cannot know
  what they do. `--allow-extensions` allows them.

nix-dev-container runs the proxy on the host and gives a container only the
filtered socket.
