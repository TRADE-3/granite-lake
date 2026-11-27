import { bcs } from "@mysten/sui/bcs";

export const UserCapBcs = bcs.struct("UserCap", {
  id: bcs.Address,
  domain: bcs.vector(bcs.u8()),
  user_wallet: bcs.Address,
});
