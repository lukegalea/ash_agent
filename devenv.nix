{ pkgs, lib, config, ... }:

let
  # Same OTP/Elixir pairing as the other Ash packages this one is used beside,
  # so the library is built against the combination the Ash ecosystem tests
  # against.
  beam = pkgs.beam.packages.erlang_27;
  stateDir = config.devenv.state;
in
{
  name = "ash_agent";

  languages.erlang = {
    enable = true;
    package = beam.erlang;
    lsp.enable = false;
  };

  languages.elixir = {
    enable = true;
    package = beam.elixir_1_18;
    lsp.enable = false;
  };

  packages = with pkgs; [
    git
    jq
  ];

  enterShell = ''
    # Cap open files at 65536, soft AND hard.
    #
    # ERTS raises its soft RLIMIT_NOFILE to the hard limit at boot and sizes its
    # fd and port tables from the result. Under a systemd user service the hard
    # limit is ~1.07e9, and every BEAM then reserves gigabytes before doing any
    # work. Lowering only the soft limit does nothing, because ERTS raises it
    # back.
    if [ "$(ulimit -Hn)" = unlimited ] || [ "$(ulimit -Hn)" -gt 65536 ]; then
      ulimit -n 65536
    fi

    # `services.postgres.port` is a request, not a guarantee: devenv moves the
    # cluster to a free port when the requested one is taken, rewrites
    # postgresql.conf, and leaves $PGPORT at the requested value. The config
    # file is authoritative, so read the port back from it when it exists.
    if [ -f "${stateDir}/postgres/postgresql.conf" ]; then
      _pgport="$(sed -n 's/^port = \([0-9]\+\).*/\1/p' "${stateDir}/postgres/postgresql.conf" | tail -n1)"
      [ -n "$_pgport" ] && export PGPORT="$_pgport"
      unset _pgport
    fi
  '';

  # The test host's database. CI uses a Postgres service container instead.
  services.postgres = {
    enable = true;
    package = pkgs.postgresql_16;
    listen_addresses = "127.0.0.1";
    port = 5452;
    initialDatabases = [
      { name = "ash_agent_test"; }
    ];
    initialScript = ''
      CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres';
    '';
  };
}
