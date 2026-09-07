# wraps a package so its bins and desktop entries launch sandboxed
{
  pkgs,
  way-secure ? pkgs.way-secure or (pkgs.callPackage ../pkgs/way-secure.nix { }),
  engine ? "waypak",
  profiles ? import ../profiles,
  name,
  ...
}@args:
let
  lib = pkgs.lib;
  # plain args go through the app module, so misuse fails like the nixos module does
  policy =
    (lib.evalModules {
      modules = [
        (import ../modules/app.nix { inherit name profiles; })
        {
          config = removeAttrs args [
            "pkgs"
            "way-secure"
            "engine"
            "profiles"
            "name"
          ];
        }
      ];
    }).config;
  launcher = import ./launcher.nix { inherit pkgs way-secure engine; } { inherit name policy; };
  run = "${launcher}/bin/waypak-${name}";
  # extra entrypoints run inside the same sandbox as the app
  mkCommand = cname: c: ''
    cat > $out/bin/${name}-${cname} <<EOF
    #!${pkgs.runtimeShell}
    export PATH=${lib.makeBinPath (map (d: pkgs.${d}) c.deps)}:\$PATH
    exec ${run} ${pkgs.runtimeShell} -c ${lib.escapeShellArg c.cmd}
    EOF
    chmod +x $out/bin/${name}-${cname}
  '';
in
# meta/version/passthru survive so modules inspecting the package still work
pkgs.symlinkJoin {
  name = "${name}-sandboxed";
  paths = [ policy.package ];
  passthru = (policy.package.passthru or { }) // {
    unwrapped = policy.package;
    waypak = {
      inherit policy launcher;
      waylandGrant = {
        inherit engine;
        appId = name;
        globals = policy.waylandGlobals;
      };
    };
  };
  inherit (policy.package) meta;
  version = policy.package.version or "unknown";
  postBuild = ''
    for bin in $out/bin/*; do
      target=$(readlink -f "$bin")
      rm "$bin"
      cat > "$bin" <<EOF
    #!${pkgs.runtimeShell}
    exec ${run} "$target" "\$@"
    EOF
      chmod +x "$bin"
    done
    if [ -d $out/share/applications ]; then
      for f in $out/share/applications/*.desktop; do
        src=$(readlink -f "$f")
        rm "$f"
        sed "s|Exec=${policy.package}/bin/|Exec=$out/bin/|" "$src" > "$f"
      done
    fi
    mkdir -p $out/bin
    ${lib.concatStrings (lib.mapAttrsToList mkCommand policy.commands)}
  '';
}
