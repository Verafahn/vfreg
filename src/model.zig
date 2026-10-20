//! In-memory representation of a CMSIS-SVD document.
//!
//! The model mirrors the element hierarchy described by the CMSIS-SVD
//! specification:
//!
//!   device -> peripherals -> registers/clusters -> fields -> enumeratedValues
//!
//! Inheritance of register properties (size, access, resetValue, resetMask)
//! is resolved by the parser: every peripheral, cluster and register stores
//! the properties that are effective for its subtree.  Optional values that
//! are still absent after inheritance mean "not specified by the SVD file".

const std = @import("std");

/// Access rights of a register or field (`accessType` in the schema).
pub const Access = enum {
    read_only,
    write_only,
    read_write,
    write_once,
    read_write_once,

    /// Human readable form used in generated documentation comments.
    pub fn label(self: Access) []const u8 {
        return switch (self) {
            .read_only => "Read-Only",
            .write_only, .write_once => "Write-Only",
            .read_write, .read_write_once => "Read-Write",
        };
    }
};

/// Write side effects (`modifiedWriteValuesType` in the schema).
pub const ModifiedWriteValues = enum {
    one_to_clear,
    one_to_set,
    one_to_toggle,
    zero_to_clear,
    zero_to_set,
    zero_to_toggle,
    clear,
    set,
    modify,
};

/// Read side effects (`readActionType` in the schema).
pub const ReadAction = enum {
    clear,
    set,
    modify,
    modify_external,
};

/// The `usage` of an enumeratedValues set.
pub const EnumUsage = enum {
    read,
    write,
    read_write,
};

/// Endianness of the processor (`endianType` in the schema).
pub const Endian = enum {
    little,
    big,
    selectable,
    other,
};

/// Usage of an address block.
pub const AddressBlockUsage = enum {
    registers,
    buffer,
    reserved,
};

/// Inclusive range used by a write constraint.
pub const WriteRange = struct {
    minimum: u64,
    maximum: u64,
};

/// A subrange of values that may be written to a field or register.
pub const WriteConstraint = union(enum) {
    write_as_read: bool,
    use_enumerated_values: bool,
    range: WriteRange,
};

/// Inclusive bit range of a field within its register.
pub const BitRange = struct {
    offset: u32,
    width: u32,
};

/// Properties inherited from device -> peripheral -> cluster -> register.
pub const RegisterProperties = struct {
    /// Register width in bits (`size`).
    size: ?u32 = null,
    access: ?Access = null,
    /// CMSIS protection string, e.g. "s", "n" or "p".
    protection: ?[]const u8 = null,
    reset_value: ?u64 = null,
    reset_mask: ?u64 = null,

    /// Applies `overrides` on top of `base`.
    pub fn merged(base: RegisterProperties, overrides: RegisterProperties) RegisterProperties {
        return .{
            .size = overrides.size orelse base.size,
            .access = overrides.access orelse base.access,
            .protection = overrides.protection orelse base.protection,
            .reset_value = overrides.reset_value orelse base.reset_value,
            .reset_mask = overrides.reset_mask orelse base.reset_mask,
        };
    }

    /// Effective access, defaulting to read-write when the SVD does not say.
    pub fn effectiveAccess(self: RegisterProperties) Access {
        return self.access orelse .read_write;
    }

    /// Effective register width in bits.
    pub fn effectiveSize(self: RegisterProperties) u32 {
        return self.size orelse 32;
    }
};

/// The `dimElementGroup`: description of an array of peripherals, clusters,
/// registers or fields.
pub const DimElement = struct {
    /// Number of array elements.
    dim: u32,
    /// Address increment between elements. Bytes for peripherals, clusters and
    /// registers; bits for fields.
    dim_increment: u64,
    /// Optional index description, e.g. "0-3", "A-D" or "0,1,2,3".
    dim_index: ?[]const u8 = null,
    /// Optional name of the C array.
    dim_name: ?[]const u8 = null,
    dim_array_index: ?DimArrayIndex = null,
};

/// Enumerated index names attached to an array (`dimArrayIndexType`).
pub const DimArrayIndex = struct {
    header_enum_name: ?[]const u8 = null,
    values: []EnumeratedValue = &.{},
};

/// One value of an enumeration.
pub const EnumeratedValue = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    /// Numeric value. `null` for `isDefault` entries or values that use
    /// binary don't-care bits such as `0b1xx`.
    value: ?u64 = null,
    is_default: bool = false,
};

/// An `enumeratedValues` element. A field may contain up to two of them
/// (one for read access and one for write access).
pub const EnumeratedValues = struct {
    name: ?[]const u8 = null,
    header_enum_name: ?[]const u8 = null,
    usage: ?EnumUsage = null,
    derived_from: ?[]const u8 = null,
    values: []EnumeratedValue = &.{},
};

