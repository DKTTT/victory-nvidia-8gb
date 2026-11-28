//! The device titles get from device creation, laid out as their inlined
//! code expects: the object header, then device fields. Its table starts
//! like the PC device interface (IUnknown, the object methods, then the
//! device methods in PC order); console additions follow. Methods we have
//! not written log their table offset and fail, so a run shows what to
//! write next.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::ffi::c_void;
use std::sync::atomic::{AtomicU32, Ordering};

use crate::object::{
    self, E_INVALIDARG, E_NOINTERFACE, E_NOTIMPL, HRESULT, Iid, Object, S_FALSE, S_OK, Table, This,
    guid, guid_text,
};
use crate::{
    descriptor, dxgi, fence, frame, list, pipeline, query, queue, resource, root, signature,
};

/// What D3D returns when none of the requested feature levels is supported.
const UNSUPPORTED: HRESULT = 0x887A_0004_u32 as i32;

/// The device interface id (the same as on PC). Titles also import it as
/// data.
pub static IID: Iid = guid(
    0x189819f1,
    0x1db6,
    0x4b57,
    [0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7],
);

/// The levels the device answers to, as on PC: `ID3D12Device1` to
/// `ID3D12Device8`, and `ID3D12Device11`, which the title creates
/// its device as. Each level's table is the one before plus its methods.
const LEVEL_IIDS: [Iid; 9] = [
    guid(
        0x77acce80,
        0x638e,
        0x4e65,
        [0x88, 0x95, 0xc1, 0xf2, 0x33, 0x86, 0x86, 0x3e],
    ),
    guid(
        0x30baa41e,
        0xb15b,
        0x475c,
        [0xa0, 0xbb, 0x1a, 0xf5, 0xc5, 0xb6, 0x43, 0x28],
    ),
    guid(
        0x81dadc15,
        0x2bad,
        0x4392,
        [0x93, 0xc5, 0x10, 0x13, 0x45, 0xc4, 0xaa, 0x98],
    ),
    guid(
        0xe865df17,
        0xa9ee,
        0x46f9,
        [0xa4, 0x63, 0x30, 0x98, 0x31, 0x5a, 0xa2, 0xe5],
    ),
    guid(
        0x8b4f173b,
        0x2fea,
        0x4b80,
        [0x8f, 0x58, 0x43, 0x07, 0x19, 0x1a, 0xb9, 0x5d],
    ),
    guid(
        0xc70b221b,
        0x40e4,
        0x4a17,
        [0x89, 0xaf, 0x02, 0x5a, 0x07, 0x27, 0xa6, 0xdc],
    ),
    guid(
        0x5c014b53,
        0x68a1,
        0x4b9b,
        [0x8b, 0xd1, 0xdd, 0x60, 0x46, 0xb9, 0x35, 0x8b],
    ),
    guid(
        0x728f1fa2,
        0xea11,
        0x4a9f,
        [0x9b, 0x52, 0x9b, 0x42, 0xa4, 0x84, 0xd5, 0xc9],
    ),
    guid(
        0x5405c344,
        0xd457,
        0x444e,
        [0xb4, 0xdd, 0x23, 0x66, 0xe4, 0x5a, 0xee, 0x39],
    ),
];

/// Whether `iid` names the device: its first interface or a newer level.
pub(crate) fn is_device(iid: *const Iid) -> bool {
    object::is(iid, &[IID]) || object::is(iid, &LEVEL_IIDS)
}

/// The interface version these layouts were checked against (2.4). Both
/// Minecraft (March 2022) and the title (April 2026) pass it.
pub const CHECKED_VERSION: u32 = 0x0002_0004;

/// Feature level 12_2, what the console hardware supports.
const HIGHEST_FEATURE_LEVEL: u32 = 0xc200;

/// `D3D12XBOX_CREATE_DEVICE_PARAMETERS` (d3d12_xs.h, the 2022-08-01
/// reference): the blob `D3D12XboxCreateDevice` takes. `Version` (the first
/// word) is [`CHECKED_VERSION`] for both titles we know; the offsets below
/// are the header's, checked by the asserts after the structure. Only
/// `CreateDeviceFlags` is read here, through [`CREATE_DEVICE_FLAGS_OFFSET`],
/// so a title that passes an older, shorter structure still works.
#[allow(dead_code)] // the layout is the point; the fields are read by offset
#[repr(C)]
struct CreateDeviceParameters {
    version: u32,
    process_debug_flags: u32,
    graphics_command_queue_ring_size_bytes: u32,
    offchip_tessellation_buffer: u64,
    graphics_scratch_memory_size_bytes: u32,
    compute_scratch_memory_size_bytes: u32,
    disable_geometry_shader_allocations: u32,
    disable_tessellation_shader_allocations: u32,
    disable_dxr: u32,
    disable_automatic_dpbb_break_batch_events: u32,
    dxr_stack_buffer: u64,
    dxr_stack_buffer_override_size_bytes: u32,
    create_device_flags: u32,
    auto_hdr_paper_white_level_nits: u32,
    disable_automatic_command_segment_chaining: u32,
    amplification_shader_indirect_args_buffer_size: u32,
    amplification_shader_payload_buffer_size: u32,
}

/// Where `CreateDeviceFlags` sits in [`CreateDeviceParameters`].
const CREATE_DEVICE_FLAGS_OFFSET: usize = 0x3c;

