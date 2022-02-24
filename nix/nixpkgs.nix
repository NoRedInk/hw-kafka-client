{ compiler ? "ghc8107" }:

with rec {
  sources = import ./sources.nix;
  nivOverlay = _: pkgs:
      { niv = (import sources.niv {}).niv;    # use the sources :)
      };
};

import sources.nixpkgs-unstable {
  config = {
    packageOverrides = super: let self = super.pkgs; in {
      haskellPackages = super.haskell.packages.${compiler}.override {
        overrides = import ./overrides.nix { pkgs = self; };
      };

    };
  };
  overlays = [nivOverlay];
}
