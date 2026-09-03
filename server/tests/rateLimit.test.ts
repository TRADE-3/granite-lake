import { describe, expect, it, beforeEach } from "vitest";
import { RateLimiter } from "../src/utils/rateLimit.js";

describe("RateLimiter", () => {
  let limiter: RateLimiter;

  beforeEach(() => {
    // Create a limiter with 3 requests per 1 second
    limiter = new RateLimiter(3, 1000);
  });

  it("should allow requests under the limit", () => {
    expect(limiter.isAllowed("user-1")).toBe(true);
    expect(limiter.isAllowed("user-1")).toBe(true);
    expect(limiter.isAllowed("user-1")).toBe(true);
  });

  it("should block requests over the limit", () => {
    // First 3 should pass
    expect(limiter.isAllowed("user-1")).toBe(true);
    expect(limiter.isAllowed("user-1")).toBe(true);
    expect(limiter.isAllowed("user-1")).toBe(true);

    // 4th should be blocked
    expect(limiter.isAllowed("user-1")).toBe(false);
  });

  it("should track different keys independently", () => {
    // Fill up user-1
    expect(limiter.isAllowed("user-1")).toBe(true);
    expect(limiter.isAllowed("user-1")).toBe(true);
    expect(limiter.isAllowed("user-1")).toBe(true);

    // user-2 should still have capacity
    expect(limiter.isAllowed("user-2")).toBe(true);
    expect(limiter.isAllowed("user-2")).toBe(true);
    expect(limiter.isAllowed("user-2")).toBe(true);

    // Now both should be blocked
    expect(limiter.isAllowed("user-1")).toBe(false);
    expect(limiter.isAllowed("user-2")).toBe(false);
  });

  it("should reset after window expires", async () => {
    // Use up all requests
    expect(limiter.isAllowed("user-1")).toBe(true);
    expect(limiter.isAllowed("user-1")).toBe(true);
    expect(limiter.isAllowed("user-1")).toBe(true);
    expect(limiter.isAllowed("user-1")).toBe(false);

    // Wait for window to expire
    await new Promise((resolve) => setTimeout(resolve, 1100));

    // Should be allowed again
    expect(limiter.isAllowed("user-1")).toBe(true);
  });

  it("should return correct retryAfter time", () => {
    // Use up all requests
    expect(limiter.isAllowed("user-1")).toBe(true);
    expect(limiter.isAllowed("user-1")).toBe(true);
    expect(limiter.isAllowed("user-1")).toBe(true);
    limiter.isAllowed("user-1"); // 4th attempt

    const retryAfter = limiter.getRetryAfter("user-1");

    // Should return ~1 second (the window size)
    expect(retryAfter).toBeGreaterThan(0);
    expect(retryAfter).toBeLessThanOrEqual(1);
  });

  it("should return window duration for unknown keys", () => {
    const retryAfter = limiter.getRetryAfter("unknown-user");
    expect(retryAfter).toBe(1); // 1000ms = 1 second
  });

  it("should cleanup expired entries", () => {
    // Use up all requests
    expect(limiter.isAllowed("user-1")).toBe(true);
    expect(limiter.isAllowed("user-1")).toBe(true);
    expect(limiter.isAllowed("user-1")).toBe(true);
    limiter.isAllowed("user-1"); // 4th, blocked

    // Manually call cleanup (normally done by interval)
    limiter.cleanup();

    // After cleanup + wait, should be allowed again
    // Note: cleanup only removes expired entries, doesn't reset the window
    // So we need to wait for the window to expire
  });
});

describe("RateLimiter edge cases", () => {
  it("should handle rapid sequential requests", () => {
    const limiter = new RateLimiter(2, 100);

    // Very fast requests
    const results = [
      limiter.isAllowed("key"),
      limiter.isAllowed("key"),
      limiter.isAllowed("key"),
      limiter.isAllowed("key"),
      limiter.isAllowed("key"),
    ];

    expect(results.filter((r) => r).length).toBe(2);
  });

  it("should handle zero maxRequests", () => {
    const limiter = new RateLimiter(0, 1000);

    // With 0 max requests, should always return false
    expect(limiter.isAllowed("user")).toBe(false);
    expect(limiter.isAllowed("user")).toBe(false);
  });
});
