// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.17;

import {Harberger} from '../Harberger.sol';
import {ERC721} from '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import {ERC721Enumerable} from '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import {ERC721Pausable} from '@openzeppelin/contracts/token/ERC721/extensions/ERC721Pausable.sol';

/// @title Harberger
/// @notice An extension of ERC721 that implements the Harberger tax model.
/// @dev This contract is a mock used for testing purposes & not audited and should NOT be used in production.
contract MockHarberger is ERC721Enumerable, Harberger {
    constructor() ERC721('MockHarberger', 'MHBG') {
        for (uint16 i = 0; i <= 50; i++) {
            mint(msg.sender, i);
        }
    }

    function send(address to, uint256 tokenId) external {
        _safeTransfer(msg.sender, to, tokenId, '');
    }

    /// @notice Mints a new token.
    /// @dev We also initialize the Harberger data to be safe from malicious forceBuy or seize actions.
    /// @param to The address to mint the token to.
    /// @param tokenId The id of the token to mint.
    function mint(address to, uint256 tokenId) public {
        _safeMint(to, tokenId);
        /// NOTE: We initialize the Harberger data to be safe from malicious forceBuy or seize actions.
        _initializeHarbergerData(tokenId);
    }
}
