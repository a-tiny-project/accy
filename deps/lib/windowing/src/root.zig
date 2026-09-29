//! The package gives a program its own windows on the desktop: it opens and
//! closes them, delivers the keyboard, mouse and gamepad input aimed at them,
//! and shows the images the program draws, on macOS and on Linux under Wayland
//! or X11. A program that draws its own pixels needs a window from the host
//! system, the input events that reach that window, and a way to hand each
//! finished image to the display. The same program code should run on each of
//! those window systems, with the parts that differ kept out of its way, and a
//! program that runs for hours should keep its bookkeeping storage at the size
//! it had when the window opened.
//!
//! The three systems name and deliver windows, input and pixels in different
//! forms, so a shared API can carry only what every one of them can answer for,
//! and code that needs one system directly needs a way to reach it. Input can
//! arrive faster than a program reads it, and a queue whose size is fixed in
//! advance has to decide what happens to an event that finds it full. The
//! display takes a new image on its own schedule, so an image the program hands
//! over may have to wait. Copying the whole image for every small change costs
//! the bandwidth of the whole image, and a 3840 by 2160 image is about 33 MB.
//! Every storage size has to be known before the first window opens, so an
//! impossible size has to be refused before any window exists.
//!
//! The native window systems answer these problems each in its own way: Apple's
//! [AppKit](https://developer.apple.com/documentation/appkit) on macOS, and the
//! [Wayland](https://wayland.freedesktop.org/) and [X11](https://www.x.org/)
//! display systems on Linux, each with a window that receives events and a
//! drawing surface that receives pixels. The package keeps what those systems
//! share: native windows, event delivery, drawing surfaces, and one
//! implementation per platform, and it hands out each window's native surface
//! for code that needs the platform directly.
//!
//! Over those implementations the package offers one API, with one
//! implementation per window system (*backend*), and on Linux it picks Wayland
//! or X11 when a window is created, falling back to the other when the first
//! choice is unavailable. Every store a window keeps, among them the event
//! queue, the input state and the presentation storage, is sized from the sizes
//! the caller passes at creation (*limits*), and each byte count is derived and
//! checked before the window opens. Each poll fills the event queue afresh and
//! the program drains it with an iterator, and an event that finds the queue
//! full is counted and dropped, so the program can read how many it lost. Each
//! hand-over to the display (*present*) names the rectangle of the image that
//! changed, and a backend that can send only those pixels does so. Hand-overs
//! follow the display's pace: the Wayland backend keeps an image that arrives
//! while the program that draws the Linux desktop under Wayland (the
//! compositor) is busy and sends it when the compositor signals for the next
//! frame, and a backend reports when a frame reached the screen where its
//! platform offers that report.
//!
//! - *region*: an axis-aligned rectangle of a frame, given as an origin, a
//!   width and a height in pixels, which a caller passes to report the part of
//!   the frame that changed.

const native_wayland = @import("wayland");
const native_xkb = @import("xkb");

const window = @import("window.zig");
pub const event = @import("event.zig");
const key = @import("key.zig");
const mouse = @import("mouse.zig");
const modifier = @import("modifier.zig");
const cursor = @import("cursor.zig");
const clipboard_module = @import("clipboard.zig");
const gamepad_module = @import("gamepad.zig");
const input_module = @import("input.zig");
const config = @import("config.zig");
const wayland = @import("wayland/root.zig");
const surface_module = @import("surface.zig");
pub const presentation = @import("presentation.zig");

pub const Window = window.Window;
pub const Size = window.Size;
pub const Scale = window.Scale;
pub const EventSource = window.EventSource;
pub const PresentRegion = window.PresentRegion;
pub const max_present_regions = window.max_present_regions;
pub const Event = event.Event;
pub const EventIterator = event.EventIterator;
pub const KeyEvent = event.KeyEvent;
pub const TextInputEvent = event.TextInputEvent;
pub const MouseButtonEvent = event.MouseButtonEvent;
pub const MouseMoveEvent = event.MouseMoveEvent;
pub const MouseWheelEvent = event.MouseWheelEvent;
pub const SizeEvent = event.SizeEvent;
pub const FocusEvent = event.FocusEvent;
pub const Key = key.Key;
pub const MouseButton = mouse.MouseButton;
pub const Modifier = modifier.Modifier;
pub const CursorShape = cursor.CursorShape;
pub const clipboard = clipboard_module;
pub const input = input_module;
pub const gamepad = gamepad_module;
pub const surface = surface_module;
pub const Gamepad = gamepad_module.Gamepad;
pub const GamepadButton = gamepad_module.Button;
pub const GamepadAxis = gamepad_module.Axis;
pub const WindowConfig = config.WindowConfig;
pub const BackendPreference = config.BackendPreference;
pub const default_wayland_compose_limits = config.default_wayland_compose_limits;
pub const default_wayland_compose_scratch_limits =
    config.default_wayland_compose_scratch_limits;
pub const default_wayland_output_count = config.default_wayland_output_count;
pub const Surface = surface_module.Surface;
pub const SurfaceKind = surface_module.Kind;
pub const SurfaceExtent = surface_module.Extent;
pub const WaylandSurface = surface_module.Wayland;
pub const WaylandDmabuf = wayland.DmabufSurface;
pub const wayland_dmabuf = wayland.present.dmabuf;
pub const X11Surface = surface_module.X11;
pub const CocoaSurface = surface_module.Cocoa;
pub const UnsupportedSurface = surface_module.Unsupported;
pub const ClipboardCapacity = clipboard_module.Capacity;
pub const EventQueueCapacity = event.Capacity;
pub const GamepadCapacity = gamepad_module.Capacity;
pub const InputCapacity = input_module.Capacity;
pub const PresentationCapacity = presentation.Capacity;
pub const WaylandSessionCapacity = wayland.session.Capacity;
pub const WaylandPresentationCapacity = wayland.presentation.Capacity;
pub const WaylandRuntimeLimits = native_wayland.runtime.Limits;
pub const WaylandRuntimeCapacity = native_wayland.runtime.Capacity;
pub const WaylandRuntimeStorageStatus = native_wayland.runtime.StorageStatus;
pub const WaylandComposeLimits = native_xkb.compose.Limits;
pub const WaylandComposeCapacity = native_xkb.compose.Capacity;
pub const WaylandComposeScratchLimits = native_xkb.compose.ScratchLimits;
pub const WaylandComposeScratchCapacity = native_xkb.compose.ScratchCapacity;
pub const WaylandClientIdCapacity = native_wayland.ClientIdCapacity;
pub const WaylandObjectCapacity = native_wayland.runtime.ObjectCapacity;
pub const WaylandGlobalCapacity = native_wayland.runtime.GlobalCapacity;
pub const WaylandEventStorageCapacity = native_wayland.runtime.EventStorageCapacity;
pub const WaylandEventStorageStatus = native_wayland.runtime.EventStorageStatus;
pub const WaylandTransportCapacity = native_wayland.TransportCapacity;
pub const WaylandTransportStatus = native_wayland.TransportStatus;
pub const WaylandProcessEnvironmentLimits = native_wayland.ProcessEnvironmentLimits;
pub const WaylandProcessEnvironmentCapacity = native_wayland.ProcessEnvironmentCapacity;
pub const WaylandProcessEnvironmentCapacityError =
    native_wayland.ProcessEnvironmentCapacityError;
pub const wayland_process_environment_capacity =
    native_wayland.process_environment_capacity;

pub const CreateError = window.CreateError;
pub const PollError = window.PollError;
pub const PresentError = window.PresentError;
