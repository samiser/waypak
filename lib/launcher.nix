{
  pkgs,
  way-secure,
  engine,
}:
{ name, policy }:
let
  inherit (pkgs) lib;

  seccompLib = pkgs.callPackage ../pkgs/seccomp-filters.nix { };
  portal = lib.elem "org.freedesktop.portal.Desktop" policy.talk;
  isolated = policy.net == "isolated";
  when = lib.optional;
  q = s: ''"${s}"'';

  commandDeps = lib.concatMap (c: c.deps) (lib.attrValues policy.commands);
  onPath = [ policy.package ] ++ commandDeps ++ when portal pkgs.flatpak-xdg-utils;
  base = [
    pkgs.bash
    pkgs.coreutils
  ];
  closureRoots = onPath ++ base ++ policy.closureExtra;
  path = "${lib.makeBinPath onPath}:${if policy.storeClosure then lib.makeBinPath base else "$PATH"}";

  seccompFile = seccompLib.mkFilter {
    syscalls = seccompLib.baseSyscalls ++ policy.extraSeccomp;
    denyUserns = !policy.userns;
  };

  flatpakInfo =
    lib.concatStringsSep "\\n" (
      [
        "[Application]"
        "name=%s"
        ""
        "[Instance]"
        "instance-id=%s"
      ]
      ++ lib.optionals (policy.net == true) [
        ""
        "[Context]"
        "shared=network;"
      ]
    )
    + "\\n";
  bwrapInfo = ''"$instance_dir/bwrapinfo.json"'';
  cleanupRm = [
    "rm -f ${
      toString (
        [
          ''"$sock"''
          ''"$bus_proxy"''
          ''"$fifo"''
        ]
        ++ when portal ''"$flatpak_info"''
        ++ when isolated ''"$info_fifo" "$block_fifo"''
      )
    }"
  ]
  ++ when portal ''rm -rf "$instance_dir"'';
  infoRedirect =
    if isolated then
      " 8> \"$info_fifo\" 7<> \"$block_fifo\""
    else if portal then
      " 8> ${bwrapInfo}"
    else
      "";

  proxy = lib.concatStringsSep " \\\n  " (
    lib.optionals portal [
      ''${pkgs.bubblewrap}/bin/bwrap --die-with-parent --ro-bind /nix /nix --bind "$XDG_RUNTIME_DIR" "$XDG_RUNTIME_DIR"''
      ''--proc /proc --dev /dev --ro-bind "$flatpak_info" /.flatpak-info''
    ]
    ++ [ "${pkgs.xdg-dbus-proxy}/bin/xdg-dbus-proxy" ]
  );
  proxyArgs = lib.concatStringsSep " " (
    [ "--filter" ]
    ++ map (n: "--talk=${n}") policy.talk
    ++ map (n: "--own=${n}") policy.own
    ++ when portal "--talk=org.freedesktop.portal.Documents"
    ++ [ "--fd=3" ]
  );

  etc = [
    "static"
    "nsswitch.conf"
    "passwd"
    "group"
    "machine-id"
    "localtime"
    "zoneinfo"
    "fonts"
  ]
  ++ lib.optionals (policy.net != false) [
    "hosts"
    "ssl"
    "pki"
  ]
  ++ when (policy.net == true) "resolv.conf";

  envAllow = [
    "LANG"
    "LANGUAGE"
    "LC_ALL"
    "LC_CTYPE"
    "LC_NUMERIC"
    "LC_TIME"
    "LC_COLLATE"
    "LC_MONETARY"
    "LC_MESSAGES"
    "LC_PAPER"
    "LC_NAME"
    "LC_ADDRESS"
    "LC_TELEPHONE"
    "LC_MEASUREMENT"
    "LC_IDENTIFICATION"
    "LOCALE_ARCHIVE"
    "TERM"
    "TZ"
    "USER"
    "LOGNAME"
    "XDG_CURRENT_DESKTOP"
    "XDG_SESSION_TYPE"
    "XDG_SESSION_DESKTOP"
  ];

  bwrapOpts = lib.concatStringsSep "\n  " (
    [ "--unshare-all --die-with-parent" ]
    ++ when policy.clearenv "--clearenv"
    ++ [
      ''--proc /proc --dev /dev --bind "$app_home/.tmp" /tmp''
      ''--tmpfs "$XDG_RUNTIME_DIR"''
      ''--bind "$sock" "$XDG_RUNTIME_DIR/wayland-0"''
      ''--bind "$bus_proxy" "$XDG_RUNTIME_DIR/bus"''
      ''--bind "$app_home" "$HOME" --chdir "$HOME"''
      "--setenv WAYLAND_DISPLAY wayland-0"
      ''--setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$XDG_RUNTIME_DIR/bus"''
      "--unsetenv DISPLAY --unsetenv UMBRIEL_SOCKET"
      ''--setenv PATH "${path}"''
    ]
    ++ when policy.clearenv ''--setenv HOME "$HOME" --setenv XDG_RUNTIME_DIR "$XDG_RUNTIME_DIR"''
    ++ when (
      !policy.storeClosure
    ) "--ro-bind /nix /nix --ro-bind /run/current-system /run/current-system"
    ++ map (f: "--ro-bind-try /etc/${f} /etc/${f}") etc
    ++ when (policy.net == true) "--share-net"
    ++ when isolated ''--ro-bind "$app_home/.resolv.conf" /etc/resolv.conf''
    ++ lib.optionals policy.gpu [
      "--ro-bind-try /etc/egl /etc/egl"
      "--dev-bind-try /dev/dri /dev/dri"
      "--ro-bind-try /sys/dev/char /sys/dev/char"
      "--ro-bind-try /sys/devices /sys/devices"
      "--ro-bind-try /sys/class /sys/class"
      "--ro-bind-try /sys/bus /sys/bus"
      "--ro-bind-try /run/opengl-driver /run/opengl-driver"
      "--ro-bind-try /run/opengl-driver-32 /run/opengl-driver-32"
    ]
    ++ lib.optionals policy.audio [
      ''--bind-try "$XDG_RUNTIME_DIR/pipewire-0" "$XDG_RUNTIME_DIR/pipewire-0"''
      ''--bind-try "$XDG_RUNTIME_DIR/pulse" "$XDG_RUNTIME_DIR/pulse"''
    ]
    ++ map (p: "--bind ${q p} ${q p}") policy.binds
    ++ map (p: "--ro-bind-try ${q p} ${q p}") policy.roBinds
    ++ lib.optionals portal [
      ''--setenv GTK_USE_PORTAL 1 --setenv FLATPAK_ID "$flatpak_id"''
      ''--ro-bind "$flatpak_info" /.flatpak-info''
      ''--bind-try "$XDG_RUNTIME_DIR/doc/by-app/$flatpak_id" "$XDG_RUNTIME_DIR/doc"''
    ]
    ++ when policy.seccomp "--seccomp 9"
    ++ when (portal || isolated) "--info-fd 8"
    ++ when isolated "--block-fd 7"
  );

  script = lib.flatten [
    ''
      set -eu
      app_id=${lib.escapeShellArg name}
      app_home="$HOME/.local/share/waypak/$app_id"
      sock="$XDG_RUNTIME_DIR/waypak-$app_id-$$"
      bus_proxy="$XDG_RUNTIME_DIR/waypak-bus-$app_id-$$"
      fifo=$(${pkgs.coreutils}/bin/mktemp -u)
    ''
    (when portal ''
      flatpak_id=${lib.escapeShellArg "org.waypak.${name}"}
      flatpak_info="$XDG_RUNTIME_DIR/waypak-info-$app_id-$$"
      instance_dir="$XDG_RUNTIME_DIR/.flatpak/$app_id-$$"
    '')
    (when isolated ''
      info_fifo=$(${pkgs.coreutils}/bin/mktemp -u)
      block_fifo=$(${pkgs.coreutils}/bin/mktemp -u)
    '')
    ''

      cleanup() {
        kill ''${app_pid:-} ''${ws_pid:-} ''${proxy_pid:-} 2>/dev/null || true
        ${lib.concatStringsSep "\n  " cleanupRm}
      }
      trap cleanup EXIT INT TERM

      ${pkgs.coreutils}/bin/mkfifo "$fifo"
      await() {
        local label=$1
        shift
        "$@" 3> "$fifo" &
        await_pid=$!
        exec 4< "$fifo"
        read -r -N1 -u 4 _ || true
        kill -0 "$await_pid" 2>/dev/null || {
          echo "waypak: $label failed" >&2
          exit 1
        }
      }

      await way-secure ${way-secure}/bin/way-secure \
        --socket-path "$sock" -e ${engine} -a "$app_id" -i "$app_id-$$" -r 3
      ws_pid=$await_pid
    ''
    (when portal ''

      printf '${flatpakInfo}' "$flatpak_id" "$app_id-$$" > "$flatpak_info"
      mkdir -p "$instance_dir"
    '')
    ''

      await xdg-dbus-proxy ${proxy} \
        "''${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}" \
        "$bus_proxy" ${proxyArgs}
      proxy_pid=$await_pid

      mkdir -p ${toString ([ ''"$app_home/.tmp"'' ] ++ map q policy.binds)}
      opts=(
        ${bwrapOpts}
      )
    ''
    (when policy.clearenv ''
      for v in ${toString envAllow}; do
        [ -n "''${!v:-}" ] && opts+=( --setenv "$v" "''${!v}" )
      done
    '')
    (when policy.storeClosure ''
      while IFS= read -r p; do
        opts+=( --ro-bind "$p" "$p" )
      done < ${pkgs.writeClosure closureRoots}
    '')
    (when policy.gpu ''
      for dev in /dev/nvidia*; do
        [ -e "$dev" ] && opts+=( --dev-bind "$dev" "$dev" )
      done
    '')
    (when policy.seccomp ''
      exec 9< ${seccompFile}
    '')
    (when isolated ''
      printf 'nameserver 169.254.1.1\n' > "$app_home/.resolv.conf"
      ${pkgs.coreutils}/bin/mkfifo "$info_fifo" "$block_fifo"
    '')
    ''

      launch=( ${pkgs.bubblewrap}/bin/bwrap "''${opts[@]}" )
    ''
    (when policy.closured ''
      launch=(
        ${pkgs.systemd}/bin/systemd-run --user --scope --quiet --collect
        --unit "waypak-$app_id-$$" --
        ${pkgs.runtimeShell} -c '
          if command -v closured >/dev/null 2>&1; then
            closured confine --label "$1" $2 ||
              echo "waypak: closured confine failed, continuing unconfined" >&2
          else
            echo "waypak: closured not on PATH, continuing unconfined" >&2
          fi
          shift 2
          exec "$@"' - "$app_id" ${
            lib.escapeShellArg (toString (closureRoots ++ [ pkgs.bubblewrap ]))
          } "''${launch[@]}"
      )
    '')
    ''
      "''${launch[@]}" "$@"${infoRedirect} &
      app_pid=$!
    ''
    (when (isolated && portal) ''
      ${pkgs.coreutils}/bin/cat "$info_fifo" > ${bwrapInfo}
    '')
    (when isolated ''
      child_pid=$(${pkgs.gnused}/bin/sed -n 's/.*"child-pid": *\([0-9]*\).*/\1/p' ${
        if portal then bwrapInfo else ''"$info_fifo"''
      })
      [ -n "$child_pid" ] || {
        echo "waypak: bwrap reported no child pid" >&2
        exit 1
      }
      ${pkgs.passt}/bin/pasta --config-net --no-map-gw --dns-forward 169.254.1.1 --quiet "$child_pid"
      printf x > "$block_fifo"
    '')
    ''
      rc=0
      wait "$app_pid" || rc=$?
      exit $rc
    ''
  ];
in
pkgs.writeShellScriptBin "waypak-${name}" (lib.concatStrings script)
