//! Recursive-descent parser that turns a CMSIS-SVD XML event stream into the
//! memory model in `model.zig`.
//!
//! The parser consumes XML nodes one at a time through `zig-xml`; it never
//! builds a DOM.  Each SVD element is handled by a dedicated function that
//! recursively consumes its children.

const std = @import("std");
const xml = @import("xml");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;

pub const Error = xml.Reader.ReadError || error{InvalidSvd};

pub const Diagnostic = struct {
    message: []const u8,
    line: usize,
    column: usize,
};

pub const Parser = struct {
    gpa: Allocator,
    reader: xml.Reader.Static,
    node: xml.Reader.Node = .eof,
    diagnostic: ?Diagnostic = null,

    pub fn init(gpa: Allocator, data: []const u8) Parser {
        return .{
            .gpa = gpa,
            .reader = .init(gpa, data, .{ .namespace_aware = false }),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.reader.deinit();
    }

    /// Parses a whole `<device>` document.  All strings in the returned model
    /// are allocated with the allocator passed to `init` (an arena is the
    /// natural choice).
    pub fn parse(self: *Parser) Error!model.Device {
        try self.reader.interface.skipProlog();
        self.node = .element_start;

        if (!std.mem.eql(u8, self.reader.interface.elementName(), "device")) {
            return self.fail("expected <device> root element, found <{s}>", .{self.reader.interface.elementName()});
        }

        var device: model.Device = .{
            .name = "",
            .schema_version = try self.optionalAttribute("schemaVersion"),
        };

        try self.advance();
        while (try self.nextChild()) |tag| {
            if (std.mem.eql(u8, tag, "vendor")) {
                device.vendor = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "vendorID")) {
                device.vendor_id = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "name")) {
                device.name = try self.parseName(tag);
            } else if (std.mem.eql(u8, tag, "series")) {
                device.series = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "version")) {
                device.version = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "description")) {
                device.description = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "licenseText")) {
                device.license_text = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "cpu")) {
                device.cpu = try self.parseCpu();
            } else if (std.mem.eql(u8, tag, "headerSystemFilename")) {
                device.header_system_filename = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "headerDefinitionsPrefix")) {
                device.header_definitions_prefix = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "addressUnitBits")) {
                device.address_unit_bits = try self.parseU32Element(tag);
            } else if (std.mem.eql(u8, tag, "width")) {
                device.width = try self.parseU32Element(tag);
            } else if (std.mem.eql(u8, tag, "size")) {
                device.properties.size = try self.parseU32Element(tag);
            } else if (std.mem.eql(u8, tag, "access")) {
                device.properties.access = try self.parseAccess(tag);
            } else if (std.mem.eql(u8, tag, "protection")) {
                device.properties.protection = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "resetValue")) {
                device.properties.reset_value = try self.parseUintElement(tag);
            } else if (std.mem.eql(u8, tag, "resetMask")) {
                device.properties.reset_mask = try self.parseUintElement(tag);
            } else if (std.mem.eql(u8, tag, "peripherals")) {
                device.peripherals = try self.parsePeripherals(device.properties);
            } else if (std.mem.eql(u8, tag, "vendorExtensions")) {
                device.has_vendor_extensions = true;
                try self.skipCurrentElement();
            } else {
                try self.skipCurrentElement();
            }
        }

        if (device.name.len == 0) {
            return self.fail("device is missing a <name>", .{});
        }

        self.resolvePeripheralDerivations(device.peripherals);
        try self.resolveEnumDerivations(device.peripherals);

        try self.reader.interface.skipDocument();
        self.node = .eof;
        return device;
    }

    fn parsePeripherals(self: *Parser, inherited: model.RegisterProperties) Error![]model.Peripheral {
        try self.expectStart("peripherals");
        try self.advance();
        var list: std.ArrayList(model.Peripheral) = .empty;
        while (try self.nextChild()) |tag| {
            if (std.mem.eql(u8, tag, "peripheral")) {
                try list.append(self.gpa, try self.parsePeripheral(inherited));
            } else {
                try self.skipCurrentElement();
            }
        }
        return try list.toOwnedSlice(self.gpa);
    }

    fn parsePeripheral(self: *Parser, inherited: model.RegisterProperties) Error!model.Peripheral {
        try self.expectStart("peripheral");

        var p: model.Peripheral = .{
            .name = "",
            .derived_from = try self.optionalAttribute("derivedFrom"),
        };
        var effective = inherited;
        var local: model.RegisterProperties = .{};
        var has_base_address = false;

        var dim: ?u32 = null;
        var dim_increment: ?u64 = null;
        var dim_index: ?[]const u8 = null;
        var dim_name: ?[]const u8 = null;
        var dim_array_index: ?model.DimArrayIndex = null;

        var blocks: std.ArrayList(model.AddressBlock) = .empty;
        var interrupts: std.ArrayList(model.Interrupt) = .empty;

        try self.advance();
        while (try self.nextChild()) |tag| {
            if (std.mem.eql(u8, tag, "dim")) {
                dim = try self.parseU32Element(tag);
            } else if (std.mem.eql(u8, tag, "dimIncrement")) {
                dim_increment = try self.parseUintElement(tag);
            } else if (std.mem.eql(u8, tag, "dimIndex")) {
                dim_index = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "dimName")) {
                dim_name = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "dimArrayIndex")) {
                dim_array_index = try self.parseDimArrayIndex();
            } else if (std.mem.eql(u8, tag, "name")) {
                p.name = try self.parseName(tag);
            } else if (std.mem.eql(u8, tag, "version")) {
                p.version = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "description")) {
                p.description = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "alternatePeripheral")) {
                p.alternate_peripheral = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "groupName")) {
                p.group_name = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "prependToName")) {
                p.prepend_to_name = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "appendToName")) {
                p.append_to_name = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "headerStructName")) {
                p.header_struct_name = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "disableCondition")) {
                p.disable_condition = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "baseAddress")) {
                p.base_address = try self.parseUintElement(tag);
                has_base_address = true;
            } else if (std.mem.eql(u8, tag, "size")) {
                const value = try self.parseU32Element(tag);
                local.size = value;
                effective.size = value;
            } else if (std.mem.eql(u8, tag, "access")) {
                const value = try self.parseAccess(tag);
                local.access = value;
                effective.access = value;
            } else if (std.mem.eql(u8, tag, "protection")) {
                const value = try self.parseDescription(tag);
                local.protection = value;
                effective.protection = value;
            } else if (std.mem.eql(u8, tag, "resetValue")) {
                const value = try self.parseUintElement(tag);
                local.reset_value = value;
                effective.reset_value = value;
            } else if (std.mem.eql(u8, tag, "resetMask")) {
                const value = try self.parseUintElement(tag);
                local.reset_mask = value;
                effective.reset_mask = value;
            } else if (std.mem.eql(u8, tag, "addressBlock")) {
                try blocks.append(self.gpa, try self.parseAddressBlock());
            } else if (std.mem.eql(u8, tag, "interrupt")) {
                try interrupts.append(self.gpa, try self.parseInterrupt());
            } else if (std.mem.eql(u8, tag, "registers")) {
                p.registers = try self.parseRegisters(effective);
            } else {
                try self.skipCurrentElement();
            }
        }

        if (p.name.len == 0) return self.fail("peripheral is missing a <name>", .{});
        if (!has_base_address) return self.fail("peripheral '{s}' is missing <baseAddress>", .{p.name});

        p.properties = effective;
        p.local_properties = local;
        p.address_blocks = try blocks.toOwnedSlice(self.gpa);
        p.interrupts = try interrupts.toOwnedSlice(self.gpa);
        p.dim = try self.buildDim(dim, dim_increment, dim_index, dim_name, dim_array_index);
        return p;
    }

    fn parseAddressBlock(self: *Parser) Error!model.AddressBlock {
        try self.expectStart("addressBlock");
        var block: model.AddressBlock = .{ .offset = 0, .size = 0 };
        var has_offset = false;
        var has_size = false;

        try self.advance();
        while (try self.nextChild()) |tag| {
            if (std.mem.eql(u8, tag, "offset")) {
                block.offset = try self.parseUintElement(tag);
                has_offset = true;
            } else if (std.mem.eql(u8, tag, "size")) {
                block.size = try self.parseUintElement(tag);
                has_size = true;
            } else if (std.mem.eql(u8, tag, "usage")) {
                const text = try self.parseTextElement(tag);
                block.usage = if (std.mem.eql(u8, text, "registers"))
                    .registers
                else if (std.mem.eql(u8, text, "buffer"))
                    .buffer
                else if (std.mem.eql(u8, text, "reserved"))
                    .reserved
                else
                    return self.fail("invalid address block usage '{s}'", .{text});
            } else if (std.mem.eql(u8, tag, "protection")) {
                block.protection = try self.parseDescription(tag);
            } else {
                try self.skipCurrentElement();
            }
        }

        if (!has_offset) return self.fail("addressBlock is missing <offset>", .{});
        if (!has_size) return self.fail("addressBlock is missing <size>", .{});
        return block;
    }

    fn parseInterrupt(self: *Parser) Error!model.Interrupt {
        try self.expectStart("interrupt");
        var interrupt: model.Interrupt = .{ .name = "" };
        var has_value = false;

        try self.advance();
        while (try self.nextChild()) |tag| {
            if (std.mem.eql(u8, tag, "name")) {
                interrupt.name = try self.parseName(tag);
            } else if (std.mem.eql(u8, tag, "description")) {
                interrupt.description = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "value")) {
                interrupt.value = @intCast(try self.parseUintElement(tag));
                has_value = true;
            } else {
                try self.skipCurrentElement();
            }
        }

        if (interrupt.name.len == 0) return self.fail("interrupt is missing a <name>", .{});
        if (!has_value) return self.fail("interrupt '{s}' is missing <value>", .{interrupt.name});
        return interrupt;
    }

    fn parseRegisters(self: *Parser, inherited: model.RegisterProperties) Error![]model.RegisterNode {
        try self.expectStart("registers");
        try self.advance();
        var list: std.ArrayList(model.RegisterNode) = .empty;
        while (try self.nextChild()) |tag| {
            if (std.mem.eql(u8, tag, "register")) {
                try list.append(self.gpa, .{ .register = try self.parseRegister(inherited) });
            } else if (std.mem.eql(u8, tag, "cluster")) {
                try list.append(self.gpa, .{ .cluster = try self.parseCluster(inherited) });
            } else {
                try self.skipCurrentElement();
            }
        }
        return try list.toOwnedSlice(self.gpa);
    }

    fn parseRegister(self: *Parser, inherited: model.RegisterProperties) Error!model.Register {
        try self.expectStart("register");

        var r: model.Register = .{
            .name = "",
            .derived_from = try self.optionalAttribute("derivedFrom"),
        };
        var effective = inherited;
        var local: model.RegisterProperties = .{};
        var has_address_offset = false;

        var dim: ?u32 = null;
        var dim_increment: ?u64 = null;
        var dim_index: ?[]const u8 = null;
        var dim_name: ?[]const u8 = null;
        var dim_array_index: ?model.DimArrayIndex = null;

        try self.advance();
        while (try self.nextChild()) |tag| {
            if (std.mem.eql(u8, tag, "dim")) {
                dim = try self.parseU32Element(tag);
            } else if (std.mem.eql(u8, tag, "dimIncrement")) {
                dim_increment = try self.parseUintElement(tag);
            } else if (std.mem.eql(u8, tag, "dimIndex")) {
                dim_index = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "dimName")) {
                dim_name = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "dimArrayIndex")) {
                dim_array_index = try self.parseDimArrayIndex();
            } else if (std.mem.eql(u8, tag, "name")) {
                r.name = try self.parseName(tag);
            } else if (std.mem.eql(u8, tag, "displayName")) {
                r.display_name = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "description")) {
                r.description = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "alternateGroup")) {
                r.alternate_group = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "alternateRegister")) {
                r.alternate_register = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "addressOffset")) {
                r.address_offset = try self.parseUintElement(tag);
                has_address_offset = true;
            } else if (std.mem.eql(u8, tag, "size")) {
                const value = try self.parseU32Element(tag);
                local.size = value;
                effective.size = value;
            } else if (std.mem.eql(u8, tag, "access")) {
                const value = try self.parseAccess(tag);
                local.access = value;
                effective.access = value;
            } else if (std.mem.eql(u8, tag, "protection")) {
                const value = try self.parseDescription(tag);
                local.protection = value;
                effective.protection = value;
            } else if (std.mem.eql(u8, tag, "resetValue")) {
                const value = try self.parseUintElement(tag);
                local.reset_value = value;
                effective.reset_value = value;
            } else if (std.mem.eql(u8, tag, "resetMask")) {
                const value = try self.parseUintElement(tag);
                local.reset_mask = value;
                effective.reset_mask = value;
            } else if (std.mem.eql(u8, tag, "dataType")) {
                r.data_type = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "modifiedWriteValues")) {
                r.modified_write_values = try self.parseModifiedWriteValues(tag);
            } else if (std.mem.eql(u8, tag, "writeConstraint")) {
                r.write_constraint = try self.parseWriteConstraint();
            } else if (std.mem.eql(u8, tag, "readAction")) {
                r.read_action = try self.parseReadAction(tag);
            } else if (std.mem.eql(u8, tag, "fields")) {
                r.fields = try self.parseFields();
            } else {
                try self.skipCurrentElement();
            }
        }

        if (r.name.len == 0) return self.fail("register is missing a <name>", .{});
        if (!has_address_offset) return self.fail("register '{s}' is missing <addressOffset>", .{r.name});

        r.properties = effective;
        r.local_properties = local;
        r.dim = try self.buildDim(dim, dim_increment, dim_index, dim_name, dim_array_index);
        return r;
    }

    fn parseCluster(self: *Parser, inherited: model.RegisterProperties) Error!model.Cluster {
        try self.expectStart("cluster");

        var c: model.Cluster = .{
            .name = "",
            .derived_from = try self.optionalAttribute("derivedFrom"),
        };
        var effective = inherited;
        var local: model.RegisterProperties = .{};
        var has_address_offset = false;

        var dim: ?u32 = null;
        var dim_increment: ?u64 = null;
        var dim_index: ?[]const u8 = null;
        var dim_name: ?[]const u8 = null;
        var dim_array_index: ?model.DimArrayIndex = null;
        var children: std.ArrayList(model.RegisterNode) = .empty;

        try self.advance();
        while (try self.nextChild()) |tag| {
            if (std.mem.eql(u8, tag, "dim")) {
                dim = try self.parseU32Element(tag);
            } else if (std.mem.eql(u8, tag, "dimIncrement")) {
                dim_increment = try self.parseUintElement(tag);
            } else if (std.mem.eql(u8, tag, "dimIndex")) {
                dim_index = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "dimName")) {
                dim_name = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "dimArrayIndex")) {
                dim_array_index = try self.parseDimArrayIndex();
            } else if (std.mem.eql(u8, tag, "name")) {
                c.name = try self.parseName(tag);
            } else if (std.mem.eql(u8, tag, "description")) {
                c.description = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "alternateCluster")) {
                c.alternate_cluster = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "headerStructName")) {
                c.header_struct_name = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "addressOffset")) {
                c.address_offset = try self.parseUintElement(tag);
                has_address_offset = true;
            } else if (std.mem.eql(u8, tag, "size")) {
                const value = try self.parseU32Element(tag);
                local.size = value;
                effective.size = value;
            } else if (std.mem.eql(u8, tag, "access")) {
                const value = try self.parseAccess(tag);
                local.access = value;
                effective.access = value;
            } else if (std.mem.eql(u8, tag, "protection")) {
                const value = try self.parseDescription(tag);
                local.protection = value;
                effective.protection = value;
            } else if (std.mem.eql(u8, tag, "resetValue")) {
                const value = try self.parseUintElement(tag);
                local.reset_value = value;
                effective.reset_value = value;
            } else if (std.mem.eql(u8, tag, "resetMask")) {
                const value = try self.parseUintElement(tag);
                local.reset_mask = value;
                effective.reset_mask = value;
            } else if (std.mem.eql(u8, tag, "register")) {
                try children.append(self.gpa, .{ .register = try self.parseRegister(effective) });
            } else if (std.mem.eql(u8, tag, "cluster")) {
                try children.append(self.gpa, .{ .cluster = try self.parseCluster(effective) });
            } else {
                try self.skipCurrentElement();
            }
        }

        if (c.name.len == 0) return self.fail("cluster is missing a <name>", .{});
        if (!has_address_offset) return self.fail("cluster '{s}' is missing <addressOffset>", .{c.name});

        c.properties = effective;
        c.local_properties = local;
        c.children = try children.toOwnedSlice(self.gpa);
        c.dim = try self.buildDim(dim, dim_increment, dim_index, dim_name, dim_array_index);
        return c;
    }

    fn parseFields(self: *Parser) Error![]model.Field {
        try self.expectStart("fields");
        try self.advance();
        var list: std.ArrayList(model.Field) = .empty;
        while (try self.nextChild()) |tag| {
            if (std.mem.eql(u8, tag, "field")) {
                try list.append(self.gpa, try self.parseField());
            } else {
                try self.skipCurrentElement();
            }
        }
        return try list.toOwnedSlice(self.gpa);
    }

    fn parseField(self: *Parser) Error!model.Field {
        try self.expectStart("field");

        var f: model.Field = .{
            .name = "",
            .derived_from = try self.optionalAttribute("derivedFrom"),
        };

        var dim: ?u32 = null;
        var dim_increment: ?u64 = null;
        var dim_index: ?[]const u8 = null;
        var dim_name: ?[]const u8 = null;
        var dim_array_index: ?model.DimArrayIndex = null;

        var bit_offset: ?u32 = null;
        var bit_width: ?u32 = null;
        var lsb: ?u32 = null;
        var msb: ?u32 = null;
        var bit_range_text: ?[]const u8 = null;
        var enums: std.ArrayList(model.EnumeratedValues) = .empty;

        try self.advance();
        while (try self.nextChild()) |tag| {
            if (std.mem.eql(u8, tag, "dim")) {
                dim = try self.parseU32Element(tag);
            } else if (std.mem.eql(u8, tag, "dimIncrement")) {
                dim_increment = try self.parseUintElement(tag);
            } else if (std.mem.eql(u8, tag, "dimIndex")) {
                dim_index = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "dimName")) {
                dim_name = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "dimArrayIndex")) {
                dim_array_index = try self.parseDimArrayIndex();
            } else if (std.mem.eql(u8, tag, "name")) {
                f.name = try self.parseName(tag);
            } else if (std.mem.eql(u8, tag, "description")) {
                f.description = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "bitOffset")) {
                bit_offset = try self.parseU32Element(tag);
            } else if (std.mem.eql(u8, tag, "bitWidth")) {
                bit_width = try self.parseU32Element(tag);
            } else if (std.mem.eql(u8, tag, "lsb")) {
                lsb = try self.parseU32Element(tag);
            } else if (std.mem.eql(u8, tag, "msb")) {
                msb = try self.parseU32Element(tag);
            } else if (std.mem.eql(u8, tag, "bitRange")) {
                bit_range_text = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "access")) {
                f.access = try self.parseAccess(tag);
            } else if (std.mem.eql(u8, tag, "modifiedWriteValues")) {
                f.modified_write_values = try self.parseModifiedWriteValues(tag);
            } else if (std.mem.eql(u8, tag, "writeConstraint")) {
                f.write_constraint = try self.parseWriteConstraint();
            } else if (std.mem.eql(u8, tag, "readAction")) {
                f.read_action = try self.parseReadAction(tag);
            } else if (std.mem.eql(u8, tag, "enumeratedValues")) {
                try enums.append(self.gpa, try self.parseEnumeratedValues());
            } else {
                try self.skipCurrentElement();
            }
        }

        if (f.name.len == 0) return self.fail("field is missing a <name>", .{});
        if (lsb != null or msb != null) {
            const low = lsb orelse return self.fail("field '{s}' has <msb> without <lsb>", .{f.name});
            const high = msb orelse return self.fail("field '{s}' has <lsb> without <msb>", .{f.name});
            if (high < low) return self.fail("field '{s}' has <msb> smaller than <lsb>", .{f.name});
            f.bit_range = .{ .offset = low, .width = high - low + 1 };
        } else if (bit_offset != null) {
            f.bit_range = .{
                .offset = bit_offset.?,
                .width = bit_width orelse 1,
            };
        } else if (bit_range_text) |text| {
            f.bit_range = parseBitRange(text) catch
                return self.fail("field '{s}' has an invalid bitRange '{s}'", .{ f.name, text });
        } else if (f.derived_from == null) {
            return self.fail("field '{s}' has no bit position", .{f.name});
        }

        if (f.bit_range) |range| {
            if (range.width == 0) return self.fail("field '{s}' has zero width", .{f.name});
        }

        f.enumerated_values = try enums.toOwnedSlice(self.gpa);
        f.dim = try self.buildDim(dim, dim_increment, dim_index, dim_name, dim_array_index);
        return f;
    }

    fn parseEnumeratedValues(self: *Parser) Error!model.EnumeratedValues {
        try self.expectStart("enumeratedValues");

        var e: model.EnumeratedValues = .{
            .derived_from = try self.optionalAttribute("derivedFrom"),
        };
        var values: std.ArrayList(model.EnumeratedValue) = .empty;

        try self.advance();
        while (try self.nextChild()) |tag| {
            if (std.mem.eql(u8, tag, "name")) {
                e.name = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "headerEnumName")) {
                e.header_enum_name = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "usage")) {
                const text = try self.parseTextElement(tag);
                e.usage = if (std.mem.eql(u8, text, "read"))
                    .read
                else if (std.mem.eql(u8, text, "write"))
                    .write
                else if (std.mem.eql(u8, text, "read-write"))
                    .read_write
                else
                    return self.fail("invalid enumeratedValues usage '{s}'", .{text});
            } else if (std.mem.eql(u8, tag, "enumeratedValue")) {
                try values.append(self.gpa, try self.parseEnumeratedValue());
            } else {
                try self.skipCurrentElement();
            }
        }

        e.values = try values.toOwnedSlice(self.gpa);
        return e;
    }

    fn parseEnumeratedValue(self: *Parser) Error!model.EnumeratedValue {
        try self.expectStart("enumeratedValue");

        var value: model.EnumeratedValue = .{ .name = "" };
        var value_text: ?[]const u8 = null;
        var is_default_text: ?[]const u8 = null;

        try self.advance();
        while (try self.nextChild()) |tag| {
            if (std.mem.eql(u8, tag, "name")) {
                value.name = try self.parseName(tag);
            } else if (std.mem.eql(u8, tag, "description")) {
                value.description = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "value")) {
                value_text = try self.parseTextElement(tag);
            } else if (std.mem.eql(u8, tag, "isDefault")) {
                is_default_text = try self.parseTextElement(tag);
            } else {
                try self.skipCurrentElement();
            }
        }

        if (value.name.len == 0) return self.fail("enumeratedValue is missing a <name>", .{});
        if (is_default_text) |text| {
            if (parseBool(text)) |is_default| {
                value.is_default = is_default;
            } else {
                return self.fail("invalid isDefault value '{s}'", .{text});
            }
        }
        if (value_text) |text| {
            value.value = parseScaledUint(text) catch null;
        }
        return value;
    }

    fn parseDimArrayIndex(self: *Parser) Error!model.DimArrayIndex {
        try self.expectStart("dimArrayIndex");
        var index: model.DimArrayIndex = .{};
        var values: std.ArrayList(model.EnumeratedValue) = .empty;

        try self.advance();
        while (try self.nextChild()) |tag| {
            if (std.mem.eql(u8, tag, "headerEnumName")) {
                index.header_enum_name = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "enumeratedValue")) {
                try values.append(self.gpa, try self.parseEnumeratedValue());
            } else {
                try self.skipCurrentElement();
            }
        }

        index.values = try values.toOwnedSlice(self.gpa);
        return index;
    }

    fn parseCpu(self: *Parser) Error!model.Cpu {
        try self.expectStart("cpu");
        var cpu: model.Cpu = .{ .name = "" };

        try self.advance();
        while (try self.nextChild()) |tag| {
            if (std.mem.eql(u8, tag, "name")) {
                cpu.name = try self.parseName(tag);
            } else if (std.mem.eql(u8, tag, "revision")) {
                cpu.revision = try self.parseDescription(tag);
            } else if (std.mem.eql(u8, tag, "endian")) {
                const text = try self.parseTextElement(tag);
                cpu.endian = if (std.mem.eql(u8, text, "little"))
                    .little
                else if (std.mem.eql(u8, text, "big"))
                    .big
                else if (std.mem.eql(u8, text, "selectable"))
                    .selectable
                else
                    .other;
            } else if (std.mem.eql(u8, tag, "mpuPresent")) {
                cpu.mpu_present = try self.parseBoolElement(tag);
            } else if (std.mem.eql(u8, tag, "fpuPresent")) {
                cpu.fpu_present = try self.parseBoolElement(tag);
            } else if (std.mem.eql(u8, tag, "fpuDP")) {
                cpu.fpu_dp = try self.parseBoolElement(tag);
            } else if (std.mem.eql(u8, tag, "dspPresent")) {
                cpu.dsp_present = try self.parseBoolElement(tag);
            } else if (std.mem.eql(u8, tag, "icachePresent")) {
                cpu.icache_present = try self.parseBoolElement(tag);
            } else if (std.mem.eql(u8, tag, "dcachePresent")) {
                cpu.dcache_present = try self.parseBoolElement(tag);
            } else if (std.mem.eql(u8, tag, "itcmPresent")) {
                cpu.itcm_present = try self.parseBoolElement(tag);
            } else if (std.mem.eql(u8, tag, "dtcmPresent")) {
                cpu.dtcm_present = try self.parseBoolElement(tag);
            } else if (std.mem.eql(u8, tag, "vtorPresent")) {
                cpu.vtor_present = try self.parseBoolElement(tag);
            } else if (std.mem.eql(u8, tag, "nvicPrioBits")) {
                cpu.nvic_prio_bits = try self.parseU32Element(tag);
            } else if (std.mem.eql(u8, tag, "vendorSystickConfig")) {
                cpu.vendor_systick_config = try self.parseBoolElement(tag);
            } else if (std.mem.eql(u8, tag, "deviceNumInterrupts")) {
                cpu.device_num_interrupts = try self.parseU32Element(tag);
            } else if (std.mem.eql(u8, tag, "sauNumRegions")) {
                cpu.sau_num_regions = try self.parseU32Element(tag);
            } else {
                try self.skipCurrentElement();
            }
        }

        if (cpu.name.len == 0) return self.fail("cpu is missing a <name>", .{});
        return cpu;
    }

    fn parseAccess(self: *Parser, tag: []const u8) Error!model.Access {
        const text = try self.parseTextElement(tag);
        if (std.mem.eql(u8, text, "read-only")) return .read_only;
        if (std.mem.eql(u8, text, "write-only")) return .write_only;
        if (std.mem.eql(u8, text, "read-write")) return .read_write;
        if (std.mem.eql(u8, text, "writeOnce")) return .write_once;
        if (std.mem.eql(u8, text, "read-writeOnce")) return .read_write_once;
        return self.fail("invalid access value '{s}'", .{text});
    }

    fn parseModifiedWriteValues(self: *Parser, tag: []const u8) Error!model.ModifiedWriteValues {
        const text = try self.parseTextElement(tag);
        if (std.mem.eql(u8, text, "oneToClear")) return .one_to_clear;
        if (std.mem.eql(u8, text, "oneToSet")) return .one_to_set;
        if (std.mem.eql(u8, text, "oneToToggle")) return .one_to_toggle;
        if (std.mem.eql(u8, text, "zeroToClear")) return .zero_to_clear;
        if (std.mem.eql(u8, text, "zeroToSet")) return .zero_to_set;
        if (std.mem.eql(u8, text, "zeroToToggle")) return .zero_to_toggle;
        if (std.mem.eql(u8, text, "clear")) return .clear;
        if (std.mem.eql(u8, text, "set")) return .set;
        if (std.mem.eql(u8, text, "modify")) return .modify;
        return self.fail("invalid modifiedWriteValues value '{s}'", .{text});
    }

    fn parseReadAction(self: *Parser, tag: []const u8) Error!model.ReadAction {
        const text = try self.parseTextElement(tag);
        if (std.mem.eql(u8, text, "clear")) return .clear;
        if (std.mem.eql(u8, text, "set")) return .set;
        if (std.mem.eql(u8, text, "modify")) return .modify;
        if (std.mem.eql(u8, text, "modifyExternal")) return .modify_external;
        return self.fail("invalid readAction value '{s}'", .{text});
    }

    fn parseWriteConstraint(self: *Parser) Error!model.WriteConstraint {
        try self.expectStart("writeConstraint");
        var constraint: ?model.WriteConstraint = null;

        try self.advance();
        while (try self.nextChild()) |tag| {
            if (std.mem.eql(u8, tag, "writeAsRead")) {
                constraint = .{ .write_as_read = try self.parseBoolElement(tag) };
            } else if (std.mem.eql(u8, tag, "useEnumeratedValues")) {
                constraint = .{ .use_enumerated_values = try self.parseBoolElement(tag) };
            } else if (std.mem.eql(u8, tag, "range")) {
                constraint = .{ .range = try self.parseWriteRange() };
            } else {
                try self.skipCurrentElement();
            }
        }

        if (constraint) |value| return value;
        return self.fail("empty writeConstraint", .{});
    }

    fn parseWriteRange(self: *Parser) Error!model.WriteRange {
        try self.expectStart("range");
        var range: model.WriteRange = .{ .minimum = 0, .maximum = 0 };
        var has_minimum = false;
        var has_maximum = false;

        try self.advance();
        while (try self.nextChild()) |tag| {
            if (std.mem.eql(u8, tag, "minimum")) {
                range.minimum = try self.parseUintElement(tag);
                has_minimum = true;
            } else if (std.mem.eql(u8, tag, "maximum")) {
                range.maximum = try self.parseUintElement(tag);
                has_maximum = true;
            } else {
                try self.skipCurrentElement();
            }
        }

        if (!has_minimum or !has_maximum) return self.fail("writeConstraint range is incomplete", .{});
        return range;
    }

    fn buildDim(
        self: *Parser,
        dim: ?u32,
        dim_increment: ?u64,
        dim_index: ?[]const u8,
        dim_name: ?[]const u8,
        dim_array_index: ?model.DimArrayIndex,
    ) Error!?model.DimElement {
        if (dim == null) {
            if (dim_increment != null or dim_index != null or dim_name != null or dim_array_index != null) {
                return self.fail("dimension elements are present without <dim>", .{});
            }
            return null;
        }
        const increment = dim_increment orelse return self.fail("<dim> is missing <dimIncrement>", .{});
        if (dim.? == 0) return self.fail("<dim> must be greater than zero", .{});
        return .{
            .dim = dim.?,
            .dim_increment = increment,
            .dim_index = dim_index,
            .dim_name = dim_name,
            .dim_array_index = dim_array_index,
        };
    }

    fn parseTextElement(self: *Parser, tag: []const u8) Error![]const u8 {
        try self.expectStart(tag);
        const raw = try self.readLeafText();
        return std.mem.trim(u8, raw, " \t\r\n");
    }

    fn parseName(self: *Parser, tag: []const u8) Error![]const u8 {
        const text = try self.parseTextElement(tag);
        if (text.len == 0) return self.fail("<{s}> must not be empty", .{tag});
        return text;
    }

    fn parseDescription(self: *Parser, tag: []const u8) Error!?[]const u8 {
        const text = try self.parseTextElement(tag);
        if (text.len == 0) return null;
        return try self.collapseWhitespace(text);
    }

    fn parseUintElement(self: *Parser, tag: []const u8) Error!u64 {
        const text = try self.parseTextElement(tag);
        return parseScaledUint(text) catch
            return self.fail("invalid integer in <{s}>: '{s}'", .{ tag, text });
    }

    fn parseU32Element(self: *Parser, tag: []const u8) Error!u32 {
        const value = try self.parseUintElement(tag);
        if (value > std.math.maxInt(u32)) {
            return self.fail("value in <{s}> does not fit in 32 bits", .{tag});
        }
        return @intCast(value);
    }

    fn parseBoolElement(self: *Parser, tag: []const u8) Error!bool {
        const text = try self.parseTextElement(tag);
        if (parseBool(text)) |value| return value;
        return self.fail("invalid boolean in <{s}>: '{s}'", .{ tag, text });
    }

    fn optionalAttribute(self: *Parser, name: []const u8) Error!?[]const u8 {
        const index = self.reader.interface.attributeIndex(name) orelse return null;
        const value = try self.reader.interface.attributeValue(index);
        return try self.gpa.dupe(u8, std.mem.trim(u8, value, " \t\r\n"));
    }

    fn expectStart(self: *Parser, tag: []const u8) Error!void {
        if (self.node != .element_start) {
            return self.fail("expected <{s}>", .{tag});
        }
        if (!std.mem.eql(u8, self.reader.interface.elementName(), tag)) {
            return self.fail("expected <{s}>, found <{s}>", .{ tag, self.reader.interface.elementName() });
        }
    }

    fn advance(self: *Parser) Error!void {
        self.node = try self.reader.interface.read();
    }

    fn nextChild(self: *Parser) Error!?[]const u8 {
        while (true) {
            switch (self.node) {
                .element_start => return self.reader.interface.elementName(),
                .element_end => {
                    try self.advance();
                    return null;
                },
                .xml_declaration,
                .comment,
                .pi,
                .text,
                .cdata,
                .character_reference,
                .entity_reference,
                => try self.advance(),
                .eof => return self.fail("unexpected end of XML document", .{}),
            }
        }
    }

    fn skipCurrentElement(self: *Parser) Error!void {
        if (self.node != .element_start) return self.fail("expected an element", .{});
        try self.reader.interface.skipElement();
        self.node = .element_end;
        try self.advance();
    }

    fn readLeafText(self: *Parser) Error![]const u8 {
        if (self.node != .element_start) return self.fail("expected an element", .{});
        const text = try self.reader.interface.readElementTextAlloc(self.gpa);
        self.node = .element_end;
        try self.advance();
        return text;
    }

    fn collapseWhitespace(self: *Parser, text: []const u8) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
        var first = true;
        while (tokens.next()) |token| {
            if (!first) out.writer.writeByte(' ') catch return error.OutOfMemory;
            out.writer.writeAll(token) catch return error.OutOfMemory;
            first = false;
        }
        return try out.toOwnedSlice();
    }

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        if (self.diagnostic == null) {
            const location = self.reader.interface.location();
            const message = std.fmt.allocPrint(self.gpa, fmt, args) catch "invalid SVD document";
            self.diagnostic = .{
                .message = message,
                .line = location.line,
                .column = location.column,
            };
        }
        return error.InvalidSvd;
    }

    fn resolvePeripheralDerivations(self: *Parser, peripherals: []model.Peripheral) void {
        _ = self;
        for (peripherals) |*peripheral| {
            const derived_name = peripheral.derived_from orelse continue;
            const base_name = lastPathSegment(derived_name);
            var base: ?*const model.Peripheral = null;
            for (peripherals) |*candidate| {
                if (candidate == peripheral) continue;
                if (std.mem.eql(u8, candidate.name, base_name)) {
                    base = candidate;
                    break;
                }
            }
            const b = base orelse continue;
            peripheral.properties = model.RegisterProperties.merged(b.properties, peripheral.local_properties);
            if (peripheral.registers.len == 0) peripheral.registers = b.registers;
            if (peripheral.description == null) peripheral.description = b.description;
            if (peripheral.group_name == null) peripheral.group_name = b.group_name;
            if (peripheral.header_struct_name == null) peripheral.header_struct_name = b.header_struct_name;
            if (peripheral.address_blocks.len == 0) peripheral.address_blocks = b.address_blocks;
            if (peripheral.interrupts.len == 0) peripheral.interrupts = b.interrupts;
        }

        for (peripherals) |*peripheral| {
            resolveNodeDerivations(peripheral.registers);
        }
    }

    fn resolveEnumDerivations(self: *Parser, peripherals: []model.Peripheral) Error!void {
        var names: std.StringHashMap(*model.EnumeratedValues) = .init(self.gpa);
        var all: std.ArrayList(*model.EnumeratedValues) = .empty;

        for (peripherals) |*peripheral| {
            try collectEnumerations(self.gpa, &names, &all, peripheral.registers);
        }

        var changed = true;
        while (changed) {
            changed = false;
            for (all.items) |set| {
                const derived = set.derived_from orelse continue;
                if (set.values.len != 0) continue;
                const base = names.get(lastPathSegment(derived)) orelse continue;
                if (base == set or base.values.len == 0) continue;
                set.values = base.values;
                changed = true;
            }
        }
    }
};

