// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Single-slot reentrancy guard for token-moving entry points.
abstract contract ReentrancyGuard {
    uint256 private _status = 1;

    error ReentrantCall();

    modifier nonReentrant() {
        if (_status != 1) revert ReentrantCall();
        _status = 2;
        _;
        _status = 1;
    }
}
