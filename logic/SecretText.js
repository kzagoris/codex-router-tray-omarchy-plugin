.pragma library

// Capability secrets must never cross the I/O boundary in diagnostics. This
// stays dependency-free so the production transport and QML workflow tests
// use the exact same sanitization rule.
function withoutSecret(value, secret) {
  var text = String(value === undefined || value === null ? "" : value)
  var capability = String(secret === undefined || secret === null ? "" : secret)
  return capability === "" ? text : text.split(capability).join("[redacted]")
}