const _: () = {
    use std::mem::offset_of;
    // The header's offsets, field by field (the documentation's order).
    assert!(offset_of!(CreateDeviceParameters, version) == 0x00);
    assert!(offset_of!(CreateDeviceParameters, process_debug_flags) == 0x04);
    assert!(offset_of!(CreateDeviceParameters, graphics_command_queue_ring_size_bytes) == 0x08);
    assert!(offset_of!(CreateDeviceParameters, offchip_tessellation_buffer) == 0x10);
    assert!(offset_of!(CreateDeviceParameters, graphics_scratch_memory_size_bytes) == 0x18);
    assert!(offset_of!(CreateDeviceParameters, compute_scratch_memory_size_bytes) == 0x1c);
    assert!(offset_of!(CreateDeviceParameters, disable_geometry_shader_allocations) == 0x20);
    assert!(offset_of!(CreateDeviceParameters, disable_tessellation_shader_allocations) == 0x24);
    assert!(offset_of!(CreateDeviceParameters, disable_dxr) == 0x28);
    assert!(offset_of!(CreateDeviceParameters, disable_automatic_dpbb_break_batch_events) == 0x2c);
    assert!(offset_of!(CreateDeviceParameters, dxr_stack_buffer) == 0x30);
    assert!(offset_of!(CreateDeviceParameters, dxr_stack_buffer_override_size_bytes) == 0x38);
    assert!(offset_of!(CreateDeviceParameters, create_device_flags) == CREATE_DEVICE_FLAGS_OFFSET);
    assert!(offset_of!(CreateDeviceParameters, auto_hdr_paper_white_level_nits) == 0x40);
    assert!(offset_of!(CreateDeviceParameters, disable_automatic_command_segment_chaining) == 0x44);
    assert!(offset_of!(CreateDeviceParameters, amplification_shader_indirect_args_buffer_size) == 0x48);
    assert!(offset_of!(CreateDeviceParameters, amplification_shader_payload_buffer_size) == 0x4c);
    assert!(size_of::<CreateDeviceParameters>() == 0x50);
};

/// `D3D12XBOX_CREATE_DEVICE_FLAGS`: the public 2022 header's bits.
const CREATE_DEVICE_FLAG_ENABLE_AUTO_HDR: u32 = 0x1;
const CREATE_DEVICE_FLAG_GPU_BUSY_COUNT_CP: u32 = 0x2;
const CREATE_DEVICE_FLAG_GPU_BUSY_COUNT_SDMA: u32 = 0x4;
const CREATE_DEVICE_FLAG_DISABLE_AUTO_DPBB: u32 = 0x8;
/// GDKX 2026.10's header names this bit; the public 2022 reference stops at
/// 0x8. The console skips compiling shaders at device creation when it is
/// set; the host compiles none at that point (translations run ahead of the
/// device), so it is accepted and ignored.
const CREATE_DEVICE_FLAG_NO_RUNTIME_COMPILATION: u32 = 0x20;
/// CPU-visible special creation flags (scarlett `PORTING.md` §3: Readback
/// gets linear staging, Upload gets linear staging when either bit is set).
/// PORTING.md and the patch (`XsWrappers.h`'s `kCpuResourceExactFlag` /
/// `kCpuResourceFlag`) assign them to an engine resource's flags word
/// (`RageBuffer.resourceFlags`), not to the public 2022 device flag enum;
/// they are recorded here because that is where the title's creation blob
/// passes its flags, and [`cpu_visible_staging`] is where resource creation
/// asks.
const CREATE_DEVICE_FLAG_CPU_VISIBLE_0X100: u32 = 0x100;
const CREATE_DEVICE_FLAG_CPU_VISIBLE_0X200: u32 = 0x200;
const CPU_VISIBLE_FLAGS: u32 =
    CREATE_DEVICE_FLAG_CPU_VISIBLE_0X100 | CREATE_DEVICE_FLAG_CPU_VISIBLE_0X200;
/// Every bit the two references name; the rest are logged as unknown.
const KNOWN_FLAGS: u32 = CREATE_DEVICE_FLAG_ENABLE_AUTO_HDR
    | CREATE_DEVICE_FLAG_GPU_BUSY_COUNT_CP
    | CREATE_DEVICE_FLAG_GPU_BUSY_COUNT_SDMA
    | CREATE_DEVICE_FLAG_DISABLE_AUTO_DPBB
    | CREATE_DEVICE_FLAG_NO_RUNTIME_COMPILATION
    | CPU_VISIBLE_FLAGS;

/// The `CreateDeviceFlags` word the title passed (0 before creation and for
/// every device since: one device per process, as on the console).
static CREATION_FLAGS: AtomicU32 = AtomicU32::new(0);

/// The device creation flags, as the title passed them to
/// `D3D12XboxCreateDevice`. 0 for a title whose parameters blob ends before
/// the flags word.
pub fn creation_flags() -> u32 {
    CREATION_FLAGS.load(Ordering::Relaxed)
}

/// Whether the title asked for the console's CPU-visible staging (linear
/// Readback staging, Upload linear staging when either 0x100/0x200 is set).
/// Host readback/upload heaps are linear by definition, so no resource
/// choice branches on this; resource creation logs the fact once and future
/// tiling/asynchronous-staging paths can ask.
pub(crate) fn cpu_visible_staging() -> bool {
    creation_flags() & CPU_VISIBLE_FLAGS != 0
}

/// Reads `CreateDeviceFlags` from the title's parameters blob. `None` when
/// that memory is not readable (a shorter, older structure): the title's
/// memory is read through the kernel, so this cannot fault.
fn read_create_device_flags(parameters: *const u32) -> Option<u32> {
    #[cfg(windows)]
    {
        let at = parameters.cast::<u8>().wrapping_add(CREATE_DEVICE_FLAGS_OFFSET);
        let mut word = [0u8; 4];
        crate::host::read_into(at, &mut word).then(|| u32::from_ne_bytes(word))
    }
    #[cfg(not(windows))]
    {
        // SAFETY: tests pass a whole `CreateDeviceParameters`; the offset is
        // inside the structure (asserted above).
        Some(unsafe {
            parameters
                .cast::<u8>()
                .add(CREATE_DEVICE_FLAGS_OFFSET)
                .cast::<u32>()
                .read_unaligned()
        })
    }
}

