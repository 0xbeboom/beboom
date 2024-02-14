// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@0xsequence/erc-1155/contracts/tokens/ERC1155/ERC1155.sol";
import "@0xsequence/erc-1155/contracts/tokens/ERC1155/ERC1155MintBurn.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Strings.sol";
import "./SafeMath.sol";

interface IBlast {
  // Note: the full interface for IBlast can be found below
  function configureClaimableGas() external;
  function claimAllGas(address contractAddress, address recipient) external returns (uint256);
}

contract Beboom is ERC1155, ERC1155MintBurn, Ownable {
    using Strings for string;
    using SafeMath for *;

    IBlast public constant BLAST = IBlast(0x4300000000000000000000000000000000000002);

    struct AtOwner {
        address addr;   // owner address
        uint256 win;    // winnings vault
        uint256 gen;    // general vault
        address inviter;   // inviter address
        uint256 balance;
    }

    event EventCreate(address indexed _creator, uint256 _tokenId, uint256 _endTime);
    event EventMint(address indexed _address, uint256 _tokenId, uint256 _quantity, address indexed _inviter, uint256 _endTime);
    event EventClaim(address indexed _owner, uint256 _amount, uint256 _gen, uint256 _aff, uint256 _win, uint256 _create, uint256 _time);
    event EventUpdateCreator(address indexed _oldCreator, address indexed _newCreator, uint256 _tokenId);
    event EventEndMint(uint256 _tokenId, uint256 _bonus, address indexed _winner, uint256 _winRewards, uint256 _creatorRewards, uint256 _genRewards);
    event EventDistributeMint(uint256 _tokenId, address indexed _inviter, uint256 _value, uint256 _creatorRewards, uint256 _genRewards, uint256 _affRewards, uint256 _pot);

    string public baseURI;
    string public name;

    uint256 private _currentTokenID = 0;
    uint256 private _isOpenTransfer = 0;

    // uint256 private constant rndInit_ = 1 hours; // round timer starts at this
    // uint256 private constant rndInc_ = 30 seconds; // every full key purchased adds this much to the timer
    // uint256 private constant rndMax_ = 24 hours; // max length a round timer can be

    uint256 private constant rndInit_ = 72 hours; // round timer starts at this
    uint256 private constant rndInc_ = 24 seconds; // every full key purchased adds this much to the timer
    uint256 private constant rndMax_ = 999 hours; // max length a round timer can be

    uint256 public constant feesPot = 50;
    uint256 public constant feesTokenOwner = 36;
    uint256 public constant feesDeployer = 2;
    uint256 public constant feesContract = 2;
    uint256 public constant feesAff = 10;

    uint256 public constant potSplitWinner = 50;
    uint256 public constant potSplitTokenOwner = 46;
    uint256 public constant potSplitDeployer = 2;
    uint256 public constant potSplitContract = 2;
    uint256[] public tokenIds;

    mapping(uint256 => uint256) public potBalance;
    mapping(uint256 => uint256) public endTime;

    mapping(uint256 => address) public creators;
    mapping(uint256 => uint256) public tokenSupply;
    mapping(uint256 => AtOwner[]) public dataOfTokenOwners; // (tokenId => owner data) owner data
    mapping(uint256 => uint256) public creatorRewards;
    mapping(address => mapping(uint256 => uint256)) public inviterRewards;
    mapping(uint256 => uint256) public rokenRoundStatus; // 0-in progress 1-end

    constructor(string memory _name, string memory _baseURI) ERC1155MintBurn() Ownable(_msgSender()) {
        name = _name;
        baseURI = _baseURI;
        BLAST.configureClaimableGas();
    }

    /**
     * @dev Require msg.sender to be the creator of the token id
     */
    modifier creatorOnly(uint256 _id) {
        require(
            creators[_id] == msg.sender,
            "At20#creatorOnly: ONLY_CREATOR_ALLOWED"
        );
        _;
    }

    function uri(uint256 _id) public view returns (string memory) {
        require(_exists(_id), "At20#uri: NONEXISTENT_TOKEN");
        return Strings.strConcat(baseURI, Strings.uint2str(_id));
    }

    /**
     * @dev Returns the total quantity for a token ID
     * @param _id uint256 ID of the token to query
     * @return amount of token in existence
     */
    function totalSupply(uint256 _id) public view returns (uint256) {
        return tokenSupply[_id];
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
        bool isExist = false;
        for (uint256 i = 1; i <= _currentTokenID; i++) {
            if (creators[i] == msg.sender) {
                isExist = true;
                break;
            }
        }
        require(!isExist, "AT20#_create: Unable to create duplicate");

         uint256 _id = _getNextTokenID();
        _incrementTokenTypeId();
        creators[_id] = msg.sender;

        // _mint(_initialOwner, _id, _initialSupply, _data);
        // tokenSupply[_id] = _initialSupply;
        _setupTimer(_id);
        emit EventCreate(msg.sender, _id, endTime[_id]);
        return _id;
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
        require(canMint, "AT20#_mint: CANNOT_MINT_MORE");

        uint256 price = getBuyPrice(_id).mul(_quantity);
        require(msg.value >= price, "AT20#_mint: Insufficient amount");

        _mint(msg.sender, _id, _quantity, _data);
        tokenSupply[_id] = tokenSupply[_id].add(_quantity);

        _distributeMint(_id, msg.value, _inviter);
        _updateDataOfOwners(_id, _quantity, _inviter);

        _updateTimer(_id);

        emit EventMint(msg.sender, _id, _quantity, _inviter, endTime[_id]);
    }

    function _canMint(uint256 tokenId) internal view returns (bool) {
        uint256 _now = block.timestamp;
        if (rokenRoundStatus[tokenId] == 1) {
            return false;
        }
        if (_now > endTime[tokenId]) {
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
        require(_to != address(0), "At20#setCreator: INVALID_ADDRESS.");
        creators[_id] = _to;

        emit EventUpdateCreator(msg.sender, _to, _id);
    }

    /**
     * @dev Returns whether the specified token exists by checking to see if it has a creator
     * @param _id uint256 ID of the token to query the existence of
     * @return bool whether the token exists
     */
    function _exists(uint256 _id) internal view returns (bool) {
        return creators[_id] != address(0);
    }

    /**
     * @dev calculates the next token ID based on value of _currentTokenID
     * @return uint256 for the next token ID
     */
    function _getNextTokenID() private view returns (uint256) {
        return _currentTokenID.add(1);
    }

    /**
     * @dev increments the value of _currentTokenID
     */
    function _incrementTokenTypeId() private {
        _currentTokenID++;
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
            _isOpenTransfer != 0,
            "AT20#safeBatchTransferFrom: Not yet open for trading"
        );

        // Update balances
        balances[_from][_id] -= _amount;
        balances[_to][_id] += _amount;

        // Emit event
        emit TransferSingle(msg.sender, _from, _to, _id, _amount);
    }

    function setOpenTransfer(uint256 open) public onlyOwner {
        _isOpenTransfer = open;
    }

    /**
     * @dev return the price buyer will pay for next 1 individual key.
     * @return price for next key bought (in wei format)
     */
    function getBuyPrice(uint256 tokenId) public view returns (uint256) {
        AtOwner[] memory _owners = dataOfTokenOwners[tokenId];

        if (_owners.length == 0) {
            return 1000000000000000;
        }
        uint256 _totalBalance = 0;
        for (uint256 i = 0; i < _owners.length; i++) {
            AtOwner memory _owner = _owners[i];
            _totalBalance.add(_owner.balance);
        }
        return _totalBalance.mul(_totalBalance).div(16000).add(1000000000000000);
    }

    /**
     * @dev updates round timer based on number of whole keys bought.
     */
    function _updateTimer(uint256 tokenId) private {
        // grab time
        uint256 _now = block.timestamp;

        // calculate time based on number of keys bought
        uint256 _newTime = rndInc_.add(endTime[tokenId]);

        // compare to max and set new end time
        if (_newTime < (rndMax_).add(_now)) endTime[tokenId] = _newTime;
        else endTime[tokenId] = rndMax_.add(_now);
    }

    function _setupTimer(uint256 tokenId) private {
        // grab time
        uint256 _now = block.timestamp;

        // calculate time based on number of keys bought
        uint256 _newTime = rndInit_.add(_now);
        endTime[tokenId] = _newTime;
    }

    /**
     * @dev update dataOfTokenOwners
     */
    function _updateDataOfOwners(uint256 _id, uint256 _quantity, address _inviter) private  {
        AtOwner[] memory _owners = dataOfTokenOwners[_id];
        bool isExist = false;
        for (uint256 i = 0; i < _owners.length; i++) {
            AtOwner memory _owner = _owners[i];
            if (_owner.addr == msg.sender) {
                isExist = true;
                _owner.balance = _owner.balance.add(_quantity);
                break;
            }
        }

        if (!isExist) {
            AtOwner memory _owner =  AtOwner(
                msg.sender,
                0,
                0,
                _inviter,
                _quantity
            );
            dataOfTokenOwners[_id].push(_owner);
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
        require(value >= _splitTotal, "AT20#_mint: Reward pool income error");
        uint256 _pot = value.sub(_splitTotal);

        potBalance[_tokenId].add(_pot);

        AtOwner[] memory _owners = dataOfTokenOwners[_tokenId];
        if (_owners.length > 0) {
            uint256 _totalBalance = 0;
            for (uint256 i = 0; i < _owners.length; i++) {
                AtOwner memory _owner = _owners[i];
                _totalBalance = _totalBalance.add(_owner.balance);
            }

            uint256 _perOwnerGen = 0;
            if (_totalBalance > 0) {
                _perOwnerGen = _genValue.div(_totalBalance);
            }

            for (uint256 i = 0; i < _owners.length; i++) {
                AtOwner memory _owner = _owners[i];
                _owner.gen = _owner.gen.add(_owner.balance.mul(_perOwnerGen));
            }
        }

        inviterRewards[inviter][_tokenId] = inviterRewards[inviter][_tokenId].add(_affValue);
        creatorRewards[_tokenId] = creatorRewards[_tokenId].add(_creatorValue);
        
        emit EventDistributeMint(
            _tokenId, 
            inviter,
            value, 
            _creatorValue, 
            _genValue,
            _affValue,
            _pot);
    }

    /**
     * @dev ends the mint. manages paying out winner/splitting up pot
     */
    function _endMint(uint256 _tokenId) private {
        uint256 _pot = potBalance[_tokenId];

        // calculate gen share
        uint256 _genValue = _pot.mul(potSplitTokenOwner).div(100);

        // calculate creator rewards
        uint256 _creatorValue = _pot.mul(potSplitDeployer).div(100);

        // calculate winner rewards
        uint256 _winnerValue = _pot.mul(potSplitWinner).div(100);

        // // calculate contract rewards
        // uint256 _splitTotal = _gen.add(_deployer).add(_winner);
        // uint256 _contract = _pot.sub(_splitTotal);

        AtOwner[] memory _owners = dataOfTokenOwners[_tokenId];
        uint256 _totalBalance = 0;
        for (uint256 i = 0; i < _owners.length; i++) {
            AtOwner memory _owner = _owners[i];
            _totalBalance = _totalBalance.add(_owner.balance);
        }
        if (_totalBalance > 0) {
            uint256 _perOwnerGen = _genValue.div(_totalBalance);

            for (uint256 i = 0; i < _owners.length; i++) {
                AtOwner memory _owner = _owners[i];
                _owner.gen = _owner.gen.add(_owner.balance.mul(_perOwnerGen));
            }
        }

        // update winner rewards
        _owners[_owners.length - 1].win = _owners[_owners.length - 1].win.add(_winnerValue);

        creatorRewards[_tokenId] = creatorRewards[_tokenId].add(_creatorValue);
        rokenRoundStatus[_tokenId] = 1;

        emit EventEndMint(_tokenId, _pot, _owners[_owners.length - 1].addr, _winnerValue, _creatorValue, _genValue);
    }

    /**
     * @dev claim all of your earnings.
     */
    function claim() public {
        uint256 _now = block.timestamp;
        uint256 _total = 0;
        uint256 _gen = 0;
        uint256 _aff = 0;
        uint256 _win = 0;
        uint256 _create = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 _tokenId = tokenIds[i];
            if (_now < endTime[_tokenId]) {
                continue;
            }

            // Check if the token has ended
            if (rokenRoundStatus[_tokenId] != 1) {
                _endMint(_tokenId);
            }
            AtOwner[] memory _owners = dataOfTokenOwners[_tokenId];
            for (uint256 j = 0; j < _owners.length; j++) {
                AtOwner memory _owner = _owners[j];
                if (_owner.addr == msg.sender) {
                    _gen = _owner.gen;
                    _win = _owner.win;

                    _total = _gen.add(_win);
                    dataOfTokenOwners[_tokenId][j].gen = 0;
                    dataOfTokenOwners[_tokenId][j].win = 0;
                    break;
                }
            }

            address _creator = creators[_tokenId];
            if (_creator == msg.sender) {
                _create = creatorRewards[_tokenId];
                _total = _total.add(_create);
                creatorRewards[_tokenId] = 0;
            }

            _aff = inviterRewards[msg.sender][_tokenId];
            _total = _total.add(_aff);
            inviterRewards[msg.sender][_tokenId] = 0;
        }
        payable(msg.sender).transfer(_total);
        emit EventClaim(msg.sender, _total, _gen, _aff, _win, _create, block.timestamp);
    }

    function addressPot(address addr) onlyOwner view  public returns (uint256, uint256, uint256, uint256) {
        uint256 _now = block.timestamp;
        uint256 _total = 0;
        uint256 _gen = 0;
        uint256 _aff = 0;
        uint256 _win = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 _tokenId = tokenIds[i];
            if (_now < endTime[_tokenId]) {
                continue;
            }

            AtOwner[] memory _owners = dataOfTokenOwners[_tokenId];
            for (uint256 j = 0; j < _owners.length; j++) {
                AtOwner memory _owner = _owners[j];
                if (_owner.addr == addr) {
                    _gen = _owner.gen;
                    _win = _owner.win;
                    _total = _owner.gen.add(_owner.win);
                    break;
                }
            }

            address _creator = creators[_tokenId];
            if (_creator == addr) {
                _total = _total.add(creatorRewards[_tokenId]);
            }
            _aff = inviterRewards[msg.sender][_tokenId];
             _total = _total.add(_aff);
        }
        return (_gen, _aff, _win, _total);
    }

    function claimGas() external {
        BLAST.claimAllGas(address(this), msg.sender);
    }
}
