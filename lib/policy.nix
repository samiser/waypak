{ lib, ... }:
{
  options = {
    package = lib.mkOption {
      type = lib.types.package;
      description = "package whose binaries are wrapped to run sandboxed";
    };
    talk = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "session bus names the app may call";
    };
    own = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "session bus names the app may claim";
    };
    net = lib.mkOption {
      type = lib.types.either lib.types.bool (lib.types.enum [ "isolated" ]);
      default = false;
      description = "true shares the host network namespace, false unshares it, \"isolated\" is a private namespace with internet via pasta (localhost and abstract sockets unreachable)";
    };
    seccomp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "apply the baseline seccomp filter (kernel keyring, ptrace, tty ioctl injection and more)";
    };
    extraSeccomp = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "extra syscall names to deny on top of the baseline, ignored when seccomp is false";
    };
    userns = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "allow nested user namespaces; chromium/electron sandboxes need them, disable for everything else";
    };
    storeClosure = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "bind only the app's closure instead of /nix and /run/current-system";
    };
    closured = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "deny execs outside the app's closure via a closured cgroup confinement; warns and continues if the closured daemon is not running";
    };
    closureExtra = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "extra packages folded into the app's closure for storeClosure and closured";
    };
    clearenv = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "clear the environment and pass only a safe allowlist (locale, term, home) so host env-var secrets do not leak into the sandbox";
    };
    binds = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "extra paths bind-mounted read-write into the sandbox; shell vars expand at launch";
    };
    roBinds = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "extra paths bind-mounted read-only into the sandbox; missing paths are skipped";
    };
    gpu = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "expose gpu devices, /sys and gl drivers";
    };
    audio = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "expose pipewire and pulse sockets";
    };
    waylandGlobals = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "privileged wayland globals the compositor should still offer this app";
    };
    commands = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            cmd = lib.mkOption {
              type = lib.types.str;
              description = "shell command run inside the app's sandbox; must stay in the foreground";
            };
            deps = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [ ];
              description = "packages put on the command's PATH and folded into the app's closure";
            };
          };
        }
      );
      default = { };
      description = "extra entrypoints installed as `<app>-<name>` bins";
    };
  };
}