fn collectEnumerations(
    gpa: Allocator,
    names: *std.StringHashMap(*model.EnumeratedValues),
    all: *std.ArrayList(*model.EnumeratedValues),
    nodes: []model.RegisterNode,
) Allocator.Error!void {
    for (nodes) |*node| {
        switch (node.*) {
            .register => |*register| {
                for (register.fields) |*field| {
                    for (field.enumerated_values) |*set| {
                        if (set.name) |name| {
                            const entry = try names.getOrPut(name);
                            if (!entry.found_existing) entry.value_ptr.* = set;
                        }
                        try all.append(gpa, set);
                    }
                }
            },
            .cluster => |*cluster| try collectEnumerations(gpa, names, all, cluster.children),
        }
    }
}

fn resolveNodeDerivations(nodes: []model.RegisterNode) void {
    for (nodes, 0..) |*node, index| {
        switch (node.*) {
            .register => |*r| {
                if (r.derived_from) |derived_name| {
                    const base_name = lastPathSegment(derived_name);
                    for (nodes[0..index]) |*candidate| {
                        switch (candidate.*) {
                            .register => |*b| {
                                if (!std.mem.eql(u8, b.name, base_name)) continue;
                                if (r.fields.len == 0) r.fields = b.fields;
                                if (r.description == null) r.description = b.description;
                                r.properties = model.RegisterProperties.merged(b.properties, r.local_properties);
                                break;
                            },
                            .cluster => {},
                        }
                    }
                }
                resolveFieldDerivationsInNodes(nodes, r);
            },
            .cluster => |*c| {
                if (c.derived_from) |derived_name| {
                    const base_name = lastPathSegment(derived_name);
                    for (nodes[0..index]) |*candidate| {
                        switch (candidate.*) {
                            .cluster => |*b| {
                                if (!std.mem.eql(u8, b.name, base_name)) continue;
                                if (c.children.len == 0) c.children = b.children;
                                if (c.description == null) c.description = b.description;
                                c.properties = model.RegisterProperties.merged(b.properties, c.local_properties);
                                break;
                            },
                            .register => {},
                        }
                    }
                }
                resolveNodeDerivations(c.children);
            },
        }
    }
}

