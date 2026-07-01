{
  config,
  lib,
  pkgs,
  ...
}:

let
  pkg = (pkgs.callPackage ../.. { }).ln-service;
  cfg = config.services.ln-service;

in
{
  options = {
    services.ln-service = {
      enable = lib.mkEnableOption "ln-service";
    };

    databaseName = lib.mkOption {
      type = lib.types.str;
      default = "db";
      example = "db";
      description = "Name of the sqlite database for the users";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:8080";
      description = "Address the server listens on";
    };

    coreLightningRune = lib.mkOption {
      type = lib.types.str;
      default = null;
      description = "Core lighting rune to communicate with the core lightning node";
    };

    coreLightningHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Core Lightning server host";
    };

  };

  config = lib.mkIf cfg.enable {
    users = {
      users.lnservice = {
        isSystemUser = true;
        group = "lnservice";
      };
      groups.lnservice = { };
    };
  };

  systemd.serives.ln-service-daemon = {
    description = "ln service daemon";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants =["network-online.target"];
    startLimitIntervalSec = 120;

  };
}