/// Logs the creation flags: the named bits at info (the title creates its
/// device once per process) and any bit neither reference names, so a run
/// shows what the title asks for. Nothing here changes device creation.
fn report_creation_flags(flags: Option<u32>) {
    let Some(flags) = flags else {
        tracing::info!(
            "D3D12.X device creation flags: the parameters blob ends before its flags word"
        );
        return;
    };
    let unknown = flags & !KNOWN_FLAGS;
    if unknown != 0 {
        tracing::info!(
            unknown = format_args!("{unknown:#x}"),
            "device creation flags this layer does not know (recorded, nothing acts on them)"
        );
    }
    let mut named = Vec::new();
    if flags & CREATE_DEVICE_FLAG_ENABLE_AUTO_HDR != 0 {
        named.push("auto HDR (not provided by the host)");
    }
    if flags & CREATE_DEVICE_FLAG_GPU_BUSY_COUNT_CP != 0 {
        named.push("GPU busy count CP");
    }
    if flags & CREATE_DEVICE_FLAG_GPU_BUSY_COUNT_SDMA != 0 {
        named.push("GPU busy count SDMA");
    }
    if flags & CREATE_DEVICE_FLAG_DISABLE_AUTO_DPBB != 0 {
        named.push("disable automatic DPBB");
    }
    if flags & CREATE_DEVICE_FLAG_NO_RUNTIME_COMPILATION != 0 {
        named.push("no runtime compilation (accepted and ignored)");
    }
    if flags & CREATE_DEVICE_FLAG_CPU_VISIBLE_0X100 != 0 {
        named.push("CPU-visible 0x100 (linear staging)");
    }
    if flags & CREATE_DEVICE_FLAG_CPU_VISIBLE_0X200 != 0 {
        named.push("CPU-visible 0x200 (linear staging)");
    }
    tracing::info!(
        flags = format_args!("{flags:#x}"),
        known = %named.join("; "),
        "D3D12.X device creation flags"
    );
}

#[repr(C)]
pub struct Device {
    object: Object,
    /// GPU address of a null constant buffer; none yet.
    null_constant_buffer: u64,
    /// Byte 0 non-zero: calls the title would otherwise inline come to the
    /// table. The rest is reserved.
    out_of_line: [u32; 16],
}
const _: () = assert!(size_of::<Device>() == 0x58);

/// One device per process, as on the console.
pub(crate) static DEVICE: Device = Device {
    object: Object::new(&FUNCTIONS),
    null_constant_buffer: 0,
    out_of_line: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
};

pub(crate) fn device() -> This {
    (&raw const DEVICE).cast()
}

/// Device creation: `(adapter, parameters, iid, out)`. The parameters start
/// with the interface version; the rest (ring and scratch sizes, features
/// to leave out) does not matter to us yet.
pub extern "system" fn create(
    _adapter: *const c_void,
    parameters: *const u32,
    iid: *const Iid,
    out: *mut This,
) -> HRESULT {
    if parameters.is_null() || iid.is_null() {
        return E_INVALIDARG;
    }
    // SAFETY: checked non-null; the title passes its parameters and an id.
    let (version, iid) = unsafe { (parameters.read(), &*iid) };
    tracing::info!(version = format_args!("{version:#x}"), "D3D12.X device");
    let flags = read_create_device_flags(parameters);
    CREATION_FLAGS.store(flags.unwrap_or(0), Ordering::Relaxed);
    report_creation_flags(flags);
    if version != CHECKED_VERSION {
        tracing::warn!(
            version = format_args!("{version:#x}"),
            "device layouts were checked against {CHECKED_VERSION:#x} only"
        );
    }
    if !is_device(iid) {
        tracing::warn!(iid = %guid_text(iid), "device created as an unknown interface");
        return E_NOINTERFACE;
    }
    if out.is_null() {
        return S_FALSE;
    }
    if *iid == LEVEL_IIDS[8] {
        NEWER.store(true, std::sync::atomic::Ordering::Relaxed);
    }
    // `VICTORY_D3D12X_SLOTS=1`: the console's interface layout beside ours
    // (log only; no slot moves). After `NEWER`, so the tables the title will
    // get are the ones checked.
    crate::xs::diagnose();
    object::answer(object::DEVICE, iid, Some(device()), out)
}

/// Set when the title creates the device as `ID3D12Device11`. Its lists and
/// queues then have the newer layouts (two more methods each; see
/// `list` and `queue`), although the interface version stays 2.4.
/// shortcut: the creation interface is the only sign of the newer layouts
/// we have (the title, April 2026, versus Minecraft, March 2022);
/// look for a better one if a title breaks the rule.
static NEWER: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub(crate) fn newer() -> bool {
    NEWER.load(std::sync::atomic::Ordering::Relaxed)
}

/// The device, or its DXGI side.
extern "system" fn query_interface(this: This, iid: *const Iid, out: *mut This) -> HRESULT {
    let found = if is_device(iid) {
        Some(this)
    } else if object::is(iid, &dxgi::DEVICE_IIDS) {
        Some(dxgi::device())
    } else {
        None
    };
    object::answer(object::DEVICE, iid, found, out)
}

/// What `D3D12ConfigureVirtualMemoryX` takes and fills in.
#[repr(C)]
pub struct VirtualMemory {
    flags: u32,
    /// GPU page table size in 4 MiB pages.
    page_table_pages: u32,
    /// Memory kept across title processes for the frame buffer.
    preserved_bytes: u32,
    /// Out: the range graphics addresses fall in.
    lowest: u64,
    highest: u64,
}
const _: () = assert!(size_of::<VirtualMemory>() == 0x20);

/// `d3d12_xs!D3D12ConfigureVirtualMemoryX`, called before any graphics
/// allocation. The inputs size console structures we do not have; the
/// range out is all of user space, since GPU addresses are CPU addresses.
pub extern "system" fn configure_virtual_memory(config: *mut VirtualMemory) -> HRESULT {
    // SAFETY: the title passes its configuration (null is tolerated).
    let Some(config) = (unsafe { config.as_mut() }) else {
        return E_INVALIDARG;
    };
    tracing::info!(
        flags = config.flags,
        page_table_pages = config.page_table_pages,
        preserved_bytes = config.preserved_bytes,
        "graphics virtual memory"
    );
    (config.lowest, config.highest) = user_space();
    S_OK
}

fn user_space() -> (u64, u64) {
    #[cfg(windows)]
    {
        use windows_sys::Win32::System::SystemInformation::{GetSystemInfo, SYSTEM_INFO};
        // SAFETY: plain data, filled in by the call.
        let mut info: SYSTEM_INFO = unsafe { std::mem::zeroed() };
        // SAFETY: a valid out pointer.
        unsafe { GetSystemInfo(&mut info) };
        (
            info.lpMinimumApplicationAddress as u64,
            info.lpMaximumApplicationAddress as u64,
        )
    }
    #[cfg(not(windows))]
    (0x1_0000, 0x7fff_fffe_ffff)
}

