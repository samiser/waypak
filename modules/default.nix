{ policies }:
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.waypak;
  wrap =
    name: app:
    import ../lib/wrap.nix (
      {
        inherit pkgs name;
        inherit (cfg) engine profiles;
      }
      // removeAttrs app [ "_module" ]
    );
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
            imports = [
              (import ./app.nix {
                inherit name;
                inherit (cfg) profiles;
              })
            ];
          }
        )
      );
      default = { };
      description = "apps installed sandboxed (security context + bwrap + filtered dbus); dbus policy defaults come from waypak's bundled profiles when the name matches";
    };

    wrappedPackages = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      default = lib.mapAttrs wrap cfg.apps;
      description = "the sandboxed wrapper for each app, for handing to e.g. `programs.<x>.package`";
    };

    waylandGrants = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      default = lib.pipe cfg.wrappedPackages [
        lib.attrValues
        (map (p: p.passthru.waypak.waylandGrant))
        (lib.filter (g: g.globals != [ ]))
      ];
      description = "privileged globals to re-grant per app, as {engine, appId, globals}; map into your compositor's security-context config (umbriel, jay, ...)";
    };
  };

  config = lib.mkIf (cfg.apps != { }) {
    environment.systemPackages = lib.attrValues cfg.wrappedPackages;
  };
}
