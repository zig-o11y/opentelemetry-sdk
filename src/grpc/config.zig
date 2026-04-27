pub const Configuration = struct {
    /// The endpoint to send the data to.
    /// Must be in the form of "host:port", withouth scheme.
    endpoint: []const u8 = "localhost:4317",

    /// Selects the connection security credentials.
    ///   true:  insecure credentials (plaintext, no peer verification).
    ///   false: SSL credentials (TLS, using the cert/key fields below if set,
    ///          otherwise the system trust store).
    ///   null (default): infer from the other fields —
    ///     - if any of the cert/key filenames below is set, use SSL;
    ///     - otherwise use LOCAL_TCP, which is plaintext but rejected by
    ///       gRPC at handshake time when the peer is not on loopback.
    ///       This makes the default safe for a local collector while
    ///       refusing to silently send cleartext to a remote host.
    insecure: ?bool = null,

    /// The maximum duration of batch exporting
    timeout_sec: u64,

    /// CA chain used to verify server certificate (PEM format).
    ///
    /// If unset, the libgrpc implementation will first try to dereference the
    /// file pointed by the GRPC_DEFAULT_SSL_ROOTS_FILE_PATH environment variable,
    /// and if that fails, try to get the roots set by grpc_override_ssl_default_roots.
    /// Eventually, if all these fail, it will try to get the roots from
    /// a well-known place on disk (in the grpc install directory).
    server_root_certificates_filename: ?[]const u8 = null,

    /// Client certificate used to authenticate the client (PEM format).
    client_certificate_filename: ?[]const u8 = null,

    /// Client private key used to authenticate the client (PEM format).
    client_private_key_filename: ?[]const u8 = null,
};
