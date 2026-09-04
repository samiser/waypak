# compiles the default seccomp filters at build time; bwrap loads the raw
# bpf via --seccomp <fd>
{ runCommandCC, libseccomp }:
runCommandCC "waypak-seccomp-filters" { buildInputs = [ libseccomp ]; } ''
  mkdir -p $out
  $CC ${./seccomp-gen.c} -o gen -lseccomp
  ./gen > $out/default.bpf
  ./gen --deny-userns > $out/no-userns.bpf
''
