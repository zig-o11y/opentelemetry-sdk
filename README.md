<div class="title-block" style="text-align: center;" align="center">

# OpenTelemetry Zig

<p><img title="jj logo" src="docs/images/zero-otel.png" width="320"></p>

**[Zig docs] &nbsp;&nbsp;&bull;&nbsp;&nbsp;**
**[Installation](#installation) &nbsp;&nbsp;&bull;&nbsp;&nbsp;**
**[Contributing](#contributing)**

[Zig docs]: https://zig-o11y.github.io/opentelemetry-sdk/

</div>

> [!CAUTION]
> This project is in **alpha** stage. While it is ready for usage and testing, it has not been battle-tested in production environments. Use with caution and expect breaking changes between releases.

This is an implementation of the [OpenTelemetry](https://opentelemetry.io) specification for the [Zig](https://ziglang.org) programming language.

The version of the OpenTelemetry specification targeted here is **1.48.0**.

## Goals

1. Provide a Zig library implementing the _stable_ features of an OpenTelemetry SDK
1. Provide a reference implementation of the OpenTelemetry API
1. Provide examples on how to use the library in real-world use cases

## Installation

Run the following command to add the package to your `build.zig.zon` dependencies, replacing `<ref>` with a release version:

```shall
zig fetch --save "git+https://github.com/zig-o11y/opentelemetry-sdk#<ref>"
```

Then in your `build.zig`:

```zig
const sdk = b.dependency("opentelemetry-sdk", .{
    .target = target,
    .optimize = optimize,
});
```

## C Language Bindings

The SDK provides C-compatible bindings, allowing C programs to use OpenTelemetry instrumentation. The C API covers all three signals: Traces, Metrics, and Logs.

### Using from C

1. **Link with the compiled library**: Build the Zig library and link it with your C project.

2. **Include the header**: Add `include/opentelemetry.h` to your project.

3. **Basic usage example**:

```c
#include "opentelemetry.h"

int main() {
    // Create a meter provider
    otel_meter_provider_t* provider = otel_meter_provider_create();

    // Create an exporter and reader
    otel_metric_exporter_t* exporter = otel_metric_exporter_stdout_create();
    otel_metric_reader_t* reader = otel_metric_reader_create(exporter);
    otel_meter_provider_add_reader(provider, reader);

    // Get a meter
    otel_meter_t* meter = otel_meter_provider_get_meter(
        provider, "my-service", "1.0.0", NULL);

    // Create and use a counter
    otel_counter_u64_t* counter = otel_meter_create_counter_u64(
        meter, "requests", "Total requests", "1");
    otel_counter_add_u64(counter, 1, NULL, 0);

    // Collect and export metrics
    otel_metric_reader_collect(reader);

    // Cleanup
    otel_meter_provider_shutdown(provider);
    return 0;
}
```

### C API Features

- **Opaque handles**: All SDK objects are exposed as opaque handles for type safety
- **Memory management**: The C API manages memory internally using page allocators
- **Error handling**: Functions return status codes (0 for success, negative for errors)
- **Examples**: See `examples/c/` for complete examples of traces, metrics, and logs

For detailed API documentation, refer to `include/opentelemetry.h`.

## Specification Support State

### Signals

| Signal | Status |
|--------|--------|
| Traces | ✅ |
| Metrics | ✅ |
| Logs | ✅ |
| Profiles | ❌ |

### OTLP Protocol

| Feature | Status |
|---------|--------|
| HTTP/Protobuf | ✅ |
| HTTP/JSON | ✅ |
| gRPC | ❌ |
| Compression (gzip) | ✅ |

## Examples

Check out the [examples](./examples) folder for practical usage examples:
- `examples/` - Zig examples for traces, metrics, and logs
- `examples/c/` - C language examples demonstrating the C API bindings

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines on how to contribute to this project, including:

- Running tests locally
- Running benchmarks
- Test and benchmark options

## Origins

This project originated from a proposal in the OpenTelemetry community to create a native Zig implementation of the OpenTelemetry SDK.

You can read more about the original proposal and discussion at:

https://github.com/open-telemetry/community/issues/2514

For a more in-depth read of why OpenTelemetry needs a Zig SDK, see ["Zig is great for Observability"](https://inge.4pr.es/zig-is-great-for-observability/).
