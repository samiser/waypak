# per-app policies:
#   talk/own = dbus names (call/claim)
#   net/gpu/audio = resource toggles
#   user-specific paths (binds) belong in host config.
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
    # tray: electron main is always pid 2 in the sandbox's pid namespace
    own = [ "org.freedesktop.StatusNotifierItem-2-1" ];
    audio = true;
    gpu = true; # screenshare needs dmabuf import
  };

  obsidian = {
    talk = [
      "org.freedesktop.Notifications"
      "org.freedesktop.portal.Desktop"
    ];
  };
}
