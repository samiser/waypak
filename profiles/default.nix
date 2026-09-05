# user-specific paths (binds) belong in host config
{
  spotify = {
    talk = [ "org.freedesktop.Notifications" ];
    own = [ "org.mpris.MediaPlayer2.spotify" ];
    audio = true;
  };

  vesktop = {
    talk = [
      "org.freedesktop.Notifications"
      "org.freedesktop.portal.Desktop"
      "org.kde.StatusNotifierWatcher"
    ];
    # electron's main process is always pid 2 in the sandbox's pid namespace
    own = [ "org.freedesktop.StatusNotifierItem-2-1" ];
    audio = true;
    gpu = true; # screenshare needs dmabuf import
  };

  clipse = {
    net = false;
    userns = false; # a go tui has no chromium sandbox to nest
    storeClosure = true;
    waylandGlobals = [ "ext_data_control_manager_v1" ];
    # clipse -listen daemonises, which dies with the sandbox's pid namespace
    commands.listener = {
      cmd = "wl-paste --type text --watch clipse --wl-store & wl-paste --type image/png --watch clipse --wl-store & wait";
      deps = [ "wl-clipboard" ];
    };
  };

  obsidian = {
    talk = [
      "org.freedesktop.Notifications"
      "org.freedesktop.portal.Desktop"
    ];
  };
}
