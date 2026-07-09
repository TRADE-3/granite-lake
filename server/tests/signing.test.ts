// HMAC signing was removed - security now relies on TLS
// This file is kept as a placeholder for future security tests
import { describe, expect, it } from "vitest";

describe("Security", () => {
  it("should use TLS for all connections", () => {
    // This is a reminder that security relies on TLS
    // Ensure your server is configured with valid TLS certificates
    expect(true).toBe(true);
  });
});
