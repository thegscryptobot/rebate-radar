// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IBGT {
    function balanceOf(address account) external view returns (uint256);
    function redeem(address receiver, uint256 amount) external;
}

interface IRewardVault {
    function getReward(address account, address recipient) external returns (uint256);
    function getWhitelistedTokens() external view returns (address[] memory);
}

contract BRSExecutor is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint16  public constant MAX_FEE_BPS = 1500;
    uint256 public constant MIN_FEE_BERA = 0.0001 ether;

    address public immutable BGT;
    address public bot;
    bool    public paused;

    mapping(address => bool)    public optedIn;
    mapping(address => uint256) public claimCount;
    mapping(address => uint256) public totalBeraReceived;

    event UserOptedIn(address indexed user, uint256 timestamp);
    event UserOptedOut(address indexed user);
    event BotUpdated(address indexed oldBot, address indexed newBot);
    event ContractPaused(address indexed caller);
    event ContractUnpaused(address indexed caller);
    event ClaimExecuted(address indexed user, address indexed vault, uint256 bgtClaimed, uint256 beraToUser, uint256 beraFee, uint16 feeBps);
    event IncentiveTokenSent(address indexed user, address indexed token, uint256 toUser, uint256 toOwner);

    error NotBot();
    error NotOptedIn();
    error IsPaused();
    error FeeTooHigh();
    error ZeroAddress();
    error TransferFailed();
    error NothingClaimed();

    modifier onlyBot() {
        if (msg.sender != bot) revert NotBot();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    constructor(address _bot, address _owner, address _bgt) {
        if (_bot   == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();
        if (_bgt   == address(0)) revert ZeroAddress();
        bot = _bot;
        BGT = _bgt;
        _transferOwnership(_owner);
    }

    function optIn() external {
        optedIn[msg.sender] = true;
        emit UserOptedIn(msg.sender, block.timestamp);
    }

    function optOut() external {
        optedIn[msg.sender] = false;
        emit UserOptedOut(msg.sender);
    }

    function executeClaim(address user, address vault, uint256 rewardUsd) external nonReentrant onlyBot whenNotPaused {
        if (!optedIn[user])     revert NotOptedIn();
        if (user == address(0)) revert ZeroAddress();
        if (vault == address(0)) revert ZeroAddress();

        _sweepLeftovers();

        uint16 feeBps = _getFeeBps(rewardUsd);
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();

        uint256 beraBefore = address(this).balance;
        uint256 bgtBefore  = IBGT(BGT).balanceOf(address(this));

        IRewardVault(vault).getReward(user, address(this));

        uint256 bgtClaimed = IBGT(BGT).balanceOf(address(this)) - bgtBefore;

        if (bgtClaimed > 0) {
            IBGT(BGT).redeem(address(this), bgtClaimed);
        }

        uint256 beraGained = address(this).balance - beraBefore;

        if (beraGained == 0 && bgtClaimed > 0) revert NothingClaimed();

        if (beraGained > 0) {
            uint256 beraFee    = (beraGained * feeBps) / 10000;
            uint256 beraToUser = beraGained - beraFee;

            if (beraFee > 0 && beraFee < MIN_FEE_BERA) {
                beraFee    = MIN_FEE_BERA;
                beraToUser = beraGained - beraFee;
            }

            (bool sentUser,) = user.call{value: beraToUser}("");
            (bool sentFee,)  = owner().call{value: beraFee}("");
            if (!sentUser || !sentFee) revert TransferFailed();

            claimCount[user]++;
            totalBeraReceived[user] += beraToUser;

            emit ClaimExecuted(user, vault, bgtClaimed, beraToUser, beraFee, feeBps);
        }

        try IRewardVault(vault).getWhitelistedTokens() returns (address[] memory tokens) {
            for (uint256 i = 0; i < tokens.length; i++) {
                if (tokens[i] == BGT) continue;

                uint256 received = IERC20(tokens[i]).balanceOf(address(this));
                if (received == 0) continue;

                uint256 tokenFee    = (received * feeBps) / 10000;
                uint256 tokenToUser = received - tokenFee;

                IERC20(tokens[i]).safeTransfer(user, tokenToUser);
                IERC20(tokens[i]).safeTransfer(owner(), tokenFee);

                emit IncentiveTokenSent(user, tokens[i], tokenToUser, tokenFee);
            }
        } catch {}
    }

    function setBot(address _newBot) external onlyOwner {
        if (_newBot == address(0)) revert ZeroAddress();
        emit BotUpdated(bot, _newBot);
        bot = _newBot;
    }

    function pause() external onlyOwner {
        paused = true;
        emit ContractPaused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit ContractUnpaused(msg.sender);
    }

    function recoverToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    function recoverBERA() external onlyOwner {
        (bool sent,) = owner().call{value: address(this).balance}("");
        if (!sent) revert TransferFailed();
    }

    function getFeeBps(uint256 rewardUsd) external pure returns (uint16) {
        return _getFeeBps(rewardUsd);
    }

    function contractBERABalance() external view returns (uint256) {
        return address(this).balance;
    }

    function _getFeeBps(uint256 rewardUsd) internal pure returns (uint16) {
        if (rewardUsd < 10  * 1e18) return 1250;
        if (rewardUsd < 100 * 1e18) return 1000;
        return 850;
    }

    function _sweepLeftovers() internal {
        if (address(this).balance > 0) {
            (bool sent,) = owner().call{value: address(this).balance}("");
            if (!sent) revert TransferFailed();
        }
    }

    receive() external payable {}
}