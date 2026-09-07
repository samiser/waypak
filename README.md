# waypak

sandbox apps on nixos, enforced by the wayland compositor via
[security-context-v1](https://wayland.app/protocols/security-context-v1)

wrapped packages keep their names and desktop entries, so launching them
normally runs them sandboxed:

- the compositor withholds privileged wayland protocols via the security context
- apps can be allowed to talk to dbus (including portals) via xdg-dbus-proxy
- bwrap gives each app a private persistent home plus whatever paths you bind

## requirements

any compositor implementing
[security-context-v1](https://wayland.app/protocols/security-context-v1)
enforces the core boundary: wlroots-based ones like sway and kwin withhold their
privileged protocols from a tagged client.

what these hardcode is the privileged set, with no way to hand a specific
protocol back to a specific app. `waylandGlobals` can be used for granular
capability permissioning on compositors that match on the security context,
currently [umbriel](https://github.com/noctalia-dev/umbriel) or
[jay](https://github.com/mahkoh/jay) (whose client rules match on
`sandbox-app-id`/`sandbox-engine`).

`config.waypak.waylandGrants` lists the re-grants as
`{ engine, appId, globals }`. `waypak.lib.toUmbrielRules` and
`waypak.lib.toJayClients` turn that into either compositor's config:

```nix
services.umbriel.settings.security_context_rule =
  waypak.lib.toUmbrielRules config.waypak.waylandGrants;
```

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
`commands`. extra entrypoints run inside the app's sandbox (eg. clipse ships a
`clipse-listener` bin for clipboard watching). PRs welcome!

`waypak.profiles` swaps or extends the bundled set (`{ }` to opt out entirely)

profiles can also be generated from a flatpak manifest's `finish-args` (json
manifests only):

```nix
waypak.profiles = waypak.policies // {
  spotify = waypak.lib.fromFlatpakManifest ./com.spotify.Client.json;
};
```

generated profiles are just attrsets, so you can extend them beyond the
capabilities flatpak can express into waypak's other options.

`waypak.wrappedPackages.<name>` exposes each sandboxed wrapper for handing to
other modules (eg. `programs.<x>.package`); the original package stays reachable
as `passthru.unwrapped`, and `passthru.waypak` carries the evaluated policy, the
launcher script and the app's wayland grant

the module is a thin layer over `waypak.lib.wrap`, which can be used anywhere
nix is used:

```nix
waypak.lib.wrap {
  inherit pkgs;
  name = "spotify";
  package = pkgs.spotify;
  binds = [ "$HOME/Music" ];
}
```

## hardening

- by default, every sandbox gets a seccomp filter using flatpak's seccomp
  capabilities as a baseline (tty ioctl keystroke injection, ptrace, kernel
  keyring, mount family). `seccomp = false` disables this, `userns = false`
  additionally denies nested user namespaces (electron/chromium apps need them
  for their own sandbox, most others don't)
- `net = "isolated"` gives the app a private network namespace with internet via
  [pasta](https://passt.top/). localhost network services and abstract sockets
  (eg. X11) are unreachable
- `storeClosure = true` binds only the app's closure instead of all of /nix and
  /run/current-system
- `closured = true` launches the app in its own cgroup and asks
  [closured](https://github.com/samiser/closured) to deny execs outside its
  closure, so even paths the sandbox can see aren't runnable. if `closured`
  isn't running it logs a warning and launches anyway

## goals

- nixos native sandboxing: wrap the package, keep the name and desktop entry,
  configure everything from the module
- each app's launcher is one generated shell script with its policy at the top,
  so `cat` on it shows you exactly what that sandbox does
- each layer does one job: the compositor decides what an app can show, the dbus
  proxy what it can say, bwrap what it can see, seccomp what it can call
- any option can be switched off and you get exactly the behaviour from before
  it existed

## non-goals

- x11: there's no security boundary to enforce there, so wayland only
- deciding what an app is allowed to _execute_. this requires an lsm, so it's
  delegated to [closured](https://github.com/samiser/closured), which is not
  required to use waypak
- as an extension of the previous point, sandboxing should work with nothing
  else running, so anything that needs a service/daemon is optional

## caveats

- network is shared by default (`net = false` to unshare, `net = "isolated"` for
  pasta), gpu and audio are opt-in per app, /etc is cherry-picked (not bound
  directly)
- apps with portal access see a fake /.flatpak-info, so they may believe they're
  flatpaks
- protects against sloppy apps and their plugin/content ecosystems, not targeted
  malware

## credits

built on [way-secure](https://git.sr.ht/~whynothugo/way-secure), vendored until
it lands in nixpkgs

design inspiration from other good solutions with overlapping concerns:

- [nixpak](https://github.com/nixpak/nixpak) for the modular approach and
  flatpak-aligned features
- [jail.nix](https://sr.ht/~alexdavid/jail.nix/) for the wrapping approach and
  interface design (i really love the combinators / pure function idea but it's
  quite different to what waypak is going for)
