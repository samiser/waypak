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

  # extra entrypoints run inside an app's sandbox; deps are package names
  # resolved here so the generated bin is self-contained
  mkCommands =
    name: app:
    lib.mapAttrsToList (
      cname: c:
      pkgs.writeShellScriptBin "${name}-${cname}" ''
        export PATH=${lib.makeBinPath (map (d: pkgs.${d}) c.deps)}:$PATH
        exec ${waypak}/bin/waypak -a ${name} -s ${pkgs.runtimeShell} -c ${lib.escapeShellArg c.cmd}
      ''
    ) app.commands;

  # replace each binary with a wrapper launching it through the sandbox;
  # desktop files pointing at the original store path are rewritten
  wrapApp =
    name: app:
    pkgs.symlinkJoin {
      name = "${name}-sandboxed";
      paths = [ app.package ];
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
        type = lib.types.bool;
        default = profile.net or true;
        description = "share the network namespace";
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
              binds = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "extra paths bind-mounted read-write into the sandbox; shell vars expand at launch";
              };
              roBinds = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "extra paths bind-mounted read-only into the sandbox; missing paths are skipped";
              };
            };
          }
        )
      );
      default = { };
      description = "apps installed sandboxed (security context + bwrap + filtered dbus); dbus policy defaults come from waypak's bundled profiles when the name matches";
    };

    securityContextRules = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      default = lib.mapAttrsToList (name: app: {
        match = {
          sandbox_engine = lib.escapeRegex cfg.engine;
          app_id = lib.escapeRegex name;
        };
        allow_globals = app.waylandGlobals;
      }) (lib.filterAttrs (_: app: app.waylandGlobals != [ ]) cfg.apps);
      description = "umbriel `[[security_context_rule]]` entries for apps with `waylandGlobals`";
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
    environment.systemPackages =
      [ waypak ]
      ++ lib.mapAttrsToList wrapApp cfg.apps
      ++ lib.concatLists (lib.mapAttrsToList mkCommands cfg.apps);
  };
}
