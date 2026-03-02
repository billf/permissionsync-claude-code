{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.programs.permissionsync-cc;
in
{
  options.programs.permissionsync-cc = {
    enable = lib.mkEnableOption "permissionsync-cc permission sync hooks";
    package = lib.mkPackageOption pkgs "permissionsync-cc" { };
    mode = lib.mkOption {
      type = lib.types.enum [
        "log"
        "auto"
        "worktree"
      ];
      default = "worktree";
      description = "Permission handling mode: log (log-only), auto (auto-approve seen rules), worktree (auto + sibling worktree rules)";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
    home.activation.permissionsync = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${cfg.package}/bin/permissionsync-setup.sh ${cfg.mode}
    '';
  };
}