fn resolveFieldDerivationsInNodes(nodes: []model.RegisterNode, current: *model.Register) void {
    for (current.fields) |*field| {
        const derived = field.derived_from orelse continue;

        var base_register = current;
        var field_name = derived;
        if (std.mem.lastIndexOfScalar(u8, derived, '.')) |dot| {
            const register_segment = lastPathSegment(derived[0..dot]);
            if (!std.mem.eql(u8, register_segment, current.name)) {
                for (nodes) |*node| {
                    switch (node.*) {
                        .register => |*register| {
                            if (std.mem.eql(u8, register.name, register_segment)) {
                                base_register = register;
                                break;
                            }
                        },
                        .cluster => {},
                    }
                }
            }
            field_name = derived[dot + 1 ..];
        }

        for (base_register.fields) |*base_field| {
            if (base_field == field) continue;
            if (!std.mem.eql(u8, base_field.name, field_name)) continue;
            if (field.bit_range == null) field.bit_range = base_field.bit_range;
            if (field.access == null) field.access = base_field.access;
            if (field.enumerated_values.len == 0) field.enumerated_values = base_field.enumerated_values;
            if (field.modified_write_values == null) field.modified_write_values = base_field.modified_write_values;
            if (field.write_constraint == null) field.write_constraint = base_field.write_constraint;
            if (field.read_action == null) field.read_action = base_field.read_action;
            break;
        }
    }
}

