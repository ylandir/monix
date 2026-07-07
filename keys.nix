# SSH public keys used both for `agenix` secret encryption and for SSH access.
# Replace every placeholder below with real keys BEFORE deploying or creating secrets.
#
#   Host keys  - on each machine run `cat /etc/ssh/ssh_host_ed25519_key.pub`.
#                On a brand-new machine, generate them first with `ssh-keygen -A`.
#   Admin keys - your personal public key(s), e.g. `cat ~/.ssh/id_ed25519.pub`.
#
# This file is the single source of truth for keys: it is imported both by
# `secrets.nix` (consumed by the agenix CLI) and by `modules/keys.mod.nix`
# (which exposes the keys as flake outputs `keys` and `keys-admin`).
{
  hosts = {
    fw0 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHhyRG7/WM9uuYwv42V24pzhqfnfcdlHROdR75vZWzoK fw0";
    fw3 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAREPLACE_WITH_FW3_HOST_KEY fw3";
  };

  admin = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF7/0+EtR35ZsgmHq0IXNY5gQ1SlTUGSRz+P38qGfn0F dylan@dylandavid.com"
  ];
}
