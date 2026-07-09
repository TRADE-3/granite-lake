export const SUI_RPC_URL = import.meta.env.VITE_SUI_RPC_URL?.trim() ?? "https://graphql.testnet.sui.io/graphql";

export const GRANITE_LAKE_PACKAGE_ID =
  import.meta.env.VITE_GRANITE_LAKE_PACKAGE_ID?.trim() ??
  "0x406cb3e27bca8260c8a5f52aa233e02c5e655a4c8c2c9009024c1f27084baffe";

export const GRANITE_LAKE_ORIGINAL_PACKAGE_ID =
  import.meta.env.VITE_GRANITE_LAKE_ORIGINAL_PACKAGE_ID?.trim() ?? GRANITE_LAKE_PACKAGE_ID;

export const GRANITE_LAKE_REGISTRY_ID =
  import.meta.env.VITE_GRANITE_LAKE_REGISTRY_ID?.trim() ??
  "0xab1bf31ba2754b488f5c2b7abd1c20ef874f66fb8712778c13b2ac8c1f6b6821";

export const PHOTO_ATTESTED_EVENT_TYPE = `${GRANITE_LAKE_ORIGINAL_PACKAGE_ID}::photo_attestation::PhotoAttested`;
export const FILE_ATTESTED_EVENT_TYPE = `${GRANITE_LAKE_ORIGINAL_PACKAGE_ID}::photo_attestation::FileAttested`;
export const PHOTO_ATTESTED_EVENT_TYPES = [
  `${GRANITE_LAKE_PACKAGE_ID}::photo_attestation::PhotoAttested`,
  `${GRANITE_LAKE_ORIGINAL_PACKAGE_ID}::photo_attestation::PhotoAttested`,
];
export const FILE_ATTESTED_EVENT_TYPES = [
  `${GRANITE_LAKE_PACKAGE_ID}::photo_attestation::FileAttested`,
  `${GRANITE_LAKE_ORIGINAL_PACKAGE_ID}::photo_attestation::FileAttested`,
];
export const USER_CAP_TYPE = `${GRANITE_LAKE_PACKAGE_ID}::photo_attestation::UserCap`;
export const USER_CAP_TYPE_ORIGINAL = `${GRANITE_LAKE_ORIGINAL_PACKAGE_ID}::photo_attestation::UserCap`;
export const USER_ENABLED_EVENT_TYPE = `${GRANITE_LAKE_ORIGINAL_PACKAGE_ID}::photo_attestation::UserEnabled`;
export const USER_DISABLED_EVENT_TYPE = `${GRANITE_LAKE_ORIGINAL_PACKAGE_ID}::photo_attestation::UserDisabled`;
export const DOMAIN_ADDED_EVENT_TYPE = `${GRANITE_LAKE_ORIGINAL_PACKAGE_ID}::photo_attestation::DomainAdded`;
