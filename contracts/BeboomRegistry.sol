// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "./SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BeboomRegistry is Ownable {
    using SafeMath for *;

    struct BeboomOwner {
        address addr;   // owner address
        uint256 win;    // winnings vault
        uint256 gen;    // general vault
        address inviter;   // inviter address
        uint256 balance;
    }

    address private _operator;

    uint256 public currentTokenID = 0;
    bool private _isOpenTransfer = false;

    uint256[] public _tokenIds;

    mapping(uint256 => uint256) private  _potBalance;
    mapping(uint256 => uint256) private _endTime;

    mapping(uint256 => address) private _creators;
    mapping(uint256 => uint256) private  _tokenSupply;
    mapping(uint256 => BeboomOwner[]) public dataOfTokenOwners; // (tokenId => owner data) owner data
    mapping(uint256 => uint256) private  _creatorRewards;
    mapping(address => mapping(uint256 => uint256)) private _inviterRewards;
    mapping(uint256 => uint256) private _tokenRoundStatus; // 0-in progress 1-end

    constructor() Ownable(_msgSender()) {
    }

    modifier authorised() {
        require(owner() == msg.sender || _operator == msg.sender);
        _;
    }

    function setOperator(address _addr) public authorised() {
        _operator = _addr;
    }

    function isCreator(uint256 tokenId) public view returns (bool) {
        return _creators[tokenId] == msg.sender;
    }

    function getCreator(uint256 tokenId) public view returns (address) {
        return _creators[tokenId];
    }

    function setCreator(address _to, uint256 _id) public {
        require(_to != address(0) && isCreator(_id), "Beboom#setCreator: INVALID_ADDRESS.");
        _creators[_id] = _to;
    }

    function isTokenCreator() public view returns (bool) {
        for (uint256 i = 1; i <= currentTokenID; i++) {
            if (_creators[i] == msg.sender) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Returns whether the specified token exists by checking to see if it has a creator
     * @param _id uint256 ID of the token to query the existence of
     * @return bool whether the token exists
     */
    function isExist(uint256 _id) public view returns (bool) {
        return _creators[_id] != address(0);
    }

    function isOpenTransfer() public view returns (bool) {
        return _isOpenTransfer;
    }

    function openTransfer(bool open) public authorised() {
        _isOpenTransfer = open;
    }

    function tokenEndTime(uint256 tokenId) public view returns (uint256) {
        return _endTime[tokenId];
    }

    function updateEndTime(uint256 tokenId, uint256 time) public authorised() {
        _endTime[tokenId] = time;
    }

    function newToken() public authorised() returns (uint256) {
        uint256 _id = currentTokenID + 1;
        _incrementTokenTypeId();
        _creators[_id] = msg.sender;
        _tokenIds.push(_id);
        return _id;
    }

    function updateTotalSupply(uint256 id, uint256 total) public authorised() {
        _tokenSupply[id] = total;
    }

    /**
     * @dev Returns the total quantity for a token ID
     * @param _id uint256 ID of the token to query
     */
    function getTotalSupply(uint256 _id) public view returns (uint256) {
        return _tokenSupply[_id];
    }

    function tokenOwners(uint256 tokenId) public view returns (BeboomOwner[] memory) {
        return dataOfTokenOwners[tokenId];
    }

    function updateOwnerTokenBalance(uint256 tokenId, uint256 index, uint256 balance) public authorised() {
        dataOfTokenOwners[tokenId][index].balance = balance;
    }

    function updateOwnerTokenGen(uint256 tokenId, uint256 index, uint256 gen) public authorised() {
        dataOfTokenOwners[tokenId][index].gen = gen;
    }

    function resetOwnerTokenValues(uint256 tokenId, uint256 index) public authorised() {
        dataOfTokenOwners[tokenId][index].gen = 0;
        dataOfTokenOwners[tokenId][index].win = 0;
    }

    function addTokenOwner(uint256 tokenId, BeboomOwner memory owner) public authorised() {
        dataOfTokenOwners[tokenId].push(owner);
    }

    /**
     * @dev increments the value of _currentTokenID
     */
    function _incrementTokenTypeId() private {
        currentTokenID++;
    }

    function tokenRoundStatus(uint256 tokenId) public view returns (uint256) {
        return _tokenRoundStatus[tokenId];
    }

    function updateRoundStatus(uint256 tokenId, uint256 status) public authorised() {
        _tokenRoundStatus[tokenId] = status;
    }

    function tokenIdCount() public view returns (uint256) {
        return _tokenIds.length;
    }

    function getTokenId(uint256 index) public view returns (uint256) {
        return _tokenIds[index];
    }

    function addPotBalance(uint256 tokenId, uint256 balance) public authorised() {
        _potBalance[tokenId] = balance.add( _potBalance[tokenId]);
    }

    function potBalance(uint256 tokenId) public view returns (uint256) {
        return _potBalance[tokenId];
    }

    function addInviterRewards(address inviter, uint256 _tokenId, uint256 rewards) public authorised() {
        _inviterRewards[inviter][_tokenId] = _inviterRewards[inviter][_tokenId].add(rewards);
    }

    function inviterRewards(address inviter, uint256 _tokenId) public view returns (uint256) {
        return _inviterRewards[inviter][_tokenId];
    }

    function resetInviterRewards(address inviter, uint256 _tokenId) public authorised() {
        _inviterRewards[inviter][_tokenId] = 0;
    }

    function addCreatorRewards(uint256 _tokenId, uint256 rewards) public authorised() {
        _creatorRewards[_tokenId] = _creatorRewards[_tokenId].add(rewards);
    }

    function creatorRewards( uint256 _tokenId) public view returns (uint256) {
        return _creatorRewards[_tokenId];
    }

    function resetCreatorRewards(uint256 _tokenId) public authorised() {
        _creatorRewards[_tokenId] = 0;
    }
}
