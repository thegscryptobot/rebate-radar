// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/BRSExecutor.sol";

contract MockERC20 is IERC20 {
    string  public name = "Mock";
    uint8   public decimals = 18;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockBGT {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function redeem(address receiver, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "Insufficient BGT");
        balanceOf[msg.sender] -= amount;
        (bool sent,) = receiver.call{value: amount}("");
        require(sent, "ETH send failed");
    }

    receive() external payable {}
}

contract MockRewardVault {
    MockBGT public bgt;
    MockERC20 public incentiveToken;
    uint256 public bgtReward;
    uint256 public incentiveReward;
    bool public hasWhitelistedTokens;

    constructor(address payable _bgt, address _incentiveToken) {
        bgt = MockBGT(_bgt);
        incentiveToken = MockERC20(_incentiveToken);
        hasWhitelistedTokens = true;
    }

    function setRewards(uint256 _bgt, uint256 _incentive) external {
        bgtReward = _bgt;
        incentiveReward = _incentive;
    }

    function setHasWhitelistedTokens(bool _has) external {
        hasWhitelistedTokens = _has;
    }

    function getReward(address, address recipient) external returns (uint256) {
        if (bgtReward > 0) bgt.mint(recipient, bgtReward);
        if (incentiveReward > 0) incentiveToken.mint(recipient, incentiveReward);
        return bgtReward;
    }

    function getWhitelistedTokens() external view returns (address[] memory) {
        if (!hasWhitelistedTokens) revert("No tokens");
        address[] memory tokens = new address[](1);
        tokens[0] = address(incentiveToken);
        return tokens;
    }
}

contract BRSExecutorTest is Test {
    BRSExecutor public executor;
    MockBGT public mockBGT;
    MockERC20 public mockIncentive;
    MockRewardVault public mockVault;

    address public owner = makeAddr("owner");
    address public bot = makeAddr("bot");
    address public user = makeAddr("user");
    address public stranger = makeAddr("stranger");

    function setUp() public {
        mockBGT = new MockBGT();
        mockIncentive = new MockERC20();
        mockVault = new MockRewardVault(payable(address(mockBGT)), address(mockIncentive));
        vm.deal(address(mockBGT), 100 ether);
        executor = new BRSExecutor(bot, owner, address(mockBGT));
        vm.prank(user);
        executor.optIn();
    }

    function test_FeeTier_Micro() public {
        assertEq(executor.getFeeBps(5e18), 1250);
    }

    function test_FeeTier_Standard() public {
        assertEq(executor.getFeeBps(50e18), 1000);
    }

    function test_FeeTier_Whale() public {
        assertEq(executor.getFeeBps(200e18), 850);
    }

    function test_OnlyBot_CanExecuteClaim() public {
        vm.prank(stranger);
        vm.expectRevert(BRSExecutor.NotBot.selector);
        executor.executeClaim(user, address(mockVault), 50e18);
    }

    function test_OptedIn() public {
        assertTrue(executor.optedIn(user));
    }

    function test_OptedOut_CannotBeClaimed() public {
        vm.prank(user);
        executor.optOut();
        vm.prank(bot);
        vm.expectRevert(BRSExecutor.NotOptedIn.selector);
        executor.executeClaim(user, address(mockVault), 50e18);
    }

    function test_Pause_BlocksClaims() public {
        vm.prank(owner);
        executor.pause();
        vm.prank(bot);
        vm.expectRevert(BRSExecutor.IsPaused.selector);
        executor.executeClaim(user, address(mockVault), 50e18);
    }

    function test_Unpause_AllowsClaims() public {
        vm.prank(owner);
        executor.pause();
        vm.prank(owner);
        executor.unpause();
        mockVault.setRewards(1 ether, 0);
        vm.prank(bot);
        executor.executeClaim(user, address(mockVault), 50e18);
        assertEq(executor.claimCount(user), 1);
    }

    function test_ZeroAddress_Bot() public {
        vm.expectRevert(BRSExecutor.ZeroAddress.selector);
        new BRSExecutor(address(0), owner, address(mockBGT));
    }

    function test_ZeroAddress_Owner() public {
        vm.expectRevert(BRSExecutor.ZeroAddress.selector);
        new BRSExecutor(bot, address(0), address(mockBGT));
    }

    function test_ZeroAddress_BGT() public {
        vm.expectRevert(BRSExecutor.ZeroAddress.selector);
        new BRSExecutor(bot, owner, address(0));
    }

    function test_FeeSplit_Standard() public {
        mockVault.setRewards(1 ether, 0);
        uint256 ownerBefore = owner.balance;
        uint256 userBefore = user.balance;
        vm.prank(bot);
        executor.executeClaim(user, address(mockVault), 50e18);
        assertEq(owner.balance - ownerBefore, 0.1 ether);
        assertEq(user.balance - userBefore, 0.9 ether);
        assertEq(executor.contractBERABalance(), 0);
    }

    function test_FeeSplit_Micro() public {
        mockVault.setRewards(0.1 ether, 0);
        vm.prank(bot);
        executor.executeClaim(user, address(mockVault), 5e18);
        assertEq(owner.balance, 0.0125 ether);
    }

    function test_FeeSplit_Whale() public {
        mockVault.setRewards(10 ether, 0);
        vm.prank(bot);
        executor.executeClaim(user, address(mockVault), 200e18);
        assertEq(owner.balance, 0.85 ether);
    }

    function test_IncentiveToken_Split() public {
        mockVault.setRewards(0, 100 ether);
        vm.prank(bot);
        executor.executeClaim(user, address(mockVault), 50e18);
        assertEq(mockIncentive.balanceOf(owner), 10 ether);
        assertEq(mockIncentive.balanceOf(user), 90 ether);
    }

    function test_VaultWithoutWhitelistedTokens() public {
        mockVault.setHasWhitelistedTokens(false);
        mockVault.setRewards(1 ether, 100 ether);
        vm.prank(bot);
        executor.executeClaim(user, address(mockVault), 50e18);
        assertEq(executor.claimCount(user), 1);
    }

    function test_Combined_BGT_And_Incentive() public {
        mockVault.setRewards(2 ether, 50 ether);
        vm.prank(bot);
        executor.executeClaim(user, address(mockVault), 50e18);
        assertEq(owner.balance, 0.2 ether);
        assertEq(user.balance, 1.8 ether);
        assertEq(mockIncentive.balanceOf(owner), 5 ether);
        assertEq(mockIncentive.balanceOf(user), 45 ether);
    }

    function test_ClaimCount_Increments() public {
        mockVault.setRewards(1 ether, 0);
        vm.prank(bot);
        executor.executeClaim(user, address(mockVault), 50e18);
        assertEq(executor.claimCount(user), 1);
        vm.prank(bot);
        executor.executeClaim(user, address(mockVault), 50e18);
        assertEq(executor.claimCount(user), 2);
    }
}