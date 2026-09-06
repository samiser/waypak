# builds the waypak launcher with the given policies baked in
{
  pkgs,
  way-secure,
  engine,
  apps,
  defaultPolicy,
}:
let
  lib = pkgs.lib;
  seccompLib = pkgs.callPackage ../pkgs/seccomp-filters.nix { };
  # picked files are handed over through the document portal
  mkFilter =
    policy:
    lib.concatStringsSep " " (
      map (n: "--talk=${n}") (policy.talk or [ ])
      ++ map (n: "--own=${n}") (policy.own or [ ])
      ++ lib.optional (usesPortal policy) "--talk=org.freedesktop.portal.Documents"
    );
  mkBinds = app: lib.concatMapStringsSep " " (p: ''--bind "${p}" "${p}"'') (app.binds or [ ]);
  mkRoBinds =
    app: lib.concatMapStringsSep " " (p: ''--ro-bind-try "${p}" "${p}"'') (app.roBinds or [ ]);
  usesPortal = app: lib.elem "org.freedesktop.portal.Desktop" (app.talk or [ ]);
  flag = v: if v then "1" else "";
  netVal =
    app:
    let
      v = app.net or false;
    in
    if v == true then
      "1"
    else if v == false then
      ""
    else
      v;
  seccompFile =
    app:
    lib.optionalString (app.seccomp or true) "${seccompLib.mkFilter {
      syscalls = seccompLib.baseSyscalls ++ (app.extraSeccomp or [ ]);
      denyUserns = !(app.userns or true);
    }}";
  # commands and app shell-outs need bash and coreutils
  closureRoots =
    app:
    [
      app.package
      pkgs.bash
      pkgs.coreutils
    ]
    ++ map (d: pkgs.${d}) (lib.concatMap (c: c.deps) (lib.attrValues (app.commands or { })))
    ++ lib.optional (usesPortal app) pkgs.flatpak-xdg-utils
    ++ (app.closureExtra or [ ]);
  closureFile =
    app:
    lib.optionalString ((app ? package) && (app.storeClosure or false)) (
      pkgs.writeClosure (closureRoots app)
    );
  # bwrap execs inside the scope, so it is confined too
  confineRoots =
    app:
    lib.optionalString ((app ? package) && (app.closured or false)) (
      toString (closureRoots app ++ [ pkgs.bubblewrap ])
    );
  mkPolicy =
    app:
    lib.concatStringsSep "\n    " [
      ''dbus_filter="${mkFilter app}"''
      ''app_path="${lib.optionalString (app ? package) "${app.package}/bin"}"''
      "extra_binds=(${mkBinds app})"
      "ro_binds=(${mkRoBinds app})"
      ''net="${netVal app}" gpu=${flag (app.gpu or false)} audio=${flag (app.audio or false)}''
      "portal=${flag (usesPortal app)}"
      ''seccomp_file="${seccompFile app}"''
      ''closure_file="${closureFile app}"''
      ''confine_roots="${confineRoots app}"''
    ];
  mkCase = name: app: "  ${name})\n    ${mkPolicy app}\n    ;;\n";
  policyCases = lib.concatStrings (lib.mapAttrsToList mkCase apps ++ [ (mkCase "*" defaultPolicy) ]);
