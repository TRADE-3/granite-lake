/* eslint-disable @typescript-eslint/no-explicit-any */
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";
import { GrpcTransport } from "@protobuf-ts/grpc-transport";
import { ChannelCredentials } from "@grpc/grpc-js";
import type { AppEnv } from "../config/env.js";
import { resolveSecretValue } from "./VaultService.js";

export type AddUserResult = {
  txDigest: string;
  userCapId: string;
};

const TRANSIENT_NETWORK_ERROR_CODES = new Set([
  "ECONNRESET",
  "ECONNREFUSED",
  "ETIMEDOUT",
  "ENOTFOUND",
  "EAI_AGAIN",
  "EPIPE",
  "ECONNABORTED",
]);

function serializeErrorChain(error: unknown, maxDepth = 6): Array<Record<string, unknown>> {
  const chain: Array<Record<string, unknown>> = [];
  let current: unknown = error;

  while (current instanceof Error && chain.length < maxDepth) {
    chain.push({
      name: current.name,
      message: current.message,
      code: (current as NodeJS.ErrnoException).code,
      stack: current.stack,
    });
    current = (current as { cause?: unknown }).cause;
  }

  return chain.length > 0 ? chain : [{ value: String(error) }];
}

export function isTransientNetworkError(error: unknown, depth = 0): boolean {
  if (!(error instanceof Error) || depth > 5) return false;

  if (/fetch failed/i.test(error.message)) return true;

  if (error.name === "RpcError") {
    const code = (error as any).code;
    if (code === "UNAVAILABLE" || code === "DEADLINE_EXCEEDED" || code === "INTERNAL") {
      return true;
    }
  }

  const code = (error as NodeJS.ErrnoException).code;
  if (code && TRANSIENT_NETWORK_ERROR_CODES.has(code)) return true;

  return isTransientNetworkError((error as { cause?: unknown }).cause, depth + 1);
}

async function withNetworkRetry<T>(fn: () => Promise<T>, attempts = 3, baseDelayMs = 300): Promise<T> {
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      return await fn();
    } catch (error) {
      const willRetry = attempt < attempts && isTransientNetworkError(error);
      console.error(
        JSON.stringify({
          level: willRetry ? 40 : 50,
          time: Date.now(),
          msg: willRetry ? "Sui RPC call failed, retrying" : "Sui RPC call failed, giving up",
          attempt,
          attempts,
          errorChain: serializeErrorChain(error),
        })
      );

      if (!willRetry) throw error;
      await new Promise((resolve) => setTimeout(resolve, baseDelayMs * 2 ** (attempt - 1)));
    }
  }

  throw new Error("unreachable");
}

