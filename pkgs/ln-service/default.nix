{
  stdenv,
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
    rev = "v${version}";
    sha256 = "sha256-/KfrtdJxg0BGO+GcVGM3khfLrfVTMPN3vV3AaYtoUI8=";
  };

  cargoHash = "sha256-5HpfZ0fPI6Z6pK4MjfGnpr5b3Fw1LwWrsJ+Asn6tIcg=";

  nativeBuildInputs = with pkgs; [ pkg-config ] ++ lib.optionals pkgs.stdenv.isDarwin [ libiconv ];
  buildInputs = with pkgs; [
    sqlite
    openssl
  ];

  meta = {
    description = "Lnurl pay service";
    homepage = "https://github.com/ubbabeck/ln-service";
    license = lib.licenses.agpl3Only;
  };

}
