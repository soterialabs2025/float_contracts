// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey as CorePoolKey} from "../../../lib/v4-core/src/types/PoolKey.sol";

interface IV4PoolConfigSource {
    function getV4PoolConfig(address assetAddress) external view returns (CorePoolKey memory key, bytes memory hookData);
}
