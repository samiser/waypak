# waypak

sandbox apps on nixos, enforced by the wayland compositor via
[security-context-v1](https://wayland.app/protocols/security-context-v1)

wrapped packages keep their names and desktop entries, so launching them
normally runs them sandboxed:

- the compositor withholds privileged wayland protocols (capture, window
  enumeration, input injection, ...)
- dbus goes through xdg-dbus-proxy with a per-app allowlist; apps allowed to
  talk to the portal get host file pickers and open links in the host browser
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
  vesktop = {
    package = pkgs.vesktop;
    binds = [ "$HOME/Downloads" ];
    roBinds = [ "$HOME/Pictures" ];
  };
};
```

dbus policies (`talk`/`own`) default from `profiles/` by app name, as do
`commands` — extra entrypoints run inside the app's sandbox (e.g. clipse ships
a `clipse-listener` bin for clipboard watching). PRs welcome!

`waypak.profiles` swaps or extends the bundled set (`{ }` to opt out entirely)

profiles can also be generated from a flatpak manifest's `finish-args`
(json manifests only):

```nix
waypak.profiles = waypak.policies // {
  spotify = waypak.lib.fromFlatpakManifest ./com.spotify.Client.json;
};
```

`waypak.wrappedPackages.<name>` exposes each sandboxed wrapper for handing to
other modules (e.g. `programs.<x>.package`); the original package stays
reachable as `passthru.unwrapped`

ad-hoc:

```bash
waypak -s some-app        # sandbox with default policy
waypak -a spotify -s cmd  # sandbox with spotify's policy
waypak wayland-info       # security context only, no bwrap
```

## hardening

- every sandbox gets a default seccomp filter (flatpak's baseline: tty ioctl
  keystroke injection, ptrace, kernel keyring, mount family); `seccomp = false`
  drops it, `userns = false` additionally denies nested user namespaces
  (electron/chromium apps need them for their own sandbox, most others don't)
- `net = "isolated"` gives the app a private network namespace with internet
  via [pasta](https://passt.top/): localhost services and abstract sockets
  (including X11) are unreachable
- `storeClosure = true` binds only the app's closure instead of all of /nix
  and /run/current-system

## goals

- sandboxing that fits how nixos already works: wrap the package, keep the
  name and desktop entry, configure everything from the module
- the whole runtime is one generated shell script, so `cat $(which waypak)`
  shows you exactly what a sandbox does
- each layer does one job: the compositor decides what an app can show, the
  dbus proxy what it can say, bwrap what it can see, seccomp what it can call
- any option can be switched off and you get exactly the behaviour from
  before it existed

## non-goals

- x11: there's no security boundary to enforce there, so wayland only
- deciding what an app is allowed to *execute*: that's an lsm's job, so it
  lives in [closured](https://github.com/samiser/closured) instead
- daemons: sandboxing works with nothing else running, anything that needs a
  service stays optional
- shipping a profile for everything: the bundled set is a starter, generate
  the rest from flatpak manifests

## caveats

- network is shared by default (`net = false` to unshare, `net = "isolated"`
  for pasta), gpu and audio are opt-in per app, /etc is cherry-picked (not
  bound directly)
- no document portal yet: file pickers show host files but only bound paths work
  inside
- protects against sloppy apps and their plugin/content ecosystems, not targeted
  malware

built on [way-secure](https://git.sr.ht/~whynothugo/way-secure) (vendored until
it lands in nixpkgs), prior art in [nixpak](https://github.com/nixpak/nixpak)
