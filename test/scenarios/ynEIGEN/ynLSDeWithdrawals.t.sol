// SPDX-License-Identifier: BSD 3-Clause License
pragma solidity ^0.8.24;

import {IStrategy} from "lib/eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {ITokenStakingNodesManager} from "src/interfaces/ITokenStakingNodesManager.sol";
import {ITokenStakingNode} from "src/interfaces/ITokenStakingNode.sol";
import {IRedeemableAsset} from "src/interfaces/IRedeemableAsset.sol";
import {IYieldNestStrategyManager} from "src/interfaces/IYieldNestStrategyManager.sol";

import {LSDWrapper} from "src/ynEIGEN/LSDWrapper.sol";
import {RedemptionAssetsVault} from "src/ynEIGEN/RedemptionAssetsVault.sol";
import {WithdrawalQueueManager} from "src/WithdrawalQueueManager.sol";

import {console} from "forge-std/console.sol";

import "./ynLSDeScenarioBaseTest.sol";

contract ynLSDeWithdrawalsTest is ynLSDeScenarioBaseTest {

    bool private _setup = true;

    address public constant user = address(0x42069);

    ITokenStakingNode public tokenStakingNode;
    RedemptionAssetsVault public redemptionAssetsVault;
    WithdrawalQueueManager public withdrawalQueueManager;
    LSDWrapper public wrapper;

    uint256 public constant AMOUNT = 1 ether;

    function setUp() public virtual override {

        super.setUp();

        uint256 _totalAssetsBefore = yneigen.totalAssets();

        // deal assets to user
        {
            deal({ token: chainAddresses.lsd.WSTETH_ADDRESS, to: user, give: 1000 ether });
            deal({ token: chainAddresses.lsd.WOETH_ADDRESS, to: user, give: 1000 ether });
            deal({ token: chainAddresses.lsd.SFRXETH_ADDRESS, to: user, give: 1000 ether });
        }

        // deploy RedemptionAssetsVault
        {
            TransparentUpgradeableProxy _proxy = new TransparentUpgradeableProxy(
                address(new RedemptionAssetsVault()),
                actors.admin.PROXY_ADMIN_OWNER,
                ""
            );
            redemptionAssetsVault = RedemptionAssetsVault(payable(address(_proxy)));
        }

        // deploy WithdrawalQueueManager
        {
            TransparentUpgradeableProxy _proxy = new TransparentUpgradeableProxy(
                address(new WithdrawalQueueManager()),
                actors.admin.PROXY_ADMIN_OWNER,
                ""
            );
            withdrawalQueueManager = WithdrawalQueueManager(address(_proxy));
        }

        // deploy wrapper
        {
            // call `initialize` on LSDWrapper
            TransparentUpgradeableProxy _proxy = new TransparentUpgradeableProxy(
                address(
                    new LSDWrapper(
                        chainAddresses.lsd.WSTETH_ADDRESS,
                        chainAddresses.lsd.WOETH_ADDRESS,
                        chainAddresses.lsd.OETH_ADDRESS,
                        chainAddresses.lsd.STETH_ADDRESS)
                    ),
                actors.admin.PROXY_ADMIN_OWNER,
                abi.encodeWithSignature("initialize()")
            );
            wrapper = LSDWrapper(address(_proxy));
        }

        // initialize RedemptionAssetsVault
        {
            RedemptionAssetsVault.Init memory _init = RedemptionAssetsVault.Init({
                admin: actors.admin.PROXY_ADMIN_OWNER,
                redeemer: address(withdrawalQueueManager),
                ynEigen: yneigen,
                assetRegistry: assetRegistry
            });
            redemptionAssetsVault.initialize(_init);
        }

        // initialize WithdrawalQueueManager
        {
            WithdrawalQueueManager.Init memory _init = WithdrawalQueueManager.Init({
                name: "ynLSDe Withdrawal Manager",
                symbol: "ynLSDeWM",
                redeemableAsset: IRedeemableAsset(address(yneigen)),
                redemptionAssetsVault: redemptionAssetsVault,
                admin: actors.admin.PROXY_ADMIN_OWNER,
                withdrawalQueueAdmin: actors.ops.WITHDRAWAL_MANAGER,
                redemptionAssetWithdrawer: actors.ops.REDEMPTION_ASSET_WITHDRAWER,
                requestFinalizer:  actors.ops.REQUEST_FINALIZER,
                withdrawalFee: 0,
                feeReceiver: actors.admin.FEE_RECEIVER
            });
            withdrawalQueueManager.initialize(_init);
        }

        // upgrade and initialize:
        // (1) tokenStakingNode implementation
        // (2) ynLSDe
        // (3) EigenStrategyManager
        // (4) AssetRegistry
        // (5) TokenStakingNodesManager
        // (6) ynEigenDepositAdapter
        _upgradeContracts();

        // unpause transfers
        {
            vm.prank(actors.admin.UNPAUSE_ADMIN);
            yneigen.unpauseTransfers();
        }

        // grant burner role
        {
            vm.startPrank(actors.admin.STAKING_ADMIN);
            yneigen.grantRole(yneigen.BURNER_ROLE(), address(withdrawalQueueManager));
            vm.stopPrank();
        }

        // top up redemptionAssetsVault
        {
            address _topper = address(0x420420);
            uint256 _amount = 50; // 50 wei
            deal({ token: chainAddresses.lsd.WSTETH_ADDRESS, to: _topper, give: _amount });
            deal({ token: chainAddresses.lsd.WOETH_ADDRESS, to: _topper, give: _amount });
            deal({ token: chainAddresses.lsd.SFRXETH_ADDRESS, to: _topper, give: _amount });
            vm.startPrank(_topper);
            IERC20(chainAddresses.lsd.WSTETH_ADDRESS).approve(address(redemptionAssetsVault), _amount);
            redemptionAssetsVault.deposit(_amount, chainAddresses.lsd.WSTETH_ADDRESS);
            IERC20(chainAddresses.lsd.WOETH_ADDRESS).approve(address(redemptionAssetsVault), _amount);
            redemptionAssetsVault.deposit(_amount, chainAddresses.lsd.WOETH_ADDRESS);
            IERC20(chainAddresses.lsd.SFRXETH_ADDRESS).approve(address(redemptionAssetsVault), _amount);
            redemptionAssetsVault.deposit(_amount, chainAddresses.lsd.SFRXETH_ADDRESS);
            vm.stopPrank();
        }

        assertApproxEqRel(yneigen.totalAssets(), _totalAssetsBefore, 1e17, "setUp: E0"); // NOTE - not best practice to have it here, but for the time being...
    }

    //
    // queueWithdrawals
    //

    function testQueueWithdrawalSTETH(uint256 _amount) public {
        if (_setup) _setupTokenStakingNode(_amount);

        IStrategy _strategy = IStrategy(chainAddresses.lsdStrategies.STETH_STRATEGY_ADDRESS);
        uint256 _shares = _strategy.shares((address(tokenStakingNode)));

        uint256 _totalAssetsBefore = yneigen.totalAssets();

        vm.prank(actors.ops.WITHDRAWAL_MANAGER);
        tokenStakingNode.queueWithdrawals(_strategy, _shares);

        assertEq(yneigen.totalAssets(), _totalAssetsBefore, "testQueueWithdrawalSTETH: E0");
        assertEq(tokenStakingNode.queuedShares(_strategy), _shares, "testQueueWithdrawalSTETH: E1");
    }

    function testQueueWithdrawalSFRXETH(uint256 _amount) public {
        if (_setup) _setupTokenStakingNode(_amount);

        IStrategy _strategy = IStrategy(chainAddresses.lsdStrategies.SFRXETH_STRATEGY_ADDRESS);
        uint256 _shares = _strategy.shares((address(tokenStakingNode)));

        uint256 _totalAssetsBefore = yneigen.totalAssets();

        vm.prank(actors.ops.WITHDRAWAL_MANAGER);
        tokenStakingNode.queueWithdrawals(_strategy, _shares);

        assertEq(yneigen.totalAssets(), _totalAssetsBefore, "testQueueWithdrawalSFRXETH: E0");
        assertEq(tokenStakingNode.queuedShares(_strategy), _shares, "testQueueWithdrawalSFRXETH: E1");
    }

    function testQueueWithdrawalOETH(uint256 _amount) public {
        if (_setup) _setupTokenStakingNode(_amount);

        IStrategy _strategy = IStrategy(chainAddresses.lsdStrategies.OETH_STRATEGY_ADDRESS);
        uint256 _shares = _strategy.shares((address(tokenStakingNode)));

        uint256 _totalAssetsBefore = yneigen.totalAssets();

        vm.prank(actors.ops.WITHDRAWAL_MANAGER);
        tokenStakingNode.queueWithdrawals(_strategy, _shares);

        assertEq(yneigen.totalAssets(), _totalAssetsBefore, "testQueueWithdrawalOETH: E0");
        assertEq(tokenStakingNode.queuedShares(_strategy), _shares, "testQueueWithdrawalOETH: E1");
    }

    function testQueueWithdrawalsWrongCaller() public {
        _setupTokenStakingNode(AMOUNT);

        IStrategy _strategy = IStrategy(chainAddresses.lsdStrategies.OETH_STRATEGY_ADDRESS);
        uint256 _shares = _strategy.shares((address(tokenStakingNode)));

        vm.expectRevert(abi.encodeWithSelector(TokenStakingNode.NotTokenStakingNodesWithdrawer.selector));
        tokenStakingNode.queueWithdrawals(_strategy, _shares);
    }

    //
    // completeQueuedWithdrawals
    //

    function testCompleteQueuedWithdrawalsSTETH(uint256 _amount) public {
        if (_setup) _setupTokenStakingNode(_amount);

        _setup = false;
        testQueueWithdrawalSTETH(_amount);

        uint256 _nonce = delegationManager.cumulativeWithdrawalsQueued(address(tokenStakingNode)) - 1;
        uint32 _startBlock = uint32(block.number);
        IStrategy _strategy = IStrategy(chainAddresses.lsdStrategies.STETH_STRATEGY_ADDRESS);
        uint256 _shares = tokenStakingNode.queuedShares(_strategy);
        uint256[] memory _middlewareTimesIndexes = new uint256[](1);
        _middlewareTimesIndexes[0] = 0;

        IStrategy[] memory _strategies = new IStrategy[](1);
        _strategies[0] = _strategy;
        vm.roll(block.number + delegationManager.getWithdrawalDelay(_strategies));

        uint256 _totalAssetsBefore = yneigen.totalAssets();

        vm.prank(actors.ops.WITHDRAWAL_MANAGER);
        tokenStakingNode.completeQueuedWithdrawals(_nonce, _startBlock, _shares, _strategy, _middlewareTimesIndexes, true);

        assertApproxEqAbs(yneigen.totalAssets(), _totalAssetsBefore, 10, "testCompleteQueuedWithdrawalsSTETH: E0");
        assertEq(tokenStakingNode.queuedShares(_strategy), 0, "testCompleteQueuedWithdrawalsSTETH: E1");
        assertApproxEqAbs(tokenStakingNode.withdrawn(IERC20(chainAddresses.lsd.WSTETH_ADDRESS)), _amount, 100, "testCompleteQueuedWithdrawalsSTETH: E2");

    }

    function testCompleteQueuedWithdrawalsSFRXETH(uint256 _amount) public {
        if (_setup) _setupTokenStakingNode(_amount);

        _setup = false;
        testQueueWithdrawalSFRXETH(_amount);

        uint256 _nonce = delegationManager.cumulativeWithdrawalsQueued(address(tokenStakingNode)) - 1;
        uint32 _startBlock = uint32(block.number);
        IStrategy _strategy = IStrategy(chainAddresses.lsdStrategies.SFRXETH_STRATEGY_ADDRESS);
        uint256 _shares = tokenStakingNode.queuedShares(_strategy);
        uint256[] memory _middlewareTimesIndexes = new uint256[](1);
        _middlewareTimesIndexes[0] = 0;

        IStrategy[] memory _strategies = new IStrategy[](1);
        _strategies[0] = _strategy;
        vm.roll(block.number + delegationManager.getWithdrawalDelay(_strategies));

        uint256 _totalAssetsBefore = yneigen.totalAssets();

        vm.prank(actors.ops.WITHDRAWAL_MANAGER);
        tokenStakingNode.completeQueuedWithdrawals(_nonce, _startBlock, _shares, _strategy, _middlewareTimesIndexes, true);

        assertApproxEqAbs(yneigen.totalAssets(), _totalAssetsBefore, 10, "testCompleteQueuedWithdrawalsSFRXETH: E0");
        assertEq(tokenStakingNode.queuedShares(_strategy), 0, "testCompleteQueuedWithdrawalsSFRXETH: E1");
        assertApproxEqAbs(tokenStakingNode.withdrawn(IERC20(chainAddresses.lsd.SFRXETH_ADDRESS)), _amount, 100, "testCompleteQueuedWithdrawalsSFRXETH: E2");
    }

    function testCompleteQueuedWithdrawalsOETH(uint256 _amount) public {
        if (_setup) _setupTokenStakingNode(_amount);

        _setup = false;
        testQueueWithdrawalOETH(_amount);

        uint256 _nonce = delegationManager.cumulativeWithdrawalsQueued(address(tokenStakingNode)) - 1;
        uint32 _startBlock = uint32(block.number);
        IStrategy _strategy = IStrategy(chainAddresses.lsdStrategies.OETH_STRATEGY_ADDRESS);
        uint256 _shares = tokenStakingNode.queuedShares(_strategy);
        uint256[] memory _middlewareTimesIndexes = new uint256[](1);
        _middlewareTimesIndexes[0] = 0;

        IStrategy[] memory _strategies = new IStrategy[](1);
        _strategies[0] = _strategy;
        vm.roll(block.number + delegationManager.getWithdrawalDelay(_strategies));

        uint256 _totalAssetsBefore = yneigen.totalAssets();

        vm.prank(actors.ops.WITHDRAWAL_MANAGER);
        tokenStakingNode.completeQueuedWithdrawals(_nonce, _startBlock, _shares, _strategy, _middlewareTimesIndexes, true);

        assertApproxEqAbs(yneigen.totalAssets(), _totalAssetsBefore, 10, "testCompleteQueuedWithdrawalsOETH: E0");
        assertEq(tokenStakingNode.queuedShares(_strategy), 0, "testCompleteQueuedWithdrawalsOETH: E1");
        assertApproxEqAbs(tokenStakingNode.withdrawn(IERC20(chainAddresses.lsd.WOETH_ADDRESS)), _amount, 100, "testCompleteQueuedWithdrawalsOETH: E2");
    }

    function testCompleteAllWithdrawals(uint256 _amount) public {
        _setupTokenStakingNode(_amount);

        uint256 _totalAssetsBefore = yneigen.totalAssets();

        _setup = false;
        testCompleteQueuedWithdrawalsSTETH(_amount);
        testCompleteQueuedWithdrawalsSFRXETH(_amount);
        testCompleteQueuedWithdrawalsOETH(_amount);

        assertApproxEqAbs(yneigen.totalAssets(), _totalAssetsBefore, 10, "testCompleteAllWithdrawals: E0");
    }

    //
    // processPrincipalWithdrawals
    //

    function testProcessPrincipalWithdrawals(uint256 _amount) public {
        testCompleteAllWithdrawals(_amount);

        uint256 _availableToWithdraw = tokenStakingNode.withdrawn(IERC20(chainAddresses.lsd.WSTETH_ADDRESS));
        IYieldNestStrategyManager.WithdrawalAction[] memory _actions = new IYieldNestStrategyManager.WithdrawalAction[](3);
        _actions[0] = IYieldNestStrategyManager.WithdrawalAction({
            nodeId: tokenStakingNode.nodeId(),
            amountToReinvest: _availableToWithdraw / 2,
            amountToQueue: _availableToWithdraw / 2,
            asset: chainAddresses.lsd.WSTETH_ADDRESS
        });
        _availableToWithdraw = tokenStakingNode.withdrawn(IERC20(chainAddresses.lsd.WOETH_ADDRESS));
        _actions[1] = IYieldNestStrategyManager.WithdrawalAction({
            nodeId: tokenStakingNode.nodeId(),
            amountToReinvest: _availableToWithdraw / 2,
            amountToQueue: _availableToWithdraw / 2,
            asset: chainAddresses.lsd.WOETH_ADDRESS
        });
        _availableToWithdraw = tokenStakingNode.withdrawn(IERC20(chainAddresses.lsd.SFRXETH_ADDRESS));
        _actions[2] = IYieldNestStrategyManager.WithdrawalAction({
            nodeId: tokenStakingNode.nodeId(),
            amountToReinvest: _availableToWithdraw / 2,
            amountToQueue: _availableToWithdraw / 2,
            asset: chainAddresses.lsd.SFRXETH_ADDRESS
        });

        uint256 _totalAssetsBefore = yneigen.totalAssets();
        uint256 _ynEigenWSTETHBalanceBefore = yneigen.assets(chainAddresses.lsd.WSTETH_ADDRESS);
        uint256 _ynEigenWOETHBalanceBefore = yneigen.assets(chainAddresses.lsd.WOETH_ADDRESS);
        uint256 _ynEigenSFRXETHBalanceBefore = yneigen.assets(chainAddresses.lsd.SFRXETH_ADDRESS);

        vm.prank(actors.ops.WITHDRAWAL_MANAGER);
        eigenStrategyManager.processPrincipalWithdrawals(_actions);

        assertEq(yneigen.totalAssets(), _totalAssetsBefore, "testProcessPrincipalWithdrawals: E0");
        assertApproxEqAbs(redemptionAssetsVault.balances(chainAddresses.lsd.WSTETH_ADDRESS), _availableToWithdraw / 2, 50, "testProcessPrincipalWithdrawals: E1");
        assertApproxEqAbs(redemptionAssetsVault.balances(chainAddresses.lsd.WOETH_ADDRESS), _availableToWithdraw / 2, 50, "testProcessPrincipalWithdrawals: E2");
        assertApproxEqAbs(redemptionAssetsVault.balances(chainAddresses.lsd.SFRXETH_ADDRESS), _availableToWithdraw / 2, 50, "testProcessPrincipalWithdrawals: E3");
        assertApproxEqAbs(yneigen.assets(chainAddresses.lsd.WSTETH_ADDRESS), _ynEigenWSTETHBalanceBefore + _availableToWithdraw / 2, 2, "testProcessPrincipalWithdrawals: E4");
        assertApproxEqAbs(yneigen.assets(chainAddresses.lsd.WOETH_ADDRESS), _ynEigenWOETHBalanceBefore + _availableToWithdraw / 2, 2, "testProcessPrincipalWithdrawals: E5");
        assertEq(yneigen.assets(chainAddresses.lsd.SFRXETH_ADDRESS), _ynEigenSFRXETHBalanceBefore + _availableToWithdraw / 2, "testProcessPrincipalWithdrawals: E6");
    }

    function testProcessPrincipalWithdrawalsNoReinvest(uint256 _amount) public {
        testCompleteAllWithdrawals(_amount);

        uint256 _availableToWithdraw = tokenStakingNode.withdrawn(IERC20(chainAddresses.lsd.WSTETH_ADDRESS));
        IYieldNestStrategyManager.WithdrawalAction[] memory _actions = new IYieldNestStrategyManager.WithdrawalAction[](3);
        _actions[0] = IYieldNestStrategyManager.WithdrawalAction({
            nodeId: tokenStakingNode.nodeId(),
            amountToReinvest: 0,
            amountToQueue: _availableToWithdraw,
            asset: chainAddresses.lsd.WSTETH_ADDRESS
        });
        _availableToWithdraw = tokenStakingNode.withdrawn(IERC20(chainAddresses.lsd.WOETH_ADDRESS));
        _actions[1] = IYieldNestStrategyManager.WithdrawalAction({
            nodeId: tokenStakingNode.nodeId(),
            amountToReinvest: 0,
            amountToQueue: _availableToWithdraw,
            asset: chainAddresses.lsd.WOETH_ADDRESS
        });
        _availableToWithdraw = tokenStakingNode.withdrawn(IERC20(chainAddresses.lsd.SFRXETH_ADDRESS));
        _actions[2] = IYieldNestStrategyManager.WithdrawalAction({
            nodeId: tokenStakingNode.nodeId(),
            amountToReinvest: 0,
            amountToQueue: _availableToWithdraw,
            asset: chainAddresses.lsd.SFRXETH_ADDRESS
        });

        uint256 _totalAssetsBefore = yneigen.totalAssets();
        uint256 _ynEigenWSTETHBalanceBefore = yneigen.assets(chainAddresses.lsd.WSTETH_ADDRESS);
        uint256 _ynEigenWOETHBalanceBefore = yneigen.assets(chainAddresses.lsd.WOETH_ADDRESS);
        uint256 _ynEigenSFRXETHBalanceBefore = yneigen.assets(chainAddresses.lsd.SFRXETH_ADDRESS);

        vm.prank(actors.ops.WITHDRAWAL_MANAGER);
        eigenStrategyManager.processPrincipalWithdrawals(_actions);

        assertEq(yneigen.totalAssets(), _totalAssetsBefore, "testProcessPrincipalWithdrawalsNoReinvest: E0");
        assertApproxEqAbs(redemptionAssetsVault.balances(chainAddresses.lsd.WSTETH_ADDRESS), _availableToWithdraw, 50, "testProcessPrincipalWithdrawalsNoReinvest: E1");
        assertApproxEqAbs(redemptionAssetsVault.balances(chainAddresses.lsd.WOETH_ADDRESS), _availableToWithdraw, 50, "testProcessPrincipalWithdrawalsNoReinvest: E2");
        assertApproxEqAbs(redemptionAssetsVault.balances(chainAddresses.lsd.SFRXETH_ADDRESS), _availableToWithdraw, 50, "testProcessPrincipalWithdrawalsNoReinvest: E3");
        assertEq(yneigen.assets(chainAddresses.lsd.WSTETH_ADDRESS), _ynEigenWSTETHBalanceBefore, "testProcessPrincipalWithdrawalsNoReinvest: E4");
        assertEq(yneigen.assets(chainAddresses.lsd.WOETH_ADDRESS), _ynEigenWOETHBalanceBefore, "testProcessPrincipalWithdrawalsNoReinvest: E5");
        assertEq(yneigen.assets(chainAddresses.lsd.SFRXETH_ADDRESS), _ynEigenSFRXETHBalanceBefore, "testProcessPrincipalWithdrawalsNoReinvest: E6");
    }

    //
    // requestWithdrawal
    //

    function testRequestWithdrawal(uint256 _amount) public {
        testProcessPrincipalWithdrawalsNoReinvest(_amount);

        uint256 _totalAssetsBefore = yneigen.totalAssets();

        uint256 _userYnLSDeBalance = yneigen.balanceOf(user);
        vm.startPrank(user);
        yneigen.approve(address(withdrawalQueueManager), _userYnLSDeBalance);
        uint256 _tokenId = withdrawalQueueManager.requestWithdrawal(_userYnLSDeBalance);
        vm.stopPrank();

        assertApproxEqAbs(
            withdrawalQueueManager.pendingRequestedRedemptionAmount(),
            assetRegistry.convertToUnitOfAccount(IERC20(chainAddresses.lsd.WSTETH_ADDRESS), _amount) + assetRegistry.convertToUnitOfAccount(IERC20(chainAddresses.lsd.WOETH_ADDRESS), _amount) + assetRegistry.convertToUnitOfAccount(IERC20(chainAddresses.lsd.SFRXETH_ADDRESS), _amount),
            1000,
            "testRequestWithdrawal: E0"
        );
        assertEq(_tokenId, 0, "testRequestWithdrawal: E1");
        assertEq(_totalAssetsBefore, yneigen.totalAssets(), "testRequestWithdrawal: E2");
    }

    //
    // claimWithdrawal
    //

    function testClaimWithdrawal(uint256 _amount) public {
        testRequestWithdrawal(_amount);

        vm.prank(actors.ops.REQUEST_FINALIZER);
        withdrawalQueueManager.finalizeRequestsUpToIndex(1);

        uint256 _userWSTETHBalanceBefore = IERC20(chainAddresses.lsd.WSTETH_ADDRESS).balanceOf(user);
        uint256 _userWOETHBalanceBefore = IERC20(chainAddresses.lsd.WOETH_ADDRESS).balanceOf(user);
        uint256 _userSFRXETHBalanceBefore = IERC20(chainAddresses.lsd.SFRXETH_ADDRESS).balanceOf(user);
        uint256 _totalAssetsBefore = yneigen.totalAssets();
        uint256 _redemptionRateBefore = redemptionAssetsVault.redemptionRate();

        vm.prank(user);
        withdrawalQueueManager.claimWithdrawal(0, user);

        assertApproxEqRel(IERC20(chainAddresses.lsd.WSTETH_ADDRESS).balanceOf(user), _userWSTETHBalanceBefore + _amount, 1, "testClaimWithdrawal: E0");
        assertApproxEqRel(IERC20(chainAddresses.lsd.WOETH_ADDRESS).balanceOf(user), _userWOETHBalanceBefore + _amount, 1, "testClaimWithdrawal: E1");
        assertApproxEqRel(IERC20(chainAddresses.lsd.SFRXETH_ADDRESS).balanceOf(user), _userSFRXETHBalanceBefore + _amount, 1, "testClaimWithdrawal: E2");
        assertLt(yneigen.totalAssets(), _totalAssetsBefore, "testClaimWithdrawal: E3");
        assertApproxEqRel(redemptionAssetsVault.redemptionRate(), _redemptionRateBefore, 1, "testClaimWithdrawal: E4");
    }

    //
    // internal helpers
    //

    function _setupTokenStakingNode(uint256 _amount) private {
        vm.assume(_amount > 10_000 && _amount < 100 ether);

        vm.prank(actors.ops.STAKING_NODE_CREATOR);
        tokenStakingNode = tokenStakingNodesManager.createTokenStakingNode();

        uint256 _len = 3;
        IERC20[] memory _assetsToDeposit = new IERC20[](_len);
        _assetsToDeposit[0] = IERC20(chainAddresses.lsd.WSTETH_ADDRESS);
        _assetsToDeposit[1] = IERC20(chainAddresses.lsd.WOETH_ADDRESS);
        _assetsToDeposit[2] = IERC20(chainAddresses.lsd.SFRXETH_ADDRESS);

        uint256[] memory _amounts = new uint256[](_len);
        _amounts[0] = _amount;
        _amounts[1] = _amount;
        _amounts[2] = _amount;

        vm.startPrank(user);
        for (uint256 i = 0; i < _len; i++) {
            _assetsToDeposit[i].approve(address(yneigen), _amounts[i]);
            yneigen.deposit(_assetsToDeposit[i], _amounts[i], user);
        }
        vm.stopPrank();

        vm.startPrank(actors.ops.STRATEGY_CONTROLLER);
        eigenStrategyManager.stakeAssetsToNode(tokenStakingNode.nodeId(), _assetsToDeposit, _amounts);
        vm.stopPrank();
    }

    function _upgradeContracts() internal {

        address[] memory _proxyAddresses = new address[](3);
        _proxyAddresses[0] = address(yneigen);
        _proxyAddresses[1] = address(assetRegistry);
        _proxyAddresses[2] = address(tokenStakingNodesManager);
        address[] memory _newImplementations = new address[](3);
        _newImplementations[0] = address(new ynEigen());
        _newImplementations[1] = address(new AssetRegistry());
        _newImplementations[2] = address(new TokenStakingNodesManager());

        address[] memory targets = new address[](6);
        uint256[] memory values = new uint256[](6);
        bytes[] memory payloads = new bytes[](6);
        bytes32 predecessor = bytes32(0);
        bytes32 salt = bytes32(0);
        uint256 delay = timelockController.getMinDelay();

        for (uint256 i = 0; i < _proxyAddresses.length; i++) {
            bytes memory _data = abi.encodeWithSignature(
                "upgradeAndCall(address,address,bytes)",
                _proxyAddresses[i], // proxy
                _newImplementations[i], // implementation
                ""
            );
            targets[i] = getTransparentUpgradeableProxyAdminAddress(_proxyAddresses[i]);
            values[i] = 0;
            payloads[i] = _data;
        }

        targets[3] = address(tokenStakingNodesManager);
        values[3] = 0;
        payloads[3] = abi.encodeWithSignature(
            "upgradeTokenStakingNode(address)",
            new TokenStakingNode()
        );

        targets[4] = getTransparentUpgradeableProxyAdminAddress(address(eigenStrategyManager));
        values[4] = 0;
        payloads[4] = abi.encodeWithSignature(
            "upgradeAndCall(address,address,bytes)",
            address(eigenStrategyManager), // proxy
            address(new EigenStrategyManager()), // implementation
            abi.encodeWithSignature(
                "initializeV2(address,address,address)",
                address(redemptionAssetsVault),
                address(wrapper),
                actors.ops.WITHDRAWAL_MANAGER
            )
        );

        targets[5] = getTransparentUpgradeableProxyAdminAddress(address(ynEigenDepositAdapter_));
        values[5] = 0;
        payloads[5] = abi.encodeWithSignature(
            "upgradeAndCall(address,address,bytes)",
            ynEigenDepositAdapter_, // proxy
            address(new ynEigenDepositAdapter()), // implementation
            abi.encodeWithSignature("initializeV2(address)", address(wrapper))
        );

        vm.prank(actors.wallets.YNSecurityCouncil);
        timelockController.scheduleBatch(targets, values, payloads, predecessor, salt, delay);

        skip(delay);

        vm.prank(actors.wallets.YNSecurityCouncil);
        timelockController.executeBatch(targets, values, payloads, predecessor, salt);
    }
}