// Convertit l'URL Alchemy classique en hôte TCP requis par grpc-js (hote:port)
function formatGrpcHost(rawUrl: string): string {
  let host = rawUrl.trim().replace(/^https?:\/\//, "").replace(/\/+$/, "");
  if (!host.includes(":")) {
    host += ":443";
  }
  return host;
}

export function createSuiClient(appEnv: AppEnv): SuiGrpcClient {
  const host = formatGrpcHost(appEnv.SUI_RPC_URL);

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const token = (appEnv as any).SUI_RPC_API_KEY ?? (appEnv as any).SUI_API_KEY ?? process.env.SUI_RPC_API_KEY;

  const meta: Record<string, string> = {};
  if (token) {
    // Les clés de métadonnées HTTP/2 (gRPC) doivent être en minuscules, grpc-js l'exige
    meta["x-token"] = token.trim();
  }

  return new SuiGrpcClient({
    network: appEnv.SUI_NETWORK,
    transport: new GrpcTransport({
      host,
      channelCredentials: ChannelCredentials.createSsl(),
      meta,
    }),
  });
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type ExecuteTransactionResult = any;

export class SuiService {
  private readonly client: SuiGrpcClient;
  private keypair: Ed25519Keypair | null = null;

  constructor(
    private readonly appEnv: AppEnv,
    client: SuiGrpcClient = createSuiClient(appEnv)
  ) {
    this.client = client;
  }

  private async initializeKeypair(): Promise<Ed25519Keypair> {
    if (this.keypair) return this.keypair;

    if (!this.appEnv.SUI_PRIVATE_KEY || !this.appEnv.SUI_PACKAGE_ID || !this.appEnv.SUI_REGISTRY_ID) {
      throw new Error("Sui configuration is incomplete. Set SUI_PRIVATE_KEY, SUI_PACKAGE_ID, and SUI_REGISTRY_ID.");
    }

    const privateKey = await resolveSecretValue(this.appEnv, this.appEnv.SUI_PRIVATE_KEY);
    if (!privateKey) {
      throw new Error("Sui private key could not be resolved from configuration.");
    }

    const decoded = decodeSuiPrivateKey(privateKey.trim());
    if (decoded.scheme !== "ED25519") {
      throw new Error(`Unsupported Sui private key scheme: ${decoded.scheme}. Expected ED25519.`);
    }

    const keypair = Ed25519Keypair.fromSecretKey(decoded.secretKey);
    const signerAddress = keypair.toSuiAddress().toLowerCase();
    const expectedAddress = this.appEnv.ADMIN_WALLET.trim().toLowerCase();

    if (signerAddress !== expectedAddress) {
      throw new Error(`Sui signer ${signerAddress} does not match ADMIN_WALLET ${expectedAddress}.`);
    }

    this.keypair = keypair;
    return keypair;
  }

  async addUser(params: { domain: string; userWallet: string }): Promise<AddUserResult> {
    const { digest, result } = await this.executeDomainAdminCall({
      functionName: "add_user",
      domain: params.domain,
      userWallet: params.userWallet,
    });

    await this.client.waitForTransaction({ result: result as any });

    const txDetails = await this.client.getTransaction({
      digest,
      include: {
        objectTypes: true,
        effects: true,
      },
    });

    const txData: any = txDetails.$kind === "Transaction" ? txDetails.Transaction : txDetails;
    const changedObjects = txData.effects?.changedObjects ?? [];
    const objectTypes = txData.objectTypes ?? {};
    const userCapId = findCreatedObjectId(changedObjects, objectTypes, "::photo_attestation::UserCap");

    if (!userCapId) {
      console.error(
        "UserCap not found in changedObjects. Query result:",
        JSON.stringify(txDetails, null, 2).slice(0, 2000)
      );
      throw new Error("Sui add_user transaction did not create a UserCap.");
    }

    return {
      txDigest: digest,
      userCapId,
    };
  }

  async disableUser(params: { domain: string; userWallet: string }): Promise<string> {
    const { digest } = await this.executeDomainAdminCall({
      functionName: "disable_user",
      domain: params.domain,
      userWallet: params.userWallet,
    });

    return digest;
  }

  async enableUser(params: { domain: string; userWallet: string }): Promise<string> {
    const { digest } = await this.executeDomainAdminCall({
      functionName: "enable_user",
      domain: params.domain,
      userWallet: params.userWallet,
    });

    return digest;
  }

  async depositSuiToAddressBalance(params: {
    recipient: string;
    amountMist: bigint;
    onDigest?: (digest: string) => Promise<void>;
  }): Promise<{ digest: string; success: boolean; gasUsedMist: bigint; error: string | null }> {
    const keypair = await this.initializeKeypair();

    const { systemState } = await this.client.core.getCurrentSystemState();
    const currentEpoch = BigInt(systemState.epoch);

    const tx = new Transaction();
    tx.setSender(keypair.toSuiAddress());
    tx.setGasBudget(this.appEnv.SUI_GAS_BUDGET);
    tx.setExpiration({ Epoch: Number(currentEpoch + 1n) });

    const [coin] = tx.splitCoins(tx.gas, [params.amountMist]);
    tx.moveCall({
      target: "0x2::coin::send_funds",
      typeArguments: ["0x2::sui::SUI"],
      arguments: [coin, tx.pure.address(params.recipient)],
    });

    const bytes = await tx.build({ client: this.client });
    const digest = await tx.getDigest();
    await params.onDigest?.(digest);

    const { signature } = await keypair.signTransaction(bytes);
    const result = await this.client.core.executeTransaction({
      transaction: bytes,
      signatures: [signature],
      include: { effects: true },
    });
    const executed = result.$kind === "Transaction" ? result.Transaction : result.FailedTransaction;
    const gasUsed = executed.effects.gasUsed;

    return {
      digest,
      success: executed.effects.status.success,
      gasUsedMist: BigInt(gasUsed.computationCost) + BigInt(gasUsed.storageCost) - BigInt(gasUsed.storageRebate),
      error: executed.effects.status.success
        ? null
        : (executed.effects.status.error?.message ?? "Transaction failed on-chain."),
    };
  }

  private async logGasState(owner: string, error: unknown): Promise<void> {
    try {
      const { balance } = await this.client.core.getBalance({ owner });
      console.error("Sui admin call failed", {
        error: error instanceof Error ? error.message : String(error),
        owner,
        gasBudget: this.appEnv.SUI_GAS_BUDGET,
        totalBalance: balance.balance,
        coinBalance: balance.coinBalance,
        addressBalance: balance.addressBalance,
      });
    } catch (balanceError) {
      console.error("Sui admin call failed; balance lookup also failed", {
        error: error instanceof Error ? error.message : String(error),
        balanceError: balanceError instanceof Error ? balanceError.message : String(balanceError),
      });
    }
  }

  private async executeDomainAdminCall(params: {
    functionName: "add_user" | "disable_user" | "enable_user";
    domain: string;
    userWallet: string;
  }): Promise<{ digest: string; result: ExecuteTransactionResult }> {
    const keypair = await this.initializeKeypair();

    let result: ExecuteTransactionResult;
    try {
      result = await withNetworkRetry(() => {
        const tx = new Transaction();

        tx.moveCall({
          target: `${this.appEnv.SUI_PACKAGE_ID}::${this.appEnv.SUI_MODULE}::${params.functionName}`,
          arguments: [
            tx.object(this.appEnv.SUI_REGISTRY_ID),
            tx.pure.vector("u8", Array.from(Buffer.from(params.domain, "utf8"))),
            tx.pure.address(params.userWallet),
          ],
        });

        tx.setGasBudget(this.appEnv.SUI_GAS_BUDGET);

        return keypair.signAndExecuteTransaction({
          transaction: tx,
          client: this.client,
        });
      });
    } catch (error) {
      await this.logGasState(keypair.toSuiAddress(), error);
      throw error;
    }

    if (result.$kind === "FailedTransaction") {
      const status = (result as any).FailedTransaction;
      throw new Error(status?.error?.message ?? "Sui transaction failed.");
    }

    const digest = (result as any).digest ?? (result as any).Transaction?.digest;
    if (!digest) {
      console.error("No digest in result:", JSON.stringify(result, null, 2).slice(0, 1000));
      throw new Error("Transaction executed but no digest found in response.");
    }

    return { digest, result };
  }
}

function findCreatedObjectId(
  changes: any[],
  objectTypes: Record<string, any>,
  objectTypeSuffix: string
): string | null {
  const created = changes.find(
    (change) => change.idOperation === "Created" && objectTypes[change.objectId]?.endsWith(objectTypeSuffix)
  );

  return created?.objectId ?? null;
}