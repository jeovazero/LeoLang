{ pkgs }:
let
  haskellPkgs = pkgs.haskell.packages.ghc965;
in
  haskellPkgs.callCabal2nix "lambdaC" ./. {}
