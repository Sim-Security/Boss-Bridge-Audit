// __| |_____________________________________________________| |__
// __   _____________________________________________________   __
//   | |                                                     | |
//   | | ____                  ____       _     _            | |
//   | || __ )  ___  ___ ___  | __ ) _ __(_) __| | __ _  ___ | |
//   | ||  _ \ / _ \/ __/ __| |  _ \| '__| |/ _` |/ _` |/ _ \| |
//   | || |_) | (_) \__ \__ \ | |_) | |  | | (_| | (_| |  __/| |
//   | ||____/ \___/|___/___/ |____/|_|  |_|\__,_|\__, |\___|| |
//   | |                                          |___/      | |
// __| |_____________________________________________________| |__
// __   _____________________________________________________   __
//   | |                                                     | |

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { L1Vault } from "./L1Vault.sol";

contract L1BossBridge is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // @audit-info - this should be a constant
    uint256 public DEPOSIT_LIMIT = 100_000 ether; // e depositing tokens, cannot have more than this

    IERC20 public immutable token; // e one bridge per token
    L1Vault public immutable vault; // e one vault per bridge
    mapping(address account => bool isSigner) public signers; // e Users who can "send" a token from L2 -> L1

    error L1BossBridge__DepositLimitReached();
    error L1BossBridge__Unauthorized();
    error L1BossBridge__CallFailed();

    event Deposit(address from, address to, uint256 amount);

    constructor(IERC20 _token) Ownable(msg.sender) {
        token = _token;
        vault = new L1Vault(token);
        // Allows the bridge to move tokens out of the vault to facilitate withdrawals
        vault.approveTo(address(this), type(uint256).max);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // q what happens if we disable an account mid-flight?
    function setSigner(address account, bool enabled) external onlyOwner {
        signers[account] = enabled;
    }

    /*
     * @notice Locks tokens in the vault and emits a Deposit event
     * the unlock event will trigger the L2 minting process. There are nodes listening
     * for this event and will mint the corresponding tokens on L2. This is a centralized process.
     * 
     * @param from The address of the user who is depositing tokens
     * @param l2Recipient The address of the user who will receive the tokens on L2
     * @param amount The amount of tokens to deposit
     */

    // Alice: approve token --> bridge
    // Bob: depositTokensToL2(from:Alice, l2Recipient:Bob, amount:all her money!)
    // @audit-high - if a user approves the bridge, any other user can steal their funds.
    // should be using "msg.sender" instead of "from".

    // @audit-high - if the vault approved the bridge, can a user steal funds from the vault?
    // Can continuously mint to the L2 and send it to an attacker's address.
    function depositTokensToL2(address from, address l2Recipient, uint256 amount) external whenNotPaused {
        if (token.balanceOf(address(vault)) + amount > DEPOSIT_LIMIT) {
            revert L1BossBridge__DepositLimitReached();
        }
        token.safeTransferFrom(from, address(vault), amount);

        // Our off-chain service picks up this event and mints the corresponding tokens on L2
        // @audit-info - should follow CEI. i.e should be above the safeTransferFrom
        emit Deposit(from, l2Recipient, amount);
    }

    /*
     * @notice This is the function responsible for withdrawing tokens from L2 to L1.
     * Our L2 will have a similar mechanism for withdrawing tokens from L1 to L2.
     * @notice The signature is required to prevent replay attacks. 
     * 
     * @param to The address of the user who will receive the tokens on L1
     * @param amount The amount of tokens to withdraw
     * @param v The v value of the signature
     * @param r The r value of the signature
     * @param s The s value of the signature
     */

    // @audit-high - Signature replay attack! Stored v,r,s on chain! Use a nonce or deadline to stop
    function withdrawTokensToL1(address to, uint256 amount, uint8 v, bytes32 r, bytes32 s) external {
        sendToL1(
            v,
            r,
            s,
            abi.encode(
                address(token),
                0, // value
                abi.encodeCall(IERC20.transferFrom, (address(vault), to, amount))
            )
        );
    }

    /*
     * @notice This is the function responsible for withdrawing ETH from L2 to L1.
     *
     * @param v The v value of the signature
     * @param r The r value of the signature
     * @param s The s value of the signature
     * @param message The message/data to be sent to L1 (can be blank)
     */
    function sendToL1(uint8 v, bytes32 r, bytes32 s, bytes memory message) public nonReentrant whenNotPaused {
        address signer = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(keccak256(message)), v, r, s);

        if (!signers[signer]) {
            revert L1BossBridge__Unauthorized();
        }

        (address target, uint256 value, bytes memory data) = abi.decode(message, (address, uint256, bytes));
        
        // q slither said this is bad, is it ok?
        // No, we just trust the message. What if the attacker calls this function with a malicious message? such as approveTo in the L1Vault Contract. Bingo bango the attacker has emptied the vaults
        (bool success,) = target.call{ value: value }(data);
        if (!success) {
            revert L1BossBridge__CallFailed();
        }
    }
}
