# turns a flatpak manifest (attrset or json path) into a waypak profile
{ lib }:
manifest:
let
  m = if lib.isAttrs manifest then manifest else builtins.fromJSON (builtins.readFile manifest);
  args = m.finish-args or [ ];
  vals = prefix: map (lib.removePrefix prefix) (lib.filter (lib.hasPrefix prefix) args);
  sockets = vals "--socket=";
  devices = vals "--device=";
  xdgDirs = {
    xdg-desktop = "$HOME/Desktop";
    xdg-documents = "$HOME/Documents";
    xdg-download = "$HOME/Downloads";
    xdg-music = "$HOME/Music";
    xdg-pictures = "$HOME/Pictures";
    xdg-videos = "$HOME/Videos";
  };
  # home/host grants are dropped because binding all of $HOME defeats the sandbox
  parseFs =
    raw:
    let
      ro = lib.hasSuffix ":ro" raw;
      p = lib.removeSuffix ":create" (lib.removeSuffix ":ro" (lib.removeSuffix ":rw" raw));
    in
    {
      inherit ro;
      path =
        xdgDirs.${p} or (
          if lib.hasPrefix "~/" p then
            "$HOME/" + lib.removePrefix "~/" p
          else if lib.hasPrefix "/" p then
            p
          else
            null
        );
    };
  fs = lib.filter (f: f.path != null) (map parseFs (vals "--filesystem="));
in
{
  talk = vals "--talk-name=";
  own = vals "--own-name=";
  net = lib.elem "network" (vals "--share=");
  audio = lib.elem "pulseaudio" sockets;
  gpu = lib.elem "dri" devices || lib.elem "all" devices;
  binds = map (f: f.path) (lib.filter (f: !f.ro) fs);
  roBinds = map (f: f.path) (lib.filter (f: f.ro) fs);
}
