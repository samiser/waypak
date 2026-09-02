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
  mkFilter =
    policy:
    lib.concatStringsSep " " (
      map (n: "--talk=${n}") (policy.talk or [ ]) ++ map (n: "--own=${n}") (policy.own or [ ])
    );
  mkBinds = app: lib.concatMapStringsSep " " (p: ''--bind "${p}" "${p}"'') (app.binds or [ ]);
  mkRoBinds = app: lib.concatMapStringsSep " " (p: ''--ro-bind-try "${p}" "${p}"'') (app.roBinds or [ ]);
  usesPortal = app: lib.elem "org.freedesktop.portal.Desktop" (app.talk or [ ]);
  flag = v: if v then "1" else "";
  mkCase = name: app: ''
    ${name})
      dbus_filter="${mkFilter app}"
      app_path="${lib.optionalString (app ? package) "${app.package}/bin"}"
      extra_binds=(${mkBinds app})
      ro_binds=(${mkRoBinds app})
      net=${flag (app.net or true)} gpu=${flag (app.gpu or false)} audio=${flag (app.audio or false)}
      portal=${flag (usesPortal app)}
      ;;
  '';
  policyCases = lib.concatStrings (lib.mapAttrsToList mkCase apps);
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
  }
  trap cleanup EXIT INT TERM
  # run the app in the background and wait: a foreground child would block
  # signal delivery, leaving the wrapper unkillable and cleanup never running
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

  # readiness: way-secure writes to fd 3 once the context is committed
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
    ${policyCases}*)
      dbus_filter="${mkFilter defaultPolicy}"
      app_path="" extra_binds=() ro_binds=()
      net=1 gpu="" audio="" portal=${flag (usesPortal defaultPolicy)}
      ;;
  esac
  # the proxy exits when its --fd closes, so hold fd 4 for the app's lifetime
  fifo2=$(${pkgs.coreutils}/bin/mktemp -u)
  ${pkgs.coreutils}/bin/mkfifo "$fifo2"
  ${pkgs.xdg-dbus-proxy}/bin/xdg-dbus-proxy \
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
  # /tmp persists per app: chromium's single-instance socket lives there,
  # and a fresh tmpfs each launch makes concurrent launches corrupt the profile
  mkdir -p "$app_home" "$app_home/.tmp"
  opts=(
    --unshare-all --die-with-parent
    --proc /proc --dev /dev --bind "$app_home/.tmp" /tmp
    --ro-bind /nix /nix
    --ro-bind /run/current-system /run/current-system
    --tmpfs "$XDG_RUNTIME_DIR"
    --bind "$sock" "$XDG_RUNTIME_DIR/wayland-0"
    --bind "$bus_proxy" "$XDG_RUNTIME_DIR/bus"
    --bind "$app_home" "$HOME"
    --chdir "$HOME"
    --setenv WAYLAND_DISPLAY wayland-0
    --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$XDG_RUNTIME_DIR/bus"
    --unsetenv DISPLAY --unsetenv UMBRIEL_SOCKET
  )
  # /etc is cherry-picked, not bound wholesale; /etc/static backs the
  # nixos symlinks
  for f in static nsswitch.conf passwd group machine-id localtime zoneinfo fonts; do
    opts+=( --ro-bind-try "/etc/$f" "/etc/$f" )
  done
  if [ -n "$net" ]; then
    opts+=( --share-net )
    for f in resolv.conf hosts ssl pki; do
      opts+=( --ro-bind-try "/etc/$f" "/etc/$f" )
    done
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
  # extra_binds triples are (--bind, src, dst); create sources, mount over app home
  for ((i = 1; i < ''${#extra_binds[@]}; i += 3)); do
    mkdir -p "''${extra_binds[i]}"
  done
  opts+=( "''${extra_binds[@]}" "''${ro_binds[@]}" )
  # app_path makes in-sandbox self-invocation hit the raw binary instead of
  # re-entering the wrapper; the xdg-open shim routes urls through the OpenURI
  # portal so they open on the host; GTK_USE_PORTAL gives host file pickers
  path=$PATH
  if [ -n "$portal" ]; then
    path="${pkgs.flatpak-xdg-utils}/bin:$path"
    opts+=( --setenv GTK_USE_PORTAL 1 )
  fi
  [ -n "$app_path" ] && path="$app_path:$path"
  opts+=( --setenv PATH "$path" )
  run_and_wait ${pkgs.bubblewrap}/bin/bwrap "''${opts[@]}" "$@"
''