extern "system" fn node_count(_: This) -> u32 {
    1
}

/// Feature query 2: the highest of the requested feature levels we support.
#[repr(C)]
struct FeatureLevels {
    count: u32,
    requested: *const u32,
    highest: u32,
}

/// Feature query 0, what an RDNA 2 GPU reports. The console's layout has
/// one field more than PC's (index 11).
const OPTIONS: [u32; 16] = [
    1,  // double-precision shader operations
    1,  // output-merger logic operations
    2,  // minimum precision: 16-bit
    3,  // tiled resources tier
    3,  // resource binding tier
    1,  // stencil reference from pixel shaders
    1,  // typed UAV loads of more formats
    1,  // rasterizer-ordered views
    3,  // conservative rasterization tier
    40, // GPU address bits per resource
    0,  // 64 KiB standard swizzle
    0,  // console-only field
    0,  // cross-node sharing tier
    0,  // cross-adapter row-major textures
    1,  // viewport and render target index from any stage
    2,  // resource heap tier
];

/// `D3D12_FEATURE` ids this device answers. The console's structures for
/// options 7-11 (the `*_xs` pages of the 2022-08-01 d3d12_xs reference) are
/// laid out as the PC ones, so the PC ids and the title's PC-sized queries
/// are what arrive here.
const FEATURE_D3D12_OPTIONS: u32 = 0;
const FEATURE_ARCHITECTURE: u32 = 1;
const FEATURE_FEATURE_LEVELS: u32 = 2;
const FEATURE_FORMAT_SUPPORT: u32 = 3;
const FEATURE_MULTISAMPLE_QUALITY_LEVELS: u32 = 4;
const FEATURE_DISPLAYABLE: u32 = 28;
const FEATURE_D3D12_OPTIONS7: u32 = 32;
const FEATURE_PROTECTED_RESOURCE_SESSION_TYPE_COUNT: u32 = 33;
const FEATURE_PROTECTED_RESOURCE_SESSION_TYPES: u32 = 34;
const FEATURE_D3D12_OPTIONS8: u32 = 36;
const FEATURE_D3D12_OPTIONS9: u32 = 37;
const FEATURE_D3D12_OPTIONS10: u32 = 39;
const FEATURE_D3D12_OPTIONS11: u32 = 40;

/// `D3D12_FEATURE_DATA_D3D12_OPTIONS7` (d3d12_xs docs): mesh shader and
/// sampler feedback tiers; 8 bytes.
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Options7 {
    mesh_shader_tier: u32,
    sampler_feedback_tier: u32,
}
const _: () = assert!(size_of::<Options7>() == 8);

/// `D3D12_FEATURE_DATA_D3D12_OPTIONS8`: unaligned block textures; 4 bytes.
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Options8 {
    unaligned_block_textures_supported: u32,
}
const _: () = assert!(size_of::<Options8>() == 4);

/// `D3D12_FEATURE_DATA_D3D12_OPTIONS9` (d3d12_xs docs): five BOOLs and the
/// WaveMMA tier; 24 bytes.
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Options9 {
    mesh_shader_pipeline_stats_supported: u32,
    mesh_shader_supports_full_range_render_target_array_index: u32,
    atomic_int64_on_typed_resource_supported: u32,
    atomic_int64_on_group_shared_supported: u32,
    derivatives_in_mesh_and_amplification_shaders_supported: u32,
    wave_mma_tier: u32,
}
const _: () = assert!(size_of::<Options9>() == 24);

/// `D3D12_FEATURE_DATA_D3D12_OPTIONS10`: two BOOLs; 8 bytes.
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Options10 {
    variable_rate_shading_sum_combiner_supported: u32,
    mesh_shader_per_primitive_shading_rate_supported: u32,
}
const _: () = assert!(size_of::<Options10>() == 8);

/// `D3D12_FEATURE_DATA_D3D12_OPTIONS11`: one BOOL; 4 bytes.
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Options11 {
    atomic_int64_on_descriptor_heap_resource_supported: u32,
}
const _: () = assert!(size_of::<Options11>() == 4);

/// `D3D12_FEATURE_DATA_DISPLAYABLE` (d3d12_xs docs): a BOOL and the shared
/// resource compatibility tier; 8 bytes.
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Displayable {
    displayable_texture: u32,
    shared_resource_compatibility_tier: u32,
}
const _: () = assert!(size_of::<Displayable>() == 8);

/// `D3D12_FEATURE_DATA_PROTECTED_RESOURCE_SESSION_TYPE_COUNT`: node in,
/// count out; 8 bytes.
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct SessionTypeCount {
    node_index: u32,
    count: u32,
}
const _: () = assert!(size_of::<SessionTypeCount>() == 8);

/// `D3D12_FEATURE_DATA_PROTECTED_RESOURCE_SESSION_TYPES`: node index, the
/// count from the query above, and room for that many GUIDs; 16 bytes on
/// x64.
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct SessionTypes {
    node_index: u32,
    count: u32,
    types: *mut Iid,
}
const _: () = assert!(size_of::<SessionTypes>() == 16);

/// Logs the first time each console (XS) feature query is answered: what was
/// asked, the structure's documented size and the answer this layer gives,
/// so a run shows the console gating the title does.
fn note_xs_query(feature: u32, name: &'static str, size: u32, answer: &'static str) {
    static SEEN: AtomicU32 = AtomicU32::new(0);
    let bit: u32 = 1
        << match feature {
            FEATURE_DISPLAYABLE => 0,
            FEATURE_D3D12_OPTIONS7 => 1,
            FEATURE_PROTECTED_RESOURCE_SESSION_TYPE_COUNT => 2,
            FEATURE_PROTECTED_RESOURCE_SESSION_TYPES => 3,
            FEATURE_D3D12_OPTIONS8 => 4,
            FEATURE_D3D12_OPTIONS9 => 5,
            FEATURE_D3D12_OPTIONS10 => 6,
            FEATURE_D3D12_OPTIONS11 => 7,
            _ => 8,
        };
    if SEEN.fetch_or(bit, Ordering::Relaxed) & bit == 0 {
        tracing::info!(
            feature = name,
            size,
            answer,
            "console (XS) feature query answered"
        );
    }
}

