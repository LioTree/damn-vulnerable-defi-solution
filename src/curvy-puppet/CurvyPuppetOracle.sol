// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

// 引入Ownable合约，用于管理所有权
import {Ownable} from "solady/auth/Ownable.sol";

// CurvyPuppetOracle合约，继承自Ownable，实现价格预言机功能
contract CurvyPuppetOracle is Ownable {
    // 将每个资产地址映射到其对应的价格信息
    mapping(address asset => Price) public prices;

    // Price结构体，包含价格值和过期时间
    struct Price {
        uint256 value;      // 价格值，不可为0
        uint256 expiration; // 价格过期的时间戳（Unix时间）
    }

    // 错误，表示提供的价格无效（例如为0）
    error InvalidPrice();
    // 错误，表示提供的过期时间无效（不在合法时间范围内）
    error InvalidExpiration();
    // 错误，表示价格已过期
    error StalePrice();
    // 错误，表示查询的资产不支持
    error UnsupportedAsset();

    // 构造函数：初始化合约所有者为部署者地址
    constructor() {
        _initializeOwner(msg.sender);
    }

    // 函数 getPrice：获取指定资产的价格信息
    // 若资产未设置价格或价格已过期，则会抛出相应错误
    function getPrice(address asset) external view returns (Price memory) {
        // 从映射中获取价格信息
        Price memory price = prices[asset];

        // 如果价格值为0，说明该资产不受支持
        if (price.value == 0) revert UnsupportedAsset();
        // 如果当前时间大于价格过期时间，说明价格已过期
        if (block.timestamp > price.expiration) revert StalePrice();

        return price;
    }

    // 函数 setPrice：设置指定资产的价格和过期时间
    // 仅允许合约所有者调用此函数
    function setPrice(address asset, uint256 value, uint256 expiration) external onlyOwner {
        // 检查价格值是否为0，若为0则抛出错误
        if (value == 0) revert InvalidPrice();
        // 检查过期时间：必须在当前时间之后，且不超过当前时间加2天
        if (expiration <= block.timestamp || expiration > block.timestamp + 2 days) revert InvalidExpiration();
        // 设置资产的价格信息
        prices[asset] = Price(value, expiration);
    }
}
