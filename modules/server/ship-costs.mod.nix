# ship-costs — the ledger. Answers "what would this month's AI usage have
# cost at API rates?" across every pool the ship spends from:
#
#   claude      cockpit Claude Code transcripts (~/.claude/projects) +
#               fleet drone usage.json archives (tasks/done|failed)
#   chatgpt     cockpit codex sessions (~/.codex/sessions) + opencode
#               messages with providerID=openai + codex drones
#   openrouter  exact spend via the API when a key is wired (metered pool);
#               otherwise whatever opencode recorded per message
#   local       llama-swap models — counted, priced $0
#
# Token counts are real (recorded by each tool); the USD figures are
# API-EQUIVALENT — what identical usage would bill at pay-per-token rates.
# Subscriptions bill flat, so this is an opportunity-cost lens, not an
# invoice. Scope: only what ran on this ship. claude.ai / chatgpt.com app
# chats leave no local artifacts and are invisible here (the Claude plan's
# limit gauge in-app includes them; nothing exposes their tokens).
#
# PRICING TABLE (in ship-costs-cli/src/main.rs, $/MTok) — update when vendors reprice:
# verified 2026-07-12: Fable 10/50, Opus 5/25, Sonnet 3/15, Haiku 1/5
# (cache read 0.1x input, cache write 1.25x/5m 2x/1h); GPT-5.6 Sol and
# GPT-5.5 5/30 (cached in 0.5), Terra 2.5/15, Luna 1/6.
#
# No plan-usage gauges here: the on-disk estimates (codex rate-limit
# snapshots, transcript-derived percentages) proved unreliable — captain
# removed them 2026-07-14. Check /usage in each app for real gauges.
{
  flake.nixosModules.ship-costs =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib.strings) hasSuffix;
      inherit (lib) types;

      cfg = config.shipCosts;

      # Configuration and helper-binary paths are baked in at build time
      # (option_env!); the key file value is a runtime path string, never a
      # nix path literal (see the option's warning below).
      shipCosts = pkgs.rustPlatform.buildRustPackage {
        pname = "ship-costs";
        version = "0.1.0";
        src = lib.sources.cleanSourceWith {
          src = ./ship-costs/ship-costs-cli;
          filter = path: type: type != "directory" || !hasSuffix "/target" (toString path);
        };
        cargoLock.lockFile = ./ship-costs/ship-costs-cli/Cargo.lock;
        env = {
          SHIP_OPENROUTER_KEY_FILE =
            if cfg.openrouterKeyFile != null then cfg.openrouterKeyFile else "";
          SHIP_SQLITE3 = "${pkgs.sqlite.bin}/bin/sqlite3";
          SHIP_CURL = "${pkgs.curl}/bin/curl";
        };
        meta.mainProgram = "ship-costs";
      };
    in
    {
      options.shipCosts = {
        enable = mkEnableOption "the ship-costs usage/cost ledger CLI";

        openrouterKeyFile = mkOption {
          # types.str, NOT types.path: interpolating a path literal would
          # copy the key into the world-readable Nix store. Only runtime
          # paths (/run/agenix/...) belong here.
          type = types.nullOr types.str;
          default = null;
          description = ''
            Runtime path (e.g. /run/agenix/...) to a file containing an
            OpenRouter key (a management key from Settings → Management
            Keys is preferred; read-only, free) for exact per-model spend
            via the activity API. Must be readable by whoever runs
            ship-costs; never a Nix path literal. null = skip the section.
          '';
        };
      };

      config = mkIf cfg.enable {
        environment.systemPackages = [ shipCosts ];
      };
    };
}