fn lastPathSegment(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| return name[dot + 1 ..];
    return name;
}

fn parseBool(text: []const u8) ?bool {
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1")) return true;
    if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "0")) return false;
    return null;
}

/// Parses `scaledNonNegativeInteger`: optional `+`, optional `0x`/`#` prefix,
/// and optional k/M/G/T binary multiplier suffix.
pub fn parseScaledUint(raw: []const u8) !u64 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return error.InvalidNumber;

    var multiplier: u64 = 1;
    switch (text[text.len - 1]) {
        'k', 'K' => {
            multiplier = 1024;
            text = text[0 .. text.len - 1];
        },
        'm', 'M' => {
            multiplier = 1024 * 1024;
            text = text[0 .. text.len - 1];
        },
        'g', 'G' => {
            multiplier = 1024 * 1024 * 1024;
            text = text[0 .. text.len - 1];
        },
        't', 'T' => {
            multiplier = 1024 * 1024 * 1024 * 1024;
            text = text[0 .. text.len - 1];
        },
        else => {},
    }

    if (text.len > 0 and text[0] == '+') text = text[1..];
    if (text.len == 0) return error.InvalidNumber;

    var base: u8 = 10;
    if (text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        base = 16;
        text = text[2..];
    } else if (text.len >= 2 and text[0] == '0' and (text[1] == 'b' or text[1] == 'B')) {
        base = 2;
        text = text[2..];
    } else if (text[0] == '#') {
        base = 2;
        text = text[1..];
    }
    if (text.len == 0) return error.InvalidNumber;

    const value = try std.fmt.parseInt(u64, text, base);
    return std.math.mul(u64, value, multiplier);
}

