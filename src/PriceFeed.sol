// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Owned } from "./lib/Owned.sol";

/// @title PriceFeed
/// @notice Publishes one event per observation and keeps the history so the
///         vault can verify that a callback price really came from a published
///         tick. On a production deployment this role would be played by a
///         Chainlink adapter or a DEX `Sync` subscription; only the event shape
///         and the `priceOf` lookup are part of the integration surface.
contract PriceFeed is Owned {
    event PriceTick(uint256 indexed tickId, uint256 price, uint256 timestamp);
    event PublisherSet(address indexed publisher);

    error NotPublisher();
    error InvalidPrice();

    /// @notice Price is USD per base token with 8 decimals, e.g. 2000e8.
    uint256 public constant MAX_PRICE = 1e30;

    address public publisher;
    uint256 public tickId;

    mapping(uint256 => uint256) public priceOf;
    mapping(uint256 => uint256) public publishedAt;

    constructor(address publisher_, address owner_) Owned(owner_) {
        if (publisher_ == address(0)) revert ZeroAddress();
        publisher = publisher_;
        emit PublisherSet(publisher_);
    }

    function setPublisher(address publisher_) external onlyOwner {
        if (publisher_ == address(0)) revert ZeroAddress();
        publisher = publisher_;
        emit PublisherSet(publisher_);
    }

    /// @notice Publish a price observation. Returns the new tick id.
    function publish(uint256 price) external returns (uint256 id) {
        if (msg.sender != publisher) revert NotPublisher();
        if (price == 0 || price > MAX_PRICE) revert InvalidPrice();

        id = ++tickId;
        priceOf[id] = price;
        publishedAt[id] = block.timestamp;
        emit PriceTick(id, price, block.timestamp);
    }

    function latest() external view returns (uint256 id, uint256 price, uint256 timestamp) {
        id = tickId;
        price = priceOf[id];
        timestamp = publishedAt[id];
    }
}
