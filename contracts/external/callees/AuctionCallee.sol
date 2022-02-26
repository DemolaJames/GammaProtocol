/**
 * SPDX-License-Identifier: UNLICENSED
 */
pragma solidity =0.6.10;

pragma experimental ABIEncoderV2;

import {ERC20Interface} from "../../interfaces/ERC20Interface.sol";
import {SafeERC20} from "../../packages/oz/SafeERC20.sol";
import {SafeMath} from "../../packages/oz/SafeMath.sol";
import {WhitelistInterface} from "../../interfaces/WhitelistInterface.sol";

/**
 * Error Codes
 * O1: otoken is not whitelisted
 * O2: cannot auction zero otokens
 * O3: auction end date must be in the future
 * O4: auctionid is not valid
 * O5: auction asset mismatch
 * 06: cannot execute transaction, auction in progress
 * 07: cannot execute transaction, auction hasn't reach it's end date
 * 08: only asset owner can withdraw assets
 * 09: asset owner cannot fill order
 * 10: cannot execute transaction, auction has expired
 */

/**
 * @title AuctionCallee
 * @author Opyn Team
 * @dev Contract for auctioning minted oTokens
 */

contract AuctionCallee {
    using SafeERC20 for ERC20Interface;
    using SafeMath for uint256;

    WhitelistInterface public whitelist;

    enum AuctionState {
        Inprogress,
        Success,
        Fail
    }

    struct AuctionData {
        address asset;
        address assetOwner;
        address premiumAsset;
        uint256 premiumAmount;
        uint256 auctionEndDate;
        bool autoSendPremium;
        AuctionState auctionState;
    }

    /// @dev id given anytime a new asset is to be auction
    uint256 public auctionId;

    /// @dev mapping between auctionId and the auctions in the contract
    mapping(uint256 => AuctionData) public auctions;

    /// @dev mapping between auctionId and the token balances in the contract
    mapping(uint256 => mapping(address => uint256)) public balances;

    /// @notice emits an event when tokens are transferred to this contract for auctioning
    event InitiateAuction(
        uint256 indexed auctionId,
        address indexed asset,
        address indexed assetOwner,
        address premiumAsset,
        uint256 premiumAmount,
        uint256 auctionEndDate,
        AuctionState auctionState
    );

    /// @notice emits an event when tokens are transferred back to the sender
    event CloseAuction(
        uint256 indexed auctionId,
        address indexed asset,
        address indexed assetOwner,
        uint256 assetAmount,
        AuctionState auctionState
    );

    /// @notice emits an event when autions are settled
    event SettleAuction(
        uint256 indexed auctionId,
        address indexed asset,
        address assetOwner,
        address indexed filler,
        uint256 assetAmount,
        address premiumAsset,
        uint256 premiumAmount,
        AuctionState auctionState
    );

    /// @notice emits an event when premium is sent
    event PremiumSent(uint256 amount, address recipient);

    /**
     * @notice receives oTokens to this contract
     * @dev returns a new auctionId
     * @param _auctionData auction params
     */
    function initiateAuction(AuctionData calldata _auctionData) external returns (uint256) {
        //require that otoken is valid
        require(whitelist.isWhitelistedOtoken(_auctionData.asset), "01");

        // get otokens amount
        uint256 amount = ERC20Interface(_auctionData.asset).balanceOf(msg.sender);

        //accept otokens
        ERC20Interface(_auctionData.asset).safeTransferFrom(msg.sender, address(this), amount);

        //add auctionid
        auctionId = auctionId.add(1);

        //assign newly created auctionId
        auctions[auctionId] = AuctionData(
            _auctionData.asset,
            msg.sender,
            _auctionData.premiumAsset,
            _auctionData.premiumAmount,
            _auctionData.auctionEndDate,
            _auctionData.autoSendPremium,
            AuctionState.Inprogress
        );

        //update balances
        balances[auctionId][_auctionData.asset] = amount;
        balances[auctionId][_auctionData.premiumAsset] = 0;

        require(amount > 0, "02");
        require(_auctionData.auctionEndDate > block.timestamp, "03");

        //emit event;
        emit InitiateAuction(
            auctionId,
            _auctionData.asset,
            msg.sender,
            _auctionData.premiumAsset,
            _auctionData.premiumAmount,
            _auctionData.auctionEndDate,
            AuctionState.Inprogress
        );

        return auctionId;
    }

    /**
     * @notice settles auction and sends otokens to autioneers, receiving premium
     * @param _auctionId id of auction to
     * @param _asset auctioning asset in the auctionData for the id supplied
     */
    function settleAuction(uint256 _auctionId, address _asset) external {
        require(auctions[_auctionId].asset != address(0), "04");
        require(auctions[_auctionId].asset == _asset, "05");
        require(auctions[_auctionId].auctionState == AuctionState.Inprogress, "06");
        require(msg.sender != auctions[_auctionId].assetOwner, "09");
        require(auctions[_auctionId].auctionEndDate > block.timestamp, "010");

        //premium info
        address premiumAsset = auctions[_auctionId].premiumAsset;

        // track premium
        uint256 premiumBalanceBefore = balances[_auctionId][premiumAsset];

        //transfer otoken to auctioneer
        ERC20Interface(auctions[_auctionId].asset).safeIncreaseAllowance(address(this), balances[_auctionId][_asset]);

        //check premium received
        uint256 premiumBalanceAfter = balances[_auctionId][premiumAsset];
        uint256 premiumReceived = premiumBalanceAfter.sub(premiumBalanceBefore);

        //check that premium received  is the right amount
        require(premiumBalanceBefore + auctions[_auctionId].premiumAmount >= premiumBalanceAfter);

        //auto transfer premium based on configured preference
        if (auctions[_auctionId].autoSendPremium) {
            // tranfer premium to owner
            ERC20Interface(auctions[_auctionId].asset).safeTransfer(auctions[_auctionId].assetOwner, premiumReceived);
            emit PremiumSent(premiumReceived, auctions[_auctionId].assetOwner);
        }

        //emit event
        emit SettleAuction(
            _auctionId,
            _asset,
            auctions[_auctionId].assetOwner,
            msg.sender,
            balances[_auctionId][_asset],
            premiumAsset,
            premiumReceived,
            AuctionState.Success
        );
    }

    /**
     * @notice closes auction and sends tokens or premium back to owner
     * @param _auctionId id of auction to close
     * @param _asset auctioning asset in the auctionData for the auctioId supplied
     */
    function closeAuction(uint256 _auctionId, address _asset) external {
        require(auctions[_auctionId].asset != address(0), "04");
        require(auctions[_auctionId].asset == _asset, "05");
        require(auctions[_auctionId].auctionState != AuctionState.Inprogress, "06");
        require(auctions[_auctionId].auctionEndDate < block.timestamp, "07");
        require(auctions[_auctionId].assetOwner == msg.sender, "08");

        if (auctions[_auctionId].auctionState == AuctionState.Success) {
            //send unclaimed premium if exists

            if (!auctions[_auctionId].autoSendPremium) {
                //premium asset
                address premiumAsset = auctions[_auctionId].premiumAsset;

                // tranfer premium to owner
                ERC20Interface(auctions[_auctionId].asset).safeTransfer(
                    auctions[_auctionId].assetOwner,
                    balances[_auctionId][premiumAsset]
                );
                emit PremiumSent(balances[_auctionId][premiumAsset], auctions[_auctionId].assetOwner);
            }
        } else {
            //send asset back to owner
            ERC20Interface(auctions[_auctionId].asset).safeTransfer(
                auctions[_auctionId].assetOwner,
                balances[_auctionId][_asset]
            );

            //emit event;
            emit CloseAuction(_auctionId, _asset, msg.sender, balances[auctionId][_asset], AuctionState.Fail);
        }
    }
}
