{ config, lib, ... }:
{
  users.mutableUsers = false;
  users.users.${config.primaryUser}.hashedPasswordFile = config.secrets.max-password.path;

  # The primary interactive agent cockpit lives here; frontends include
  # tmux over tailnet SSH and opencode web through Cloudflare Access.
  cockpit.enable = true;

  # Agent-fleet microVM host. Brings up the host-only bridge +
  # egress proxy + microvm.nix runner (see microvm-host.mod.nix).
  agentFleet.enable = true;

  # Matrix alerting (alerts.mod.nix): unit failures and the 6-hourly
  # sweep post to the Ship Alerts room on the local tuwunel as @alertbot.
  alerts.enable = true;
  alerts.credentialsEnvFile = config.secrets.matrix-alertbot-env.path;

  # Fleet ops feed (fleet-log-stream.mod.nix): the agent-fleet audit log
  # streamed line-for-line into a Fleet Ops room, posted by alertbot.
  fleetLogStream.enable = true;
  fleetLogStream.credentialsEnvFile = config.secrets.matrix-alertbot-env.path;
  fleetLogStream.inviteUsers = [ "@dylan:chat.su.is" ];

  # Usage/cost ledger CLI (ship-costs.mod.nix). The OpenRouter section is
  # bootstrap-gated until its read-only management key is provisioned.
  shipCosts.enable = true;
  shipCosts.openrouterKeyFile =
    if builtins.pathExists ./secrets/openrouter-management-key.age then
      config.secrets.openrouter-management-key.path
    else
      null;

  # Plain-language line atop failure alerts, from the ship-local model
  # (free, loopback; degrades to the raw alert if inference is down).
  alerts.summary.enable = true;
  # EcoFlow RIVER 3 Plus over USB HID; probed 2026-07-19 (usbhid-ups, 3746:ffff).
  alerts.ups.enable = true;

  # Declarative Fabric Minecraft server (see minecraft.mod.nix). Tailnet-only
  # and egress-fenced so a compromised server cannot pivot onto the host.
  minecraft.enable = true;

  # Media stack (media.mod.nix): Jellyfin + Sonarr/Radarr/Bazarr/Prowlarr/
  # SABnzbd, tailnet-only and egress-fenced. Tree at /srv/media pending the
  # future RAID array. Provider/indexer accounts wire up in the web UIs.
  media.enable = true;

  # Local inference: llama.cpp (Vulkan) behind llama-swap on :8091,
  # tailnet-only, with models loaded on demand.
  inference.enable = true;
  inference.models."qwen3.6-35b-a3b" = {
    file = "Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf";
    flags = [
      "-c"
      "65536"
      "--flash-attn"
      "on"
      "--jinja"
    ];
    aliases = [ "qwen3.6" ];
  };
  inference.models."gpt-oss-120b" = {
    file = "gpt-oss-120b-mxfp4-00001-of-00003.gguf";
    flags = [
      "-c"
      "131072"
      "--flash-attn"
      "on"
      "--jinja"
    ];
    aliases = [ "gpt-oss" ];
  };
  # Dense small models for judgment-heavy chat (remy). Both ~18-20G UD-Q4_K_XL,
  # so they populate fast; dense (not the 3B-active MoE) = better instruction
  # following and routing. Mistral is remy's brain; Qwen 27B is on the bench
  # for an A/B via remy.model.
  inference.models."mistral-small-3.2-24b" = {
    file = "Mistral-Small-3.2-24B-Instruct-2506-UD-Q4_K_XL.gguf";
    flags = [
      "-c"
      "32768"
      "--flash-attn"
      "on"
      "--jinja"
    ];
    aliases = [
      "mistral"
      "mistral-small"
    ];
  };
  inference.models."qwen3.6-27b" = {
    file = "Qwen3.6-27B-UD-Q4_K_XL.gguf";
    flags = [
      "-c"
      "65536"
      "--flash-attn"
      "on"
      "--jinja"
    ];
    aliases = [ "qwen3.6-dense" ];
  };

  # Syncthing serves the declaratively managed ~/crate/sync mesh.
  services.syncthing.enable = true;

  # Family Matrix homeserver: tuwunel without federation, token-gated
  # registration, exposed at chat.su.is through its own tunnel.
  matrix.enable = true;
  matrix.serverName = "chat.su.is";
  matrix.registrationTokenEnvFile = config.secrets.matrix-registration-env.path;
  matrix.tunnelTokenFile = config.secrets.matrix-cloudflare-tunnel-token.path;

  # Household organizer and budget-room assistant.
  remy.enable = true;
  remy.credentialsEnvFile = config.secrets.matrix-remy-env.path;
  remy.registrationEnvFile = config.secrets.matrix-registration-env.path;
  remy.budgetRoomId = "!pSYRAx0dRdSkbxwgPr:chat.su.is";
  remy.budgetbotEnvFile = config.secrets.matrix-budgetbot-env.path;
  remy.inviteUsers = [
    "@dylan:chat.su.is"
    "@gab:chat.su.is"
  ];
  remy.scratchpad.users = [ "@dylan:chat.su.is" ];
  remy.calendar.credentialsFile = config.secrets.remy-caldav-json.path;
  # A French bot deserves a French model. Mistral Small 3.2 (dense 24B) —
  # sharper instruction following/routing than the qwen a3b MoE. Flip this to
  # "qwen3.6-27b" or "qwen3.6-35b-a3b" to A/B.
  remy.model = "mistral-small-3.2-24b";
  # Mirror the daily log into the Syncthing/Obsidian vault (max:syncthing tree).
  remy.famlog.path = "/home/max/crate/sync/notes/famlog.md";
  remy.famlog.owner = "max";
  remy.famlog.group = "syncthing";

  # News digests post twice daily to the captain's private News room.
  newsbot.enable = true;
  newsbot.credentialsEnvFile = config.secrets.matrix-newsbot-env.path;
  newsbot.registrationEnvFile = config.secrets.matrix-registration-env.path;
  newsbot.claudeTokenFile = config.secrets.agent-claude-token.path;
  newsbot.inviteUsers = [ "@dylan:chat.su.is" ];

  # Curtis, the work-Discord bot: wholesale order lines + staff requests.
  # guildId pins slash-command sync to one server for instant availability
  # (global sync can take Discord up to an hour).
  curtisbot.enable = true;
  curtisbot.credentialsEnvFile = config.secrets.curtisbot-env.path;
  curtisbot.guildId = "916523305362685952";
  # Test server sandbox: same commands, separate test.db.
  curtisbot.testGuildId = "1529484237210910753";

  # opencode web UI cockpit seat, authenticated by Cloudflare Access.
  cockpit.webEnable = true;
  systemd.services.opencode-web.serviceConfig.Environment = [
    "OPENCODE_CONFIG=/home/max/.config/opencode/opencode.jsonc"
  ];
  cockpit.webTunnelTokenFile = config.secrets.opencode-web-cloudflare-tunnel-token.path;

  secrets = {
    max-password.file = ./secrets/max-password.age;
    agent-claude-token.file = ./secrets/agent-claude-token.age;
    agent-codex-auth.file = ./secrets/agent-codex-auth.age;
    agent-openrouter-key.file = ./secrets/agent-openrouter-key.age;
    opencode-web-cloudflare-tunnel-token.file = ./secrets/opencode-web-cloudflare-tunnel-token.age;
    matrix-registration-env.file = ./secrets/matrix-registration.env.age;

    # Retained for remy's adopt-budget-room oneshot.
    matrix-budgetbot-env.file = ./secrets/matrix-budgetbot.env.age;
    matrix-remy-env.file = ./secrets/matrix-remy.env.age;
    matrix-newsbot-env.file = ./secrets/matrix-newsbot.env.age;
    remy-caldav-json = {
      file = ./secrets/remy-caldav.json.age;
      owner = "remy";
    };
    matrix-cloudflare-tunnel-token.file = ./secrets/matrix-cloudflare-tunnel-token.age;
    matrix-alertbot-env.file = ./secrets/matrix-alertbot.env.age;
    curtisbot-env.file = ./secrets/curtisbot.env.age;
  }
  // lib.optionalAttrs (builtins.pathExists ./secrets/openrouter-management-key.age) {
    openrouter-management-key = {
      file = ./secrets/openrouter-management-key.age;
      owner = config.primaryUser;
    };
  };

  # agenix in this input has no restartUnits option; make the encrypted
  # source an explicit unit trigger so token rotation restarts cloudflared.
  systemd.services.opencode-web-tunnel.restartTriggers = [
    ./secrets/opencode-web-cloudflare-tunnel-token.age
  ];
  systemd.services.matrix-tunnel.restartTriggers = [
    ./secrets/matrix-cloudflare-tunnel-token.age
  ];

  agentFleet.credentials = {
    claudeTokenFile = config.secrets.agent-claude-token.path;
    codexAuthFile = config.secrets.agent-codex-auth.path;
    openrouterKeyFile = config.secrets.agent-openrouter-key.path;
  };

  # Keep more workers than typical demand so incoming tasks get an already
  # warm VM instead of waiting for boot. Fleet-wide resources are slice-capped.
  agentFleet.workers = lib.lists.imap1 (index: name: { inherit name index; }) [
    "astrapia"
    "cicinnurus"
    "drepanornis"
    "epimachus"
    "lophorina"
    "manucodia"
    "paradisaea"
    "seleucidis"
  ];
}
