// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";

/**
 * @notice A contract that allows deployers of Gnosis Safe wallets to be rewarded.
 *         Includes an optional authorization mechanism to ensure only expected accounts
 *         are rewarded for certain deployments.
 */
contract WalletDeployer {
    // Addresses of a Safe factory and copy on this chain
    SafeProxyFactory public immutable cook; // Address of SafeProxyFactory
    address public immutable cpy; // Address of Safe master copy (implementation)

    uint256 public constant pay = 1 ether;
    address public immutable chief; // Address of admin
    address public immutable gem; // Address of token

    address public mom; // Address of authorizer proxy (TransparentProxy)
    address public hat;

    error Boom();

    constructor(address _gem, address _cook, address _cpy, address _chief) {
        gem = _gem;
        cook = SafeProxyFactory(_cook);
        cpy = _cpy;
        chief = _chief;
    }

    /**
     * @notice Allows the chief to set an authorizer contract.
     * Can be called only once.
     */
    function rule(address _mom) external {
        if (msg.sender != chief || _mom == address(0) || mom != address(0)) {
            revert Boom();
        }
        mom = _mom;
    }

    /**
     * @notice Allows the caller to deploy a new Safe account and receive a payment in return.
     *         If the authorizer is set, the caller must be authorized to execute the deployment
     * @param aim The expected address where the Safe wallet should be deployed
     * @param wat The initialization data for the Safe wallet setup
     * @param num The nonce/salt value used for deterministic address calculation
     */
    function drop(address aim, bytes memory wat, uint256 num) external returns (bool) {
        if (mom != address(0) && !can(msg.sender, aim)) {
            return false;
        }

        if (address(cook.createProxyWithNonce(cpy, wat, num)) != aim) {
            return false;
        }

        if (IERC20(gem).balanceOf(address(this)) >= pay) {
            IERC20(gem).transfer(msg.sender, pay);
        }
        return true;
    }

    function can(address u, address a) public view returns (bool y) {
        assembly {
            let m := sload(0)  // 从存储槽0读取mom地址
            if iszero(extcodesize(m)) { stop() }  // 如果mom合约不存在，停止执行
            let p := mload(0x40)  // 获取空闲内存指针
            mstore(0x40, add(p, 0x44))  // 更新内存指针，分配68字节空间
            mstore(p, shl(0xe0, 0x4538c4eb))  // 存储can(address,address)函数选择器
            mstore(add(p, 0x04), u)  // 存储第一个参数：用户地址
            mstore(add(p, 0x24), a)  // 存储第二个参数：目标地址  
            if iszero(staticcall(gas(), m, p, 0x44, p, 0x20)) { stop() }  // 静态调用mom.can(u,a)
            y := mload(p)  // 读取返回的bool值
        }
    }
}
