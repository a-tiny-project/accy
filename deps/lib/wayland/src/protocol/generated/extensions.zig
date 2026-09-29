pub const version = "1.49";
pub const tag = "1.49";
pub const url = "https://gitlab.freedesktop.org/wayland/wayland-protocols";
pub const release_url = "https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/1.49/downloads/wayland-protocols-1.49.tar.xz";
pub const archive_sha256 = "ec4c8f74942d6dff7ace8b4ce4764f0ef9ff618a935d974ea77edee2ad240b14";
pub const license_sha256 = "f1a2b233e8a9a71c40f4aa885be08a0842ac85bb8588703c1dd7e6e6502e3124";
pub const oracle_tool = "wayland-scanner";
pub const oracle_version = "1.25.0";
pub const oracle_output_sha256 = "22fb9bd102cb3cd159c6ab23048e981ead8f3d889dae08df5d49c7a81134035a";
pub const oracle_signatures_sha256 = "80466dfabb0d310f8d0c0b5afccc167506320baa83723d23a792014354a54540";

pub const File = struct {
    name: []const u8,
    upstream_path: []const u8,
    sha256: []const u8,
};

pub const files = [_]File{
    .{ .name = "xdg-shell.xml", .upstream_path = "stable/xdg-shell/xdg-shell.xml", .sha256 = "7ba7f9c8473deee674cb1f154a18abd0bb0cc072604fc055b0c15e459fc4c7df" },
    .{ .name = "viewporter.xml", .upstream_path = "stable/viewporter/viewporter.xml", .sha256 = "dcb12279a03746301fe490aaed4b38a403485a925abfce2ccfceb644e104fe71" },
    .{ .name = "fractional-scale-v1.xml", .upstream_path = "staging/fractional-scale/fractional-scale-v1.xml", .sha256 = "5941de5d28f427ecdadddc8623a6f6af0a30b0ab4726847236ba7a7652b81316" },
    .{ .name = "xdg-decoration-unstable-v1.xml", .upstream_path = "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml", .sha256 = "68753c4a85a28659e3aa1fe0f138329a8bf3dff0b4789f4663a2c7fedbfecf2f" },
    .{ .name = "cursor-shape-v1.xml", .upstream_path = "staging/cursor-shape/cursor-shape-v1.xml", .sha256 = "bb57d91e53a79dadab7c612dab87c233393cee73673feefa7442cfbfdd9aed2f" },
    .{ .name = "presentation-time.xml", .upstream_path = "stable/presentation-time/presentation-time.xml", .sha256 = "dffac93bcb2bb1d8c385e72b8a8c2c0d4d79a336866322f3ba886dce2b27b1e2" },
    .{ .name = "ext-image-capture-source-v1.xml", .upstream_path = "staging/ext-image-capture-source/ext-image-capture-source-v1.xml", .sha256 = "4ef41d15e4cdb9f550158391358ceec724a6708b43b7efedec03121a6bb8458d" },
    .{ .name = "ext-image-copy-capture-v1.xml", .upstream_path = "staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml", .sha256 = "41a446653f788fabb404cab3168c0bd667c1ff4b54f1f0bb1e18810a1f47d73f" },
    .{ .name = "linux-dmabuf-v1.xml", .upstream_path = "stable/linux-dmabuf/linux-dmabuf-v1.xml", .sha256 = "2735bb4589cbb364dfcb6a821dd3abbf0c0257956b716b9691718ddfd453df4c" },
    .{ .name = "linux-drm-syncobj-v1.xml", .upstream_path = "staging/linux-drm-syncobj/linux-drm-syncobj-v1.xml", .sha256 = "5ede41a56eced6aa635caa7ab2996066bff9fd211620dbf9f73aafab740bec71" },
};
