{ policies }:
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.waypak;
  way-secure = pkgs.way-secure or (pkgs.callPackage ../pkgs/way-secure.nix { });

  waypak = import ../lib/cli.nix {
    inherit pkgs way-secure;
    inherit (cfg) engine defaultPolicy;
    apps = cfg.apps;
  };

  mkCommands =
    name: app:
    lib.mapAttrsToList (
      cname: c:
      pkgs.writeShellScriptBin "${name}-${cname}" ''
        export PATH=${lib.makeBinPath (map (d: pkgs.${d}) c.deps)}:$PATH
        exec ${waypak}/bin/waypak -a ${name} -s ${pkgs.runtimeShell} -c ${lib.escapeShellArg c.cmd}
      ''
    ) app.commands;

  # meta/version/passthru survive so modules inspecting the package still work
  wrapApp =
    name: app:
    pkgs.symlinkJoin {
      name = "${name}-sandboxed";
      paths = [ app.package ];
      passthru = (app.package.passthru or { }) // {
        unwrapped = app.package;
      };
      inherit (app.package) meta;
      version = app.package.version or "unknown";
      postBuild = ''
        for bin in $out/bin/*; do
          target=$(readlink -f "$bin")
          rm "$bin"
          cat > "$bin" <<EOF
        #!${pkgs.runtimeShell}
        exec ${waypak}/bin/waypak -s -a ${name} "$target" "\$@"
        EOF
          chmod +x "$bin"
        done
        if [ -d $out/share/applications ]; then
          for f in $out/share/applications/*.desktop; do
            src=$(readlink -f "$f")
            rm "$f"
            sed "s|Exec=${app.package}/bin/|Exec=$out/bin/|" "$src" > "$f"
          done
        fi
      '';
    };

  policyOptions =
    name:
    let
      profile = cfg.profiles.${name} or { };
    in
    {
      talk = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = profile.talk or [ ];
        description = "session bus names the app may call";
      };
      own = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = profile.own or [ ];
        description = "session bus names the app may claim";
      };
      net = lib.mkOption {
        type = lib.types.either lib.types.bool (lib.types.enum [ "isolated" ]);
        default = profile.net or false;
        description = "true shares the host network namespace, false unshares it, \"isolated\" is a private namespace with internet via pasta (localhost and abstract sockets unreachable)";
      };
      seccomp = lib.mkOption {
        type = lib.types.bool;
        default = profile.seccomp or true;
        description = "apply the baseline seccomp filter (kernel keyring, ptrace, tty ioctl injection and more)";
      };
      extraSeccomp = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = profile.extraSeccomp or [ ];
        description = "extra syscall names to deny on top of the baseline, ignored when seccomp is false";
      };
      userns = lib.mkOption {
        type = lib.types.bool;
        default = profile.userns or true;
        description = "allow nested user namespaces; chromium/electron sandboxes need them, disable for everything else";
      };
      storeClosure = lib.mkOption {
        type = lib.types.bool;
        default = profile.storeClosure or false;
        description = "bind only the app's closure instead of /nix and /run/current-system";
      };
      closured = lib.mkOption {
        type = lib.types.bool;
        default = profile.closured or false;
        description = "deny execs outside the app's closure via a closured cgroup confinement; warns and continues if the closured daemon is not running";
      };
      closureExtra = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = profile.closureExtra or [ ];
        description = "extra packages folded into the app's closure for storeClosure and closured";
      };
      clearenv = lib.mkOption {
        type = lib.types.bool;
        default = profile.clearenv or true;
        description = "clear the environment and pass only a safe allowlist (locale, term, home) so host env-var secrets do not leak into the sandbox";
      };
      binds = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = profile.binds or [ ];
        description = "extra paths bind-mounted read-write into the sandbox; shell vars expand at launch";
      };
      roBinds = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = profile.roBinds or [ ];
        description = "extra paths bind-mounted read-only into the sandbox; missing paths are skipped";
      };
      gpu = lib.mkOption {
        type = lib.types.bool;
        default = profile.gpu or false;
        description = "expose gpu devices, /sys and gl drivers";
      };
      audio = lib.mkOption {
        type = lib.types.bool;
        default = profile.audio or false;
        description = "expose pipewire and pulse sockets";
      };
      waylandGlobals = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = profile.waylandGlobals or [ ];
        description = "privileged wayland globals the compositor should still offer this app";
      };
      commands = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              cmd = lib.mkOption {
                type = lib.types.str;
                description = "shell command run inside the app's sandbox; must stay in the foreground";
              };
              deps = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "package names put on the command's PATH";
              };
            };
          }
        );
        default = profile.commands or { };
        description = "extra entrypoints installed as `<app>-<name>` bins";
      };
    };
in
{
  options.waypak = {
    engine = lib.mkOption {
      type = lib.types.str;
      default = "waypak";
      description = "sandbox engine id reported to the compositor via security-context-v1";
    };

    profiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = policies;
      description = "policy defaults applied to `apps` by name; waypak's bundled profiles unless overridden";
    };

    apps = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = policyOptions name // {
              package = lib.mkOption {
                type = lib.types.package;
                description = "package whose binaries are wrapped to run sandboxed";
              };
            };
          }
        )
      );
      default = { };
      description = "apps installed sandboxed (security context + bwrap + filtered dbus); dbus policy defaults come from waypak's bundled profiles when the name matches";
    };

    wrappedPackages = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      default = lib.mapAttrs wrapApp cfg.apps;
      description = "the sandboxed wrapper for each app, for handing to e.g. `programs.<x>.package`";
    };

    waylandGrants = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      default = lib.mapAttrsToList (name: app: {
        inherit (cfg) engine;
        appId = name;
        globals = app.waylandGlobals;
      }) (lib.filterAttrs (_: app: app.waylandGlobals != [ ]) cfg.apps);
      description = "privileged globals to re-grant per app, as {engine, appId, globals}; map into your compositor's security-context config (umbriel, jay, ...)";
    };

    defaultPolicy = lib.mkOption {
      type = lib.types.submodule {
        options = {
          talk = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
          own = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
        };
      };
      default = { };
      description = "dbus policy for ad-hoc `waypak -s` runs without an `apps` entry; empty = deny all";
    };
  };

  config = lib.mkIf (cfg.apps != { }) {
    environment.systemPackages = [
      waypak
    ]
    ++ lib.attrValues cfg.wrappedPackages
    ++ lib.concatLists (lib.mapAttrsToList mkCommands cfg.apps);
  };
}
