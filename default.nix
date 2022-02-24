{ compiler ? "ghc8107" // { system = "x86_64-darwin"; }}:

with rec {
  pkgs = (import ./nix/nixpkgs.nix {
    inherit compiler;
  });
  drv = pkgs.haskellPackages.hw-kafka-client;
};

drv