in
pkgs.writeShellScriptBin "waypak" ''
  set -eu
  app_id=""
  sandbox=""
  while [ $# -gt 0 ]; do
    case $1 in
      -a) app_id=$2; shift 2 ;;
      -s) sandbox=1; shift ;;
      *) break ;;
    esac
  done
  if [ $# -lt 1 ]; then
    echo "usage: waypak [-a app-id] [-s] <command...>" >&2
    exit 1
  fi
  [ -n "$app_id" ] || app_id=''${1##*/}

  sock="$XDG_RUNTIME_DIR/waypak-$app_id-$$"
  bus_proxy="$XDG_RUNTIME_DIR/waypak-bus-$app_id-$$"
  fifo=$(${pkgs.coreutils}/bin/mktemp -u)
  ${pkgs.coreutils}/bin/mkfifo "$fifo"

  cleanup() {
    [ -n "''${app_pid:-}" ] && kill "$app_pid" 2>/dev/null || true
    [ -n "''${ws_pid:-}" ] && kill "$ws_pid" 2>/dev/null || true
    [ -n "''${proxy_pid:-}" ] && kill "$proxy_pid" 2>/dev/null || true
    rm -f "$sock" "$bus_proxy" "$fifo"
    [ -n "''${info_fifo:-}" ] && rm -f "$info_fifo" "$block_fifo" || true
    [ -n "''${flatpak_info:-}" ] && rm -f "$flatpak_info" || true
  }
  trap cleanup EXIT INT TERM
  # a foreground child would block signal delivery and skip cleanup
  run_and_wait() {
    "$@" &
    app_pid=$!
    rc=0
    wait "$app_pid" || rc=$?
    exit $rc
  }

  ${way-secure}/bin/way-secure \
    --socket-path "$sock" \
    -e ${engine} -a "$app_id" -i "$app_id-$$" \
    -r 3 3> "$fifo" &
  ws_pid=$!

  # way-secure writes to fd 3 once the context is committed
  read -r _ < "$fifo" || true
  kill -0 "$ws_pid" 2>/dev/null || {
    echo "waypak: way-secure failed" >&2
    exit 1
  }

  if [ -z "$sandbox" ]; then
    rm -f "$fifo"
    WAYLAND_DISPLAY=''${sock##*/} run_and_wait "$@"
  fi

  rm -f "$fifo"
  case $app_id in
  ${policyCases}esac
  proxy=( ${pkgs.xdg-dbus-proxy}/bin/xdg-dbus-proxy )
  # portals resolve the calling app id from /.flatpak-info in the proxy's
  # mount namespace, so the proxy gets its own bwrap carrying that file
  if [ -n "$portal" ]; then
    flatpak_info="$XDG_RUNTIME_DIR/waypak-info-$app_id-$$"
    printf '[Application]\nname=%s\n\n[Instance]\ninstance-id=%s\n' \
      "$app_id" "$app_id-$$" > "$flatpak_info"
    proxy=(
      ${pkgs.bubblewrap}/bin/bwrap --die-with-parent
      --ro-bind /nix /nix --bind "$XDG_RUNTIME_DIR" "$XDG_RUNTIME_DIR"
      --proc /proc --dev /dev
      --ro-bind "$flatpak_info" /.flatpak-info
      "''${proxy[@]}"
    )
  fi
  # the proxy exits when its --fd closes, so hold fd 4 for the app's lifetime
  fifo2=$(${pkgs.coreutils}/bin/mktemp -u)
  ${pkgs.coreutils}/bin/mkfifo "$fifo2"
  "''${proxy[@]}" \
    "''${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}" \
    "$bus_proxy" --filter $dbus_filter --fd=3 3> "$fifo2" &
  proxy_pid=$!
  exec 4< "$fifo2"
  rm -f "$fifo2"
  read -r -N1 -u4 _ || true
  kill -0 "$proxy_pid" 2>/dev/null || {
    echo "waypak: xdg-dbus-proxy failed" >&2
    exit 1
  }

  app_home="$HOME/.local/share/waypak/$app_id"
  # a fresh /tmp each launch would break chromium's single-instance socket
  mkdir -p "$app_home" "$app_home/.tmp"
  opts=(
    --unshare-all --die-with-parent
    --proc /proc --dev /dev --bind "$app_home/.tmp" /tmp
    --tmpfs "$XDG_RUNTIME_DIR"
    --bind "$sock" "$XDG_RUNTIME_DIR/wayland-0"
    --bind "$bus_proxy" "$XDG_RUNTIME_DIR/bus"
    --bind "$app_home" "$HOME"
    --chdir "$HOME"
    --setenv WAYLAND_DISPLAY wayland-0
    --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$XDG_RUNTIME_DIR/bus"
    --unsetenv DISPLAY --unsetenv UMBRIEL_SOCKET
  )
  if [ -n "$closure_file" ]; then
    path="${
      lib.makeBinPath [
        pkgs.bash
        pkgs.coreutils
      ]
    }"
    while IFS= read -r p; do
      opts+=( --ro-bind "$p" "$p" )
    done < "$closure_file"
  else
    path=$PATH
    opts+=( --ro-bind /nix /nix --ro-bind /run/current-system /run/current-system )
  fi
  # /etc/static backs the nixos /etc symlinks
  for f in static nsswitch.conf passwd group machine-id localtime zoneinfo fonts; do
    opts+=( --ro-bind-try "/etc/$f" "/etc/$f" )
  done
  if [ "$net" = 1 ]; then
    opts+=( --share-net )
    for f in resolv.conf hosts ssl pki; do
      opts+=( --ro-bind-try "/etc/$f" "/etc/$f" )
    done
  elif [ "$net" = isolated ]; then
    for f in hosts ssl pki; do
      opts+=( --ro-bind-try "/etc/$f" "/etc/$f" )
    done
    printf 'nameserver 169.254.1.1\n' > "$app_home/.resolv.conf"
    opts+=( --ro-bind "$app_home/.resolv.conf" /etc/resolv.conf )
  fi
  if [ -n "$gpu" ]; then
    opts+=(
      --ro-bind-try /etc/egl /etc/egl
      --dev-bind-try /dev/dri /dev/dri
      --ro-bind-try /sys/dev/char /sys/dev/char
      --ro-bind-try /sys/devices /sys/devices
      --ro-bind-try /sys/class /sys/class
      --ro-bind-try /sys/bus /sys/bus
      --ro-bind-try /run/opengl-driver /run/opengl-driver
      --ro-bind-try /run/opengl-driver-32 /run/opengl-driver-32
    )
    for dev in /dev/nvidia*; do
      [ -e "$dev" ] && opts+=( --dev-bind "$dev" "$dev" )
    done
  fi
  if [ -n "$audio" ]; then
    opts+=(
      --bind-try "$XDG_RUNTIME_DIR/pipewire-0" "$XDG_RUNTIME_DIR/pipewire-0"
      --bind-try "$XDG_RUNTIME_DIR/pulse" "$XDG_RUNTIME_DIR/pulse"
    )
  fi
  # extra_binds are (--bind, src, dst) triples whose sources must exist
  for ((i = 1; i < ''${#extra_binds[@]}; i += 3)); do
    mkdir -p "''${extra_binds[i]}"
  done
  opts+=( "''${extra_binds[@]}" "''${ro_binds[@]}" )
  if [ -n "$portal" ]; then
    path="${pkgs.flatpak-xdg-utils}/bin:$path"
    # the by-app view of the document portal makes picked files resolvable
    opts+=(
      --setenv GTK_USE_PORTAL 1
      --setenv FLATPAK_ID "$app_id"
      --ro-bind "$flatpak_info" /.flatpak-info
      --bind-try "$XDG_RUNTIME_DIR/doc/by-app/$app_id" "$XDG_RUNTIME_DIR/doc"
    )
  fi
  # raw binary first, so in-sandbox self-invocation skips the wrapper
  [ -n "$app_path" ] && path="$app_path:$path"
  opts+=( --setenv PATH "$path" )
  if [ -n "$seccomp_file" ]; then
    exec 9< "$seccomp_file"
    opts+=( --seccomp 9 )
  fi
  if [ "$net" = isolated ]; then
    info_fifo=$(${pkgs.coreutils}/bin/mktemp -u)
    block_fifo=$(${pkgs.coreutils}/bin/mktemp -u)
    ${pkgs.coreutils}/bin/mkfifo "$info_fifo" "$block_fifo"
    opts+=( --info-fd 8 --block-fd 7 )
  fi
  launch=( ${pkgs.bubblewrap}/bin/bwrap "''${opts[@]}" )
  # confine must land on the scope's cgroup before bwrap execs
  if [ -n "$confine_roots" ]; then
    export WAYPAK_APP_ID="$app_id" WAYPAK_CONFINE_ROOTS="$confine_roots"
    launch=(
      ${pkgs.systemd}/bin/systemd-run --user --scope --quiet --collect
      --unit "waypak-$app_id-$$" --
      ${pkgs.runtimeShell} -c '
        if command -v closured >/dev/null 2>&1; then
          closured confine --label "$WAYPAK_APP_ID" $WAYPAK_CONFINE_ROOTS ||
            echo "waypak: closured confine failed, continuing unconfined" >&2
        else
          echo "waypak: closured not on PATH, continuing unconfined" >&2
        fi
        exec "$@"' - "''${launch[@]}"
    )
  fi
  if [ "$net" = isolated ]; then
    # bwrap parks the app on the block fd until pasta configures the namespace
    "''${launch[@]}" "$@" 8> "$info_fifo" 7<> "$block_fifo" &
    app_pid=$!
    child_pid=$(${pkgs.gnused}/bin/sed -n 's/.*"child-pid": *\([0-9]*\).*/\1/p' "$info_fifo")
    rm -f "$info_fifo"
    [ -n "$child_pid" ] || {
      echo "waypak: bwrap reported no child pid" >&2
      exit 1
    }
    ${pkgs.passt}/bin/pasta --config-net --no-map-gw --dns-forward 169.254.1.1 --quiet "$child_pid"
    printf x > "$block_fifo"
    rm -f "$block_fifo"
    rc=0
    wait "$app_pid" || rc=$?
    exit $rc
  fi
  run_and_wait "''${launch[@]}" "$@"
''