/// A bit field of a register.
pub const Field = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    bit_range: ?BitRange = null,
    access: ?Access = null,
    modified_write_values: ?ModifiedWriteValues = null,
    write_constraint: ?WriteConstraint = null,
    read_action: ?ReadAction = null,
    enumerated_values: []EnumeratedValues = &.{},
    dim: ?DimElement = null,
    derived_from: ?[]const u8 = null,
};

/// A register.
pub const Register = struct {
    name: []const u8,
    display_name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    alternate_group: ?[]const u8 = null,
    alternate_register: ?[]const u8 = null,
    address_offset: u64 = 0,
    /// Effective properties after inheritance.
    properties: RegisterProperties = .{},
    /// Properties explicitly written on this register.  Used when resolving
    /// `derivedFrom`, where unspecified properties come from the base.
    local_properties: RegisterProperties = .{},
    data_type: ?[]const u8 = null,
    modified_write_values: ?ModifiedWriteValues = null,
    write_constraint: ?WriteConstraint = null,
    read_action: ?ReadAction = null,
    fields: []Field = &.{},
    dim: ?DimElement = null,
    derived_from: ?[]const u8 = null,
};

/// A cluster groups registers and other clusters at an address offset.
pub const Cluster = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    alternate_cluster: ?[]const u8 = null,
    header_struct_name: ?[]const u8 = null,
    address_offset: u64 = 0,
    /// Effective properties after inheritance.
    properties: RegisterProperties = .{},
    /// Properties explicitly written on this cluster.
    local_properties: RegisterProperties = .{},
    children: []RegisterNode = &.{},
    dim: ?DimElement = null,
    derived_from: ?[]const u8 = null,
};

/// A register or a cluster inside a `registers` section.
pub const RegisterNode = union(enum) {
    register: Register,
    cluster: Cluster,
};

/// An address block assigned to a peripheral.
pub const AddressBlock = struct {
    offset: u64,
    size: u64,
    usage: AddressBlockUsage = .registers,
    protection: ?[]const u8 = null,
};

/// An interrupt associated with a peripheral.
pub const Interrupt = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    value: i64 = 0,
};

/// Processor description of the device.
pub const Cpu = struct {
    name: []const u8,
    revision: ?[]const u8 = null,
    endian: Endian = .other,
    mpu_present: ?bool = null,
    fpu_present: ?bool = null,
    fpu_dp: ?bool = null,
    dsp_present: ?bool = null,
    icache_present: ?bool = null,
    dcache_present: ?bool = null,
    itcm_present: ?bool = null,
    dtcm_present: ?bool = null,
    vtor_present: ?bool = null,
    nvic_prio_bits: u32 = 0,
    vendor_systick_config: bool = false,
    device_num_interrupts: ?u32 = null,
    sau_num_regions: ?u32 = null,
};

/// A peripheral of the device.
pub const Peripheral = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    alternate_peripheral: ?[]const u8 = null,
    group_name: ?[]const u8 = null,
    prepend_to_name: ?[]const u8 = null,
    append_to_name: ?[]const u8 = null,
    header_struct_name: ?[]const u8 = null,
    disable_condition: ?[]const u8 = null,
    base_address: u64 = 0,
    /// Effective properties after inheritance.
    properties: RegisterProperties = .{},
    /// Properties explicitly written on this peripheral.
    local_properties: RegisterProperties = .{},
    address_blocks: []AddressBlock = &.{},
    interrupts: []Interrupt = &.{},
    registers: []RegisterNode = &.{},
    dim: ?DimElement = null,
    derived_from: ?[]const u8 = null,
};

/// The root `device` element.
pub const Device = struct {
    schema_version: ?[]const u8 = null,
    vendor: ?[]const u8 = null,
    vendor_id: ?[]const u8 = null,
    name: []const u8,
    series: ?[]const u8 = null,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    license_text: ?[]const u8 = null,
    cpu: ?Cpu = null,
    header_system_filename: ?[]const u8 = null,
    header_definitions_prefix: ?[]const u8 = null,
    /// Size of the smallest addressable unit in bits.
    address_unit_bits: u32 = 8,
    /// Maximum single transfer width in bits.
    width: u32 = 32,
    /// Device-level register defaults.
    properties: RegisterProperties = .{},
    peripherals: []Peripheral = &.{},
    /// True when a vendorExtensions section was present (its content is
    /// intentionally ignored).
    has_vendor_extensions: bool = false,
};

test "register properties merge" {
    const base: RegisterProperties = .{
        .size = 32,
        .access = .read_write,
        .reset_value = 0,
    };
    const merged = RegisterProperties.merged(base, .{ .access = .read_only });
    try std.testing.expectEqual(@as(?u32, 32), merged.size);
    try std.testing.expectEqual(Access.read_only, merged.access.?);
    try std.testing.expectEqual(@as(?u64, 0), merged.reset_value);
}
