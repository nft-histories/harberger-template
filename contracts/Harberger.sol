// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.17;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Pausable} from '@openzeppelin/contracts/security/Pausable.sol';
import {ERC721} from '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import {ERC721Enumerable} from '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import {ERC721Pausable} from '@openzeppelin/contracts/token/ERC721/extensions/ERC721Pausable.sol';

/// @title Harberger
/// @notice An extension of ERC721 that implements the Harberger tax model.
/// @dev This contract is a WIP & not audited and should NOT be used in production.
abstract contract Harberger is Ownable, Pausable, ERC721Enumerable {
    struct TokenHarbergerData {
        uint evaluationInETH; // The current evaluation of the token
        uint timestampOfLastEvaluation; // The timestamp of the last evaluation
        uint taxOwedInETH; // The amount of tax owed on the token
        uint timestampOfLastPaid; // The timestamp of the last time the tax was paid
        uint timestampOfLastForceBuy; // The timestamp of the last time the token was force bought
    }

    uint public constant taxDivider = 1e4; // 1/10000
    uint public constant annum = 365 days; // 1 year
    uint public constant taxRate = 7e3; // 7% per year
    uint public constant taxGracePeriod = 30 days; // 30 days
    uint public constant evaluationMinimum = 1e16; // 0.01 ETH
    uint public constant selfEvaluationLockPeriod = 7 days; // 7 days
    uint public constant forceBuyLockPeriod = 7 days; // 7 days

    /// @dev Mapping from token ID to token data
    mapping(uint => TokenHarbergerData) public tokens;

    /// @notice Emitted when a token's taxes are recalculated
    event TaxRecalculation(uint indexed tokenId, uint taxOwedInETH);
    /// @notice Emitted when a token is found to be overdue on taxes (i.e.: in arrears)
    event FoundInArrears(uint indexed tokenId);
    /// @notice Emitted when a token is seized for non-payment of taxes
    event Seized(uint indexed tokenId);
    /// @notice Emitted when a token is re-evaluated by its owner
    event SelfEvaluation(uint indexed tokenId, uint evaluationInETH);
    /// @notice Emitted when a token is force-bought
    event ForceBought(uint indexed tokenId, uint price, address indexed buyer);

    /// @notice Transfers all the accumulated ETH (tax) to the caller.
    /// NOTE: Can only be called by the owner of the contract.
    /// @dev Could be improved by 1. passing in an `amount` to withdraw and 2. making the transfer to `owner` instead of `msg.sender`.
    function withdrawTaxes() external onlyOwner {
        uint balance = address(this).balance;
        require(balance > 0, 'Harberger: no taxes to withdraw');
        payable(msg.sender).transfer(balance);
    }

    // .___________.    ___      ___   ___      ______   ______    _______   _______
    // |           |   /   \     \  \ /  /     /      | /  __  \  |       \ |   ____|
    // `---|  |----`  /  ^  \     \  V  /     |  ,----'|  |  |  | |  .--.  ||  |__
    //     |  |      /  /_\  \     >   <      |  |     |  |  |  | |  |  |  ||   __|
    //     |  |     /  _____  \   /  .  \     |  `----.|  `--'  | |  '--'  ||  |____
    //     |__|    /__/     \__\ /__/ \__\     \______| \______/  |_______/ |_______|

    /// @notice Attempts to seize the token with `tokenId` if its owner is in arrears (late on their tax payments).
    /// This will transfer the token to the contract owner and emit a `Seized` event.
    /// NOTE: Can only be called by the owner of the contract.
    /// @param tokenId The ID of the token to seize.
    function seize(uint tokenId) external virtual onlyOwner {
        require(isInArrears(tokenId), 'Harberger: not in arrears');
        TokenHarbergerData storage token = tokens[tokenId];
        token.taxOwedInETH = 0;
        token.timestampOfLastPaid = block.timestamp;
        _transfer(ownerOf(tokenId), owner(), tokenId);
        emit Seized(tokenId);
    }

    /// @notice The owner of the token with `tokenId` pays their taxes.
    /// NOTE: Can only be called by the owner of the token.
    /// NOTE: This recalculates the tax before paying it. This is to prevent the owner from paying less than they should.
    /// It may make sense to call `recalculateTax` before calling this function so that the owner knows how much they owe.
    /// @dev Could be improved by 1. passing in an `amount` to pay 2. emitting an event with the amount paid
    /// @param tokenId The ID of the token to pay taxes for.
    function payTax(uint tokenId) external payable virtual {
        TokenHarbergerData storage token = tokens[tokenId];
        require(msg.sender == ownerOf(tokenId), 'Harberger: not owner');
        require(msg.value >= recalculateTax(tokenId), 'Harberger: not enough sent');
        token.timestampOfLastPaid = block.timestamp;
        token.taxOwedInETH = 0;
    }

    /// @notice Check if the token with `tokenId` is in arrears (late on their tax payments).
    /// Returns `true` if the token is in arrears, `false` otherwise. Also emits an event if the token is in arrears.
    /// NOTE: If a token is in arrears, it can be seized by the owner of the contract.
    /// @param tokenId The ID of the token to check.
    /// @return inArrears `true` if the token is in arrears, `false` otherwise.
    function isInArrears(uint tokenId) public virtual returns (bool inArrears) {
        inArrears = _isInArrears(tokenId);
        if (inArrears) {
            emit FoundInArrears(tokenId);
        }
        return inArrears;
    }

    /// @notice Recalculates the tax owed for the token with `tokenId` and stores it in the contract.
    /// Also returns the amount of tax owed in ETH and emits a `TaxRecalculation` event.
    /// @param tokenId The ID of the token to recalculate the tax for.
    /// @return taxOwed The amount of tax owed in ETH.
    function recalculateTax(uint tokenId) public virtual returns (uint taxOwed) {
        TokenHarbergerData storage token = tokens[tokenId];
        taxOwed = _taxOwedFor(tokenId);
        token.taxOwedInETH = taxOwed;
        emit TaxRecalculation(tokenId, taxOwed);
    }

    /// @notice Calculates the tax that would be owed for the token with `tokenId` for a one year period.
    /// @param tokenId The ID of the token to calculate the tax for.
    /// @return The amount of tax that would be owner per year in ETH.
    function perAnnumTax(uint tokenId) public view virtual returns (uint) {
        TokenHarbergerData storage token = tokens[tokenId];
        return (token.evaluationInETH * taxRate) / taxDivider;
    }

    /// @dev Internal view function to see if a token is in arrears.
    /// @dev "In arrears" means that the taxes have not been paid for a period of time greater than `annum + taxGracePeriod`.
    /// @param tokenId The ID of the token to check.
    /// @return `true` if the token is in arrears, `false` otherwise.
    function _isInArrears(uint tokenId) internal view virtual returns (bool) {
        TokenHarbergerData storage token = tokens[tokenId];
        uint taxDeadline = token.timestampOfLastPaid + annum + taxGracePeriod;
        return block.timestamp > taxDeadline;
    }

    /// @dev Internal view function to calculate the tax owed for the token with `tokenId`.
    /// @param tokenId The ID of the token to calculate the tax for.
    /// @return The amount of tax owed in ETH.
    function _taxOwedFor(uint tokenId) internal view virtual returns (uint) {
        TokenHarbergerData storage token = tokens[tokenId];
        uint timeSinceLastPaid = block.timestamp - token.timestampOfLastEvaluation;
        return (perAnnumTax(tokenId) * timeSinceLastPaid) / annum;
    }

    //  __    __       ___      .______      .______    _______ .______        _______  _______ .______           ______   ______    _______   _______
    // |  |  |  |     /   \     |   _  \     |   _  \  |   ____||   _  \      /  _____||   ____||   _  \         /      | /  __  \  |       \ |   ____|
    // |  |__|  |    /  ^  \    |  |_)  |    |  |_)  | |  |__   |  |_)  |    |  |  __  |  |__   |  |_)  |       |  ,----'|  |  |  | |  .--.  ||  |__
    // |   __   |   /  /_\  \   |      /     |   _  <  |   __|  |      /     |  | |_ | |   __|  |      /        |  |     |  |  |  | |  |  |  ||   __|
    // |  |  |  |  /  _____  \  |  |\  \----.|  |_)  | |  |____ |  |\  \----.|  |__| | |  |____ |  |\  \----.   |  `----.|  `--'  | |  '--'  ||  |____
    // |__|  |__| /__/     \__\ | _| `._____||______/  |_______|| _| `._____| \______| |_______|| _| `._____|    \______| \______/  |_______/ |_______|

    /// @dev This function overrides the ERC721 `_mint` function to initialize Harberger data.
    /// @param to The address to mint the token to.
    /// @param tokenId The ID of the token to mint.
    function _mint(address to, uint tokenId) internal virtual override(ERC721) {
        super._mint(to, tokenId);
        _initializeHarbergerData(tokenId);
    }

    /// @dev This function overrides the ERC721 `_burn` function to delete Harberger data.
    /// @param tokenId The ID of the token to burn.
    function _burn(uint tokenId) internal virtual override {
        super._burn(tokenId);
        delete tokens[tokenId];
    }

    /// @notice Initializes the Harberger data for the token with `tokenId`.
    /// @param tokenId The ID of the token to initialize the Harberger data for.
    function _initializeHarbergerData(uint tokenId) internal virtual {
        TokenHarbergerData storage token = tokens[tokenId];
        token.timestampOfLastPaid = block.timestamp;
        token.timestampOfLastEvaluation = block.timestamp;
        token.evaluationInETH = evaluationMinimum;
        token.taxOwedInETH = 0;
    }

    /// @notice The owner of the token with `tokenId` changes the evaluation of the token to `newEvaluation`.
    /// Emits a `SelfEvaluation` event.
    /// NOTE:w A few conditions must be met for this to succeed, like the token not being in arrears or a lock period.
    /// @dev We should have a mechanism where changing the evaluation doesn't reset the tax owed.
    /// @param tokenId The ID of the token to change the evaluation of.
    /// @param newEvaluation The new evaluation of the token.
    function selfEvaluate(uint tokenId, uint newEvaluation) external virtual {
        TokenHarbergerData storage token = tokens[tokenId];

        require(ownerOf(tokenId) == msg.sender, 'Harberger: not owner');
        require(newEvaluation >= evaluationMinimum, 'Harberger: evaluation too small');
        require(!isInArrears(tokenId), 'Harberger: in arrears');

        /// @dev If the token is force buy locked, it means the owner has just bought it.
        /// They should be able to set the evaluation to whatever they want, regardless of if the old owner just selfEvaluated it.
        /// If the token is not force buy locked, it means the owner has had it for a while.
        /// Old owners should not be able to self evaluate it too often because they could just keep changing the evaluation to avoid paying (as much) tax.
        if (!isForceBuyLocked(tokenId)) {
            require(!isSelfEvaluationLocked(tokenId), 'Harberger: self evaluation locked');
        }

        token.evaluationInETH = newEvaluation;
        token.timestampOfLastEvaluation = block.timestamp;
        emit SelfEvaluation(tokenId, newEvaluation);
    }

    /// @notice Any non-owner of the token with `tokenId` can buy the token for `newEvaluation` ETH if it's not force buy locked.
    /// Emits a `ForceBought` event and puts the token in a force buy lock period.
    /// @param tokenId The ID of the token to buy.
    function forceBuy(uint tokenId) external payable virtual {
        TokenHarbergerData storage token = tokens[tokenId];

        require(ownerOf(tokenId) != msg.sender, 'Harberger: owner cannot self force buy');
        require(!isForceBuyLocked(tokenId), 'Harberger: force buy locked');
        require(msg.value >= token.evaluationInETH, 'Harberger: not enough sent');

        token.timestampOfLastForceBuy = block.timestamp;
        _transfer(ownerOf(tokenId), msg.sender, tokenId);
        emit ForceBought(tokenId, msg.value, msg.sender);
    }

    /// @notice Checks if the token with `tokenId` is in a force buy lock period. Returns `true` if it is, `false` otherwise.
    /// NOTE: A force buy lock period is a period of time where the token cannot be force bought. It is set when the token is force bought.
    /// @param tokenId The ID of the token to check.
    /// @return `true` if the token is in a force buy lock period, `false` otherwise.
    function isForceBuyLocked(uint tokenId) public view virtual returns (bool) {
        TokenHarbergerData storage token = tokens[tokenId];
        uint timestampOfLockExpiration = token.timestampOfLastForceBuy + forceBuyLockPeriod;
        return block.timestamp <= timestampOfLockExpiration;
    }

    /// @notice Checks if the token with `tokenId` is in a self evaluation lock period. Returns `true` if it is, `false` otherwise.
    /// NOTE: A self evaluation lock period is a period of time where the token cannot be self evaluated. It is set when the token is self evaluated.
    /// @param tokenId The ID of the token to check.
    /// @return `true` if the token is in a self evaluation lock period, `false` otherwise.
    function isSelfEvaluationLocked(uint tokenId) public view virtual returns (bool) {
        TokenHarbergerData storage token = tokens[tokenId];
        uint timestampOfLockExpiration = token.timestampOfLastEvaluation + selfEvaluationLockPeriod;
        return block.timestamp <= timestampOfLockExpiration;
    }

    //   _______  _______ .___________.___________. _______ .______          _______.
    //  /  _____||   ____||           |           ||   ____||   _  \        /       |
    // |  |  __  |  |__   `---|  |----`---|  |----`|  |__   |  |_)  |      |   (----`
    // |  | |_ | |   __|      |  |        |  |     |   __|  |      /        \   \
    // |  |__| | |  |____     |  |        |  |     |  |____ |  |\  \----.----)   |
    //  \______| |_______|    |__|        |__|     |_______|| _| `._____|_______/

    /// @notice Gets the evaluation of the token with `tokenId` (as stored).
    /// @param tokenId The ID of the token to get the evaluation of.
    /// @return evaluation evaluation in ETH.
    function getEvaluation(uint tokenId) external view virtual returns (uint evaluation) {
        return tokens[tokenId].evaluationInETH;
    }

    /// @notice Gets the timestamp of the last evaluation of the token with `tokenId` (as stored).
    /// @param tokenId The ID of the token to get the timestamp of the last evaluation of.
    /// @return timestamp the timestamp of the last evaluation.
    function getTimestampOfLastEvaluation(
        uint tokenId
    ) external view virtual returns (uint timestamp) {
        return tokens[tokenId].timestampOfLastEvaluation;
    }

    /// @notice Gets the tax owed on the token with `tokenId` (as stored - you may want to `recalculateTax` beforehand).
    /// @param tokenId The ID of the token to get the tax owed on.
    /// @return taxOwed tax owed in ETH.
    function getTaxOwed(uint tokenId) external view virtual returns (uint taxOwed) {
        return tokens[tokenId].taxOwedInETH;
    }

    /// @notice Gets the timestamp of the last time the tax was paid on the token with `tokenId` (as stored).
    /// @param tokenId The ID of the token to get the timestamp of the last time the tax was paid on.
    /// @return timestamp the timestamp of the last time the tax was paid.
    function getTimestampOfLastPaid(uint tokenId) external view virtual returns (uint timestamp) {
        return tokens[tokenId].timestampOfLastPaid;
    }

    /// @notice Gets the timestamp of the last time the token with `tokenId` was force bought (as stored).
    /// @param tokenId The ID of the token to get the timestamp of the last time it was force bought.
    /// @return timestamp the timestamp of the last time the token was force bought.
    function getTimestampOfLastForceBuy(
        uint tokenId
    ) external view virtual returns (uint timestamp) {
        return tokens[tokenId].timestampOfLastForceBuy;
    }
}