extern "system" fn check_feature_support(
    _: This,
    feature: u32,
    data: *mut c_void,
    size: u32,
) -> HRESULT {
    let expected = match feature {
        FEATURE_D3D12_OPTIONS => size_of_val(&OPTIONS),
        FEATURE_ARCHITECTURE => 16,
        FEATURE_FEATURE_LEVELS => size_of::<FeatureLevels>(),
        FEATURE_FORMAT_SUPPORT => 12,
        FEATURE_MULTISAMPLE_QUALITY_LEVELS => 16,
        FEATURE_DISPLAYABLE => size_of::<Displayable>(),
        FEATURE_D3D12_OPTIONS7 => size_of::<Options7>(),
        FEATURE_D3D12_OPTIONS8 => size_of::<Options8>(),
        FEATURE_D3D12_OPTIONS9 => size_of::<Options9>(),
        FEATURE_D3D12_OPTIONS10 => size_of::<Options10>(),
        FEATURE_D3D12_OPTIONS11 => size_of::<Options11>(),
        FEATURE_PROTECTED_RESOURCE_SESSION_TYPE_COUNT => size_of::<SessionTypeCount>(),
        FEATURE_PROTECTED_RESOURCE_SESSION_TYPES => size_of::<SessionTypes>(),
        _ => {
            // The console's queries have structures in the 2022-08-01
            // reference and are all handled above; anything else is a query
            // this layer has not written. Name the id and the size the title
            // asked for, so a run shows what it gates on instead of a title
            // reading uninitialised memory.
            tracing::warn!(
                feature,
                size,
                "device feature query not implemented"
            );
            return E_NOTIMPL;
        }
    };
    if data.is_null() || size as usize != expected {
        return E_INVALIDARG;
    }
    match feature {
        FEATURE_D3D12_OPTIONS => {
            // SAFETY: checked size and non-null.
            unsafe { data.cast::<[u32; 16]>().write_unaligned(OPTIONS) };
            S_OK
        }
        FEATURE_ARCHITECTURE => {
            // SAFETY: checked size and non-null.
            let a = unsafe { &mut *data.cast::<[u32; 4]>() };
            if a[0] != 0 {
                return E_INVALIDARG; // one node only
            }
            // Not tile-based; unified, cache-coherent memory.
            a[1..].copy_from_slice(&[0, 1, 1]);
            S_OK
        }
        FEATURE_FORMAT_SUPPORT => {
            // SAFETY: checked size and non-null.
            let q = unsafe { &mut *data.cast::<[u32; 3]>() };
            // shortcut: every use of every format; answer from the host
            // device once there is one.
            q[1] = 0x7fff_ffff;
            q[2] = 0xffff;
            S_OK
        }
        FEATURE_MULTISAMPLE_QUALITY_LEVELS => {
            // SAFETY: checked size and non-null.
            let q = unsafe { &mut *data.cast::<[u32; 4]>() };
            // Format, sample count, flags in; one quality level out for the
            // counts the hardware has.
            q[3] = u32::from(matches!(q[1], 1 | 2 | 4 | 8));
            S_OK
        }
        FEATURE_FEATURE_LEVELS => feature_levels(data),
        // The console's feature data, with the documented sizes (asserted
        // above) and the support this translation actually provides: none of
        // these optional paths is implemented, so every tier/BOOL is zero.
        // A title that gates on them takes the same fallback it took when
        // the query failed (E_NOTIMPL) before, and now reads defined memory.
        FEATURE_DISPLAYABLE => {
            // SAFETY: checked size and non-null.
            unsafe { data.cast::<Displayable>().write_unaligned(Displayable::default()) };
            note_xs_query(
                feature,
                "D3D12_FEATURE_DISPLAYABLE",
                size,
                "displayable textures unsupported",
            );
            S_OK
        }
        FEATURE_D3D12_OPTIONS7 => {
            // SAFETY: checked size and non-null.
            unsafe { data.cast::<Options7>().write_unaligned(Options7::default()) };
            note_xs_query(
                feature,
                "D3D12_FEATURE_D3D12_OPTIONS7",
                size,
                "mesh shader tier 0, sampler feedback tier 0",
            );
            S_OK
        }
        FEATURE_D3D12_OPTIONS8 => {
            // SAFETY: checked size and non-null.
            unsafe { data.cast::<Options8>().write_unaligned(Options8::default()) };
            note_xs_query(
                feature,
                "D3D12_FEATURE_D3D12_OPTIONS8",
                size,
                "unaligned block textures unsupported",
            );
            S_OK
        }
        FEATURE_D3D12_OPTIONS9 => {
            // SAFETY: checked size and non-null.
            unsafe { data.cast::<Options9>().write_unaligned(Options9::default()) };
            note_xs_query(
                feature,
                "D3D12_FEATURE_D3D12_OPTIONS9",
                size,
                "no mesh/WaveMMA options",
            );
            S_OK
        }
        FEATURE_D3D12_OPTIONS10 => {
            // SAFETY: checked size and non-null.
            unsafe { data.cast::<Options10>().write_unaligned(Options10::default()) };
            note_xs_query(
                feature,
                "D3D12_FEATURE_D3D12_OPTIONS10",
                size,
                "no VRS sum combiner or per-primitive shading rate",
            );
            S_OK
        }
        FEATURE_D3D12_OPTIONS11 => {
            // SAFETY: checked size and non-null.
            unsafe { data.cast::<Options11>().write_unaligned(Options11::default()) };
            note_xs_query(
                feature,
                "D3D12_FEATURE_D3D12_OPTIONS11",
                size,
                "no 64-bit atomics on descriptor heap resources",
            );
            S_OK
        }
        FEATURE_PROTECTED_RESOURCE_SESSION_TYPE_COUNT => {
            // SAFETY: checked size and non-null.
            let q = unsafe { &mut *data.cast::<SessionTypeCount>() };
            if q.node_index != 0 {
                return E_INVALIDARG; // one node only
            }
            q.count = 0; // no protected resources
            note_xs_query(
                feature,
                "D3D12_FEATURE_PROTECTED_RESOURCE_SESSION_TYPE_COUNT",
                size,
                "no protected resource session types",
            );
            S_OK
        }
        FEATURE_PROTECTED_RESOURCE_SESSION_TYPES => {
            // SAFETY: checked size and non-null.
            let q = unsafe { &mut *data.cast::<SessionTypes>() };
            // The count query answers 0, so a title must ask for 0 types.
            if q.node_index != 0 || q.count != 0 {
                return E_INVALIDARG;
            }
            note_xs_query(
                feature,
                "D3D12_FEATURE_PROTECTED_RESOURCE_SESSION_TYPES",
                size,
                "no protected resource session types",
            );
            S_OK
        }
        // The size match above owns every id it lets through; a new id must be
        // added there first.
        _ => E_NOTIMPL,
    }
}

