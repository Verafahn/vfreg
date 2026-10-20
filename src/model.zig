pub const Device = struct {
    // Specify the underlying XML schema to which the CMSIS-SVD schema is compliant.
    // Has to be set to: "http://www.w3.org/2001/XMLSchema-instance".
    @"xmlns:xs": []const u8,
    // Specify the file path and file name of the CMSIS-SVD Schema. For example, CMSIS-SVD.xsd.
    @"xs:noNamespaceSchemaLocation": []const u8,
    // Specify the compliant CMSIS-SVD schema version (for example, 1.1).
    schemaVersion: []const u8,

    // Specify the vendor of the device using the full name.
    vendor: []const u8,
    // Specify the vendor abbreviation without spaces or special characters.
    // This information is used to define the directory.
    vendorID: []const u8,
    // The string identifies the device or device series. Device names are required to be unique.
    name: []const u8,
    // Specify the name of the device series.
    series: []const u8,
    // Define the version of the SVD file. Silicon vendors maintain the description throughout
    //  the life-cycle of the device and ensure that all updated and released copies have a unique
    //  version string. Higher numbers indicate a more recent version.
    version: []const u8,
    // Describe the main features of the device (for example CPU, clock frequency, peripheral overview).
    description: []const u8,
    // The text will be copied into the header section of the generated device header file and
    //  shall contain the legal disclaimer. New lines can be inserted by using \n. This section
    //  is mandatory if the SVD file is used for generating the device header file.
    licenseText: []const u8,
    // Describe the processor included in the device.
    cpu: []const u8,
    // Specify the file name (without extension) of the device-specific system include file
    // (system_<device>.h; See CMSIS-Core description). The header file generator customizes
    //  the include statement referencing the CMSIS system file within the CMSIS device header
    //  file. By default, the filename is system_device-name.h. In cases where a device series
    //  shares a single system header file, the name of the series shall be used instead of the
    //  individual device name.
    headerSystemFilename: []const u8,
    // This string is prepended to all type definition names generated in the CMSIS-Core device
    //  header file. This is used if the vendor's software requires vendor-specific types in
    //  order to avoid name clashes with other definied types.
    headerDefinitionsPrefix: []const u8,
    // Define the number of data bits uniquely selected by each address. The value for
    //  Cortex-M-based devices is 8 (byte-addressable).
    addressUnitBits:[]const u8,
    // Define the number of data bit-width of the maximum single data transfer supported by the
    //  bus infrastructure. This information is relevant for debuggers when accessing registers,
    //  because it might be required to issue multiple accesses for resources of a bigger size.
    //  The expected value for Cortex-M-based devices is 32.
    width:[]const u8,
    // Default bit-width of any register contained in the device.
    size: []const u8,
    // Default access rights for all registers.
    access: ?Access,
    // Default access protection for all registers. protectionStringType 0..1
    protection: []const u8,
    // Default value for all registers at RESET. scaledNonNegativeInteger 0..1
    resetValue: []const u8,
    // Define which register bits have a defined reset value. scaledNonNegativeInteger 0..1
    resetMask: []const u8,
    // Group to define peripherals.   1..1
    peripherals: Peripherals,
    // The content and format of this section is unspecified. Silicon vendors may choose to provide
    //  additional information. By default, this section is ignored when constructing CMSIS files.
    // It is up to the silicon vendor to specify a schema for this section. xs:anyType (restriction) 0..1
    vendorExtensions: []const u8,
};

pub const Access = enum {
    read,
    write,
    @"read-write",
};

pub const Peripherals = struct {
    peripherals: []Peripheral,
};

pub const Peripheral = struct {
    // Define the number of elements in an array. scaledNonNegativeInteger 0..1
    dim: []const u8,
    // Specify the address increment, in Bytes, between two neighboring array members in the address map. scaledNonNegativeInteger 0..1
    dimIncrement: []const u8,
    // Do not define on peripheral level. By default, <dimIndex> is an integer value starting at 0. dimIndexType 0..1
    dimIndex: void,
    // Specify the name of the C-type structure. If not defined, then the entry of the <name> element is used. idnetifierType 0..1
    dimName: void,
    // Grouping element to create enumerations in the header file. dimArrayIndexType 0..1
    dimArrayIndex: void,
    // The string identifies the peripheral. Peripheral names are required to be unique for a device. The name needs to be an ANSI C identifier to generate the header file. You can use the placeholder [%s] to create arrays. dimableIdentifierType 1..1
    name: void,
    // The string specifies the version of this peripheral description. xs:string 0..1
    version: void,
    // The string provides an overview of the purpose and functionality of the peripheral. xs:string 0..1
    description: void,
    // All address blocks in the memory space of a device are assigned to a unique peripheral by default. If multiple peripherals describe the same address blocks, then this needs to be specified explicitly. A peripheral redefining an address block needs to specify the name of the peripheral that is listed first in the description. dimaleIdentifierType 0..1
    alternatePeripheral: void,
    // Define a name under which the System Viewer is showing this peripheral. xs:Name 0..1
    groupName: void,
    // Define a string as prefix. All register names of this peripheral get this prefix. identifierType 0..1
    prependToName: void,
    // Define a string as suffix. All register names of this peripheral get this suffix. identifierType 0..1
    appendToName: void,
    // Specify the base name of C structures. The headerfile generator uses the name of a peripheral as the base name for the C structure type. If <headerStructName> element is specfied, then this string is used instead of the peripheral name; useful when multiple peripherals get derived and a generic type name should be used. dimableIdentifierType 0..1
    headerStructName: void,
    // Define a C-language compliant logical expression returning a TRUE or FALSE result. If TRUE, refreshing the display for this peripheral is disabled and related accesses by the debugger are suppressed.
    disableCondition: void,
    // constants and references to other registers contained in the description are allowed: <peripheral>-><register>-><field>, for example, (System->ClockControl->apbEnable == 0). The following operators are allowed in the expression [&&,||, ==, !=, >>, <<, &, |].
    
    Only: void,
    //
    Attention: void,
    // this feature only in cases where accesses from the debugger to registers of un-clocked peripherals result in severe debugging failures. SVD is intended to provide static information and does not include any run-time computation or functions. Such capabilities can be added by the tools, and is beyond the scope of this description language.
    Use: void,
    // 0..1
    stringType: void,
    // Lowest address reserved or used by the peripheral. scaledNonNegativeInteger 1..1
    baseAddress: void,
    // to registerPropertiesGroup for details about the colored elements.  
     	Refer: void,
    // Define the default bit-width of any register contained in the device (implicit inheritance). scaledNonNegativeInteger 0..1
    size: void,
    // Define default access rights for all registers. accessType 0..1
    access: void,
    // Define default protection rights for all registers. protectionStringType 0..1
    protection: void,
    // Define the default value for all registers at RESET. scaledNonNegativeInteger 0..1
    resetValue: void,
    // Identify which register bits have a defined reset value. scaledNonNegativeInteger 0..1
    resetMask: void,
    // Specify an address range uniquely mapped to this peripheral. A peripheral must have at least one address block, but can allocate multiple distinct address ranges. If a peripheral is derived from another peripheral, the addressBlock is not mandatory. addressBlockType 0/1..*
    addressBlock: void,
    // A peripheral can have multiple associated interrupts. This entry allows the debugger to show interrupt names instead of interrupt numbers. interruptType 0..*
    interrupt: void,
    // Group to enclose register definitions. registersType 0..1
    registers: void,
};