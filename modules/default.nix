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
      profile = policies.${name} or { };
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
    };
in
{
  options.waypak = {
    engine = lib.mkOption {
      type = lib.types.str;
      default = "waypak";
      description = "sandbox engine id reported to the compositor via security-context-v1";
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
            };
          }
        )
      );
      default = { };
      description = "apps installed sandboxed (security context + bwrap + filtered dbus); dbus policy defaults come from waypak's bundled profiles when the name matches";
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
    environment.systemPackages = [ waypak ] ++ lib.mapAttrsToList wrapApp cfg.apps;
  };
}
