# vfreg

`vfreg` translates a [CMSIS-SVD](https://arm-software.github.io/CMSIS_5/latest/SVD/html/index.html)
XML description into a single, self-contained Zig source file containing
memory-mapped peripheral, register and bit-field definitions. It is written in
Zig and provides both a command-line tool and a library API.

## Build and test

Requires Zig 0.17.0 or newer. Zig fetches the `zig-xml` dependency
automatically.

```sh
zig build
zig build test
```

The executable is installed to `zig-out/bin/reg` (`reg.exe` on Windows). The
`run` step forwards its arguments to the executable:

```sh
zig build run -- .svd/STM32F103.svd STM32F103.zig
```

## Command line

```
reg <input.svd> [output.zig]
```

If `output.zig` is omitted, the generated source is written to stdout. Errors
are reported on stderr and terminate with exit status 1.

## Generated code

```zig
pub const GPIOx_CTRL_MODE = enum(u2) {
    Input = 0x0,
    Output = 0x1,
    Alternate = 0x2,
    _,
};

pub const GPIOx_CTRL = packed struct(u32) {
    /// Enable
    ENABLE: u1 = 0x1,
    /// Mode selection
    MODE: GPIOx_CTRL_MODE = .Alternate,
    z_reserve_0: u5 = 0,
    /// Kept field
    KEEP: u8 = 0x0,
    z_reserve_1: u16 = 0,
};

pub const GPIOx = extern struct {
    /// Control register
    /// Access: Read-Write
    CTRL: GPIOx_CTRL,
};

pub const GPIOA: *volatile GPIOx = @ptrFromInt(0x40010800);
```

Register layouts are packed structs with explicit backing integer types;
unused bits become `z_reserve_N` fields. SVD descriptions and register access
rights are emitted as documentation comments, and `resetValue`, when present,
becomes the default value of each field. Fields with numeric `enumeratedValues` use an
`enum(uN)` type; an enum is non-exhaustive when its declared values do not cover
every bit pattern. Peripherals in the same group with identical layouts share a
type using an `x` placeholder (`GPIOx`), while every peripheral instance is
emitted as a `*volatile` pointer constant.

## Using vfreg in a Zig build

Add `vfreg` to `build.zig.zon` as usual. Inside `build`, with the usual
`target` and `optimize` values, generate the register module and import it:

```zig
const vfreg = b.dependency("vfreg", .{
    .target = b.graph.host,
});
const generator = b.addRunArtifact(vfreg.artifact("reg"));

generator.addFileArg(b.path("input.svd"));
const generated = generator.addOutputFileArg2("registers.zig", .{});

const registers = b.createModule(.{
    .root_source_file = generated,
    .target = target,
    .optimize = optimize,
});

const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "registers", .module = registers },
        },
    }),
});
```

The generator executable runs on the host, while the generated module is
compiled for the requested target.

## Library API

The package also exposes a `vfreg` module (via `dependency.module("vfreg")`)
with the parser and generator:

```zig
const vfreg = @import("vfreg");

// allocator: std.mem.Allocator
var parser: vfreg.parser.Parser = .init(allocator, svd_bytes);
defer parser.deinit();

const device = try parser.parse();
const zig_source = try vfreg.generator.generate(allocator, device);
```

`svd_bytes` must remain valid until `parse` returns. Model strings and the
generated source are allocated with `allocator`; `Device` has no `deinit`, so
using an arena is the simplest way to manage them.

## Limitations

- Alternate register descriptions that overlap an already-described address are
  omitted, since one Zig struct cannot contain two overlapping fields.
- Clusters are flattened into the peripheral layout, and register/field arrays
  are emitted as individual members.
- Common `derivedFrom` forms are resolved (peripherals, clusters, registers,
  fields and enumerated values); derived names that contain array placeholders
  (`%s`) are not resolved.
- Address offsets are treated as byte offsets.
- CPU, interrupt and address-block metadata is parsed but not emitted; the
  output focuses on register access.