fn parseBitRange(raw: []const u8) !model.BitRange {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len < 5 or text[0] != '[' or text[text.len - 1] != ']') return error.InvalidBitRange;
    text = text[1 .. text.len - 1];
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidBitRange;
    const msb = try std.fmt.parseInt(u32, std.mem.trim(u8, text[0..colon], " \t"), 0);
    const lsb = try std.fmt.parseInt(u32, std.mem.trim(u8, text[colon + 1 ..], " \t"), 0);
    if (msb < lsb) return error.InvalidBitRange;
    return .{ .offset = lsb, .width = msb - lsb + 1 };
}

test "parse scaled integers" {
    try std.testing.expectEqual(@as(u64, 32), try parseScaledUint("0x20"));
    try std.testing.expectEqual(@as(u64, 10), try parseScaledUint("0b1010"));
    try std.testing.expectEqual(@as(u64, 10), try parseScaledUint("#1010"));
    try std.testing.expectEqual(@as(u64, 4 * 1024), try parseScaledUint("4k"));
    try std.testing.expectError(error.InvalidNumber, parseScaledUint(""));
}

test "parse bit ranges" {
    const range = try parseBitRange("[7:4]");
    try std.testing.expectEqual(@as(u32, 4), range.offset);
    try std.testing.expectEqual(@as(u32, 4), range.width);
    try std.testing.expectError(error.InvalidBitRange, parseBitRange("[3:7]"));
}

