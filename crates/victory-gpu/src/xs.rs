//! The console's interface layout, checked against this build's tables
//! (`VICTORY_D3D12X_SLOTS=1`, off by default; logging only, no slot moves).
//!
//! `PORTING.md` (the scarlett porting notes) gives the XS slot of the
//! methods the title's game calls, and the porting patch's `XsWrappers.h`
//! (`namespace slots`) has the same numbers as constants. This module prints
//! those slots beside the ones our objects expose in the layout the current
//! title gets, so a method in the desktop place instead of the console's -
//! every slot after it wrong - shows up in the log instead of as a crash.
//! Where a method is not in this build at all, the slot's occupant (if it is
//! one we named) is shown too. The notes also describe the engine-side
//! `RageBuffer` (64 bytes) and its `RageMemoryType`; this layer has no
//! engine-side buffer structure (console resources arrive as D3D12
//! descriptions), so those are pinned in the tests here as documentation,
//! and the memory-type mapping is printed.

use std::fmt::Write as _;
use std::sync::OnceLock;

use crate::device;

/// Whether the self-check is on: `VICTORY_D3D12X_SLOTS=1`. Unset or any
/// other value keeps it off and silent.
fn on() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("VICTORY_D3D12X_SLOTS").is_some_and(|v| v == "1"))
}

/// The console's `RageMemoryType` (PORTING.md §3) mapped to the D3D12 heap
/// type this layer uses for it: Default=0 → DEFAULT (1), Upload=1 →
/// UPLOAD (2), Readback=2 → READBACK (3), Custom=3 → CUSTOM (4). No
/// `RageBuffer` exists in this layer, so nothing reads this yet; the
/// self-check prints it, and a future engine-side reader has the mapping.
const RAGE_MEMORY_TYPE_HEAP: [u32; 4] = [1, 2, 3, 4];

/// `ID3D12Resource`'s slots in PORTING.md §2.
const RESOURCE_XS: &[(usize, &str)] = &[
    (8, "Map"),
    (9, "Unmap"),
    (10, "GetDesc"),
    (11, "GetGPUVirtualAddress"),
];

/// `ID3D12DescriptorHeap`'s slot in PORTING.md §2.
const DESCRIPTOR_HEAP_XS: &[(usize, &str)] = &[(9, "GetCPUDescriptorHandleForHeapStart")];

/// `ID3D12Fence`'s slot in PORTING.md §2.
const FENCE_XS: &[(usize, &str)] = &[(8, "GetCompletedValue")];

/// `ID3D12Device`'s slots in PORTING.md §2 and `XsWrappers.h`
/// (`slots::device*`).
const DEVICE_XS: &[(usize, &str)] = &[
    (9, "CreateCommandAllocator"),
    (12, "CreateCommandList"),
    (13, "CheckFeatureSupport"),
    (14, "CreateDescriptorHeap"),
    (15, "GetDescriptorHandleIncrementSize"),
    (17, "CreateConstantBufferView"),
    (24, "GetResourceAllocationInfo"),
    (25, "GetResourceTiling"),
    (27, "CreateCommittedResource"),
    (28, "CreateHeap"),
    (29, "CreatePlacedResource"),
    (30, "CreateReservedResource"),
    (36, "CreateFence"),
    (38, "GetCopyableFootprints"),
];

/// `ID3D12GraphicsCommandList`'s slots in PORTING.md §2 and `XsWrappers.h`
/// (`slots::commandList*`).
const LIST_XS: &[(usize, &str)] = &[
    (9, "Close"),
    (10, "Reset"),
    (15, "CopyBufferRegion"),
    (16, "CopyTextureRegion"),
    (17, "CopyResource"),
    (18, "CopyTiles"),
    (26, "ResourceBarrier"),
    (73, "CopyRaytracingAccelerationStructure"),
    (146, "Barrier"),
];

/// `ID3D12CommandQueue`'s slots in PORTING.md §2 and `XsWrappers.h`
/// (`slots::queue*`): the console inserts methods before `Signal`, which is
/// 16 there instead of desktop's 14.
const QUEUE_XS: &[(usize, &str)] = &[
    (10, "ExecuteCommandLists"),
    (11, "UpdateTileMappings"),
    (16, "Signal"),
];

/// One interface: what PORTING.md says, and where this build has the
/// methods.
struct Interface {
    name: &'static str,
    /// `(slot, method)` from PORTING.md, in slot order.
    xs: &'static [(usize, &'static str)],
    /// The table this run hands the title.
    active: &'static [*const ()],
    /// The older (desktop-layout) table, for the interfaces with two.
    desktop: Option<&'static [*const ()]>,
    /// This build's methods of the interface: name → handler.
    methods: &'static [crate::object::Named],
}

