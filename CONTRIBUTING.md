# Contributing to OpenTelemetry Zig

The version of Zig used for development is declared in [`build.zig.zon`](./build.zig.zon) in the `.minimum_zig_version` field.

## Build Commands

### Building the library

Build the C SDK library:

```shell
zig build
```

This compiles the OpenTelemetry C SDK as a static library in `zig-out/lib/`, and associated headers in `zig-out/include`.

### Running tests

Unit tests are executed as part of CI pipeline, you can run them locally while developing:

```shell
zig build test
```

#### Test options

The test build supports the following options:

- `-Dtest-verbose=true`: Show verbose test output with timing information (instead of dots)
- `-Dtest-fail-first=true`: Stop on first test failure
- `-Dtest-show-logs=true`: Show captured log output for tests with warnings/errors

To run only specific tests matching a pattern, use build args:

```shell
zig build test -- "counter"
```

Example usage:

```shell
# Run tests with verbose output (shows test names and timing)
zig build test -Dtest-verbose=true

# Run specific tests with verbose output and stop on first failure
zig build test -Dtest-verbose=true -Dtest-fail-first=true -- "counter"

# Show captured logs for tests with warnings/errors
zig build test -Dtest-show-logs=true
```

### Running integration tests

Integration tests verify the SDK behavior against real OpenTelemetry backends. These tests require Docker to be installed and running.

```shell
# Build and install the integration test binaries to zig-out/bin/integration_tests/
zig build integration

# Run them against a real OTLP collector (Docker required)
zig build run-integration

# Filter to a specific test by name
zig build run-integration -- metrics
```

Integration tests are executed as part of CI on pull requests.

> [!IMPORTANT]
> `run-integration` requires Docker to be installed and the Docker daemon to be running.

### Running examples

The example workflow follows the same two-step layout as integration tests:

```shell
# Build every example (Zig + C) and install to zig-out/bin/<category>/<name>
zig build examples

# Run the installed binaries
zig build run-examples
```

#### Examples options

Filter to specific examples (applies to both `examples` and `run-examples`):

```shell
# Only examples whose name contains "otlp"
zig build run-examples -Dexamples-filter=otlp

# Only histogram examples
zig build run-examples -Dexamples-filter=histogram
```

Examples are organized by signal type and language:
- `examples/metrics/` - Metrics API examples
- `examples/trace/` - Tracing API examples
- `examples/logs/` - Logging API examples
- `examples/baggage/`, `examples/propagation/` - Context-propagation examples
- `examples/c/` - C-API examples linking against the static library

### Running benchmarks

Benchmarks are executed as part of the pipeline on Pull Requests if they contain a label `run::benchmarks`.

They can be executed locally with:

```shell
zig build benchmarks -Doptimize=ReleaseFast
```

#### Benchmark options

The benchmark build supports the following options:

- `-Dbenchmark-output=<path>`: Path to write benchmark results to a file
- `-Dbenchmark-debug=true`: Enable debug build mode for benchmarks (useful for profiling)

To run only specific benchmarks matching a pattern, use build args:

```shell
# Run only counter benchmarks
zig build benchmarks -Doptimize=ReleaseFast -- "counter"

# Run a specific benchmark and save results
zig build benchmarks -Doptimize=ReleaseFast -Dbenchmark-output="results.txt" -- "hist.record"

# Run benchmarks in debug mode for profiling
zig build benchmarks -Dbenchmark-debug=true -- "counter"
```

> [!NOTE]
> Currently there is no good way of comparing benchmark runs across various machines,
> as the results do not include CPU information.
> Benchmarks are still useful for detecting improvements or regressions during local development.

### Generating documentation

Generate API documentation:

```shell
zig build docs
```

Documentation will be generated in `zig-out/docs/` and can be viewed by opening `index.html` in a browser.

For example:

```shell
python -m http.server -d zig-out/docs
open "http://localhost:8000/"
```

## Development Workflow

A typical development workflow:

1. Make your changes
2. Run unit tests: `zig build test`
3. Run integration tests: `zig build integration` (if applicable)
4. Run relevant examples: `zig build examples -Dexamples-filter=<signal>`
5. Run benchmarks: `zig build benchmarks -Doptimize=ReleaseFast` (if performance-critical)
6. Commit your changes
