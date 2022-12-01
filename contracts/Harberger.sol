// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.17;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Pausable} from '@openzeppelin/contracts/security/Pausable.sol';
import {ERC721} from '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import {ERC721Enumerable} from '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import {ERC721Pausable} from '@openzeppelin/contracts/token/ERC721/extensions/ERC721Pausable.sol';

abstract contract Harberger is Ownable, Pausable, ERC721Enumerable {
    struct TokenHarbergerData {
        uint evaluationInETH;
        uint timestampOfLastEvaluation;
        uint taxOwedInETH;
        uint timestampOfLastPaid;
        uint timestampOfLastForceBuy;
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

    event TaxRecalculation(uint indexed tokenId, uint taxOwedInETH);
    event FoundInArrears(uint indexed tokenId);
    event Seized(uint indexed tokenId);
    event SelfEvaluation(uint indexed tokenId, uint evaluationInETH);
    event ForceBought(uint indexed tokenId, uint price, address indexed buyer);

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

    function seize(uint tokenId) external virtual onlyOwner {
        require(isInArrears(tokenId), 'Harberger: not in arrears');
        TokenHarbergerData storage token = tokens[tokenId];
        token.taxOwedInETH = 0;
        token.timestampOfLastPaid = block.timestamp;
        _transfer(ownerOf(tokenId), owner(), tokenId);
        emit Seized(tokenId);
    }

    function payTax(uint tokenId) external payable virtual {
        TokenHarbergerData storage token = tokens[tokenId];
        require(msg.sender == ownerOf(tokenId), 'Harberger: not owner');
        require(msg.value >= recalculateTax(tokenId), 'Harberger: not enough sent');
        token.timestampOfLastPaid = block.timestamp;
        token.taxOwedInETH = 0;
    }

    function isInArrears(uint tokenId) public virtual returns (bool inArrears) {
        inArrears = _isInArrears(tokenId);
        if (inArrears) {
            emit FoundInArrears(tokenId);
        }
        return inArrears;
    }

    function recalculateTax(uint tokenId) public virtual returns (uint taxOwed) {
        TokenHarbergerData storage token = tokens[tokenId];
        taxOwed = _taxOwedFor(tokenId);
        token.taxOwedInETH = taxOwed;
        emit TaxRecalculation(tokenId, taxOwed);
    }

    function perAnnumTax(uint tokenId) public view virtual returns (uint) {
        TokenHarbergerData storage token = tokens[tokenId];
        return (token.evaluationInETH * taxRate) / taxDivider;
    }

    function _isInArrears(uint tokenId) internal view virtual returns (bool) {
        TokenHarbergerData storage token = tokens[tokenId];
        uint taxDeadline = token.timestampOfLastPaid + annum + taxGracePeriod;
        return block.timestamp > taxDeadline;
    }

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

    function forceBuy(uint tokenId) external payable virtual {
        TokenHarbergerData storage token = tokens[tokenId];

        require(ownerOf(tokenId) != msg.sender, 'Harberger: owner cannot self force buy');
        require(!isForceBuyLocked(tokenId), 'Harberger: force buy locked');
        require(msg.value >= token.evaluationInETH, 'Harberger: not enough sent');

        token.timestampOfLastForceBuy = block.timestamp;
        _transfer(ownerOf(tokenId), msg.sender, tokenId);
        emit ForceBought(tokenId, msg.value, msg.sender);
    }

    function isForceBuyLocked(uint tokenId) public view virtual returns (bool) {
        TokenHarbergerData storage token = tokens[tokenId];
        uint timestampOfLockExpiration = token.timestampOfLastForceBuy + forceBuyLockPeriod;
        return block.timestamp <= timestampOfLockExpiration;
    }

    function isSelfEvaluationLocked(uint tokenId) public view virtual returns (bool) {
        TokenHarbergerData storage token = tokens[tokenId];
        uint timestampOfLockExpiration = token.timestampOfLastEvaluation + selfEvaluationLockPeriod;
        return block.timestamp <= timestampOfLockExpiration;
    }
}