fn interfaces(newer: bool) -> Vec<Interface> {
    vec![
        Interface {
            name: "ID3D12Resource",
            xs: RESOURCE_XS,
            active: crate::resource::table(),
            desktop: None,
            methods: crate::resource::methods(),
        },
        Interface {
            name: "ID3D12DescriptorHeap",
            xs: DESCRIPTOR_HEAP_XS,
            active: crate::descriptor::heap_table(),
            desktop: None,
            methods: crate::descriptor::heap_methods(),
        },
        Interface {
            name: "ID3D12Fence",
            xs: FENCE_XS,
            active: crate::fence::table(),
            desktop: None,
            methods: crate::fence::methods(),
        },
        Interface {
            name: "ID3D12Device",
            xs: DEVICE_XS,
            active: device::table(),
            desktop: None,
            methods: device::methods(),
        },
        Interface {
            name: "ID3D12GraphicsCommandList",
            xs: LIST_XS,
            active: crate::list::table(newer),
            desktop: Some(crate::list::table(false)),
            methods: crate::list::methods(),
        },
        Interface {
            name: "ID3D12CommandQueue",
            xs: QUEUE_XS,
            active: crate::queue::table(newer),
            desktop: Some(crate::queue::table(false)),
            methods: crate::queue::methods(),
        },
    ]
}

/// One row of the table: a method PORTING.md places, and this build.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Row {
    pub(crate) interface: &'static str,
    /// The slot PORTING.md gives (the XS layout).
    pub(crate) xs_slot: usize,
    pub(crate) method: &'static str,
    /// The slot in the layout this run uses (`None`: not in this build).
    pub(crate) slot: Option<usize>,
    /// The slot in the older/desktop layout, where there are two.
    pub(crate) desktop_slot: Option<usize>,
    /// The named method sitting at `xs_slot` in our layout, if any: says
    /// what a missing method's slot holds instead.
    pub(crate) occupant: Option<&'static str>,
}

/// The rows for one layout: for each method PORTING.md names, where this
/// build puts it (the active layout) and, for the two interfaces that have
/// one, in the older/desktop layout as well.
fn rows(newer: bool) -> Vec<Row> {
    let mut rows = Vec::new();
    for interface in interfaces(newer) {
        for &(xs_slot, method) in interface.xs {
            let handler = interface
                .methods
                .iter()
                .find(|entry| entry.0 == method)
                .map(|entry| entry.1);
            let slot = handler.and_then(|h| interface.active.iter().position(|&p| p == h));
            let desktop_slot = match (interface.desktop, handler) {
                (Some(desktop), Some(h)) => desktop.iter().position(|&p| p == h),
                _ => None,
            };
            let occupant = interface
                .methods
                .iter()
                .find(|entry| interface.active.get(xs_slot) == Some(&entry.1))
                .map(|entry| entry.0);
            rows.push(Row {
                interface: interface.name,
                xs_slot,
                method,
                slot,
                desktop_slot,
                occupant,
            });
        }
    }
    rows
}

/// The table the self-check logs: PORTING.md's slots and this build's, one
/// line per method, then what the notes say about `RageBuffer` and its
/// memory types. Kept separate from [`diagnose`] so a test can read it.
fn table_text(rows: &[Row], layout: &str) -> String {
    let mut text = String::new();
    let _ = writeln!(
        text,
        "XS interface layout from PORTING.md (scarlett) against this build's {layout} tables; ~ = not in this build"
    );
    for row in rows {
        let ours = match row.slot {
            Some(slot) => slot.to_string(),
            None => "~".to_string(),
        };
        let status = if row.slot == Some(row.xs_slot) {
            "match".to_string()
        } else {
            "DIFF".to_string()
        };
        let desktop = match row.desktop_slot {
            Some(slot) if row.slot != Some(slot) => format!(" (desktop {slot})"),
            _ => String::new(),
        };
        let occupant = match row.occupant {
            Some(name) if row.slot != Some(row.xs_slot) => {
                format!(" [slot {} holds {name}]", row.xs_slot)
            }
            _ => String::new(),
        };
        let _ = writeln!(
            text,
            "{:<26} XS {:>3}  {:<36} ours {:>3}  {status}{desktop}{occupant}",
            row.interface, row.xs_slot, row.method, ours
        );
    }
    let _ = writeln!(
        text,
        "RageBuffer (64 bytes): console-side engine struct, not in this layer (PORTING.md 3); its layout is pinned in this module's tests"
    );
    let _ = writeln!(
        text,
        "RageMemoryType (Default=0 Upload=1 Readback=2 Custom=3) -> this layer's D3D12 heap types {RAGE_MEMORY_TYPE_HEAP:?}"
    );
    text
}