fn feature_levels(data: *mut c_void) -> HRESULT {
    // SAFETY: the caller checked size and non-null.
    let query = unsafe { &mut *data.cast::<FeatureLevels>() };
    if query.requested.is_null() {
        return E_INVALIDARG;
    }
    // SAFETY: the title passes `count` levels.
    let requested = unsafe { std::slice::from_raw_parts(query.requested, query.count as usize) };
    match requested
        .iter()
        .copied()
        .filter(|&l| l <= HIGHEST_FEATURE_LEVEL)
        .max()
    {
        Some(level) => {
            query.highest = level;
            S_OK
        }
        None => UNSUPPORTED,
    }
}

/// Device methods 0x1c8 and 0x218 (`SLOT`). The title calls both
/// (title+0x2477578 and title+0x24800d5) as `(this, description, interface
/// id, out)`, asks for `ID3D12PipelineState`, and on success keeps the
/// object `out` names and draws with it; on failure it goes without that
/// pipeline, silently. What the descriptions hold is not known: the calls
/// fail as they always did, with `out` null, and the first ones log the
/// description's words and what its first word points at, so that the two
/// methods can be written.
/// shortcut: not implemented. Answering `S_OK` here without making the
/// pipeline would hand the title whatever its stack held as an object.
extern "system" fn unknown_pipeline<const SLOT: usize>(
    _: This,
    desc: *const u8,
    _iid: *const Iid,
    out: *mut This,
) -> HRESULT {
    static CALLS: [AtomicU32; 2] = [const { AtomicU32::new(0) }; 2];
    let calls = CALLS[usize::from(SLOT == 0x218)].fetch_add(1, Ordering::Relaxed) + 1;
    if !out.is_null() {
        // SAFETY: the title's out pointer (a local of its own).
        unsafe { *out = std::ptr::null() };
    }
    if calls <= 4 || calls.is_power_of_two() {
        // Sixteen 64-bit words at `at`, read through the kernel: neither
        // pointer is known to be mapped.
        #[cfg(windows)]
        let words = |at: usize| -> Option<Vec<u64>> {
            let mut bytes = [0u8; 128];
            (at != 0 && crate::host::read_into(at as *const u8, &mut bytes)).then(|| {
                bytes
                    .as_chunks::<8>().0.iter()
                    .map(|c| c.iter().rev().fold(0u64, |v, &b| v << 8 | u64::from(b)))
                    .collect()
            })
        };
        #[cfg(not(windows))]
        let words = |_: usize| None::<Vec<u64>>;
        let description = words(desc as usize);
        let first = description
            .as_ref()
            .and_then(|w| words(w[0] as usize));
        tracing::warn!(
            slot = format_args!("{:#x}", SLOT),
            calls,
            description = format_args!("{description:x?}"),
            first_points_at = format_args!("{first:x?}"),
            "a pipeline creation method that is not implemented: the title goes without this pipeline"
        );
    }
    E_NOTIMPL
}

/// The host device's state: the console's device is removed when the host's is
/// (VIctory 13185f5: the default answer, E_NOTIMPL, reads as a lost device).
extern "system" fn removed_reason(_: This) -> HRESULT {
    #[cfg(windows)]
    if let Some(host) = crate::host::host() {
        // SAFETY: a plain query.
        if let Err(e) = unsafe { host.device.GetDeviceRemovedReason() } {
            return e.code().0;
        }
    }
    S_OK
}

/// IUnknown 3, object methods 4, device methods 76 (0x18-0x290), then the
/// methods `ID3D12Device1` to `ID3D12Device8` add, in order: 3, 1, 3, 6, 9,
/// 1, 2, 9 (0x298-0x3a0, the console's own among them), then those of
/// `ID3D12Device9` to `ID3D12Device11`, whose console layout is unknown.
/// Every slot exists so that a call to one we have not written logs it.
static FUNCTIONS: Table<160> = {
    let mut f = object::d3d12_object(object::missing_table::<{ object::DEVICE }, 160>());
    f[0] = query_interface as *const (); // 0x00
    f[7] = node_count as *const (); // 0x38
    f[8] = queue::create as *const (); // 0x40
    f[9] = list::create_allocator as *const (); // 0x48
    f[12] = list::create_list as *const (); // 0x60
    f[10] = pipeline::create_graphics as *const (); // 0x50
    f[11] = pipeline::create_compute as *const (); // 0x58
    f[13] = check_feature_support as *const (); // 0x68
    f[14] = descriptor::create_heap as *const (); // 0x70
    f[15] = descriptor::increment_size as *const (); // 0x78
    f[16] = root::create as *const (); // 0x80
    f[17] = descriptor::create_cbv as *const (); // 0x88
    f[18] = descriptor::create_srv as *const (); // 0x90
    f[19] = descriptor::create_uav as *const (); // 0x98
    f[20] = descriptor::create_rtv as *const (); // 0xa0
    f[21] = descriptor::create_dsv as *const (); // 0xa8
    f[22] = descriptor::create_sampler as *const (); // 0xb0
    f[23] = descriptor::copy as *const (); // 0xb8
    f[24] = descriptor::copy_simple as *const (); // 0xc0
    f[25] = resource::allocation_info as *const (); // 0xc8; the XS notes put GetResourceTiling here and allocation info at 24 (crate::xs logs it)
    f[26] = resource::custom_heap_properties as *const (); // 0xd0
    f[27] = resource::create_committed as *const (); // 0xd8
    f[28] = resource::create_heap as *const (); // 0xe0
    f[29] = resource::create_placed as *const (); // 0xe8
    f[36] = fence::create as *const (); // 0x120
    f[37] = removed_reason as *const (); // 0x128
    f[38] = resource::copyable_footprints as *const (); // 0x130
    f[39] = query::create as *const (); // 0x138
    f[41] = signature::create as *const (); // 0x148
    f[48] = queue::create_x as *const (); // 0x180
    f[57] = unknown_pipeline::<0x1c8> as *const (); // 0x1c8
    f[61] = descriptor::create_sampler_x as *const (); // 0x1e8
    f[62] = pipeline::create_compute_x as *const (); // 0x1f0
    f[67] = unknown_pipeline::<0x218> as *const (); // 0x218
    f[69] = object::ignore as *const (); // 0x228 debug error filter
    f[70] = descriptor::create_placed_srv as *const (); // 0x230
    f[71] = descriptor::create_placed_uav as *const (); // 0x238
    f[73] = list::create_list_x as *const (); // 0x248
    f[74] = resource::register_page_pool as *const (); // 0x250
    f[75] = resource::unregister_page_pool as *const (); // 0x258
    // CreateCommittedResourceX: its description is PC's plus DCC options,
    // which we have no use for (the AMD upscaler's, on Series S).
    f[76] = resource::create_committed as *const (); // 0x260
    f[78] = frame::set_interval as *const (); // 0x270
    f[79] = frame::schedule as *const (); // 0x278
    f[80] = frame::wait as *const (); // 0x280
    f[81] = frame::statistics as *const (); // 0x288
    f[86] = pipeline::create_stream as *const (); // 0x2b0
    f[108] = resource::allocation_info2 as *const (); // 0x360
    f[127] = resource::create_committed3 as *const (); // 0x3f8
    f[133] = resource::create_at_address as *const (); // 0x428
    Table(f)
};

