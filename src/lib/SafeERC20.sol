// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IERC20 } from "../interfaces/IERC20.sol";

/// @notice ERC20 transfers that tolerate both boolean-returning and
///         no-return tokens, while still reverting on a false return.
library SafeERC20 {
    error SafeTransferFailed();
    error SafeTransferFromFailed();

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (data.length != 0 && (data.length != 32 || !abi.decode(data, (bool))))) {
            revert SafeTransferFailed();
        }
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (!ok || (data.length != 0 && (data.length != 32 || !abi.decode(data, (bool))))) {
            revert SafeTransferFromFailed();
        }
    }
}
