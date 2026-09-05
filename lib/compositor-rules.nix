# maps waypak's neutral `waylandGrants` into a compositor's security-context
# config. umbriel and jay are the only compositors that expose per-app re-grants
{ lib }:
let
  # jay bundles globals into named capabilities
  jayCapability = {
    ext_data_control_manager_v1 = "data-control";
    zwlr_data_control_manager_v1 = "data-control";
    zwp_virtual_keyboard_manager_v1 = "virtual-keyboard";
    ext_foreign_toplevel_list_v1 = "foreign-toplevel-list";
    ext_idle_notifier_v1 = "idle-notifier";
    ext_session_lock_manager_v1 = "session-lock";
    zwlr_layer_shell_v1 = "layer-shell";
    ext_image_copy_capture_manager_v1 = "screencopy";
    zwlr_screencopy_manager_v1 = "screencopy";
    ext_transient_seat_manager_v1 = "seat-manager";
    wp_drm_lease_device_v1 = "drm-lease";
    zwp_input_method_manager_v2 = "input-method";
    ext_workspace_manager_v1 = "workspace-manager";
    zwlr_foreign_toplevel_manager_v1 = "foreign-toplevel-manager";
    zwlr_output_manager_v1 = "head-manager";
    zwlr_gamma_control_manager_v1 = "gamma-control-manager";
    zwlr_virtual_pointer_manager_v1 = "virtual-pointer";
  };
in
{
  # umbriel matches on regex, so engine and app id are escaped
  toUmbrielRules = map (g: {
    match = {
      sandbox_engine = lib.escapeRegex g.engine;
      app_id = lib.escapeRegex g.appId;
    };
    allow_globals = g.globals;
  });

  toJayClients = map (g: {
    match = {
      sandbox-engine = g.engine;
      sandbox-app-id = g.appId;
    };
    capabilities = lib.unique (map (n: jayCapability.${n}) g.globals);
  });
}
