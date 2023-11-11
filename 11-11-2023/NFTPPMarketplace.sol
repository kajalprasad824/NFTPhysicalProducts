// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

interface ITokenRegistry {
    function enabled(address) external view returns (bool);
}

contract NFTPPMarketplace is ERC721Holder,ERC1155Holder,Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using Address for address payable;
    using SafeERC20 for IERC20;

    /// @notice Events for the contract
    event ItemListed(
        address indexed owner,
        address indexed nft,
        uint256 tokenId,
        uint256 quantity,
        address payToken,
        uint256 pricePerItem,
        uint256 startingTime
    );

    event ItemCanceled(
        address indexed owner,
        address indexed nft,
        uint256 tokenId
    );

    event ItemUpdated(
        address indexed owner,
        address indexed nft,
        uint256 tokenId,
        address payToken,
        uint256 newPrice
    );

    event ItemSold(
        address indexed seller,
        address indexed buyer,
        address indexed nft,
        uint256 tokenId,
        uint256 quantity,
        address payToken,
        uint256 pricePerItem
    );

    event ConfirmDelivery(
        address indexed nft,
        uint256 tokenId,
        address indexed owner
    );

    event UpdatePlatformFee(uint16 platformFee);
    event UpdatePlatformFeeRecipient(address indexed platformFeeRecipient);
    event UpdateTokenRegistery(address indexed tokenRegistery);

    /// @notice Structure for listed items
    struct Listing {
        uint256 quantity;
        uint256 pricePerItem;
        uint256 startingTime;
        address payToken;
        address buyer;
        bool sold;
    }

    struct Escrow {
        address nft;
        address buyer;
        address payToken;
        uint256 amount;
        uint256 tokenID;
        bool exists;
    }

    bytes4 private constant INTERFACE_ID_ERC721 = 0x80ac58cd;
    bytes4 private constant INTERFACE_ID_ERC1155 = 0xd9b67a26;

    /// @notice NftAddress -> Token ID -> Owner -> Listing item
    mapping(address => mapping(uint256 => mapping(address => Listing)))
        public listings;

    mapping(address => Escrow[]) public escrow;

    /// @notice Platform fee
    uint16 public platformFee;

    /// @notice Platform fee receipient
    address payable public platformFeeRecipient;

    /// @notice Token registry
    address public tokenRegistry;

    /// @notice Contract initializer
    constructor(
        address initialOwner,
        address _tokenRegistry,
        address payable _platformFeeRecipient,
        uint16 _platformFee
    )Ownable(initialOwner) {
        require(
            _platformFeeRecipient != address(0),
            "Marketplace: Invalid Platform Fee Recipient"
        );
        require(
            _platformFee <= 1000,
            "Platform fee can not be greater than 10%"
        );
        tokenRegistry = _tokenRegistry;
        platformFee = _platformFee;
        platformFeeRecipient = _platformFeeRecipient;
    }

    modifier alreadyListed(
        address _nftAddress,
        uint256 _tokenId,
        address _owner
    ) {
        Listing memory listing = listings[_nftAddress][_tokenId][_owner];
        require(listing.quantity == 0, "already listed");
        _;
    }

    modifier notListed(
        address _nftAddress,
        uint256 _tokenId,
        address _owner
    ) {
        Listing memory listing = listings[_nftAddress][_tokenId][_owner];
        require(listing.quantity != 0, "NFT not listed");
        _;
    }

    modifier validListing(
        address _nftAddress,
        uint256 _tokenId,
        address _owner
    ) {
        Listing memory listedItem = listings[_nftAddress][_tokenId][_owner];

        require(listedItem.sold == false, "NFT already sold");
        require(listedItem.quantity > 0, "not listed item");
        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721 nft = IERC721(_nftAddress);
            require(nft.ownerOf(_tokenId) == _owner, "not owning item");
        } else if (
            IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC1155)
        ) {
            IERC1155 nft = IERC1155(_nftAddress);
            require(
                nft.balanceOf(_owner, _tokenId) >= listedItem.quantity,
                "not owning item"
            );
        } else {
            revert("invalid nft address");
        }

        _;
    }

    /// @notice Method for listing NFT
    /// @param _nftAddress Address of NFT contract
    /// @param _tokenId Token ID of NFT
    /// @param _quantity token amount to list (needed for ERC-1155 NFTs, set as 1 for ERC-721)
    /// @param _payToken Paying token
    /// @param _pricePerItem sale price for each iteam
    /// @param _startingTime scheduling for a future sale
    // TODO transfer nft to this address
    function listItem(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _quantity,
        address _payToken,
        uint256 _pricePerItem,
        uint256 _startingTime
    ) public alreadyListed(_nftAddress, _tokenId, _msgSender()) {
        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721 nft = IERC721(_nftAddress);
            require(nft.ownerOf(_tokenId) == _msgSender(), "not owning item");
            require(
                nft.isApprovedForAll(_msgSender(), address(this)),
                "item not approved"
            );
        } else if (
            IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC1155)
        ) {
            IERC1155 nft = IERC1155(_nftAddress);
            require(
                nft.balanceOf(_msgSender(), _tokenId) >= _quantity,
                "must hold enough nfts"
            );
            require(
                nft.isApprovedForAll(_msgSender(), address(this)),
                "item not approved"
            );
        } else {
            revert("invalid nft address");
        }

        require(
            _payToken == address(0) ||
                (tokenRegistry != address(0) &&
                    ITokenRegistry(tokenRegistry).enabled(_payToken)),
            "invalid pay token"
        );

        listings[_nftAddress][_tokenId][_msgSender()] = Listing(
            _quantity,
            _pricePerItem,
            _startingTime,
            _payToken,
            address(0),
            false
        );
        emit ItemListed(
            _msgSender(),
            _nftAddress,
            _tokenId,
            _quantity,
            _payToken,
            _pricePerItem,
            _startingTime
        );
    }

    /// @notice Method for canceling listed NFT
    function cancelListing(address _nftAddress, uint256 _tokenId)
        external
        nonReentrant
        validListing(_nftAddress, _tokenId, _msgSender())
    {
        delete (listings[_nftAddress][_tokenId][_msgSender()]);
        emit ItemCanceled(_msgSender(), _nftAddress, _tokenId);
    }

    /// @notice Method for updating listed NFT
    /// @param _nftAddress Address of NFT contract
    /// @param _tokenId Token ID of NFT
    /// @param _payToken payment token
    /// @param _newPrice New sale price for each iteam
    function updateListing(
        address _nftAddress,
        uint256 _tokenId,
        address _payToken,
        uint256 _newPrice
    ) external nonReentrant validListing(_nftAddress, _tokenId, _msgSender()) {
        Listing storage listedItem = listings[_nftAddress][_tokenId][
            _msgSender()
        ];
        require(
            _payToken == address(0) ||
                (tokenRegistry != address(0) &&
                    ITokenRegistry(tokenRegistry).enabled(_payToken)),
            "invalid pay token"
        );

        //_updateListing(_nftAddress,_tokenId,_payToken,_newPrice);

        listedItem.payToken = _payToken;
        listedItem.pricePerItem = _newPrice;
        emit ItemUpdated(
            _msgSender(),
            _nftAddress,
            _tokenId,
            _payToken,
            _newPrice
        );
    }

    /// @notice Method for buying listed NFT
    /// @param _nftAddress NFT contract address
    /// @param _tokenId TokenId
    /// @param _payToken payment token
    function buyItem(
        address _nftAddress,
        uint256 _tokenId,
        address _payToken,
        address _owner
    )
        external
        payable
        nonReentrant
        validListing(_nftAddress, _tokenId, _owner)
    {
        Listing storage listedItem = listings[_nftAddress][_tokenId][_owner];
        require(listedItem.payToken == _payToken, "invalid pay token");
        require(_getNow() >= listedItem.startingTime, "item not buyable");

        uint256 price = listedItem.pricePerItem.mul(listedItem.quantity);

        if (listedItem.payToken == address(0)) {
            require(
                msg.value >= listedItem.pricePerItem.mul(listedItem.quantity),
                "insufficient balance to buy"
            );

            (bool feeTransferSuccess, ) = address(this).call{value: price}("");
            require(feeTransferSuccess, "fee transfer failed");
        } else {
            IERC20(_payToken).safeTransferFrom(
                _msgSender(),
                address(this),
                price
            );
        }

        listedItem.sold = true;
        listedItem.buyer = _msgSender();
        _buyItem(_nftAddress, _tokenId, _payToken, _owner);
    }

    function confirmDelivery(
        address _nftAddress,
        uint256 _tokenId,
        address _owner
    ) public {
        Listing memory listedItem = listings[_nftAddress][_tokenId][_owner];
        require(listedItem.buyer == _msgSender() || owner() == _msgSender(), "Either buyer or owner can confirm");

        // Transfer NFT to buyer from smart contract
        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721(_nftAddress).safeTransferFrom(
                address(this),
                _msgSender(),
                _tokenId
            );
        } else {
            IERC1155(_nftAddress).safeTransferFrom(
                address(this),
                _msgSender(),
                _tokenId,
                listedItem.quantity,
                bytes("")
            );
        }

        uint256 price = listedItem.pricePerItem.mul(listedItem.quantity);
        uint256 feeAmount = price.mul(platformFee).div(1e4);
        // uint256 remainAmount = price - feeAmount;

        if (listedItem.payToken == address(0)) {
            (bool platformFeeTransferSuccess, ) = platformFeeRecipient.call{
                value: feeAmount
            }("");
            require(platformFeeTransferSuccess, "platform fee transfer failed");
            // (bool sellerTransferSuccess, ) = _owner.call{
            //     value: remainAmount
            // }("");
            // require(sellerTransferSuccess, "seller amount transfer failed");
        } else {
            IERC20(listedItem.payToken).safeTransfer(
                platformFeeRecipient,
                feeAmount
            );
            // IERC20(listedItem.payToken).safeTransfer(
            //     _owner,
            //     remainAmount
            // );
        }

        escrow[_owner].push(
                Escrow(
                    _nftAddress,
                    listedItem.buyer,
                    address(listedItem.payToken),
                    price.sub(feeAmount),
                    _tokenId,
                    true
                )
            );

        delete (listings[_nftAddress][_tokenId][_owner]);

        emit ConfirmDelivery(_nftAddress, _tokenId, _owner);
    }

    //-------------------------------------Admin Functions-----------------------------------

     /*
     @notice Method for paying escrow
     @dev Only contract owner can pay escrow
     @param _owner Owner of the NFT
    */
    function payEscrow(address _owner) external onlyOwner {
        Escrow[] memory escrowItems = escrow[_owner];
        require(escrowItems.length != 0, "No escrow items");
        for (uint256 i = 0; i < escrowItems.length; i++) {
            Escrow memory escrowItem = escrowItems[i];
            if (!escrowItem.exists) {
                continue;
            }
            if (escrowItem.payToken == address(0)) {
                (bool transferSuccess, ) = (_owner).call{
                    value: escrowItem.amount
                }("");
                require(transferSuccess, "transfer failed");
            } else {
                IERC20(escrowItem.payToken).safeTransfer(
                    _owner,
                    escrowItem.amount
                );
            }

            escrowItem.exists = false;
        }
        delete (escrow[_owner]);
    }

    /**
     @notice Update tokenRegistry contract
     @dev Only admin
     */
    function updateTokenRegistry(address _registry) external onlyOwner {
        tokenRegistry = _registry;
        emit UpdateTokenRegistery(_registry);
    }

    /**
     @notice Method for updating platform fee address
     @dev Only admin
     @param _platformFeeRecipient payable address the address to sends the funds to
     */
    function updatePlatformFeeRecipient(address payable _platformFeeRecipient)
        external
        onlyOwner
    {
        platformFeeRecipient = _platformFeeRecipient;
        emit UpdatePlatformFeeRecipient(_platformFeeRecipient);
    }

    /**
     @notice Method for updating platform fee
     @dev Only admin
     @param _platformFee uint16 the platform fee to set
     */
    function updatePlatformFee(uint16 _platformFee) external onlyOwner {
        platformFee = _platformFee;
        emit UpdatePlatformFee(_platformFee);
    }

    //----------------------------------Private Functions-------------------------------

    function _buyItem(
        address _nftAddress,
        uint256 _tokenId,
        address _payToken,
        address _owner
    ) private {
        Listing memory listedItem = listings[_nftAddress][_tokenId][_owner];

        // Transfer NFT to smart contract from seller
        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721(_nftAddress).safeTransferFrom(
                _owner,
                address(this),
                _tokenId
            );
        } else {
            IERC1155(_nftAddress).safeTransferFrom(
                _owner,
                address(this),
                _tokenId,
                listedItem.quantity,
                bytes("")
            );
        }

        emit ItemSold(
            _owner,
            _msgSender(),
            _nftAddress,
            _tokenId,
            listedItem.quantity,
            _payToken,
            listedItem.pricePerItem.div(listedItem.quantity)
        );
    }

    function _getNow() private view returns (uint256) {
        return block.timestamp;
    }

}


