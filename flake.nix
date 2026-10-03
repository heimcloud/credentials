# DO-NOT-EDIT. This file was auto-generated using github:denful/flake-file.
# Use `nix run .#write-flake` to regenerate it.
{
  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree ./modules);

  inputs = {
    flake-file.url = "github:denful/flake-file";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    import-tree.url = "github:denful/import-tree";
    neo = {
      url = "github:madebydamo/neo";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    reporter = {
      url = "github:heimcloud/reporter.neo/v0.1.2";
      inputs = {
        flake-file.follows = "flake-file";
        flake-parts.follows = "flake-parts";
        import-tree.follows = "import-tree";
        neo.follows = "neo";
        nixpkgs.follows = "nixpkgs";
      };
    };
  };
}
