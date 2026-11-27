import { createHmac, timingSafeEqual } from "node:crypto";

export type AccessTokenClaims = {
  sub: string;
  wallet: string;
  fid: string;
  aud: string;
  iat: number;
  exp: number;
};

// HS256 only: this server both issues and verifies, so the header is fixed and
// compared as-is rather than parsed (no algorithm negotiation to attack).
const HEADER = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");

export function signAccessToken(claims: AccessTokenClaims, secret: string): string {
  const body = `${HEADER}.${Buffer.from(JSON.stringify(claims)).toString("base64url")}`;
  return `${body}.${hmac(body, secret).toString("base64url")}`;
}

export function verifyAccessToken(
  token: string,
  secret: string,
  audience: string,
  nowSeconds = Math.floor(Date.now() / 1000)
): AccessTokenClaims | null {
  const [header, payload, signature, extra] = token.split(".");
  if (header !== HEADER || !payload || !signature || extra !== undefined) return null;

  const expected = hmac(`${header}.${payload}`, secret);
  const actual = Buffer.from(signature, "base64url");
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) return null;

  let claims: AccessTokenClaims;
  try {
    claims = JSON.parse(Buffer.from(payload, "base64url").toString("utf8")) as AccessTokenClaims;
  } catch {
    return null;
  }

  if (claims.aud !== audience || typeof claims.exp !== "number" || claims.exp <= nowSeconds) return null;
  return claims;
}

function hmac(value: string, secret: string): Buffer {
  return createHmac("sha256", secret).update(value).digest();
}
