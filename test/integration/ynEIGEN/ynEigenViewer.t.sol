// SPDX-License-Identifier: BSD 3-Clause License
pragma solidity 0.8.24;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ITokenStakingNodesManager,ITokenStakingNode} from "../../../src/interfaces/ITokenStakingNodesManager.sol";

import {ynEigenViewer} from "../../../src/ynEIGEN/ynEigenViewer.sol";
import {console} from "forge-std/console.sol";
import "./ynEigenIntegrationBaseTest.sol";

interface IAssetRegistryView {
    function assets() external view returns (IERC20Metadata[] memory);
}

contract ynEigenViewerTest is ynEigenIntegrationBaseTest {

    ynEigenViewer private _ynEigenViewer;

    function setUp() public override {
        super.setUp();
        _ynEigenViewer = new ynEigenViewer(
            address(assetRegistry),
            address(ynEigenToken),
            address(tokenStakingNodesManager),
            address(rateProvider)
        );
    }

    function testGetAllStakingNodes() public {
        ITokenStakingNode[] memory _nodes = _ynEigenViewer.getAllStakingNodes();
        assertEq(_nodes.length, 0, "There should be no nodes");
    }

    function testGetYnEigenAssets() public {
        IERC20[] memory _assets = assetRegistry.getAssets();
        assertTrue(_assets.length > 0, "testGetYnEigenAssets: E0");

        ynEigenViewer.AssetInfo[] memory _assetsInfo = _ynEigenViewer.getYnEigenAssets();
        for (uint256 i = 0; i < _assets.length; ++i) {
            assertEq(_assetsInfo[i].asset, address(_assets[i]), "testGetYnEigenAssets: E1");
            assertEq(_assetsInfo[i].name, IERC20Metadata(address(_assets[i])).name(), "testGetYnEigenAssets: E2");
            assertEq(_assetsInfo[i].symbol, IERC20Metadata(address(_assets[i])).symbol(), "testGetYnEigenAssets: E3");
            assertEq(_assetsInfo[i].ratioOfTotalAssets, 0, "testGetYnEigenAssets: E4");
            assertEq(_assetsInfo[i].totalBalance, 0, "testGetYnEigenAssets: E5");
        }
    }

    function testGetYnEigenAssetsAfterDeposits() public {
        // Define deposit amounts
        uint256 sfrxEthAmount = 1 ether;
        uint256 wstEthAmount = 0.5 ether;
        uint256 rEthAmount = 0.75 ether;

        // Create a user for deposits
        address user = makeAddr("user");

        // Make deposits to the user
        deal(address(chainAddresses.lsd.SFRXETH_ADDRESS), user, sfrxEthAmount);
        deal(address(chainAddresses.lsd.WSTETH_ADDRESS), user, wstEthAmount);
        deal(address(chainAddresses.lsd.RETH_ADDRESS), user, rEthAmount);

        // Switch to user context
        vm.startPrank(user);

        // Approve and deposit tokens
        IERC20(chainAddresses.lsd.SFRXETH_ADDRESS).approve(address(ynEigenToken), sfrxEthAmount);
        IERC20(chainAddresses.lsd.WSTETH_ADDRESS).approve(address(ynEigenToken), wstEthAmount);
        IERC20(chainAddresses.lsd.RETH_ADDRESS).approve(address(ynEigenToken), rEthAmount);

        ynEigenToken.deposit(IERC20(chainAddresses.lsd.SFRXETH_ADDRESS), sfrxEthAmount, user);
        ynEigenToken.deposit(IERC20(chainAddresses.lsd.WSTETH_ADDRESS), wstEthAmount, user);
        ynEigenToken.deposit(IERC20(chainAddresses.lsd.RETH_ADDRESS), rEthAmount, user);
        
        // End user context
        vm.stopPrank();


        // Get asset info after deposits
        ynEigenViewer.AssetInfo[] memory assetsInfo = _ynEigenViewer.getYnEigenAssets();

        // Calculate total assets
        uint256 totalAssets = ynEigenToken.totalAssets();
        
        // Calculate the value of each deposit in ETH and its expected ratio
        uint256 sfrxEthValueInEth = assetRegistry.convertToUnitOfAccount(IERC20(chainAddresses.lsd.SFRXETH_ADDRESS), sfrxEthAmount);
        uint256 wstEthValueInEth = assetRegistry.convertToUnitOfAccount(IERC20(chainAddresses.lsd.WSTETH_ADDRESS), wstEthAmount);
        uint256 rEthValueInEth = assetRegistry.convertToUnitOfAccount(IERC20(chainAddresses.lsd.RETH_ADDRESS), rEthAmount);
        
        uint256 totalValueInEth = sfrxEthValueInEth + wstEthValueInEth + rEthValueInEth;
        
        uint256 expectedSfrxEthRatio = (sfrxEthValueInEth * 1e6) / totalValueInEth;
        uint256 expectedWstEthRatio = (wstEthValueInEth * 1e6) / totalValueInEth;
        uint256 expectedREthRatio = (rEthValueInEth * 1e6) / totalValueInEth;

        // Verify asset info
        for (uint256 i = 0; i < assetsInfo.length; i++) {
            if (assetsInfo[i].asset == address(chainAddresses.lsd.SFRXETH_ADDRESS)) {
                assertEq(assetsInfo[i].totalBalance, sfrxEthValueInEth, "Incorrect sfrxETH balance");
                assertApproxEqRel(assetsInfo[i].ratioOfTotalAssets, expectedSfrxEthRatio, 1e16, "Incorrect sfrxETH ratio");
            } else if (assetsInfo[i].asset == address(chainAddresses.lsd.WSTETH_ADDRESS)) {
                assertEq(assetsInfo[i].totalBalance, wstEthValueInEth, "Incorrect wstETH balance");
                assertApproxEqRel(assetsInfo[i].ratioOfTotalAssets, expectedWstEthRatio, 1e16, "Incorrect wstETH ratio");
            } else if (assetsInfo[i].asset == address(chainAddresses.lsd.RETH_ADDRESS)) {
                assertEq(assetsInfo[i].totalBalance, rEthValueInEth, "Incorrect rETH balance");
                assertApproxEqRel(assetsInfo[i].ratioOfTotalAssets, expectedREthRatio, 1e16, "Incorrect rETH ratio");
            } else {
                assertEq(assetsInfo[i].totalBalance, 0, "Non-zero balance for undeposited asset");
                assertEq(assetsInfo[i].ratioOfTotalAssets, 0, "Non-zero ratio for undeposited asset");
            }
        }
    }

    function testPreviewDepositStETH() public {
        // Set up test amount
        uint256 testAmount = 1 ether;

        // Log STETH_ADDRESS
        console.log("STETH_ADDRESS:", address(chainAddresses.lsd.STETH_ADDRESS));

        // Call previewDeposit
        uint256 expectedShares = _ynEigenViewer.previewDeposit(IERC20(chainAddresses.lsd.STETH_ADDRESS), testAmount);

        // Verify the result
        assertTrue(expectedShares > 0, "Expected shares should be greater than 0");
    }

    function testGetRate() public {
        // Get rate
        uint256 rate = _ynEigenViewer.getRate();

        // Verify that the rate is not zero
        assertEq(rate, 1e18, "Rate is 1 with no deposits");
    }
}