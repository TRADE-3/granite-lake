import type { FastifyRequest, FastifyReply } from "fastify";

/**
 * Simple in-memory rate limiter.
 * Note: For production, use Redis or similar for distributed rate limiting.
 */
export class RateLimiter {
  private requests = new Map<string, { count: number; resetAt: number }>();

  constructor(
    private maxRequests: number,
    private windowMs: number
  ) {}

  /**
   * Check if request is allowed. Returns true if allowed, false if rate limited.
   */
  isAllowed(key: string): boolean {
    // If maxRequests is 0, always block
    if (this.maxRequests <= 0) {
      return false;
    }

    const now = Date.now();
    const record = this.requests.get(key);

    if (!record || now > record.resetAt) {
      // Start new window
      this.requests.set(key, {
        count: 1,
        resetAt: now + this.windowMs,
      });
      return true;
    }

    if (record.count >= this.maxRequests) {
      // Rate limited
      return false;
    }

    record.count++;
    return true;
  }

  /**
   * Reset the rate limiter (useful for testing).
   */
  reset(): void {
    this.requests.clear();
  }

  /**
   * Get seconds until rate limit resets.
   */
  getRetryAfter(key: string): number {
    const record = this.requests.get(key);
    if (!record) return this.windowMs / 1000;
    return Math.max(1, Math.ceil((record.resetAt - Date.now()) / 1000));
  }

  /**
   * Clean up expired entries periodically.
   */
  cleanup(): void {
    const now = Date.now();
    for (const [key, record] of this.requests) {
      if (now > record.resetAt) {
        this.requests.delete(key);
      }
    }
  }
}

// Rate limiters for different endpoints
export const otpRequestLimiter = new RateLimiter(5, 60 * 1000); // 5 requests per minute per IP
export const otpVerifyLimiter = new RateLimiter(10, 15 * 60 * 1000); // 10 attempts per 15 min per userId

// Cleanup old entries every 5 minutes
setInterval(
  () => {
    otpRequestLimiter.cleanup();
    otpVerifyLimiter.cleanup();
  },
  5 * 60 * 1000
);

/**
 * Reset all rate limiters (for testing purposes).
 */
export function resetAllRateLimiters(): void {
  otpRequestLimiter.reset();
  otpVerifyLimiter.reset();
}

/**
 * Decorator to rate limit OTP requests by IP.
 */
export function rateLimitOtpRequest() {
  return (request: FastifyRequest, reply: FastifyReply) => {
    const ip = request.ip || (request.headers["x-forwarded-for"] as string) || "unknown";
    const key = `otp_request:${ip}`;

    if (!otpRequestLimiter.isAllowed(key)) {
      const retryAfter = otpRequestLimiter.getRetryAfter(key);
      reply.header("Retry-After", retryAfter);
      reply.status(429).send({
        error: "rate_limit_exceeded",
        message: `Too many OTP requests. Limit: 5 per minute. Try again in ${retryAfter} seconds.`,
      });
      return reply;
    }
  };
}

/**
 * Decorator to rate limit OTP verify attempts by userId.
 */
export function rateLimitOtpVerify() {
  return (request: FastifyRequest, reply: FastifyReply) => {
    // Get userId from request body
    const body = request.body as Record<string, unknown> | undefined;
    const userId = body?.userId as string | undefined;

    if (!userId) {
      // No userId in request, allow through (will fail validation later)
      return;
    }

    const key = `otp_verify:${userId}`;

    if (!otpVerifyLimiter.isAllowed(key)) {
      const retryAfter = otpVerifyLimiter.getRetryAfter(key);
      reply.header("Retry-After", retryAfter);
      reply.status(429).send({
        error: "rate_limit_exceeded",
        message: `Too many OTP verification attempts. Limit: 10 per 15 minutes. Try again in ${retryAfter} seconds.`,
      });
      return reply;
    }
  };
}
