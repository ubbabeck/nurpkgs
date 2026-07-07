{ pkgs, nix-bitcoin, ... }:

let
  # clnrest REST server, as configured by the clnrest plugin below.
  CLNREST_PORT = 3010;

  # nix-bitcoin runs clightning against the "regtest" bitcoin network, so the
  # network data dir (rune + TLS cert live here) is dataDir/regtest.
  networkDir = "/var/lib/clightning/regtest";
  runePath = "${networkDir}/admin-rune";
  clnCaCertPath = "${networkDir}/ca.pem";

  # ln-service listens here (settings.local_server default).
  lnServicePort = 8080;

  # API key used to add an LNURL-pay identifier via the protected API. Stored
  # in the store only because this is a test VM; real deployments use a secret.
  apiKey = "test-api-key";
  apiKeyFile = pkgs.writeText "ln-service-api-key" apiKey;
in
{
  name = "ln-service";
  nodes.machine =
    { config, lib, ... }:
    {
      imports = [
        nix-bitcoin.nixosModules.default
        ../nixos-modules/ln-service/default.nix
      ];
      virtualisation.cores = 2;
      virtualisation.memorySize = 2048;

      # Don't pin nixpkgs; use the flake's nixpkgs for nix-bitcoin packages too.
      nix-bitcoin.useVersionLockedPkgs = false;
      # Auto-generate node secrets (RPC passwords etc.) for the test VM.
      nix-bitcoin.generateSecrets = true;

      services.bitcoind.regtest = true;

      services.clightning = {
        enable = true;
        plugins.clnrest = {
          enable = true;
          port = CLNREST_PORT;
          # Writes an admin rune to ${networkDir}/admin-rune at service start.
          createAdminRune = true;
        };
      };

      services.ln-service = {
        enable = true;
        # The rune and CA cert live in clightning's private data dir; systemd
        # LoadCredential reads them as root when ln-service starts (after
        # clightning), so the hardened DynamicUser service can use them.
        coreLightningRuneFile = runePath;
        coreLightningCertFile = clnCaCertPath;
        inherit apiKeyFile;
        settings = {
          callback_domain = "example.com";
          cln_conf.cln_rest_url = "127.0.0.1:${toString CLNREST_PORT}";
        };
      };

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      # ln-service reads the rune and cert from clightning's runtime dir via
      # LoadCredential, so it must start only once clightning has written them.
      systemd.services.ln-service-daemon = {
        after = [ "clightning.service" ];
        requires = [ "clightning.service" ];
      };
    };

  testScript = ''
    import json

    start_all()

    machine.wait_for_unit("bitcoind.service")
    machine.wait_for_unit("clightning.service")

    # clnrest generates the admin rune and TLS cert in postStart; wait for both.
    machine.wait_for_file("${runePath}")
    machine.wait_for_file("${clnCaCertPath}")
    machine.wait_for_open_port(${toString CLNREST_PORT})

    # ln-service is ordered after clightning, so it starts once the rune exists.
    machine.wait_for_unit("ln-service-daemon.service")
    machine.wait_for_open_port(${toString lnServicePort})

    # The runtime config must have the rune substituted in (not the placeholder).
    config = machine.succeed("cat /run/ln-service/config.toml")
    print("ln-service config:\n" + config)
    assert "@RUNE@" not in config, "rune placeholder was not substituted"
    assert "@API_KEY@" not in config, "api_key placeholder was not substituted"

    base = "http://127.0.0.1:${toString lnServicePort}"

    # Health endpoint should be up.
    machine.succeed(f"curl -fsS {base}/health")

    # Register an LNURL-pay identifier via the protected (api-key) endpoint.
    machine.succeed(
        f"curl -fsS -X POST {base}/protected/add-identifier "
        f"-H 'Authorization: Bearer ${apiKey}' "
        "-H 'Content-Type: application/json' "
        "--data '{\"identifier\":\"alice\"}'"
    )

    # LNURL-pay request returns the callback used to request an invoice.
    lnurlp = json.loads(
        machine.succeed(f"curl -fsS {base}/.well-known/lnurlp/alice")
    )
    print("lnurlp response:", lnurlp)
    assert lnurlp["tag"] == "payRequest", lnurlp
    callback = lnurlp["callback"]

    # The callback host is the (cosmetic) callback_domain; hit the local server
    # instead, reusing the registered hash from the lnurlp call above. This
    # drives ln-service -> clnrest (rune + pinned CA cert) -> clightning, which
    # mints a real bolt11 invoice.
    path = callback.split("/get-invoice/", 1)[1]
    invoice = json.loads(
        machine.succeed(f"curl -fsS '{base}/get-invoice/{path}?amount=100000'")
    )
    print("invoice response:", invoice)
    assert invoice["pr"].startswith("lnbcrt"), invoice
  '';
}
