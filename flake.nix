{
  description = "permissionsync-cc — log and sync Claude Code permission approvals";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    claude-baseline = {
      url = "github:bethmaloney/claude-baseline";
      flake = false;
    };
  };

  outputs = inputs@{ flake-parts, ... }:
    let
      # Scripts that are entry points — these get wrapped with makeWrapper
      executableScripts = [
        "permissionsync-log-permission-v1.sh"
        "permissionsync-log-permission.sh"
        "permissionsync-log-confirmed.sh"
        "permissionsync-sync.sh"
        "permissionsync-worktree-sync.sh"
        "permissionsync-settings.sh"
        "permissionsync-launch.sh"
        "permissionsync.sh"
        "permissionsync-log-hook-errors.sh"
        "permissionsync-watch-config.sh"
        "permissionsync-sync-on-end.sh"
        "permissionsync-session-start.sh"
        "permissionsync-worktree-create.sh"
        "permissionsync-setup.sh"
      ];

      # Library scripts — sourced only, installed to lib/ subdir, NOT in bin/
      libraryScripts = [
        "permissionsync-lib.sh"
        "permissionsync-config.sh"
      ];

      # Build-time only scripts (not installed to bin/)
      buildScripts = [
        "generate-base-settings.sh"
      ];

      # Scripts copied to share/ (executables + build-time + installer)
      shareScripts = executableScripts ++ buildScripts ++ [ "permissionsync-install.sh" ];
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

            nativeBuildInputs = [ pkgs.makeWrapper pkgs.jq ];

            dontBuild = true;

            installPhase = ''
              runHook preInstall

              # Raw (unwrapped) copies — used by permissionsync-setup.sh to cp into ~/.claude/hooks/
              mkdir -p $out/share/permissionsync-cc
              for s in ${builtins.concatStringsSep " " shareScripts}; do
                cp "$src/$s" "$out/share/permissionsync-cc/$s"
                chmod +x "$out/share/permissionsync-cc/$s"
              done

              # Library scripts go to lib/ subdir — sourced only, NOT on PATH
              mkdir -p $out/share/permissionsync-cc/lib
              for s in ${builtins.concatStringsSep " " libraryScripts}; do
                cp "$src/lib/$s" "$out/share/permissionsync-cc/lib/$s"
              done

              mkdir -p $out/bin

              # Executable scripts get wrapped with runtime deps on PATH and lib dir
              for s in ${builtins.concatStringsSep " " executableScripts}; do
                cp "$src/$s" "$out/bin/$s"
                chmod +x "$out/bin/$s"
                wrapProgram "$out/bin/$s" \
                  --prefix PATH : "${pkgs.lib.makeBinPath runtimeDeps}" \
                  --set PERMISSIONSYNC_LIB_DIR "$out/share/permissionsync-cc/lib"
              done

              # Generate base settings from claude-baseline readonly tiers
              ${pkgs.bash}/bin/bash $src/generate-base-settings.sh \
                "${inputs.claude-baseline}" \
                "$out/share/permissionsync-cc/base-settings.json"

              # Patch permissionsync-setup.sh to find raw scripts in share/
              sed -i 's|PERMISSIONSYNC_SHARE_DIR=.*|PERMISSIONSYNC_SHARE_DIR="'"$out"'/share/permissionsync-cc"|' \
                "$out/bin/.permissionsync-setup.sh-wrapped"

              runHook postInstall
            '';

            meta = {
              description = "Log and sync Claude Code permission approvals";
              license = pkgs.lib.licenses.mit;
              mainProgram = "permissionsync-setup.sh";
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

              # Generate base-settings.json for test-baseline.sh
              ${pkgs.bash}/bin/bash generate-base-settings.sh \
                "${inputs.claude-baseline}" \
                base-settings.json

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
