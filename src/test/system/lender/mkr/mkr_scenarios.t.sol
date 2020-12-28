// Copyright (C) 2020 Centrifuge

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.15 <0.6.0;
pragma experimental ABIEncoderV2;

import "../../test_suite.sol";
import "tinlake-math/interest.sol";
import {BaseTypes} from "../../../../lender/test/coordinator-base.t.sol";
import { MKRAssessor }from "../../../../lender/adapters/mkr/assessor.sol";


contract LenderSystemTest is TestSuite, Interest {

    MKRAssessor mkrAssessor;

    function setUp() public {
        // setup hevm
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

        bool mkrAdapter = true;
        deployContracts(mkrAdapter);
        createTestUsers();

        nftFeed_ = NFTFeedLike(address(nftFeed));

        root.relyContract(address(clerk), address(this));
        mkrAssessor = MKRAssessor(address(assessor));
        mkr.depend("currency" ,currency_);
        mkr.depend("drop", mkrLenderDeployer.seniorToken());
    }

    function _setupRunningPool() internal {
        uint seniorSupplyAmount = 1500 ether;
        uint juniorSupplyAmount = 200 ether;
        uint nftPrice = 200 ether;
        // interest rate default => 5% per day
        uint borrowAmount = 100 ether;
        uint maturityDate = 5 days;

        ModelInput memory submission = ModelInput({
            seniorSupply : 800 ether,
            juniorSupply : 200 ether,
            seniorRedeem : 0 ether,
            juniorRedeem : 0 ether
            });

        supplyAndBorrowFirstLoan(seniorSupplyAmount, juniorSupplyAmount, nftPrice, borrowAmount, maturityDate, submission);
    }

    function testMKRRaise() public {
        _setupRunningPool();
        uint preReserve = assessor.totalBalance();
        uint nav = nftFeed.calcUpdateNAV();
        uint preSeniorBalance = assessor.seniorBalance();

        uint amountDAI = 10 ether;

        clerk.raise(amountDAI);

        //raise reserves a spot for drop and locks the tin
        assertEq(assessor.seniorBalance(), safeAdd(preSeniorBalance, rmul(amountDAI, clerk.mat())));
        assertEq(assessor.totalBalance(), safeAdd(preReserve, amountDAI));

        assertEq(mkrAssessor.effectiveTotalBalance(), preReserve);
        assertEq(mkrAssessor.effectiveSeniorBalance(), preSeniorBalance);
        assertEq(clerk.remainingCredit(), amountDAI);
    }

    function testMKRDraw() public {
        _setupRunningPool();
        uint preReserve = assessor.totalBalance();
        uint nav = nftFeed.calcUpdateNAV();
        uint preSeniorBalance = assessor.seniorBalance();

        uint creditLineAmount = 10 ether;
        uint drawAmount = 5 ether;
        clerk.raise(creditLineAmount);

        //raise reserves a spot for drop and locks the tin
        assertEq(assessor.seniorBalance(), safeAdd(preSeniorBalance, rmul(creditLineAmount, clerk.mat())));
        assertEq(assessor.totalBalance(), safeAdd(preReserve, creditLineAmount));

        uint preSeniorDebt = assessor.seniorDebt();
        clerk.draw(drawAmount);

        // seniorBalance and reserve should have changed
        assertEq(mkrAssessor.effectiveTotalBalance(), safeAdd(preReserve, drawAmount));

        assertEq(safeAdd(mkrAssessor.effectiveSeniorBalance(),assessor.seniorDebt()),
            safeAdd(safeAdd(preSeniorBalance, rmul(drawAmount, clerk.mat())), preSeniorDebt));

        //raise reserves a spot for drop and locks the tin. no impact from the draw function
        assertEq(safeAdd(assessor.seniorBalance(),assessor.seniorDebt()),
            safeAdd(safeAdd(preSeniorBalance, rmul(creditLineAmount, clerk.mat())), preSeniorDebt));

        assertEq(assessor.totalBalance(), safeAdd(preReserve, creditLineAmount));
    }
}