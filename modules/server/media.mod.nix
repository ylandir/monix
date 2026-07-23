# Media stack aspect — Jellyfin plus the Usenet automation chain (Sonarr,
# Radarr, Bazarr, Prowlarr, SABnzbd), reachable over the tailnet and nowhere
# else. Inert until a host sets `media.enable`; imported on every host, so
# gated explicitly (same pattern as minecraft.mod.nix).
#
# PHILOSOPHY / THREAT MODEL. Six long-running network services that parse
# untrusted remote content (NNTP articles, indexer API responses, media
# containers, subtitle files). We assume any one of them can be compromised
# and make that lead nowhere:
#   - Reachability: every web UI has openFirewall = false. fw0 opens zero
#     public inbound ports; tailscale0 is the sole trusted interface, so the
#     UIs (and Jellyfin playback) are reached by being on the tailnet.
#   - Anti-pivot egress fence: the stack legitimately needs loopback (the
#     services talk to each other on 127.0.0.1) and the public internet
#     (Usenet provider over NNTPS, indexers, metadata databases, subtitle
#     providers) — but must NOT reach the home LAN or the agent-fleet microVM
#     bridge. A shared systemd IP allow/deny fence enforces exactly that.
#   - Blast radius: each service runs unprivileged under its own upstream
#     user; the shared `media` group is the only cross-service surface, and
#     it grants access to the media tree alone.
#
# STORAGE. One tree, one filesystem: MEDIAROOT below. Downloads and library
# live on the same filesystem ON PURPOSE — the *arr import step is then a
# hardlink (instant, no double disk). The services only ever see the path, so
# the planned move to a dedicated RAID array is: build array, copy tree,
# mount it at MEDIAROOT, done — no service config changes.
#
# App-level wiring (Prowlarr↔*arr connections, quality profiles, provider
# credentials, download dirs) is one-time state in each app's web UI, not Nix:
# upstream keeps that state in per-service SQLite/ini under /var/lib. The
# module's job is users, dirs, reachability, and the fence.
{
  flake.nixosModules.media =
    {
      config,
      lib,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
      inherit (lib.options) mkEnableOption;

      cfg = config.media;
      networkFences = import ../../lib/network-fences.nix;

      # THE MEDIA TREE. downloads/ is SABnzbd's (incomplete + complete);
      # library/ is *arr-managed and what Jellyfin reads. Same filesystem =
      # hardlink imports (see STORAGE above).
      mediaRoot = "/srv/media";

      # Shared egress fence for the whole stack. systemd checks IPAddressAllow
      # BEFORE IPAddressDeny; anything matched by neither is ALLOWED. So:
      # allow the tailnet (UI/playback reachability) and loopback (the
      # services interconnect on 127.0.0.1, and DNS goes through the
      # systemd-resolved stub on 127.0.0.53), deny every private/link-local
      # range (home LAN, agent-fleet bridge 10.100.0.0/24 — inside
      # 10.0.0.0/8), and let the public internet (provider, indexers,
      # metadata, subtitles) fall through as allowed.
      egressFence = {
        Slice = "services.slice";
        IPAddressAllow = [
          "100.64.0.0/10" # tailnet (CGNAT range)
          "127.0.0.0/8" # loopback: inter-service APIs + resolved stub
          "::1"
        ];
        IPAddressDeny = networkFences.privateRanges;
      };
    in
    {
      options.media.enable = mkEnableOption "the tailnet-only Jellyfin + Usenet automation media stack";

      config = mkIf cfg.enable {
        # THE SHARED GROUP. Every service that touches the media tree runs
        # with `media` as its primary group, so imports/rips/subtitles land
        # group-owned and every other member can read them. Prowlarr is
        # deliberately absent: it only brokers indexer searches and never
        # touches media files.
        users.groups.media = { };

        # THE MEDIA TREE. Setgid (2…) so everything created inside inherits
        # the media group; group-writable so any member service can import.
        # `d` rules create-if-missing and never touch existing content —
        # safe across the future RAID re-mount.
        systemd.tmpfiles.rules = [
          "d ${mediaRoot} 2775 root media -"
          "d ${mediaRoot}/downloads 2775 sabnzbd media -"
          "d ${mediaRoot}/downloads/incomplete 2775 sabnzbd media -"
          "d ${mediaRoot}/downloads/complete 2775 sabnzbd media -"
          "d ${mediaRoot}/library 2775 root media -"
          "d ${mediaRoot}/library/movies 2775 root media -"
          "d ${mediaRoot}/library/tv 2775 root media -"
        ];

        # --- The librarians: decide WHAT to fetch, manage the library ---
        services.sonarr = {
          enable = true;
          group = "media";
          openFirewall = false; # tailnet-only (UI on :8989)
        };
        services.radarr = {
          enable = true;
          group = "media";
          openFirewall = false; # tailnet-only (UI on :7878)
        };

        # Subtitles: watches Sonarr/Radarr libraries, fetches matching subs.
        services.bazarr = {
          enable = true;
          group = "media";
          openFirewall = false; # tailnet-only (UI on :6767)
        };

        # Indexer broker: holds the indexer accounts, fans searches out to
        # them, returns scored candidates to the *arrs (Newznab API).
        services.prowlarr = {
          enable = true;
          openFirewall = false; # tailnet-only (UI on :9696)
        };

        # --- The downloader: NNTP fetch, par2 repair, unpack ---
        services.sabnzbd = {
          enable = true;
          group = "media";
          openFirewall = false; # tailnet-only (UI on :8080)
        };

        # --- Playback ---
        services.jellyfin = {
          enable = true;
          group = "media";
          openFirewall = false; # tailnet-only (web/API on :8096)
        };
        # Hardware transcode (VAAPI) on the Strix Halo iGPU. Mesa is already
        # live on fw0 (Vulkan inference); Jellyfin just needs the device
        # nodes. Selected inside Jellyfin: Dashboard → Playback → VAAPI,
        # /dev/dri/renderD128.
        users.users.jellyfin.extraGroups = [
          "render"
          "video"
        ];

        # HARDENING — the fence (see header) on every unit in the stack.
        # Prowlarr runs with DynamicUser and no media access; it still gets
        # the fence (it talks only to indexers + the *arrs on loopback).
        systemd.services.sonarr.serviceConfig = egressFence;
        systemd.services.radarr.serviceConfig = egressFence;
        systemd.services.bazarr.serviceConfig = egressFence;
        systemd.services.prowlarr.serviceConfig = egressFence;
        systemd.services.sabnzbd.serviceConfig = egressFence;
        systemd.services.jellyfin.serviceConfig = egressFence;
      };
    };
}