/// Prints the porting notes' XS layout beside this build's tables, and warns
/// where they differ: one `info` table plus one `warn` per difference. Called
/// from device creation, after the title's layout is known (`NEWER`).
pub(crate) fn diagnose() {
    if !on() {
        return;
    }
    let newer = device::newer();
    let rows = rows(newer);
    let layout = if newer {
        "newer (XS, ID3D12Device11)"
    } else {
        "older (desktop)"
    };
    tracing::info!(slots = %table_text(&rows, layout), "XS interface slot self-check");
    for row in &rows {
        if row.slot != Some(row.xs_slot) {
            tracing::warn!(
                interface = row.interface,
                xs_slot = row.xs_slot,
                method = row.method,
                ours = ?row.slot,
                desktop = ?row.desktop_slot,
                "an interface slot differs from the console porting notes (no slot was changed)"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::offset_of;

    fn row<'a>(rows: &'a [Row], interface: &str, method: &str) -> &'a Row {
        rows.iter()
            .find(|r| r.interface == interface && r.method == method)
            .unwrap_or_else(|| panic!("no row for {interface}::{method}"))
    }

    /// The XS slots the title's layout needs: Signal is 16 (two console
    /// methods before it, not desktop's 14) in the newer layout the title
    /// asks for, and 14 in the older/desktop one. The shared device, list
    /// and resource slots stay where the notes say.
    #[test]
    fn porting_slots_are_where_the_porting_notes_say() {
        let newer = rows(true);
        assert_eq!(
            row(&newer, "ID3D12CommandQueue", "Signal").slot,
            Some(16),
            "the console's Signal slot"
        );
        assert_eq!(
            row(&newer, "ID3D12CommandQueue", "ExecuteCommandLists").slot,
            Some(10)
        );
        // PORTING.md puts UpdateTileMappings at 11; this build has desktop's
        // SetMarker there and no UpdateTileMappings (the check logs it).
        let update = row(&newer, "ID3D12CommandQueue", "UpdateTileMappings");
        assert_eq!(update.slot, None);
        assert_eq!(update.occupant, Some("SetMarker"));

        // The older/desktop layout keeps Signal at 14: only the newer one is
        // the console's.
        let older = rows(false);
        assert_eq!(
            row(&older, "ID3D12CommandQueue", "Signal").slot,
            Some(14)
        );

        assert_eq!(
            row(&newer, "ID3D12Device", "CreateCommandAllocator").slot,
            Some(9)
        );
        assert_eq!(
            row(&newer, "ID3D12Device", "CreateCommandList").slot,
            Some(12)
        );
        assert_eq!(
            row(&newer, "ID3D12Device", "CheckFeatureSupport").slot,
            Some(13)
        );
        assert_eq!(
            row(&newer, "ID3D12Device", "CreateCommittedResource").slot,
            Some(27)
        );
        assert_eq!(row(&newer, "ID3D12Device", "CreateHeap").slot, Some(28));
        assert_eq!(
            row(&newer, "ID3D12Device", "CreatePlacedResource").slot,
            Some(29)
        );
        assert_eq!(row(&newer, "ID3D12Device", "CreateFence").slot, Some(36));
        assert_eq!(
            row(&newer, "ID3D12Device", "GetCopyableFootprints").slot,
            Some(38)
        );
        // The notes put GetResourceAllocationInfo at 24 and GetResourceTiling
        // at 25; this build has allocation info at desktop's 25 and no
        // tiling call (the check logs both rows).
        let alloc = row(&newer, "ID3D12Device", "GetResourceAllocationInfo");
        assert_eq!((alloc.xs_slot, alloc.slot), (24, Some(25)));
        let tiling = row(&newer, "ID3D12Device", "GetResourceTiling");
        assert_eq!(tiling.slot, None);
        assert_eq!(tiling.occupant, Some("GetResourceAllocationInfo"));

        assert_eq!(
            row(&newer, "ID3D12GraphicsCommandList", "Close").slot,
            Some(9)
        );
        assert_eq!(
            row(&newer, "ID3D12GraphicsCommandList", "Reset").slot,
            Some(10)
        );
        assert_eq!(
            row(&newer, "ID3D12GraphicsCommandList", "CopyBufferRegion").slot,
            Some(15)
        );
        assert_eq!(
            row(&newer, "ID3D12GraphicsCommandList", "CopyTextureRegion").slot,
            Some(16)
        );
        assert_eq!(
            row(&newer, "ID3D12GraphicsCommandList", "CopyResource").slot,
            Some(17)
        );
        assert_eq!(
            row(&newer, "ID3D12GraphicsCommandList", "ResourceBarrier").slot,
            Some(26)
        );
        assert_eq!(
            row(&newer, "ID3D12GraphicsCommandList", "Barrier").slot,
            Some(146),
            "the enhanced barrier"
        );
        // This build has neither CopyTiles nor the raytracing acceleration
        // structure copy: tiled resources go through the page pool.
        assert_eq!(
            row(&newer, "ID3D12GraphicsCommandList", "CopyTiles").slot,
            None
        );
        assert_eq!(
            row(
                &newer,
                "ID3D12GraphicsCommandList",
                "CopyRaytracingAccelerationStructure"
            )
            .slot,
            None
        );

        assert_eq!(row(&newer, "ID3D12Resource", "Map").slot, Some(8));
        assert_eq!(row(&newer, "ID3D12Resource", "Unmap").slot, Some(9));
        assert_eq!(row(&newer, "ID3D12Resource", "GetDesc").slot, Some(10));
        assert_eq!(
            row(&newer, "ID3D12Resource", "GetGPUVirtualAddress").slot,
            Some(11)
        );
        assert_eq!(row(&newer, "ID3D12Fence", "GetCompletedValue").slot, Some(8));
        assert_eq!(
            row(
                &newer,
                "ID3D12DescriptorHeap",
                "GetCPUDescriptorHandleForHeapStart"
            )
            .slot,
            Some(9)
        );
    }

    /// The logged table names both the matches and the differences, so a
    /// run's log can be diffed against PORTING.md by eye.
    #[test]
    fn the_logged_table_names_the_slots_and_differences() {
        let text = table_text(&rows(true), "newer (XS)");
        println!("{text}");
        assert!(text.contains("ID3D12CommandQueue"), "interface named");
        assert!(text.contains("Signal"), "method named");
        assert!(text.contains("DIFF"), "a difference is marked");
        assert!(text.contains("SetMarker"), "the slot's occupant is named");
        assert!(text.contains("RageBuffer (64 bytes)"), "notes printed");
    }

    /// The engine-side `RageBuffer` PORTING.md §3 describes: 64 bytes with
    /// these offsets. This layer has no RageBuffer (resources arrive as
    /// D3D12 descriptions), so this pins the numbers for anything that
    /// later reads one.
    #[test]
    fn the_porting_notes_rage_buffer_is_64_bytes() {
        #[allow(dead_code)] // the layout is the point
        #[repr(C)]
        struct RageBuffer {
            functions: *const (),
            element_count: u32,
            element_stride_and_flags: u16,
            resource_flags: u16,
            memory_flags: u8,
            format_or_usage_flags: u8,
            format_type_index: u16,
            additional_offset: u32,
            gpu_address: u64,
            resource: *const (),
            view_state: *const (),
            related_state: *const (),
            cpu_address_or_cbv: u64,
        }
        assert_eq!(size_of::<RageBuffer>(), 64);
        assert_eq!(offset_of!(RageBuffer, element_count), 0x08);
        assert_eq!(offset_of!(RageBuffer, element_stride_and_flags), 0x0c);
        assert_eq!(offset_of!(RageBuffer, resource_flags), 0x0e);
        assert_eq!(offset_of!(RageBuffer, memory_flags), 0x10);
        assert_eq!(offset_of!(RageBuffer, format_or_usage_flags), 0x11);
        assert_eq!(offset_of!(RageBuffer, format_type_index), 0x12);
        assert_eq!(offset_of!(RageBuffer, additional_offset), 0x14);
        assert_eq!(offset_of!(RageBuffer, gpu_address), 0x18);
        assert_eq!(offset_of!(RageBuffer, resource), 0x20);
        assert_eq!(offset_of!(RageBuffer, view_state), 0x28);
        assert_eq!(offset_of!(RageBuffer, related_state), 0x30);
        assert_eq!(offset_of!(RageBuffer, cpu_address_or_cbv), 0x38);

        // RageMemoryType: Default=0, Upload=1, Readback=2, Custom=3, and
        // the heap types they map onto here.
        assert_eq!(RAGE_MEMORY_TYPE_HEAP, [1, 2, 3, 4]);
    }
}