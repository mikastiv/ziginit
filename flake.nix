{
  description = "zig flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    zig-flake.url = "github:silversquirl/zig-flake";
    zig-flake.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      zig-flake,
    }:
    let
      lib = nixpkgs.lib;
      fs = lib.fileset;
      forAllSystems =
        f:
        builtins.mapAttrs (
          system: pkgs: f system pkgs zig-flake.packages.${system}.zig_0_16_0
        ) nixpkgs.legacyPackages;
    in
    {
      devShells = forAllSystems (
        system: pkgs: zig: {
          default = pkgs.mkShellNoCC {
            nativeBuildInputs = [
              zig
              zig.zls
            ];
          };
        }
      );

      packages = forAllSystems (
        system: pkgs: zig: {
          default = pkgs.stdenvNoCC.mkDerivation {
            name = "ziginit";
            version = "0.1.0";
            meta.mainProgram = "ziginit";
            src = fs.toSource {
              root = ./.;
              fileset = fs.intersection (fs.fromSource (lib.sources.cleanSource ./.)) (
                fs.unions [
                  ./src
                  ./build.zig
                  ./build.zig.zon
                ]
              );
            };

            nativeBuildInputs = [ zig ];
            dontInstall = true;
            strictDeps = true;

            configurePhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$TEMP/.cache
            '';

            buildPhase = ''
              zig build install -Doptimize=ReleaseSafe --color off --prefix $out
            '';
          };
        }
      );
    };
}
