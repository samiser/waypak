# waypak

sandbox apps on nixos, enforced by the wayland compositor via
[security-context-v1](https://wayland.app/protocols/security-context-v1)

wrapped packages keep their names and desktop entries, so launching them
normally runs them sandboxed:

- the compositor withholds privileged wayland protocols (capture, window
  enumeration, input injection, ...)
- dbus goes through xdg-dbus-proxy with a per-app allowlist, portals still work
- bwrap gives each app a private persistent home plus whatever paths you bind

## requirements

a compositor implementing security-context-v1, like
[umbriel](https://github.com/noctalia-dev/umbriel)

## usage

```nix
imports = [ waypak.nixosModules.default ];

waypak.apps = {
  spotify.package = pkgs.spotify;
  obsidian = {
    package = pkgs.obsidian;
    binds = [ "$HOME/notes" ];
  };
};
```

dbus policies (`talk`/`own`) default from `profiles/` by app name. PRs welcome!
`waypak.profiles` swaps or extends the bundled set (`{ }` to opt out entirely)

ad-hoc:

```bash
waypak -s some-app        # sandbox with default policy
waypak -a spotify -s cmd  # sandbox with spotify's policy
waypak wayland-info       # security context only, no bwrap
```

## caveats

- network is shared by default (`net = false` to unshare); gpu and audio are
  opt-in per app; /etc is cherry-picked, not bound wholesale
- no document portal yet: file pickers show host files but only bound paths work
  inside
- protects against sloppy apps and their plugin/content ecosystems, not targeted
  malware

built on [way-secure](https://git.sr.ht/~whynothugo/way-secure) (vendored until
it lands in nixpkgs), prior art in [nixpak](https://github.com/nixpak/nixpak)
