{
  description = "permissionsync-cc — log and sync Claude Code permission approvals";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      scripts = [
        "install.sh"
        "log-permission.sh"
        "log-permission-auto.sh"
        "sync-permissions.sh"
      ];
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          runtimeDeps = [
            pkgs.jq
            pkgs.coreutils
            pkgs.gnused
            pkgs.gnugrep
            pkgs.diffutils
          ];
        in
        {
          default = pkgs.stdenvNoCC.mkDerivation {
            pname = "permissionsync-cc";
            version = "0.1.0";

            src = self;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            dontBuild = true;

            installPhase = ''
              runHook preInstall

              # Raw (unwrapped) copies for install.sh to cp into ~/.claude/hooks/
              mkdir -p $out/share/permissionsync-cc
              for s in ${builtins.concatStringsSep " " scripts}; do
                cp "$src/$s" "$out/share/permissionsync-cc/$s"
                chmod +x "$out/share/permissionsync-cc/$s"
              done

              # Wrapped copies in bin/ with runtime deps on PATH
              mkdir -p $out/bin
              for s in ${builtins.concatStringsSep " " scripts}; do
                cp "$src/$s" "$out/bin/$s"
                chmod +x "$out/bin/$s"
                wrapProgram "$out/bin/$s" \
                  --prefix PATH : "${pkgs.lib.makeBinPath runtimeDeps}"
              done

              # Patch SCRIPT_DIR in the wrapped install.sh so it finds the
              # raw scripts in share/ (for copying to ~/.claude/hooks/)
              sed -i 's|SCRIPT_DIR=.*|SCRIPT_DIR="'"$out"'/share/permissionsync-cc"|' \
                "$out/bin/.install.sh-wrapped"

              runHook postInstall
            '';

            meta = {
              description = "Log and sync Claude Code permission approvals";
              license = pkgs.lib.licenses.mit;
              platforms = supportedSystems;
              mainProgram = "install.sh";
            };
          };
        }
      );

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            packages = [
              pkgs.jq
              pkgs.shellcheck
              pkgs.shfmt
              pkgs.coreutils
              pkgs.gnused
              pkgs.gnugrep
              pkgs.diffutils
            ];
          };
        }
      );

      checks = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          shellcheck = pkgs.stdenvNoCC.mkDerivation {
            name = "check-shellcheck";
            src = self;
            nativeBuildInputs = [ pkgs.shellcheck ];
            dontBuild = true;
            doCheck = true;
            checkPhase = ''
              shellcheck -s bash ${builtins.concatStringsSep " " (map (s: "$src/${s}") scripts)}
            '';
            installPhase = "mkdir -p $out";
          };

          shfmt = pkgs.stdenvNoCC.mkDerivation {
            name = "check-shfmt";
            src = self;
            nativeBuildInputs = [ pkgs.shfmt ];
            dontBuild = true;
            doCheck = true;
            checkPhase = ''
              shfmt -d ${builtins.concatStringsSep " " (map (s: "$src/${s}") scripts)}
            '';
            installPhase = "mkdir -p $out";
          };
        }
      );
    };
}
