# Editors. Neovim is NvChad via nix4nvchad's home-manager module: the starter
# config is provisioned declaratively, and runtime tools (compiler, lazygit,
# future LSP servers) are injected into the nvim wrapper only — not the global
# PATH. Plain pkgs.neovim must NOT be installed alongside it (the wrapper
# collides); packages-editors carries only helix and vim.
#
# Both editors pin 'shell' to /bin/sh: nushell is the login shell, and the
# editors' POSIX `-c` shell-outs die under it ("E79: Cannot expand wildcards").
{ inputs, ... }:
{
  flake.homeModules.editors =
    { pkgs, ... }:
    {
      imports = [ inputs.nix4nvchad.homeManagerModules.default ];

      programs.nvchad = {
        enable = true;

        # LSP servers/formatters go here as they're adopted (e.g. nil,
        # lua-language-server) — visible only inside the nvim wrapper.
        extraPackages = [
          pkgs.lazygit
        ];

        extraConfig = ''
          vim.o.shell = "/bin/sh"
        '';
      };

      home.file.".vimrc".text = ''
        set shell=/bin/sh
      '';
    };
}
