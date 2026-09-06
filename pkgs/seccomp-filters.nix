{
  runCommandCC,
  libseccomp,
  lib,
}:
rec {
  baseSyscalls = [
    "syslog"
    "uselib"
    "acct"
    "quotactl"
    "add_key"
    "keyctl"
    "request_key"
    "move_pages"
    "mbind"
    "get_mempolicy"
    "set_mempolicy"
    "migrate_pages"
    "ptrace"
    "perf_event_open"
  ];

  mkFilter =
    {
      syscalls ? baseSyscalls,
      denyUserns ? false,
    }:
    runCommandCC "waypak-seccomp${lib.optionalString denyUserns "-no-userns"}.bpf"
      { buildInputs = [ libseccomp ]; }
      ''
        $CC ${./seccomp-gen.c} -o gen -lseccomp
        ./gen ${lib.optionalString denyUserns "--deny-userns"} ${lib.escapeShellArgs syscalls} > $out
      '';
}
