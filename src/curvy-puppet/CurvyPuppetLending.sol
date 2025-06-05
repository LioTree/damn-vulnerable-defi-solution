// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {IStableSwap} from "./IStableSwap.sol";
import {CurvyPuppetOracle} from "./CurvyPuppetOracle.sol";
import {console} from "forge-std/console.sol";

/// @title Curvy Puppet 借贷合约
/// @notice 允许用户存入 DVT 作为抵押以借出 Curve stETH/ETH 池的 LP 代币，支持清算机制
contract CurvyPuppetLending is ReentrancyGuard {
    using FixedPointMathLib for uint256;

    /// @notice 借出的资产（LP 代币）地址，由 Curve 池提供
    address public immutable borrowAsset;
    /// @notice 抵押资产（DVT）地址
    address public immutable collateralAsset;
    /// @notice Curve 池合约，用于获取 LP 价格和虚拟价格
    IStableSwap public immutable curvePool;
    /// @notice Permit2 合约，用于托管安全的 ERC-20 授权转移
    IPermit2 public immutable permit2;
    /// @notice 价格预言机，用于获取 ETH/DVT 的当前价格
    CurvyPuppetOracle public immutable oracle;

    /// @notice 用户仓位数据，包含抵押量和借款量
    struct Position {
        uint256 collateralAmount; // 抵押的 DVT 数量
        uint256 borrowAmount;     // 借出的 LP 代币数量
    }

    /// @notice 存储每个用户的 Position
    mapping(address who => Position) public positions;

    /// @notice 自定义错误，表示传入数量不合法
    error InvalidAmount();
    /// @notice 自定义错误，表示抵押不足以支持借款
    error NotEnoughCollateral();
    /// @notice 自定义错误，表示仓位健康，不可清算
    error HealthyPosition(uint256 borrowValue, uint256 collateralValue);
    /// @notice 自定义错误，表示提取后仓位不健康，禁止提取
    error UnhealthyPosition();

    /// @param _collateralAsset DVT 代币地址
    /// @param _curvePool Curve 池合约实例
    /// @param _permit2 Permit2 合约实例
    /// @param _oracle 预言机实例
    constructor(
        address _collateralAsset,
        IStableSwap _curvePool,
        IPermit2 _permit2,
        CurvyPuppetOracle _oracle
    ) {
        borrowAsset = _curvePool.lp_token();   // 从池中读取 LP 代币地址
        collateralAsset = _collateralAsset;
        curvePool = _curvePool;
        permit2 = _permit2;
        oracle = _oracle;
    }

    /// @notice 存入抵押资产 (DVT)
    /// @param amount 要存入的 DVT 数量
    function deposit(uint256 amount) external nonReentrant {
        // 更新用户抵押量
        positions[msg.sender].collateralAmount += amount;
        // 从用户钱包拉取 DVT 到本合约
        _pullAssets(collateralAsset, amount);
    }

    /// @notice 提取抵押资产
    /// @param amount 要提取的 DVT 数量
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();

        // 计算提取后的剩余抵押量
        uint256 remainingCollateral = positions[msg.sender].collateralAmount - amount;
        // 计算剩余抵押价值（按当前价格）
        uint256 remainingCollateralValue = getCollateralValue(remainingCollateral);
        // 获取当前借款价值
        uint256 borrowValue = getBorrowValue(positions[msg.sender].borrowAmount);

        // 保证提取后仓位仍满足 175% 抵押率
        if (borrowValue * 175 > remainingCollateralValue * 100) revert UnhealthyPosition();

        // 更新仓位并转 DVT 回用户
        positions[msg.sender].collateralAmount = remainingCollateral;
        IERC20(collateralAsset).transfer(msg.sender, amount);
    }

    /// @notice 借出 LP 代币
    /// @param amount 要借出的 LP 数量，若为 uint256.max 则自动根据可用额度借满
    function borrow(uint256 amount) external {
        // 获取当前已抵押价值和已借款的价值
        uint256 collateralValue = getCollateralValue(positions[msg.sender].collateralAmount); 
        uint256 currentBorrowValue = getBorrowValue(positions[msg.sender].borrowAmount); 

        // 最大可借价值 = 抵押价值 * 100 / 175 (对应 175% 抵押率)
        uint256 maxBorrowValue = collateralValue * 100 / 175;
        // 可用借款价值 = 最大可借价值 - 已借价值
        uint256 availableBorrowValue = maxBorrowValue - currentBorrowValue;

        if (amount == type(uint256).max) {
            // 自动计算借满额度：可用价值 / LP 价格
            amount = availableBorrowValue.divWadDown(_getLPTokenPrice());
        }

        if (amount == 0) revert InvalidAmount();

        // 计算此次借款的价值并检查是否超限
        uint256 borrowAmountValue = getBorrowValue(amount);
        if (currentBorrowValue + borrowAmountValue > maxBorrowValue) revert NotEnoughCollateral();

        // 更新仓位并转出 LP 代币给用户
        positions[msg.sender].borrowAmount += amount;
        IERC20(borrowAsset).transfer(msg.sender, amount);
    }

    /// @notice 偿还借款并可取回抵押
    /// @param amount 偿还的 LP 数量
    function redeem(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        // 减少借款量并拉取 LP 代币
        positions[msg.sender].borrowAmount -= amount;
        _pullAssets(borrowAsset, amount);

        // 若全部偿还，则返还剩余抵押
        if (positions[msg.sender].borrowAmount == 0) {
            uint256 returnAmount = positions[msg.sender].collateralAmount;
            positions[msg.sender].collateralAmount = 0;
            IERC20(collateralAsset).transfer(msg.sender, returnAmount);
        }
    }

    /// @notice 清算不健康仓位
    /// @param target 要清算的用户地址
    function liquidate(address target) external nonReentrant {
        uint256 borrowAmount = positions[target].borrowAmount;
        uint256 collateralAmount = positions[target].collateralAmount;

        // 计算当前抵押价值 *100 与 借款价值 *175 对比
        uint256 collateralValue = getCollateralValue(collateralAmount) * 100;
        // console.log("collateralValue", collateralValue);
        uint256 borrowValue = getBorrowValue(borrowAmount) * 175;
        // console.log("borrowValue", borrowValue);
        // 若抵押充足则拒绝清算
        if (collateralValue >= borrowValue) revert HealthyPosition(borrowValue, collateralValue);

        // 删除用户仓位数据
        delete positions[target];

        // 清算者偿还债务并拉取 LP，获取抵押 DVT
        _pullAssets(borrowAsset, borrowAmount);
        IERC20(collateralAsset).transfer(msg.sender, collateralAmount);
    }

    /// @notice 获取指定 LP 数量的价值 (按当前市场价向上取整)
    function getBorrowValue(uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;
        return amount.mulWadUp(_getLPTokenPrice());
    }

    /// @notice 获取指定抵押 DVT 数量的价值 (按当前市场价向下取整)
    /// oracle.getPrice(collateralAsset) 返回的价格以 1e18 缩放，单位为 wei，
    /// 表示 1 个 DVT 代币对应的价格。例如，如果返回值为 1e18，则表示 1 DVT = 1 ETH。
    /// 将该价格乘以抵押的 DVT 数量（amount）得到总抵押价值，单位为 wei。
    function getCollateralValue(uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;
        return amount.mulWadDown(oracle.getPrice(collateralAsset).value);
    }

    /// @notice 查询用户借款量
    function getBorrowAmount(address who) external view returns (uint256) {
        return positions[who].borrowAmount;
    }

    /// @notice 查询用户抵押量
    function getCollateralAmount(address who) external view returns (uint256) {
        return positions[who].collateralAmount;
    }

    /// @dev 内部函数：使用 Permit2 从用户转移指定代币到本合约
    function _pullAssets(address asset, uint256 amount) private {
        permit2.transferFrom({
            from: msg.sender,
            to: address(this),
            amount: SafeCast.toUint160(amount),
            token: asset
        });
    }

    /// @dev 内部函数：获取 LP 代币价格 = 基础资产价格 × Curve 虚拟价格
    /// oracle.getPrice(curvePool.coins(0)) 返回基础资产价格，单位为 wei（1e18 缩放），
    /// 表示 1 个基础资产值多少 wei。
    /// Curve 池的虚拟价格表示 1 个 LP 代币对应多少个基础资产，
    /// 因此两者相乘后，返回值表示 1 个 LP 代币对应的基础资产价值，单位为 wei。
    function _getLPTokenPrice() private view returns (uint256) {
        // oracle.getPrice(curvePool.coins(0)) 获取基础资产(如 stETH)价格
        return oracle.getPrice(curvePool.coins(0)).value
            .mulWadDown(curvePool.get_virtual_price());
    }
}