/// The device's table, for the XS slot self-check (`crate::xs`).
pub(crate) fn table() -> &'static [*const ()] {
    &FUNCTIONS.0
}

/// The device methods the console's porting notes name (PORTING.md, and the
/// `slots` list in the scarlett patch's `XsWrappers.h`), as this module puts
/// them, for the XS slot self-check. `GetResourceAllocationInfo` is included
/// because the notes put it at 24 and `GetResourceTiling` at 25: showing
/// which the two this build has where is the point of the check.
pub(crate) fn methods() -> &'static [object::Named] {
    use object::Named;
    static METHODS: [Named; 12] = [
        Named("CreateCommandAllocator", list::create_allocator as *const ()),
        Named("CreateCommandList", list::create_list as *const ()),
        Named("CheckFeatureSupport", check_feature_support as *const ()),
        Named("CreateDescriptorHeap", descriptor::create_heap as *const ()),
        Named(
            "GetDescriptorHandleIncrementSize",
            descriptor::increment_size as *const (),
        ),
        Named(
            "CreateConstantBufferView",
            descriptor::create_cbv as *const (),
        ),
        Named(
            "GetResourceAllocationInfo",
            resource::allocation_info as *const (),
        ),
        Named(
            "CreateCommittedResource",
            resource::create_committed as *const (),
        ),
        Named("CreateHeap", resource::create_heap as *const ()),
        Named("CreatePlacedResource", resource::create_placed as *const ()),
        Named("CreateFence", fence::create as *const ()),
        Named(
            "GetCopyableFootprints",
            resource::copyable_footprints as *const (),
        ),
    ];
    &METHODS
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::object::slot;

    fn create_as(iid: &Iid) -> (HRESULT, This) {
        let parameters = CreateDeviceParameters {
            version: CHECKED_VERSION,
            ..unsafe { std::mem::zeroed() }
        };
        let mut device = std::ptr::null();
        let hr = create(
            std::ptr::null(),
            (&raw const parameters).cast(),
            iid,
            &mut device,
        );
        (hr, device)
    }

    #[test]
    fn creation_hands_out_the_device() {
        let (hr, device) = create_as(&IID);
        assert_eq!(hr, S_OK);
        assert_eq!(device, super::device());
        // The title tests byte 0x18 before inlining a device call.
        // SAFETY: the device is 0x58 bytes.
        assert_ne!(unsafe { device.cast::<u8>().add(0x18).read() }, 0);
        assert_eq!(create_as(&[0; 16]).0, E_NOINTERFACE);
        assert_eq!(
            slot::<extern "system" fn(This) -> u32>(device, 0x38)(device),
            1
        );
        let missing = slot::<extern "system" fn() -> HRESULT>(device, 0xf0);
        assert_eq!(missing(), E_NOTIMPL);
    }

    #[test]
    fn newer_device_levels_are_the_same_device() {
        // ID3D12Device11, as the title asks for it.
        let (hr, device) = create_as(&LEVEL_IIDS[8]);
        assert_eq!((hr, device), (S_OK, super::device()));
        let mut same = std::ptr::null();
        assert_eq!(query_interface(device, &LEVEL_IIDS[4], &mut same), S_OK);
        assert_eq!(same, device);
        // A Device8 method we have not written fails without crashing.
        let missing = slot::<extern "system" fn() -> HRESULT>(device, 0x3a0);
        assert_eq!(missing(), E_NOTIMPL);
    }

    /// A device child, and the DXGI device, hand out the device as any
    /// interface the device itself answers to.
    #[test]
    fn the_device_is_found_at_every_level_through_others() {
        type Get = extern "system" fn(This, *const Iid, *mut This) -> HRESULT;
        let fence_iid = &crate::fence::FENCE_IIDS[0];
        let mut fence = std::ptr::null();
        assert_eq!(
            crate::fence::create(std::ptr::null(), 0, 0, fence_iid, &mut fence),
            S_OK
        );
        let get_device = slot::<Get>(fence, 0x38);
        let dxgi = dxgi::device();
        let query = slot::<Get>(dxgi, 0);
        for iid in std::iter::once(&IID).chain(&LEVEL_IIDS) {
            let mut found = std::ptr::null();
            assert_eq!(get_device(fence, iid, &mut found), S_OK, "{iid:02x?}");
            assert_eq!(found, device());
            let mut found = std::ptr::null();
            assert_eq!(query(dxgi, iid, &mut found), S_OK, "{iid:02x?}");
            assert_eq!(found, device());
        }
        // What the device is not, it is not through them either.
        let mut found = device();
        assert_eq!(get_device(fence, fence_iid, &mut found), E_NOINTERFACE);
        assert!(found.is_null());
        slot::<extern "system" fn(This) -> u32>(fence, 0x10)(fence);
    }

    /// The host's: a fence's `GetDevice` for `ID3D12Device5`.
    #[cfg(windows)]
    #[test]
    fn the_hosts_children_hand_out_newer_device_levels() {
        use windows::Win32::Graphics::Direct3D12::{
            D3D12_FENCE_FLAG_NONE, ID3D12Device5, ID3D12Fence,
        };
        let Some(host) = crate::host::host() else {
            return; // no host GPU here
        };
        // SAFETY: plain calls on the host device and its fence.
        unsafe {
            let fence: ID3D12Fence = host.device.CreateFence(0, D3D12_FENCE_FLAG_NONE).unwrap();
            let mut device: Option<ID3D12Device5> = None;
            assert!(fence.GetDevice(&mut device).is_ok());
            assert!(device.is_some());
        }
    }

    #[test]
    fn virtual_memory_configuration_reports_user_space() {
        let mut config = VirtualMemory {
            flags: 0,
            page_table_pages: 7,
            preserved_bytes: 0,
            lowest: 0,
            highest: 0,
        };
        assert_eq!(configure_virtual_memory(&mut config), S_OK);
        assert!(0 < config.lowest && config.lowest < config.highest);
        let heap = Box::new(0u8);
        assert!((config.lowest..=config.highest).contains(&(&raw const *heap as u64)));
        assert_eq!(configure_virtual_memory(std::ptr::null_mut()), E_INVALIDARG);
    }

    #[test]
    fn feature_levels_pick_the_highest_supported() {
        type Check = extern "system" fn(This, u32, *mut c_void, u32) -> HRESULT;
        let device = device();
        let check = slot::<Check>(device, 0x68);
        let query = |levels: &[u32], size| {
            let mut query = FeatureLevels {
                count: levels.len() as u32,
                requested: levels.as_ptr(),
                highest: 0,
            };
            let hr = check(device, 2, (&raw mut query).cast(), size);
            (hr, query.highest)
        };
        let levels = [0xb000, 0xb100, 0xc000, 0xc100, 0xd000];
        assert_eq!(query(&levels, 0x18), (S_OK, 0xc100));
        assert_eq!(query(&levels, 0x10).0, E_INVALIDARG);
        assert_eq!(query(&levels[4..], 0x18).0, UNSUPPORTED);
    }

    /// The console's creation parameters: the documented offsets (checked by
    /// the compile-time asserts) and its flags word at 0x3c, recorded without
    /// changing creation. The bits GDKX names are read; unknown bits are
    /// only logged.
    #[test]
    fn creation_flags_are_read_from_the_console_parameters() {
        let mut parameters: CreateDeviceParameters = unsafe { std::mem::zeroed() };
        parameters.version = CHECKED_VERSION;
        parameters.create_device_flags = CREATE_DEVICE_FLAG_ENABLE_AUTO_HDR
            | CREATE_DEVICE_FLAG_NO_RUNTIME_COMPILATION
            | CREATE_DEVICE_FLAG_CPU_VISIBLE_0X100
            | CREATE_DEVICE_FLAG_CPU_VISIBLE_0X200
            | 0x4000;
        let flags = read_create_device_flags((&raw const parameters).cast());
        assert_eq!(flags, Some(0x1 | 0x20 | 0x100 | 0x200 | 0x4000));
        assert_eq!(size_of::<CreateDeviceParameters>(), 0x50);
        assert_eq!(
            std::mem::offset_of!(CreateDeviceParameters, create_device_flags),
            0x3c
        );
    }

    /// The console (XS) feature structures: the documented sizes are
    /// accepted, a wrong size is rejected rather than partly written, and
    /// each answer is the all-zero "this translation does not provide it",
    /// which is the fallback the title took when the query used to fail.
    #[test]
    fn console_feature_queries_fill_their_documented_sizes() {
        type Check = extern "system" fn(This, u32, *mut c_void, u32) -> HRESULT;
        let device = device();
        let check = slot::<Check>(device, 0x68);
        for (feature, size) in [
            (FEATURE_DISPLAYABLE, 8usize),
            (FEATURE_D3D12_OPTIONS7, 8),
            (FEATURE_D3D12_OPTIONS8, 4),
            (FEATURE_D3D12_OPTIONS9, 24),
            (FEATURE_D3D12_OPTIONS10, 8),
            (FEATURE_D3D12_OPTIONS11, 4),
        ] {
            let mut data = vec![0xa5u8; size];
            assert_eq!(
                check(device, feature, data.as_mut_ptr().cast(), size as u32),
                S_OK,
                "feature {feature}"
            );
            assert!(
                data.iter().all(|&b| b == 0),
                "feature {feature} answered zeros"
            );
            assert_eq!(
                check(
                    device,
                    feature,
                    data.as_mut_ptr().cast(),
                    (size - 1) as u32
                ),
                E_INVALIDARG,
                "feature {feature} wrong size"
            );
        }
        // Protected resource sessions: one node, none supported.
        let mut count = SessionTypeCount {
            node_index: 0,
            count: 7,
        };
        assert_eq!(
            check(
                device,
                FEATURE_PROTECTED_RESOURCE_SESSION_TYPE_COUNT,
                (&raw mut count).cast(),
                8
            ),
            S_OK
        );
        assert_eq!(count.count, 0);
        let mut types = SessionTypes {
            node_index: 0,
            count: 0,
            types: std::ptr::null_mut(),
        };
        assert_eq!(
            check(
                device,
                FEATURE_PROTECTED_RESOURCE_SESSION_TYPES,
                (&raw mut types).cast(),
                16
            ),
            S_OK
        );
        assert_eq!(
            check(
                device,
                FEATURE_PROTECTED_RESOURCE_SESSION_TYPES,
                (&raw mut types).cast(),
                8
            ),
            E_INVALIDARG
        );
        // A query with no XS structure is still refused, with its id and
        // size logged.
        let mut other = [0u8; 8];
        assert_eq!(
            check(device, 99, other.as_mut_ptr().cast(), 8),
            E_NOTIMPL
        );
    }
}
