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
      scripts = [
        "install.sh"
        "log-permission.sh"
        "log-permission-auto.sh"
        "sync-permissions.sh"
        "permissionsync-config.sh"
        "permissionsync-lib.sh"
      ];
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem = { config, self', inputs', pkgs, system, ... }:
        let
          runtimeDeps = [
            pkgs.jq
            pkgs.coreutils
            pkgs.gnused
            pkgs.gnugrep
            pkgs.diffutils
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
              mainProgram = "install.sh";
            };
          };

          checks.tests = pkgs.stdenvNoCC.mkDerivation {
            name = "permissionsync-cc-tests";
            src = inputs.self;
            nativeBuildInputs = [ pkgs.bash pkgs.jq ];
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
