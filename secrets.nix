# agenix rules. Read by the `agenix`/`ragenix` CLI (NOT imported by the flake).
#
# Each entry maps a secret file path (relative to the repo root) to the set of
# public keys it is encrypted to. A host's secrets are encrypted to that host's
# key plus every admin key, so an admin can always rekey them.
#
# To create or edit a secret:    agenix -e hosts/fw0/secrets/litellm.env.age
# To rekey everything after a
# key change:                    agenix -r
#
# Add a line here for every new secret before creating it.
let
  keys = import ./keys.nix;

  inherit (keys) admin;
  inherit (keys.hosts) fw0 fw3;
in
{
  "hosts/fw3/dylan-password.age".publicKeys = [ fw3 ] ++ admin;

  # Comic Code (paid font; see modules/desktop/fonts.mod.nix). Encrypted to
  # every desktop host that should ship it — rekey (`agenix -r`) after adding
  # a host here.
  "assets/fonts/comic-code.age".publicKeys = [ fw3 ] ++ admin;

  "hosts/fw0/secrets/max-password.age".publicKeys = [ fw0 ] ++ admin;
  # Retained bootstrap key; fw0 is already enrolled and does not consume it at runtime.
  "hosts/fw0/secrets/tailscale.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/agent-claude-token.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/agent-codex-auth.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/agent-openrouter-key.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/openrouter-management-key.age".publicKeys = [ fw0 ] ++ admin;
  # Reserved app-local password; current web cockpit uses Cloudflare Access only.
  "hosts/fw0/secrets/opencode-web-env.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/opencode-web-cloudflare-tunnel-token.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/matrix-registration.env.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/matrix-cloudflare-tunnel-token.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/matrix-budgetbot.env.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/matrix-remy.env.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/matrix-newsbot.env.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/remy-caldav.json.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/matrix-alertbot.env.age".publicKeys = [ fw0 ] ++ admin;
  # Discord bot token for Curtis, the work orders/requests bot (DISCORD_TOKEN=...).
  "hosts/fw0/secrets/curtisbot.env.age".publicKeys = [ fw0 ] ++ admin;
  # Reserved for the currently disabled LiteLLM/Open WebUI modules.
  "hosts/fw0/secrets/litellm.env.age".publicKeys = [ fw0 ] ++ admin;
  "hosts/fw0/secrets/open-webui.env.age".publicKeys = [ fw0 ] ++ admin;
}
