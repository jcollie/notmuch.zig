# SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
# SPDX-License-Identifier: GPL-3.0-or-later

{
  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    };
  };

  outputs =
    {
      nixpkgs,
      ...
    }:
    let
      lib = nixpkgs.lib;
      platforms = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
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
            pkgs.git-pages-cli
            pkgs.pinact
            pkgs.pkg-config
            pkgs.reuse
            pkgs.zig_0_16
          ];
          buildInputs = [
            pkgs.notmuch
          ];
          NOTMUCH_INCLUDE = "${lib.getInclude pkgs.notmuch}/include";
        };
      });
    };
}
