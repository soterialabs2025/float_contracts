// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {V3Deployments4663} from "../contracts/coffer/V3Deployments4663.sol";
import {CofferStrategy} from "../contracts/coffer/CofferStrategy.sol";
import {CofferStrategyManager} from "../contracts/coffer/CofferStrategyManager.sol";
import {CofferVault} from "../contracts/coffer/CofferVault.sol";
import {CofferLiquidShares} from "../contracts/coffer/CofferLiquidShares.sol";
import {CofferKeeper} from "../contracts/coffer/CofferKeeper.sol";
import {CofferSwapRouter} from "../contracts/coffer/CofferSwapRouter.sol";
import {CofferOperatorRegistry} from "../contracts/coffer/CofferOperatorRegistry.sol";
import {TwapQuoteLib} from "../contracts/coffer/libraries/TwapQuoteLib.sol";
import {IUniswapV3PoolMinimal} from "../contracts/coffer/interfaces/IUniswapV3PoolMinimal.sol";

/// @dev Robinhood (4663) fork: USDG→WETH TWAP, a real COST/USDG mint + rotation, and a CASHCAT→FRONG rotation.
///      Skips when `ROBINHOOD_MAIN_RPC_URL` is unset so CI without the RPC stays green.
///
///      Deposit is 0.03 ETH (≈ 0.01 ETH per strategy) from live pool balances at block ~62_545_800:
///        WETH/USDG 0.01%  `0x52e6…`  ~4,985 WETH
///        COST/USDG  0.30%  `0x0a21…`  ~607 COST + 446k USDG
///        AAPL/USDG  0.30%  `0x783C…`  ~87k USDG  (COST rotation target)
///        NVDA/USDG  0.30%  `0xB944…`  ~9.8k USDG (thinnest stock; 0.01 ETH ≈ 0.3% of that side)
///        CASHCAT/WETH 1%   `0xA70f…`  ~612 WETH
///        FRONG/WETH  1%    `0x09a4…`  ~15.8 WETH (thinnest rotation target; 0.01 ETH ≈ 0.06%)
contract CofferForkTest is Test {
    address internal constant WETH = V3Deployments4663.WETH;
    address internal constant NPM = V3Deployments4663.NPM;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant COST = 0x4EA005168D7F09a7A0Ba9D1DEf21a479950E44C2;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant CASHCAT = 0x020bfC650A365f8BB26819deAAbF3E21291018b4;
    address internal constant FRONG = 0x6245e67affA44a23077f0Ea7f981a8DC743a0c47;
    address internal constant QUOTE_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address internal constant COST_POOL = 0x0a2121A50A09eD0796ae81F9c53fF9398355a398;
    address internal constant AAPL_POOL = 0x783C9bbB765047CFdD2b84b92b2Ca9F11D34b7Ed;
    address internal constant CASHCAT_POOL = 0xA70fc67C9F69da90B63a0e4C05D229954574E313;
    address internal constant FRONG_POOL = 0x09a431261E3d0F1dc2f7e0b14718DBBBCBe19Ae4;
    address internal constant FEE_MANAGER = 0xEc57538d5C129e1e985d81b7Ef05BBb63375D8BE;
    uint24 internal constant FEE_30BP = 3_000;
    uint24 internal constant FEE_100BP = 10_000;
    uint256 internal constant DEPOSIT = 0.03 ether;

    CofferOperatorRegistry internal registry;
    CofferVault internal vault;
    CofferStrategy internal sVol;
    CofferStrategy internal sCost;
    CofferStrategy internal sNvda;
    CofferSwapRouter internal router;
    CofferKeeper internal keeper;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_MAIN_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        registry = new CofferOperatorRegistry(address(this));
        keeper = new CofferKeeper(address(registry));
        router = new CofferSwapRouter();
        vault = new CofferVault(address(this));
        CofferLiquidShares shares = new CofferLiquidShares(address(this));
        shares.bootstrap(address(vault));
        vault.bootstrap(address(this), address(shares), address(registry), address(keeper));

        sVol = new CofferStrategy(address(this), WETH, address(0));
        sCost = new CofferStrategy(address(this), USDG, QUOTE_POOL);
        sNvda = new CofferStrategy(address(this), USDG, QUOTE_POOL);
        _boot(sVol, CASHCAT, FEE_100BP, CofferStrategyManager.ReserveMode.QUOTE_ONLY);
        _boot(sCost, COST, FEE_30BP, CofferStrategyManager.ReserveMode.PAIRED);
        _boot(sNvda, NVDA, FEE_30BP, CofferStrategyManager.ReserveMode.PAIRED);

        sVol.setAllowedToken(FRONG, true);
        sCost.setAllowedToken(AAPL, true);

        vault.addStrategy(address(sVol), 3334);
        vault.addStrategy(address(sCost), 3333);
        vault.addStrategy(address(sNvda), 3333);
        keeper.addStrategy(address(sVol));
        keeper.addStrategy(address(sCost));
        keeper.addStrategy(address(sNvda));

        vm.deal(address(this), 10 ether);
    }

    function _boot(CofferStrategy s, address asset, uint24 fee, CofferStrategyManager.ReserveMode mode) internal {
        s.bootstrap(
            address(this), address(vault), address(router), address(registry), address(keeper), FEE_MANAGER, asset, fee, mode
        );
        router.addAuthorizedStrategy(address(s));
    }

    function _nftCount(address s) internal view returns (uint256) {
        return IERC721(NPM).balanceOf(s);
    }

    function _seed() internal {
        vault.depositETH{value: DEPOSIT}();
    }

    function test_UsdgWethTwapMatchesSpotWithinBand() public view {
        IUniswapV3PoolMinimal quote = IUniswapV3PoolMinimal(QUOTE_POOL);
        assertEq(quote.fee(), 100, "quote conversion uses the 0.01% pool");
        uint256 spot = TwapQuoteLib.spotPrice1e18(quote, WETH);
        uint256 twap = TwapQuoteLib.twapPrice1e18(quote, WETH, 30 minutes);
        (uint256 band,) = TwapQuoteLib.bandPrices(quote, WETH, 30 minutes, 300);
        assertGt(spot, 0, "spot USDG per WETH");
        assertGt(twap, 0, "30-min TWAP readable");
        assertGt(band, 0, "spot is inside the 3% gate the stock legs use to convert");
        assertApproxEqRel(spot, twap, 0.03e18, "live 0.01% pool should sit inside 3% of its TWAP");
    }

    function test_CostMintAndRotateToAapl() public {
        _seed();

        assertEq(sCost.ASSET(), COST);
        assertEq(sCost.pool(), COST_POOL);
        assertGt(_nftCount(address(sCost)), 0, "COST/USDG position minted");
        assertGt(sCost.reservedAsset(), 0, "paired reserve holds COST");
        assertGt(sCost.reservedQuote(), 0, "and USDG");
        assertGt(sCost.poolValueTwap(), 0, "COST TWAP gate open after mint");

        uint256 navBefore = sCost.poolValue();
        sCost.changeAsset(AAPL, FEE_30BP);

        assertEq(sCost.ASSET(), AAPL);
        assertEq(sCost.pool(), AAPL_POOL);
        assertEq(IERC20(COST).balanceOf(address(sCost)), 0, "old stock sold to dust");
        assertGt(_nftCount(address(sCost)), 0, "AAPL/USDG position minted");
        assertGt(sCost.reservedQuote(), 0, "paired reserve rebuilt from USDG");
        assertApproxEqRel(sCost.poolValue(), navBefore, 0.05e18, "value carried across two 0.3% swaps");
        assertGt(sCost.poolValueTwap(), 0, "AAPL TWAP gate open");
    }

    function test_VolatileRotatesCashcatToFrong() public {
        _seed();

        assertEq(sVol.ASSET(), CASHCAT);
        assertEq(sVol.pool(), CASHCAT_POOL);
        assertGt(_nftCount(address(sVol)), 0, "CASHCAT/WETH position minted");
        assertEq(sVol.reservedAsset(), 0, "quote-only reserve holds no CASHCAT");
        assertGt(sVol.reservedQuote(), 0, "30% as WETH");
        assertGt(sVol.poolValueTwap(), 0, "CASHCAT TWAP gate open after mint");

        uint256 navBefore = sVol.poolValue();
        sVol.changeAsset(FRONG, FEE_100BP);

        assertEq(sVol.ASSET(), FRONG);
        assertEq(sVol.pool(), FRONG_POOL);
        assertEq(IERC20(CASHCAT).balanceOf(address(sVol)), 0, "old volatile sold to dust");
        assertGt(_nftCount(address(sVol)), 0, "FRONG/WETH position minted");
        assertEq(sVol.reservedAsset(), 0, "quote-only reserve still holds no asset");
        assertGt(sVol.reservedQuote(), 0);
        assertApproxEqRel(sVol.poolValue(), navBefore, 0.05e18, "value carried across two 1% swaps");
        assertGt(sVol.poolValueTwap(), 0, "FRONG TWAP gate open");
    }
}
