{ profiles }:
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
    import ../lib/wrap.nix {
      inherit pkgs name;
      inherit (cfg) engine profiles;
      modules = [ app ];
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
      type = lib.types.attrsOf lib.types.deferredModule;
      default = { };
      description = "policy modules applied to `apps` by name, merged with the bundled set";
    };

    apps = lib.mkOption {
      type = lib.types.attrsOf lib.types.deferredModule;
      default = { };
      description = "apps installed sandboxed, each a policy module layered on the profile of the same name";
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

  config = {
    waypak.profiles = profiles;
    environment.systemPackages = lib.mkIf (cfg.apps != { }) (lib.attrValues cfg.wrappedPackages);
  };
}
