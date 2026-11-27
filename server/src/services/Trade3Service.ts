import { z } from "zod";

// Only the fields GL uses. zod drops everything else (bank accounts, address,
// other company users), so it never travels further than this file.
const companyMeSchema = z.object({
  success: z.literal(true),
  user: z.object({
    id: z.number().int().positive(),
    company_id: z.number().int().positive(),
    email: z.string().email(),
    is_active: z.boolean(),
    name: z.string(),
    position: z.string().nullish(),
    role: z.string(),
    company: z.object({
      name: z.string(),
      is_whitelisted: z.boolean(),
    }),
  }),
});

export type Trade3User = {
  id: number;
  companyId: number;
  email: string;
  isActive: boolean;
  name: string;
  position: string | null;
  role: string;
  companyName: string;
  companyWhitelisted: boolean;
};

export class Trade3Error extends Error {
  constructor(readonly kind: "unauthorized" | "unavailable") {
    super(kind === "unauthorized" ? "Trade3 rejected the access token." : "Trade3 is unavailable.");
  }
}

const TIMEOUT_MS = 10_000;

// Errors deliberately carry no response body or token, so neither can be logged.
export async function fetchTrade3User(baseUrl: string, accessToken: string): Promise<Trade3User> {
  let payload: unknown;

  try {
    const response = await fetch(`${baseUrl.replace(/\/+$/, "")}/api/company/me`, {
      headers: { authorization: `Bearer ${accessToken}`, accept: "application/json" },
      redirect: "error",
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });

    if (response.status === 401 || response.status === 403) throw new Trade3Error("unauthorized");
    if (!response.ok) throw new Trade3Error("unavailable");
    payload = await response.json();
  } catch (error) {
    if (error instanceof Trade3Error) throw error;
    throw new Trade3Error("unavailable");
  }

  const parsed = companyMeSchema.safeParse(payload);
  if (!parsed.success) throw new Trade3Error("unavailable");

  const { user } = parsed.data;
  return {
    id: user.id,
    companyId: user.company_id,
    email: user.email.trim().toLowerCase(),
    isActive: user.is_active,
    name: user.name,
    position: user.position ?? null,
    role: user.role,
    companyName: user.company.name,
    companyWhitelisted: user.company.is_whitelisted,
  };
}
