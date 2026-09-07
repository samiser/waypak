# waypak

sandbox apps on nixos, enforced by the wayland compositor via
[security-context-v1](https://wayland.app/protocols/security-context-v1)

wrapped packages keep their names and desktop entries, so launching them
normally runs them sandboxed:

- the compositor withholds privileged wayland protocols from the app
- xdg-dbus-proxy filters what it can say on the bus, portals included
- bwrap gives it a private persistent home plus whatever paths you bind

## requirements

any compositor implementing
[security-context-v1](https://wayland.app/protocols/security-context-v1) (sway,
kwin, ...) enforces the core boundary by withholding its privileged protocols
from a tagged client.

handing a specific protocol back to a specific app needs a compositor that
matches rules on the security context, currently
[umbriel](https://github.com/noctalia-dev/umbriel) or
[jay](https://github.com/mahkoh/jay). `waylandGlobals` declares the re-grants
per app, `config.waypak.waylandGrants` collects them as
`{ engine, appId, globals }`, and `waypak.lib.toUmbrielRules` or
`waypak.lib.toJayClients` turns that into compositor config:

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

dbus policy (`talk`/`own`) and `commands` default from `profiles/` by app name.
commands are extra entrypoints that run inside the app's sandbox, eg. clipse
ships a `clipse-listener` bin for clipboard watching.

`waypak.profiles` swaps or extends the bundled set (`{ }` opts out). profiles
can also be generated from a flatpak manifest's `finish-args` (json only), and
since they're plain attrsets you can extend them with waypak's other options:

```nix
waypak.profiles = waypak.policies // {
  spotify = waypak.lib.fromFlatpakManifest ./com.spotify.Client.json;
};
```

`waypak.wrappedPackages.<name>` is each sandboxed package, for handing to eg.
`programs.<x>.package`. the original stays reachable as `passthru.unwrapped`,
and `passthru.waypak` carries the policy, launcher and wayland grant.

the module is a thin layer over `waypak.lib.wrap`:

```nix
waypak.lib.wrap {
  inherit pkgs;
  name = "spotify";
  package = pkgs.spotify;
  binds = [ "$HOME/Music" ];
}
```

## hardening

every sandbox by default:

- unshares all namespaces (`net = true` shares the host network)
- clears the environment except locale, term, home and xdg session vars
  (`clearenv = false` inherits everything)
- gets a seccomp filter based on flatpak's (tty keystroke injection, ptrace,
  kernel keyring, perf, memory policy). `seccomp = false` disables it,
  `userns = false` also denies nested user namespaces (electron/chromium apps
  need them for their own sandbox)
- sees a cherry-picked /etc, with gpu and audio opt-in

opt-in:

- `net = "isolated"`: private network namespace with internet via
  [pasta](https://passt.top/). localhost and abstract sockets are unreachable
- `storeClosure = true`: bind only the app's closure instead of all of /nix and
  /run/current-system
- `closured = true`: run the app in its own cgroup and have
  [closured](https://github.com/samiser/closured) deny execs outside its
  closure, so even paths the sandbox can see aren't runnable. warns and launches
  anyway if closured isn't running

## goals

- nixos native: wrap the package, keep the name and desktop entry, configure
  everything from the module
- each app's launcher is one generated shell script with its policy at the top,
  so `cat` on it shows exactly what that sandbox does
- each layer does one job: the compositor decides what an app can show, the dbus
  proxy what it can say, bwrap what it can see, seccomp what it can call
- any option can be switched off for exactly the behaviour from before it
  existed

## non-goals

- x11: there's no security boundary to enforce, so wayland only
- deciding what an app can _execute_ needs an lsm, so it's delegated to
  [closured](https://github.com/samiser/closured), which is optional
- sandboxing works with nothing else running, so anything needing a daemon is
  optional

## caveats

- apps with portal access see a fake /.flatpak-info, so they may think they're
  flatpaks
- the threat model is supply chain attacks, a compromised app, plugin or
  dependency only reaches what its sandbox exposes. it is not a defence against
  malware built to escape bwrap, the compositor or the kernel

## credits

built on [way-secure](https://git.sr.ht/~whynothugo/way-secure), vendored until
it lands in nixpkgs

design inspiration from other good solutions with overlapping concerns:

- [nixpak](https://github.com/nixpak/nixpak) for the modular approach and
  flatpak-aligned features
- [jail.nix](https://sr.ht/~alexdavid/jail.nix/) for the wrapping approach and
  interface design (i really love the combinators / pure function idea but it's
  quite different to what waypak is going for)
