// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

contract NFTPP1155 is ERC1155{
    
    mapping(uint256 => string) private _tokenURIs;

    constructor() ERC1155("") {}

    function mint(address account, uint256 id, uint256 amount,string calldata _uri)
        public
       
    {
        _mint(account, id, amount, "");
        _setTokenURI(id, _uri);
    }

     function _setTokenURI(uint tokenId, string calldata _tokenURI) internal {
        _tokenURIs[tokenId] = _tokenURI;
    }

    ///@notice fetches the URI associated with a token
    ///@param tokenId the id of the token
    function uri(uint256 tokenId) public view override returns (string memory) {
        return _tokenURIs[tokenId];
    }
}