//! The package lets a Zig program act as a client of a Wayland compositor, the
//! program that draws a Linux desktop: it frames the messages between the two,
//! names the objects those messages are about, passes open files across, and
//! sets up the shared memory that holds a window's pixels.
//!
//! A client and a compositor talk over a Unix domain socket, and every request
//! or event on it is a message about one object, named by a 32-bit id. Pixels
//! are too large to copy through the socket, so the client puts them in memory
//! both processes map and hands the compositor the open file behind that
//! memory. A client that runs for hours should keep a memory footprint fixed at
//! the size it had when it connected.
//!
//! Messages from asynchronous requests and events share one socket, together
//! with the open files some of them carry, and the kernel delivers the bytes in
//! pieces of its choosing, so a reader holds part of a message until the rest
//! arrives. An open file that crosses the socket is a kernel resource the
//! receiver now holds, so a reader that drops one and leaves it open leaks it.
//! The compositor acknowledges a client's delete some time after the client
//! sends it, so an id reused before that acknowledgement would name two objects
//! at once. The compositor reads a buffer after the client commits it, so a
//! client that writes new pixels into it too early changes an image the
//! compositor is still reading.
//!
//! The
//! [Wayland protocol](https://wayland.freedesktop.org/docs/book/Protocol.html)
//! answers these at the wire: each object follows an interface of numbered
//! requests and events, a message is an eight-byte header and a payload padded
//! to four bytes, open files ride beside the bytes as `SCM_RIGHTS` data on the
//! socket, and client and compositor draw ids from separate ranges. The package
//! takes the wire format and the interfaces themselves through request and
//! event tables (*generated protocol code*), generated from the upstream
//! protocol description of release 1.25.0, pinned by hash, and checked against
//! the output of the reference generator `wayland-scanner` 1.23.1.
//!
//! The package implements the wire in Zig, and the transport reads and writes
//! through an inbox and outbox (*transport ring*) the caller sizes before the
//! socket opens, holding one maximum-size message and one full batch of open
//! files by default. Every open file has one owner at each step (*descriptor
//! ownership*): a queued file passes to the transport once message validation
//! and room reservation succeed, and a received file the caller leaves untaken
//! is closed. Client ids come from a store allocated once (*object id pool*),
//! sized at 256 ids by default, which hands ids out and takes them back with no
//! further allocation and returns an id to reuse only after the compositor
//! acknowledges the delete. The client records each interface the compositor
//! advertises on its registry (*global*) in a separate store keyed by the
//! registry's name for it, kept apart from the objects the client creates. Each
//! pixel buffer is marked (*busy*) from the moment it is attached until the
//! compositor releases it: the compositor may still read it meanwhile, and the
//! client waits for the release before writing into it again. The protocol
//! object that names an open file to the compositor lives only as long as it
//! takes to create one buffer from it, and the mapping stays with the buffer.
//!
//! - *wire message*: one request or event on the socket, an eight-byte header
//!   giving the object id, the opcode and the total size, followed by a payload
//!   padded to four bytes.
//! - *object id*: the 32-bit name of one protocol object, where a client picks
//!   ids below 0xff000000 and the compositor picks the rest.
//! - *shared memory pool*: the protocol object that names an open file to the
//!   compositor, out of which one buffer is created and which the client
//!   destroys at once, leaving the buffer live.

pub const connection = @import("connection.zig");
pub const ids = @import("ids.zig");
pub const protocol = @import("protocol/root.zig");
pub const runtime = @import("runtime/root.zig");
pub const shm = @import("shm/root.zig");
pub const stream = @import("stream/root.zig");
pub const transport = @import("transport.zig");
pub const wire = @import("wire.zig");

pub const Transport = transport.Transport;
pub const TransportLimits = transport.Limits;
pub const TransportCapacity = transport.Capacity;
pub const TransportCapacityError = transport.CapacityError;
pub const TransportStorageError = transport.StorageError;
pub const TransportStatus = transport.Status;
pub const ClientIdLimits = ids.Limits;
pub const ClientIdCapacity = ids.Capacity;
pub const ClientIdCapacityError = ids.CapacityError;
pub const ClientIdStorageError = ids.StorageError;
pub const ClientIdStorageStatus = ids.Status;
pub const default_client_id_count = ids.default_client_id_count;
pub const default_transport_byte_count = transport.default_byte_count;
pub const default_transport_descriptor_count = transport.default_descriptor_count;
pub const ProcessEnvironmentLimits = connection.ProcessEnvironmentLimits;
pub const ProcessEnvironmentCapacity = connection.ProcessEnvironmentCapacity;
pub const ProcessEnvironmentCapacityError = connection.ProcessEnvironmentCapacityError;
pub const process_environment_capacity = connection.process_environment_capacity;
pub const connect = connection.connect;
pub const connectNamed = connection.connectNamed;
