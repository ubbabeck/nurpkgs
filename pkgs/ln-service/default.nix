{
  pkgs,
  lib,
  rustPlatform,
  ...
}:
rustPlatform.buildRustPackage rec {
  pname = "ln-service";
  name = pname;
  version = "1.0";

  src = pkgs.fetchFromGitHub {
    owner = "ubbabeck";
    repo = name;
    # fix-regression: callback registration + stdout logging.
    rev = "0d66838cc6d829a227a45805f7efda6f98274275";
    sha256 = "sha256-Q/3Pbn7W5Q+SW5iYCyq8sSCnwVpeys2e4G82BOAw8gk=";
  };

  cargoHash = "sha256-5HpfZ0fPI6Z6pK4MjfGnpr5b3Fw1LwWrsJ+Asn6tIcg=";

  # Run the crate's unit tests (mocked, hermetic) during the build.
  doCheck = true;

  nativeBuildInputs = with pkgs; [ pkg-config ] ++ lib.optionals pkgs.stdenv.isDarwin [ libiconv ];
  buildInputs = with pkgs; [
    sqlite
    openssl
  ];

  meta = {
    description = "Lnurl pay service";
    homepage = "https://github.com/ubbabeck/ln-service";
    license = lib.licenses.agpl3Only;
    mainProgram = name;
  };

}
