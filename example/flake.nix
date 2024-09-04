{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    impure-overlays = {
      url = "impure-overlays";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, impure-overlays, ... }:
    let
      system = "x86_64-linux";
      iO = impure-overlays.withConfig { inherit system; };
      inherit (iO) mkApp mkScript;
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          iO.overlays.default # <-- the overlay containing our patches if any
        ];
      };
      demoApp = mkApp mkScript "demo" {
        runtimeInputs = with pkgs; [ hello ];
        text = ''
          hello
        '';
      };
    in
    {
      /* if you want to build with impure-overlays patch,
        use `nix build --impure` or `nix develop .#overlay.pkg.build`
        to build without your overlay, use `nix build` without `--impure` */
      packages.${system}.overlay = iO.packages.${system};

      apps.${system} = {
        demo = demoApp; # <-- apps to be run without patches
      } // iO.impureApps {
        impureDemo = demoApp; # <-- apps to be run with patches
      };

      devShells.${system} = {
        /* your devShells go here */
        overlay = iO.devShells.${system}; # <-- support `nix develop '.#overlay.<pkg>.{unpack,diff.build}'`
      };
    };
}

