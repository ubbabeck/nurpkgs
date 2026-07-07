{
  config,
  lib,
  pkgs,
  ...
}:

let
  pkg = (pkgs.callPackage ../.. { }).ln-service;
  cfg = config.services.ln-service;
  hardening = import ../hardening.nix;

  settingsFormat = pkgs.formats.toml { };

  # TOML has no null; a null-valued option means "leave the key unset", so drop
  # such keys (recursively) before generating the config.
  filterNulls = lib.filterAttrsRecursive (_: v: v != null);

  # Generated into the world-readable Nix store, so secrets (api_key, rune) are
  # left as @PLACEHOLDER@ tokens and substituted at runtime by ExecStartPre.
  configFile = settingsFormat.generate "config.toml" (filterNulls cfg.settings);
in
{
  options = {
    services.ln-service = {
      enable = lib.mkEnableOption "ln-service";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkg;
        defaultText = "pkgs.ln-service";
        description = "The ln-service package to use.";
      };

      coreLightningRuneFile = lib.mkOption {
        type = lib.types.path;
        example = "/run/keys/ln-service-rune";
        description = ''
          A file containing the Core Lightning rune used to authenticate with
          the Core Lightning REST (clnrest) node. Loaded via systemd
          credentials at runtime, keeping it out of the world-readable Nix
          store. Substituted into {option}`settings.cln_conf.rune`.
        '';
      };

      apiKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/keys/ln-service-key";
        description = ''
          A file containing the ln-service API key, used to add or remove
          users. Loaded via systemd credentials at runtime and substituted
          into {option}`settings.api_key`, keeping it out of the Nix store.

          Takes precedence over {option}`settings.api_key`.
        '';
      };

      coreLightningCertFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/keys/ln-service-ca-cert";
        description = ''
          The Core Lightning REST (clnrest) CA certificate. Loaded via systemd
          credentials at runtime and substituted into
          {option}`settings.cln_conf.ca_cert_path`.

          Use this when the certificate lives in a directory the hardened,
          {option}`DynamicUser` service cannot read directly (for example
          clightning's data dir). Takes precedence over
          {option}`settings.cln_conf.ca_cert_path`.
        '';
      };

      settings = lib.mkOption {
        type = lib.types.submodule {
          freeformType = settingsFormat.type;

          options = {
            local_server = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1:8080";
              description = "Address the server listens on.";
            };

            db_path = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/ln-service";
              description = ''
                Directory holding the sqlite database (ln-service creates
                `identifier.db` inside it).
              '';
            };

            callback_domain = lib.mkOption {
              type = lib.types.str;
              example = "example.com";
              description = "The domain used for the lnurl server.";
            };

            api_key = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = ''
                API key used to add or remove users.

                Warning: this value is stored in the world-readable Nix store.
                Use {option}`apiKeyFile` instead.
              '';
            };

            min_sendable = lib.mkOption {
              type = lib.types.ints.positive;
              default = 1000;
              description = "Minimum sendable amount in msats.";
            };

            max_sendable = lib.mkOption {
              type = lib.types.ints.positive;
              default = 100000000;
              description = "Maximum sendable amount in msats.";
            };

            cln_conf = {
              cln_rest_url = lib.mkOption {
                type = lib.types.str;
                default = "127.0.0.1:3010";
                description = "Core Lightning REST (clnrest) host.";
              };

              ca_cert_path = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Path to the Core Lightning REST CA certificate, readable by
                  the service. To load a cert from a directory the service
                  cannot reach, set {option}`coreLightningCertFile` instead.
                '';
              };
            };
          };
        };
        default = { };
        description = ''
          Configuration rendered to the ln-service TOML config file
          (`--conf`). Keys mirror the ln-service config format verbatim
          (snake_case); any key not listed above can still be set as freeform
          TOML.

          Secrets ({option}`apiKeyFile` and {option}`coreLightningRuneFile`)
          must not be set here, as this file is world-readable in the Nix
          store.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Secrets never touch the generated (world-readable) config: they are
    # written as tokens here and replaced from systemd credentials at runtime.
    # mkDefault so the api_key placeholder only applies when apiKeyFile is set,
    # letting an insecure inline settings.api_key still win if the user sets it.
    services.ln-service.settings = {
      cln_conf.rune = "@RUNE@";
      api_key = lib.mkIf (cfg.apiKeyFile != null) (lib.mkForce "@API_KEY@");
      # When a cert file is loaded via credentials, its real path is only known
      # at runtime; write a token that ExecStartPre rewrites to the credential.
      cln_conf.ca_cert_path = lib.mkIf (cfg.coreLightningCertFile != null) (lib.mkForce "@CA_CERT_PATH@");
    };

    systemd.services.ln-service-daemon = {
      description = "ln service daemon";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      startLimitIntervalSec = 120;

      serviceConfig =
        hardening.default
        // hardening.allowAllIPAddresses
        // {
          # Copy the generated config into the runtime dir and substitute
          # secrets from systemd credentials, keeping them out of the store.
          ExecStartPre = pkgs.writeShellScript "ln-service-config" ''
            set -euo pipefail
            umask 077
            conf="$RUNTIME_DIRECTORY/config.toml"
            install -m 0600 ${configFile} "$conf"
            ${lib.getExe pkgs.replace-secret} '@RUNE@' "$CREDENTIALS_DIRECTORY/rune" "$conf"
            ${lib.optionalString (cfg.apiKeyFile != null) ''
              ${lib.getExe pkgs.replace-secret} '@API_KEY@' "$CREDENTIALS_DIRECTORY/api_key" "$conf"
            ''}
            ${lib.optionalString (cfg.coreLightningCertFile != null) ''
              # Point ca_cert_path at the credential the service can read.
              ${pkgs.gnused}/bin/sed -i "s|@CA_CERT_PATH@|$CREDENTIALS_DIRECTORY/ca_cert|" "$conf"
            ''}
          '';
          # ln-service parses only the space-separated `--conf <PATH>` form.
          ExecStart = "${lib.getExe cfg.package} --conf %t/ln-service/config.toml";

          LoadCredential =
            [ "rune:${cfg.coreLightningRuneFile}" ]
            ++ lib.optional (cfg.apiKeyFile != null) "api_key:${cfg.apiKeyFile}"
            ++ lib.optional (cfg.coreLightningCertFile != null) "ca_cert:${cfg.coreLightningCertFile}";

          RuntimeDirectory = "ln-service";
          # db_path and logging_path default under /var/lib/ln-service.
          StateDirectory = "ln-service";
          DynamicUser = true;
        };
    };

    warnings = lib.optional (
      cfg.settings.api_key != "" && cfg.apiKeyFile == null
    ) "services.ln-service.settings.api_key is world-readable in the Nix store. Use services.ln-service.apiKeyFile instead.";
  };
}
