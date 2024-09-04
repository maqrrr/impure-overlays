{
  description = "Flake to ease local development of overlays";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-24.05";
  };
  outputs = { nixpkgs, ... }:
    let
      isPure = !(builtins ? currentSystem);
      withConfig =
        {
          # suppress extra output
          quiet ? false

          # relative path to flake root
        , overlaysDir ? "./overlays"

          # XXX is there any reason to support an array of systems by default?
        , system ? "x86_64-linux"

          # absolute path for overlays
        , overlaysPath ? (nixpkgs.lib.maybeEnv "IMPURE_OVERLAYS_PATH" (if !isPure then "${builtins.getEnv "PWD"}/${overlaysDir}" else false))

          # pkgs
        , pkgs ? import nixpkgs { inherit system; }

          # override doCheck by default to make patch dev simpler
        , extraOverrideAtrs ? { doCheck = false; }

          # if installed in a flake, assume it was at the root level by default
        , flakePrefix ? ".#"

          # default nixpkgs repo to use if there's no ./flake.nix
        , nixpkgsRepo ? "nixpkgs"
        }:
        let
          # find all the user's overlay packages from directory contents
          localOverlays =
            if overlaysPath != false && builtins.pathExists overlaysPath
            then
              builtins.attrNames
                (
                  (lib.filterAttrs
                    (name: type: type == "directory")
                    (builtins.readDir overlaysPath))
                )
            else
              [ ];

          # build an overlay for any packages found in the directory
          overlays.default = (_: prev: (
            lib.genAttrs localOverlays (name:
              prev.${name}.overrideAttrs (oA:
                let
                  versionSuffix = if prev.${name}.src.name == "source" then "-${oA.version}" else "";
                  srcPath = /${overlaysPath}/${name}/${srcToDir prev.${name}.src}${versionSuffix};
                  srcAttr = if builtins.pathExists srcPath then { src = srcPath; } else { };
                in
                srcAttr // extraOverrideAtrs)
            )
          ));

          # internal utilities
          lib = pkgs.lib;
          getExe = x: lib.meta.getExe' x (
            # builtins.getExe without the warning
            x.meta.mainProgram or (lib.getName x)
          );

          pkgs' = (pkgs.appendOverlays [ overlays.default ]);
          removeSuffixes = suffixes: name: lib.foldl' (acc: suffix: lib.removeSuffix suffix acc) name suffixes;
          srcToDir = src: (removeSuffixes [ ".tar.gz" ".tar.xz" ".tar.bz2" ".zip" ".tgz" ".tbz2" ".txz" ".tar.lzma" ] src.name);

          # exported utilities
          mkScript = name: args: (pkgs.writeShellApplication (args // { inherit name; }));
          mkApp = program: { program = getExe program; type = "app"; };

          # bash snippets
          overlayNoticeBash =
            let
              hasOverlays = (builtins.length localOverlays) > 0;
            in
            if !quiet then ''
              ${ if hasOverlays then ''
                if [[ -n ''${IMPURE_OVERLAYS_PATH:-} ]]; then
                  echo "[impure-overlays] running with $IMPURE_OVERLAYS_PATH: [ ${lib.concatStringsSep " " localOverlays } ]" >&2
                else
                  echo "[impure-overlays] running with impure without overlays" >&2
                fi
              '' else ""}
            '' else "";
          setFlakePrefixBash = ''
            # check to see if there's a flake in the local directory
            # NOTE: maybe this should search upwards recursively?
            has_flake_overlay=$(\
              # see if we're installed by checking if the flake's devShells has an 'overlay' key
              nix eval --impure --expr \
              "(builtins.hasAttr \"overlay\" (builtins.getFlake \"$(pwd)\").devShells.\''${builtins.currentSystem})" \
              2> /dev/null || \
              :)  # NOTE: happy bash :)

            # use the global prefix as the default
            flakePrefix="impure-overlays#"

            # but we're installed in .#overlay. if true
            if [[ "$has_flake_overlay" == "true" ]]; then
              flakePrefix="${flakePrefix}overlay."
            fi
          '';
          exportImpureOverlaysPath = ''
            IMPURE_OVERLAYS_PATH=$(pwd)/${overlaysDir}
            export IMPURE_OVERLAYS_PATH
          '';

          # expose devShell for all pkgs to generate local impure overlays
          genOverlay =
            let
              gitArgs = ''
                -c user.name="Impure Overlays" \
                -c user.email="impure-overlays@example.com" \
              '';
              pkgDirName = pkg: "${overlaysDir}/${pkg.pname}";
              unpackPkgShell = name:
                let
                  impureShell = pkgs'.mkShell {
                    buildInputs = [ pkgs.git ];
                    shellHook =
                      let
                        pkgDir = pkgDirName pkgs.${name};
                        pkg = pkgs.${name};
                      in
                      ''
                        # figure out source_root for our pkg version
                        source_root=${srcToDir pkg.src}
                        if [[ "${pkg.src.name}" == "source" ]]; then
                          # save it in a versioned directory
                          old_source_root=$source_root
                          source_root=${srcToDir pkgs.${name}.src}-${pkgs.${name}.version}
                        fi

                        if [ ! -d "${pkgDir}/$source_root" ]; then 
                          # attempt to unpack
                          pwd=$(pwd)
                          nixpkgsOverride=$(nix flake metadata --json '.#' | jq -r '"github:/\(.locks.nodes.nixpkgs.locked | .owner)/\(.locks.nodes.nixpkgs.locked | .repo)/\(.locks.nodes.nixpkgs.locked | .rev)"' || :)

                          ${ if !quiet then ''
                          echo "[impure-overlays] Using nixpkgs from flake.nix ($nixpkgsOverride)" >&2
                          '' else "" }

                          # go to overlay pkg directory
                          mkdir -p ${pkgDir}
                          cd ${pkgDir}

                          if [ -n "$nixpkgsOverride" ]; then
                            nix develop --override-flake nixpkgs "$nixpkgsOverride" -i '${nixpkgsRepo}#${name}' --unpack
                          else
                            nix develop -i '${nixpkgsRepo}#${name}' --unpack
                          fi
                        
                          if [ ! -d "$source_root" ]; then
                            mv "$old_source_root" "$source_root"
                          fi

                          # setup git
                          if [ ! -d ".git" ]; then
                            # need a new repo
                            git init -q
                            git config commit.gpgsign false
                            git add .
                            git \
                              ${gitArgs} \
                              commit \
                              -qm "Initial commit" \
                              --allow-empty 
                          else
                            # we already have git, so just make a new commit
                              git \
                                ${gitArgs} \
                                commit \
                                -qam "Added $source_root"
                          fi

                          # move back 
                          cd - > /dev/null
                        else
                          echo "[impure-overlays] $source_root exists -- skipping unpack." >&2
                        fi

                        echo "[impure-overlays] '${name}' ready to edit: ${pkgDir}/$source_root" >&2

                        cd ${pkgDir}/$source_root
                        exit
                      '';
                  };
                  pureShell = pkgs.mkShell {
                    shellHook = ''
                      ${exportImpureOverlaysPath}
                      ${setFlakePrefixBash}
                      nix develop --impure "''${flakePrefix}${name}.unpack" "$@"
                      exit
                    '';
                  };
                in
                if isPure then pureShell else impureShell;
              diffPkgShell = name: pkgs.mkShell {
                buildInputs = [ pkgs.git ];
                shellHook =
                  let
                    pkgDir = pkgDirName pkgs.${name};
                  in
                  ''
                    # go to ./overlays/pkg directory
                    mkdir -p ${pkgDir}
                    cd ${pkgDir}

                    # figure out source_root for our pkg version
                    source_root=${srcToDir pkgs.${name}.src}
                    if [ ! -d "$source_root" ]; then
                      echo "[impure-overlays] Could not find $source_root in $(pwd)" >&2
                      exit 1
                    fi

                    # make a patch
                    # first with any commits
                    cd $source_root
                    output=$(
                      git format-patch \
                        --stdout \
                        --relative \
                        -1 \
                        $(git rev-list --max-parents=0 HEAD)..HEAD \
                        && \
                          # then anything not commited
                          git diff \
                          --relative \
                          --cached \
                          -- "$source_root/" \
                          && \
                            # then anything else changed
                            git diff \
                            --relative
                    )
                    echo "$output"

                    exit
                  '';
              };
              defaultPkgShell =
                name:
                let
                  impureShell =
                    let
                      pkg = pkgs'.${name};
                      pkgDir = pkgDirName pkg;
                    in
                    pkgs'.mkShell
                      {
                        shellHook = ''
                          # figure out source_root for our pkg version
                          source_root=${pkgDir}/${srcToDir pkgs.${name}.src}

                          # unpack the source if we don't have it
                          if [ ! -d "$source_root" ]; then
                            ${setFlakePrefixBash}
                            nix develop "''${flakePrefix}${name}.unpack" "$@"
                          else
                            echo "[impure-overlays] $source_root exists -- skipping unpack." >&2
                          fi

                          cd ${pkgDir}/$new_source_root
                        '';
                      };
                  pureShell = pkgs.mkShell {
                    shellHook = ''
                      ${exportImpureOverlaysPath}
                      ${setFlakePrefixBash}
                      nix develop --impure "''${flakePrefix}${name}" "$@"
                      exit
                    '';
                  };
                in
                if isPure then pureShell else impureShell;
              buildPkgShell = name: pkgs.mkShell {
                shellHook = ''
                  set -x
                  ${setFlakePrefixBash}
                  nix build --impure "''${flakePrefix}${name}" "$@"
                  exit
                '';
              };
            in
            lib.genAttrs (builtins.attrNames pkgs) (name:
              (defaultPkgShell name) // {
                unpack = unpackPkgShell name;
                diff = diffPkgShell name;
                build = buildPkgShell name;
              });

          # re-run these 'nix run' commands impurely to take use any overlays
          # NOTE: you'd think we could use __impure to trigger this, but only passing --impure seems to make apps run impurely
          impureApps = (attrs: (builtins.mapAttrs
            (name: value:
              if isPure then value // {
                program =
                  lib.getExe (mkScript "pure-${name}" {
                    text = ''
                      ${exportImpureOverlaysPath}
                      ${overlayNoticeBash}
                      nix run --impure "${flakePrefix}${name}" "$@"
                    '';
                  });
              }
              else
                value
            )
            attrs)
          // {
            overlay = lib.genAttrs (builtins.attrNames pkgs) (name:
              let
                pureApp = mkApp (mkScript "overlay-${name}" {
                  text = ''
                    ${exportImpureOverlaysPath}
                    ${setFlakePrefixBash}
                    nix run --impure "''${flakePrefix}${name}" -- "$@"
                    exit
                  '';
                });
                impureApp = mkApp (mkScript "overlay-impure-${name}" {
                  text = ''
                    ${overlayNoticeBash}
                    ${getExe pkgs'.${name}} "$@"
                  '';
                });
              in
              if isPure then pureApp else impureApp);
          }
          );
        in
        {
          # XXX is this ok to do? it works but produces warnings
          inherit overlays mkScript mkApp impureApps;
        } // {
          devShells.${system} = genOverlay;
          apps.${system} = (impureApps { }).overlay;
          packages.${system} = lib.genAttrs localOverlays (name: pkgs'.${name});
          templates = {
            default = {
              path = ./example;
              description = "impure-overlays example flake integration";
            };
          };
          # TODO: ./test.sh should be a `checks` entry here, but it's unclear how to do it
        };
      defaultConfig = withConfig { };
    in
    defaultConfig // {
      inherit withConfig;
    };
}
