{
  description = "permissionsync-cc — log and sync Claude Code permission approvals";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ flake-parts, ... }:
    let
      # Scripts that are entry points — these get wrapped with makeWrapper
      executableScripts = [
        "log-permission.sh"
        "log-permission-auto.sh"
        "sync-permissions.sh"
        "worktree-sync.sh"
        "setup-hooks.sh"
      ];

      # Scripts that are sourced by others — must NOT be wrapped
      libraryScripts = [
        "permissionsync-lib.sh"
        "permissionsync-config.sh"
      ];

      allScripts = executableScripts ++ libraryScripts ++ [ "install.sh" ];
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      flake = {
        overlays.default = final: prev: {
          permissionsync-cc = inputs.self.packages.${prev.system}.default;
        };
      };

      perSystem = { config, self', inputs', pkgs, system, ... }:
        let
          runtimeDeps = [
            pkgs.jq
            pkgs.coreutils
            pkgs.gnused
            pkgs.gnugrep
            pkgs.diffutils
            pkgs.git
          ];
        in
        {
          packages.default = pkgs.stdenvNoCC.mkDerivation {
            pname = "permissionsync-cc";
            version = "0.1.0";

            src = inputs.self;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            dontBuild = true;

            installPhase = ''
              runHook preInstall

              # Raw (unwrapped) copies — used by setup-hooks.sh to cp into ~/.claude/hooks/
              mkdir -p $out/share/permissionsync-cc
              for s in ${builtins.concatStringsSep " " allScripts}; do
                cp "$src/$s" "$out/share/permissionsync-cc/$s"
                chmod +x "$out/share/permissionsync-cc/$s"
              done

              mkdir -p $out/bin

              # Library scripts go into bin/ UNwrapped (they get source'd, not exec'd)
              for s in ${builtins.concatStringsSep " " libraryScripts}; do
                cp "$src/$s" "$out/bin/$s"
                chmod +x "$out/bin/$s"
              done

              # Executable scripts get wrapped with runtime deps on PATH
              for s in ${builtins.concatStringsSep " " executableScripts}; do
                cp "$src/$s" "$out/bin/$s"
                chmod +x "$out/bin/$s"
                wrapProgram "$out/bin/$s" \
                  --prefix PATH : "${pkgs.lib.makeBinPath runtimeDeps}"
              done

              # Patch setup-hooks.sh to find raw scripts in share/
              sed -i 's|PERMISSIONSYNC_SHARE_DIR=.*|PERMISSIONSYNC_SHARE_DIR="'"$out"'/share/permissionsync-cc"|' \
                "$out/bin/.setup-hooks.sh-wrapped"

              runHook postInstall
            '';

            meta = {
              description = "Log and sync Claude Code permission approvals";
              license = pkgs.lib.licenses.mit;
              mainProgram = "setup-hooks.sh";
            };
          };

          checks.tests = pkgs.stdenvNoCC.mkDerivation {
            name = "permissionsync-cc-tests";
            src = inputs.self;
            nativeBuildInputs = [ pkgs.bash pkgs.jq pkgs.diffutils pkgs.git ];
            dontBuild = true;
            doCheck = true;
            checkPhase = ''
              patchShebangs tests/
              for t in tests/test-*.sh; do
                echo "=== Running $t ==="
                bash "$t"
              done
            '';
            installPhase = ''
              touch $out
            '';
          };

          checks.pre-commit-check = inputs.git-hooks.lib.${system}.run {
            src = inputs.self;
            hooks = {
              shellcheck = {
                enable = true;
                excludes = [ "^\\.envrc$" ];
                args = [ "--exclude=SC1091" ];
              };
              shfmt.enable = true;
            };
          };

          devShells.default =
            let
              inherit (config.checks.pre-commit-check) shellHook enabledPackages;
            in
            pkgs.mkShell {
              inherit shellHook;
              packages = enabledPackages ++ [
                pkgs.jq
                pkgs.coreutils
                pkgs.gnused
                pkgs.gnugrep
                pkgs.diffutils
              ];
            };
        };
    };
}
