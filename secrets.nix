# agenix rules. Read by the `agenix`/`ragenix` CLI (NOT imported by the flake).
#
# Each entry maps a secret file path (relative to the repo root) to the set of
# public keys it is encrypted to. A host's secrets are encrypted to that host's
# key plus every admin key, so an admin can always rekey them.
#
# To create or edit a secret:    agenix -e hosts/fw0/litellm.env.age
# To rekey everything after a
# key change:                    agenix -r
#
# Add a line here for every new secret before creating it.
let
  keys = import ./keys.nix;

  inherit (keys) admin;
  inherit (keys.hosts) fw0;
in
{
  "hosts/fw0/tailscale.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/agent-claude-token.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/agent-codex-auth.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/agent-openrouter-key.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/opencode-web-env.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/opencode-web-cloudflare-tunnel-token.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/actual-cloudflare-tunnel-token.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/matrix-registration.env.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/matrix-cloudflare-tunnel-token.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/matrix-budgetbot.env.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/litellm.env.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/open-webui.env.age".publicKeys = [ fw0 ] ++ admin;
}
