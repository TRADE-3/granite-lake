import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiJsonRpcClient, type SuiObjectChange } from "@mysten/sui/jsonRpc";
import { Transaction } from "@mysten/sui/transactions";
import type { AppEnv } from "../config/env.js";
import { resolveSecretValue } from "./VaultService.js";

export type AddUserResult = {
  txDigest: string;
  userCapId: string;
};

export class SuiService {
  private readonly client: SuiJsonRpcClient;

  constructor(private readonly appEnv: AppEnv) {
    this.client = new SuiJsonRpcClient({
      network: appEnv.SUI_NETWORK,
      url: appEnv.SUI_RPC_URL,
    });
  }

  async addUser(params: { domain: string; userWallet: string }): Promise<AddUserResult> {
    const result = await this.executeDomainAdminCall({
      functionName: "add_user",
      domain: params.domain,
      userWallet: params.userWallet,
      showObjectChanges: true,
    });

    const userCapId = findCreatedObjectId(result.objectChanges ?? [], "::photo_attestation::UserCap");

    if (!userCapId) {
      throw new Error("Sui add_user transaction did not create a UserCap.");
    }

    return {
      txDigest: result.digest,
      userCapId,
    };
  }

  async disableUser(params: { domain: string; userWallet: string }): Promise<string> {
    const result = await this.executeDomainAdminCall({
      functionName: "disable_user",
      domain: params.domain,
      userWallet: params.userWallet,
      showObjectChanges: false,
    });

    return result.digest;
  }

  async enableUser(params: { domain: string; userWallet: string }): Promise<string> {
    const result = await this.executeDomainAdminCall({
      functionName: "enable_user",
      domain: params.domain,
      userWallet: params.userWallet,
      showObjectChanges: false,
    });

    return result.digest;
  }

  private async executeDomainAdminCall(params: {
    functionName: "add_user" | "disable_user" | "enable_user";
    domain: string;
    userWallet: string;
    showObjectChanges: boolean;
  }) {
    const privateKey = await this.getPrivateKey();

    const keypair = toEd25519Keypair(privateKey);
    const signerAddress = keypair.toSuiAddress().toLowerCase();
    const expectedAddress = this.appEnv.ADMIN_WALLET.trim().toLowerCase();

    if (signerAddress !== expectedAddress) {
      throw new Error(`Sui signer ${signerAddress} does not match ADMIN_WALLET ${expectedAddress}.`);
    }

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

    const result = await this.client.signAndExecuteTransaction({
      signer: keypair,
      transaction: tx,
      options: {
        showEffects: true,
        showObjectChanges: params.showObjectChanges,
      },
    });

    if (result.effects?.status.status !== "success") {
      throw new Error(result.effects?.status.error ?? "Sui transaction failed.");
    }

    return result;
  }

  private async getPrivateKey(): Promise<string> {
    if (!this.appEnv.SUI_PRIVATE_KEY || !this.appEnv.SUI_PACKAGE_ID || !this.appEnv.SUI_REGISTRY_ID) {
      throw new Error("Sui configuration is incomplete. Set SUI_PRIVATE_KEY, SUI_PACKAGE_ID, and SUI_REGISTRY_ID.");
    }

    const privateKey = await resolveSecretValue(this.appEnv, this.appEnv.SUI_PRIVATE_KEY);

    if (!privateKey) {
      throw new Error("Sui private key could not be resolved from configuration.");
    }

    return privateKey;
  }
}

function toEd25519Keypair(privateKey: string): Ed25519Keypair {
  const decoded = decodeSuiPrivateKey(privateKey.trim());

  if (decoded.scheme !== "ED25519") {
    throw new Error(`Unsupported Sui private key scheme: ${decoded.scheme}. Expected ED25519.`);
  }

  return Ed25519Keypair.fromSecretKey(decoded.secretKey);
}

function findCreatedObjectId(changes: SuiObjectChange[], objectTypeSuffix: string): string | null {
  const created = changes.find((change) => change.type === "created" && change.objectType.endsWith(objectTypeSuffix));

  return created?.type === "created" ? created.objectId : null;
}
