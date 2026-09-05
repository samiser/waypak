{
  description = "flatpak-style app sandboxing for NixOS, enforced by your Wayland compositor";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
      waySecure = pkgs: pkgs.way-secure or (pkgs.callPackage ./pkgs/way-secure.nix { });
    in
    {
      policies = import ./profiles;

      lib = {
        fromFlatpakManifest = import ./lib/flatpak-manifest.nix { inherit (nixpkgs) lib; };
      }
      // import ./lib/compositor-rules.nix { inherit (nixpkgs) lib; };

      nixosModules.default = import ./modules { policies = self.policies; };

      overlays.default = final: _: { way-secure = waySecure final; };

      packages = forAllSystems (pkgs: rec {
        way-secure = waySecure pkgs;
        waypak = import ./lib/cli.nix {
          inherit pkgs;
          way-secure = waySecure pkgs;
          engine = "waypak";
          apps = self.policies;
          defaultPolicy = { };
        };
        default = waypak;
      });
    };
}
