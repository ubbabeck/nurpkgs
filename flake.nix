{
  description = "My personal NUR repository";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.nix-bitcoin.url = "github:fort-nix/nix-bitcoin/release";
  inputs.nix-bitcoin.inputs.nixpkgs.follows = "nixpkgs";
  outputs = { self, nixpkgs, nix-bitcoin }:
    let
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;
      nixos-lib = import (nixpkgs + "/nixos/lib") { };
      mkTest = imports: system: nixos-lib.runTest {
      inherit imports;
      hostPkgs = import nixpkgs {inherit system;};
      # Available both to the test module and to node modules.
      node.specialArgs = { inherit nix-bitcoin; };
      _module.args = { inherit nix-bitcoin; };
    };
    in
    {
      legacyPackages = forAllSystems (system: import ./default.nix {
        pkgs = import nixpkgs { inherit system; };
      });
      packages = forAllSystems (system: nixpkgs.lib.filterAttrs (_: v: nixpkgs.lib.isDerivation v) self.legacyPackages.${system});
      nixosModules = import ./nixos-modules;
      # homeModules = import ./home-modules;
      # darwinModules = import ./darwin-modules;
      # flakeModules = import ./flake-modules;
      checks = forAllSystems (system: {
        ln-service = mkTest [./tests/ln-service.nix] system;
      });
    };
}