test "parse a small device" {
    const data =
        \\<?xml version="1.0"?>
        \\<device schemaVersion="1.3">
        \\  <name>DEMO</name>
        \\  <version>1.0</version>
        \\  <description>Demo device</description>
        \\  <addressUnitBits>8</addressUnitBits>
        \\  <width>32</width>
        \\  <size>32</size>
        \\  <access>read-write</access>
        \\  <resetValue>0</resetValue>
        \\  <peripherals>
        \\    <peripheral>
        \\      <name>PERIPH</name>
        \\      <description>A demo peripheral</description>
        \\      <groupName>PERIPH</groupName>
        \\      <baseAddress>0x40000000</baseAddress>
        \\      <registers>
        \\        <register>
        \\          <name>CTRL</name>
        \\          <description>Control</description>
        \\          <addressOffset>0</addressOffset>
        \\          <resetValue>0x1</resetValue>
        \\          <fields>
        \\            <field>
        \\              <name>ENABLE</name>
        \\              <bitOffset>0</bitOffset>
        \\              <bitWidth>1</bitWidth>
        \\              <enumeratedValues>
        \\                <enumeratedValue><name>Off</name><value>0</value></enumeratedValue>
        \\                <enumeratedValue><name>On</name><value>1</value></enumeratedValue>
        \\              </enumeratedValues>
        \\            </field>
        \\          </fields>
        \\        </register>
        \\      </registers>
        \\    </peripheral>
        \\  </peripherals>
        \\</device>
    ;

    // The model is heap allocated, so use an arena just like the real tool.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var arena_parser: Parser = .init(arena.allocator(), data);
    defer arena_parser.deinit();

    const device = try arena_parser.parse();
    try std.testing.expectEqualStrings("DEMO", device.name);
    try std.testing.expectEqual(@as(usize, 1), device.peripherals.len);
    try std.testing.expectEqual(@as(u64, 0x40000000), device.peripherals[0].base_address);
    try std.testing.expectEqual(@as(usize, 1), device.peripherals[0].registers.len);
    const reg = device.peripherals[0].registers[0].register;
    try std.testing.expectEqualStrings("CTRL", reg.name);
    try std.testing.expectEqual(@as(?u64, 1), reg.properties.reset_value);
    try std.testing.expectEqual(@as(usize, 1), reg.fields.len);
    try std.testing.expectEqual(@as(usize, 2), reg.fields[0].enumerated_values[0].values.len);
}
