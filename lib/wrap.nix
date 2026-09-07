{
  pkgs,
  way-secure ? pkgs.way-secure or (pkgs.callPackage ../pkgs/way-secure.nix { }),
  engine ? "waypak",
  profiles ? import ../profiles,
  name,
  ...
}@args:
let
  inherit (pkgs) lib;

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

  mkCommand = cname: c: ''
    cat > $out/bin/${name}-${cname} <<EOF
    #!${pkgs.runtimeShell}
    exec ${run} ${pkgs.runtimeShell} -c ${lib.escapeShellArg c.cmd}
    EOF
    chmod +x $out/bin/${name}-${cname}
  '';
in
pkgs.symlinkJoin {
  inherit (policy.package) meta;

  name = "${name}-sandboxed";
  paths = [ policy.package ];
  version = policy.package.version or "unknown";
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
