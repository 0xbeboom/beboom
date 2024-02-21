// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@0xsequence/erc-1155/contracts/tokens/ERC1155/ERC1155.sol";
import "@0xsequence/erc-1155/contracts/tokens/ERC1155/ERC1155MintBurn.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Strings.sol";
import "./SafeMath.sol";
import "./BeboomRegistry.sol";

interface IBlast {
  // Note: the full interface for IBlast can be found below
  function configureClaimableGas() external;
  function claimAllGas(address contractAddress, address recipient) external returns (uint256);
}

contract Beboom is ERC1155, ERC1155MintBurn, Ownable {
    using Strings for string;
    using SafeMath for *;

    IBlast public constant BLAST = IBlast(0x4300000000000000000000000000000000000002);
    uint256 public constant rndInit_ = 24 hours; // round timer starts at this
    uint256 public constant rndInc_ = 1 hours; // every full key purchased adds this much to the timer
    uint256 public constant rndMax_ = 24 hours; // max length a round timer can be

    uint256 public constant feesPot = 50;
    uint256 public constant feesTokenOwner = 36;
    uint256 public constant feesDeployer = 2;
    uint256 public constant feesContract = 2;
    uint256 public constant feesAff = 10;

    uint256 public constant potSplitWinner = 50;
    uint256 public constant potSplitTokenOwner = 46;
    uint256 public constant potSplitDeployer = 2;
    uint256 public constant potSplitContract = 2;

    BeboomRegistry public registry;

    event EventCreate(address indexed _creator, uint256 _tokenId, uint256 _endTime);
    event EventMint(address indexed _address, uint256 _tokenId, uint256 _quantity, address indexed _inviter, uint256 _endTime);
    event EventClaim(address indexed _owner, uint256 _amount, uint256 _gen, uint256 _aff, uint256 _win, uint256 _create, uint256 _time);
    event EventUpdateCreator(address indexed _oldCreator, address indexed _newCreator, uint256 _tokenId);
    event EventEndMint(uint256 _tokenId, uint256 _bonus, address indexed _winner, uint256 _winRewards, uint256 _creatorRewards, uint256 _genRewards);
    event EventDistributeMint(uint256 _tokenId, address indexed _inviter, uint256 _value, uint256 _creatorRewards, uint256 _genRewards, uint256 _affRewards, uint256 _pot);

    string public baseURI;
    string public name;

    constructor(
        string memory _name, 
        string memory _baseURI,
        BeboomRegistry _registry) ERC1155MintBurn() Ownable(_msgSender()) {
        name = _name;
        baseURI = _baseURI;
        registry = _registry;
        BLAST.configureClaimableGas();
    }

    /**
     * @dev Require msg.sender to be the creator of the token id
     */
    modifier creatorOnly(uint256 _id) {
        require(
            registry.isCreator(_id),
            "Beboom#creatorOnly: ONLY_CREATOR_ALLOWED"
        );
        _;
    }

    function uri(uint256 _id) public view returns (string memory) {
        require(registry.isExist(_id), "Beboom#uri: NONEXISTENT_TOKEN");
        return Strings.strConcat(baseURI, Strings.uint2str(_id));
    }

    function setRegistry(BeboomRegistry _registry) public onlyOwner {
        registry = _registry;
    }

    /**
     * @dev Will update the base URL of token's URI
     * @param _newBaseMetadataURI New base URL of token's URI
     */
    function setBaseMetadataURI(
        string memory _newBaseMetadataURI
    ) public onlyOwner {
        _setBaseMetadataURI(_newBaseMetadataURI);
    }

    function _setBaseMetadataURI(string memory _newBaseMetadataURI) internal {
        baseURI = _newBaseMetadataURI;
    }

    /**
     * @dev Creates a new token type 
     * @return The newly created token ID
     */
    function create() external returns (uint256) {
        require(!registry.isTokenCreator(), "Beboom#_create: Unable to create duplicate");
        uint256 _newId = registry.newToken();
        _setupTimer(_newId);
        emit EventCreate(msg.sender, _newId, registry.tokenEndTime(_newId));
        return _newId;
    }

    /**
     * @dev Mints some amount of tokens to an address
     * @param _id          Token ID to mint
     * @param _quantity    Amount of tokens to mint
     * @param _data        Data to pass if receiver is contract
     */
    function mint(
        uint256 _id,
        uint256 _quantity,
        address _inviter,
        bytes memory _data
    ) public payable {
        bool canMint = _canMint(_id);
        if (!canMint) {
            _endMint(_id);
        }
        require(canMint, "Beboom#_mint: CANNOT_MINT_MORE");

        uint256 price = getBuyPrice(_id, _quantity).mul(_quantity);
        // require(msg.value >= price, "Beboom#_mint: Insufficient amount");
        require(msg.value >= price, uintToString(msg.value));

        _mint(msg.sender, _id, _quantity, _data);
        registry.updateTotalSupply(_id, _quantity.add(registry.getTotalSupply(_id)));

        _distributeMint(_id, msg.value, _inviter);
        _updateDataOfOwners(_id, _quantity, _inviter);

        _updateTimer(_id, _quantity);

        emit EventMint(msg.sender, _id, _quantity, _inviter, registry.tokenEndTime(_id));
    }

    function uintToString(uint256 value) public pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }

    function _canMint(uint256 tokenId) internal view returns (bool) {
        uint256 _now = block.timestamp;
        if (registry.tokenRoundStatus(tokenId) == 1) {
            return false;
        }
        if (_now > registry.tokenEndTime(tokenId)) {
            return false;
        }

        return true;
    }

    /**
     * @dev Change the creator address for given tokens
     * @param _to   Address of the new creator
     * @param _id   Token id to change creator
     */
    function setCreator(address _to, uint256 _id) creatorOnly(_id) public {
        registry.setCreator(_to, _id);
        emit EventUpdateCreator(msg.sender, _to, _id);
    }

    /**
     * @notice Transfers amount amount of an _id from the _from address to the _to address specified
     * @param _from    Source address
     * @param _to      Target address
     * @param _id      ID of the token type
     * @param _amount  Transfered amount
     */
    function _safeTransferFrom(
        address _from,
        address _to,
        uint256 _id,
        uint256 _amount
    ) internal virtual override {
        require(
            registry.isOpenTransfer(),
            "Beboom#safeBatchTransferFrom: Not yet open for trading"
        );

        // Update balances
        balances[_from][_id] -= _amount;
        balances[_to][_id] += _amount;

        // Emit event
        emit TransferSingle(msg.sender, _from, _to, _id, _amount);
    }

    /**
     * @dev return the price buyer will pay for next 1 individual key.
     * @return price for next key bought (in wei format)
     */
    function getBuyPrice(uint256 tokenId, uint256 quantity) public view returns (uint256) {
        BeboomRegistry.BeboomOwner[] memory _owners = registry.tokenOwners(tokenId);

        uint256 _newQuantity = _owners.length.add(quantity);
        uint256 _t1 = _newQuantity.mul(_newQuantity).mul(87654321);
        uint256 _t2 = _newQuantity.mul(109876543210);
        return _t1.add(_t2);
    }

    /**
     * @dev Return the current ID's total token minted quantity.
     * @return Total minted quantity for all users.
     */
    function getTokenMints(uint256 tokenId) public view returns (uint256) {
        BeboomRegistry.BeboomOwner[] memory _owners = registry.tokenOwners(tokenId);
        uint256 _total = 0;
        for (uint256 i = 0; i < _owners.length; i++) {
            BeboomRegistry.BeboomOwner memory _owner = _owners[i];
            _total = _total.add(_owner.balance);
        }
        return _total;
    }

    /**
     * @dev updates round timer based on number of whole keys bought.
     */
    function _updateTimer(uint256 tokenId, uint256 quantity) private {
        // grab time
        uint256 _now = block.timestamp;

        // calculate time based on number of keys bought
        uint256 _endTime = registry.tokenEndTime(tokenId);
        uint256 _newTime = rndInc_.mul(quantity).add(_endTime);

        // compare to max and set new end time
        if (_newTime < (rndMax_).add(_now)) registry.updateEndTime(tokenId, _newTime);
        else registry.updateEndTime(tokenId, rndMax_.add(_now));
    }

    function _setupTimer(uint256 tokenId) private {
        // grab time
        uint256 _now = block.timestamp;
        // calculate time based on number of keys bought
        uint256 _newTime = rndInit_.add(_now);
        registry.updateEndTime(tokenId, _newTime);
    }

    /**
     * @dev update dataOfTokenOwners
     */
    function _updateDataOfOwners(uint256 _id, uint256 _quantity, address _inviter) private  {
        BeboomRegistry.BeboomOwner[] memory _owners = registry.tokenOwners(_id);
        bool isExist = false;
        for (uint256 i = 0; i < _owners.length; i++) {
            BeboomRegistry.BeboomOwner memory _owner = _owners[i];
            if (_owner.addr == msg.sender) {
                isExist = true;
                registry.updateOwnerTokenBalance(_id, i,_owner.balance.add(_quantity));
                break;
            }
        }

        if (!isExist) {
            BeboomRegistry.BeboomOwner memory _owner =  BeboomRegistry.BeboomOwner(
                msg.sender,
                0,
                0,
                _inviter,
                _quantity
            );
            registry.addTokenOwner(_id, _owner);
        }
    }

    /**
     * @dev distributes blast
     */
    function _distributeMint(
        uint256 _tokenId,
        uint256 value,
        address inviter
    ) private {
        // calculate gen share
        uint256 _genValue = value.mul(feesTokenOwner).div(100);

        // calculate aff rewards
        uint256 _affValue = value.mul(feesAff).div(100);

        // calculate deployer rewards
        uint256 _creatorValue = value.mul(feesDeployer).div(100);

        // calculate contract rewards
        uint256 _contractValue = value.mul(feesContract).div(100);

        // calculate pot
        uint256 _splitTotal = _genValue.add(_affValue).add(_creatorValue).add(_contractValue);
        require(value >= _splitTotal, "Beboom#_mint: Reward pool income error");
        uint256 _pot = value.sub(_splitTotal);

        registry.addPotBalance(_tokenId, _pot);

        _updateGen(_tokenId, _genValue);

        registry.addInviterRewards(inviter, _tokenId, _affValue);
        registry.addCreatorRewards(_tokenId, _creatorValue);
        
        emit EventDistributeMint(
            _tokenId, 
            inviter,
            value, 
            _creatorValue, 
            _genValue,
            _affValue,
            _pot);
    }

    function _updateGen(uint256 _tokenId, uint256 _genValue) private {
        BeboomRegistry.BeboomOwner[] memory _owners = registry.tokenOwners(_tokenId);
        if (_owners.length > 0) {
            uint256 _totalBalance = 0;
            for (uint256 i = 0; i < _owners.length; i++) {
                BeboomRegistry.BeboomOwner memory _owner = _owners[i];
                _totalBalance = _totalBalance.add(_owner.balance);
            }

            uint256 _perOwnerGen = _genValue;
            if (_totalBalance > 0) {
                _perOwnerGen = _genValue.div(_totalBalance);
            }

            for (uint256 i = 0; i < _owners.length; i++) {
                BeboomRegistry.BeboomOwner memory _owner = _owners[i];
                registry.updateOwnerTokenGen(_tokenId, i, _owner.gen.add(_owner.balance.mul(_perOwnerGen)));
            }
        }
    }

    /**
     * @dev ends the mint. manages paying out winner/splitting up pot
     */
    function _endMint(uint256 _tokenId) private {
        uint256 _pot = registry.potBalance(_tokenId);

        // calculate gen share
        uint256 _genValue = _pot.mul(potSplitTokenOwner).div(100);

        // calculate creator rewards
        uint256 _creatorValue = _pot.mul(potSplitDeployer).div(100);

        // calculate winner rewards
        uint256 _winnerValue = _pot.mul(potSplitWinner).div(100);

        // // calculate contract rewards
        // uint256 _splitTotal = _gen.add(_deployer).add(_winner);
        // uint256 _contract = _pot.sub(_splitTotal);

        BeboomRegistry.BeboomOwner[] memory _owners = registry.tokenOwners(_tokenId);
        uint256 _totalBalance = 0;
        for (uint256 i = 0; i < _owners.length; i++) {
            BeboomRegistry.BeboomOwner memory _owner = _owners[i];
            _totalBalance = _totalBalance.add(_owner.balance);
        }
        if (_totalBalance > 0) {
            uint256 _perOwnerGen = _genValue.div(_totalBalance);

            for (uint256 i = 0; i < _owners.length; i++) {
                BeboomRegistry.BeboomOwner memory _owner = _owners[i];
                registry.updateOwnerTokenGen(_tokenId, i, _owner.gen.add(_owner.balance.mul(_perOwnerGen)));
            }
        }

        // update winner rewards
        _owners[_owners.length - 1].win = _owners[_owners.length - 1].win.add(_winnerValue);

        registry.addCreatorRewards(_tokenId, _creatorValue);
        registry.updateRoundStatus(_tokenId, 1);

        emit EventEndMint(_tokenId, _pot, _owners[_owners.length - 1].addr, _winnerValue, _creatorValue, _genValue);
    }

    /**
     * @dev claim all of your earnings.
     */
    function claim() public {
        uint256 _total = 0;
        uint256 _gen = 0;
        uint256 _aff = 0;
        uint256 _win = 0;
        uint256 _create = 0;

        for (uint256 i = 0; i < registry.tokenIdCount(); i++) {
            uint256 _tokenId = registry.getTokenId(i);

            BeboomRegistry.BeboomOwner[] memory _owners = registry.tokenOwners(_tokenId);
            for (uint256 j = 0; j < _owners.length; j++) {
                BeboomRegistry.BeboomOwner memory _owner = _owners[j];
                if (_owner.addr == msg.sender) {
                    _gen = _owner.gen;
                    _win = _owner.win;

                    _total = _gen.add(_win);
                    registry.resetOwnerTokenValues(_tokenId, j);
                    break;
                }
            }

            address _creator = registry.getCreator(_tokenId);
            if (_creator == msg.sender) {
                _create = registry.creatorRewards(_tokenId);
                _total = _total.add(_create);
                registry.resetCreatorRewards(_tokenId);
            }

            _aff = registry.inviterRewards(msg.sender, _tokenId);
            _total = _total.add(_aff);
            registry.resetInviterRewards(msg.sender, _tokenId);
        }
        require(_total > 0, "Beboom#_claim: No available rewards to claim");
        payable(msg.sender).transfer(_total);
        emit EventClaim(msg.sender, _total, _gen, _aff, _win, _create, block.timestamp);
    }

    function addressPot(address addr) onlyOwner view  public returns (uint256, uint256, uint256, uint256) {
        uint256 _total = 0;
        uint256 _gen = 0;
        uint256 _aff = 0;
        uint256 _win = 0;

        for (uint256 i = 0; i < registry.tokenIdCount(); i++) {
            uint256 _tokenId = registry.getTokenId(i);

            BeboomRegistry.BeboomOwner[] memory _owners = registry.tokenOwners(_tokenId);
            for (uint256 j = 0; j < _owners.length; j++) {
                BeboomRegistry.BeboomOwner memory _owner = _owners[j];
                if (_owner.addr == addr) {
                    _gen = _owner.gen;
                    _win = _owner.win;
                    _total = _owner.gen.add(_owner.win);
                    break;
                }
            }

            address _creator = registry.getCreator(_tokenId);
            if (_creator == addr) {
                _total = _total.add(registry.creatorRewards(_tokenId));
            }
            _aff = registry.inviterRewards(msg.sender, _tokenId);
             _total = _total.add(_aff);
        }
        return (_gen, _aff, _win, _total);
    }

    function claimGas() external {
        BLAST.claimAllGas(address(this), msg.sender);
    }
}
