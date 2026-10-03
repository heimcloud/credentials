{...}: {
  flake-file.inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    neo.url = "github:madebydamo/neo";
    neo.inputs.nixpkgs.follows = "nixpkgs";
    reporter.url = "github:heimcloud/reporter.neo/v0.1.0";
    reporter.inputs.nixpkgs.follows = "nixpkgs";
    reporter.inputs.neo.follows = "neo";
    reporter.inputs.flake-parts.follows = "flake-parts";
    reporter.inputs.import-tree.follows = "import-tree";
    reporter.inputs.flake-file.follows = "flake-file";
  };
}
