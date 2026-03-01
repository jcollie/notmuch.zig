{
  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    };
    zig = {
      url = "git+https://git.ocjtech.us/jeff/zig-overlay.git";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs =
    {
      nixpkgs,
      zig,
      ...
    }:
    let
      lib = nixpkgs.lib;
      platforms = lib.attrNames zig.packages;
      makePackages =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ ];
        };
      forAllSystems = (function: lib.genAttrs platforms (system: function (makePackages system)));
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          nativeBuildInputs = [
            zig.packages.${pkgs.stdenv.hostPlatform.system}.master
            pkgs.pkg-config
            pkgs.reuse
            pkgs.pinact
          ];
          buildInputs = [
            pkgs.notmuch
          ];
        };
      });
    };
}
