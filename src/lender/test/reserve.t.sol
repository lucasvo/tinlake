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

import "ds-test/test.sol";
import "tinlake-math/math.sol";

import "../../test/simple/token.sol";
import "./../reserve.sol";
import "./mock/assessor.sol";
import "../../borrower/test/mock/shelf.sol";
import "./mock/clerk.sol";

interface ReserveLike {
    function hardDeposit(uint currencyAmount) external;
    function hardPayout(uint currencyAmount) external;
}

contract LendingAdapterMock is ClerkMock {
    ReserveLike reserve;
    ERC20Like currency;

    constructor(address currency_, address reserve_) public    {
        reserve = ReserveLike(reserve_);
        currency = ERC20Like(currency_);
    }

    function draw(uint amount) public {
        currency.mint(address(this), amount);
        currency.approve(address(reserve), amount);
        reserve.hardDeposit(amount);
    }

    function wipe(uint amount) public {
        reserve.hardPayout(amount);
    }
}

contract ReserveTest is DSTest, Math {
    SimpleToken currency;
    Reserve reserve;
    ShelfMock shelf;
    AssessorMock assessor;

    LendingAdapterMock lending;

    address shelf_;
    address reserve_;
    address currency_;
    address assessor_;

    address self;

    uint256 constant ONE = 10**27;

    function setUp() public {
        currency = new SimpleToken("CUR", "Currency");
        shelf = new ShelfMock();
        assessor = new AssessorMock();

        reserve = new Reserve(address(currency));

        shelf_ = address(shelf);
        reserve_ = address(reserve);
        currency_ = address(currency);
        assessor_ = address(assessor);
        self = address(this);

        reserve.depend("shelf", shelf_);
        reserve.depend("assessor", assessor_);
    }

    function setUpLendingAdapter() public {
        lending = new LendingAdapterMock(currency_, reserve_);
        reserve.depend("lending", address(lending));
        reserve.rely(address(lending));
        lending.setReturn("activated", true);
    }

    function fundReserve(uint amount) public {
        currency.mint(self, amount);
        currency.approve(reserve_, amount);
        reserve.deposit(amount);
    }

    function testReserveBalanceBorrowFullReserve() public {
        uint borrowAmount = 100 ether;
        bool requestWant = true;
        // fund reserve with exact borrowAmount
        fundReserve(borrowAmount);
        // borrow action: shelf requests currency
        shelf.setReturn("balanceRequest", requestWant, borrowAmount);

        uint reserveBalance = currency.balanceOf(reserve_);
        uint shelfBalance = currency.balanceOf(shelf_);

          // set maxCurrencyAvailable allowance to exact borrowAmount
        reserve.file("currencyAvailable", borrowAmount);
        uint currencyAvailable = reserve.currencyAvailable();

        reserve.balance();

        // assert currency was transferred from reserve to shelf
        assertEq(currency.balanceOf(reserve_), safeSub(reserveBalance, borrowAmount));
        assertEq(currency.balanceOf(shelf_), safeAdd(shelfBalance, borrowAmount));
        assertEq(reserve.currencyAvailable(), safeSub(currencyAvailable, borrowAmount));
        assertEq(assessor.values_uint("borrowUpdate_currencyAmount"), borrowAmount);
    }

    function testReserveBalanceBorrowPartialReserve() public {
        uint borrowAmount = 100 ether;
        bool requestWant = true;
        // fund reserve with twice as much currency then borrowAmount
        fundReserve(safeMul(borrowAmount, 2));
        // borrow action: shelf requests currency
        shelf.setReturn("balanceRequest", requestWant, borrowAmount);

        uint reserveBalance = currency.balanceOf(reserve_);
        uint shelfBalance = currency.balanceOf(shelf_);

        // set maxCurrencyAvailable allowance to twice as much as borrowAmount
        reserve.file("currencyAvailable",  safeMul(borrowAmount, 2));
        uint currencyAvailable = reserve.currencyAvailable();

        reserve.balance();

        // assert currency was transferred from reserve to shelf
        assertEq(currency.balanceOf(reserve_), safeSub(reserveBalance, borrowAmount));
        assertEq(currency.balanceOf(shelf_), safeAdd(shelfBalance, borrowAmount));
        assertEq(reserve.currencyAvailable(), safeSub(currencyAvailable, borrowAmount));
        assertEq(assessor.values_uint("borrowUpdate_currencyAmount"), borrowAmount);
    }

    function testReserveBalanceRepay() public {
        uint repayAmount = 100 ether;
        bool requestWant = false;
        // fund shelf with enough currency
        currency.mint(shelf_, repayAmount);

        // borrow action: shelf requests currency
        shelf.setReturn("balanceRequest", requestWant, repayAmount);
        // shelf approve reserve to take currency
        shelf.doApprove(currency_, reserve_, repayAmount);
        uint reserveBalance = currency.balanceOf(reserve_);
        uint shelfBalance = currency.balanceOf(shelf_);
        uint currencyAvailable = reserve.currencyAvailable();
        reserve.balance();

        // assert currency was transferred from shelf to reserve
        assertEq(currency.balanceOf(reserve_), safeAdd(reserveBalance, repayAmount));
        assertEq(currency.balanceOf(shelf_), safeSub(shelfBalance, repayAmount));
        assertEq(reserve.currencyAvailable(), currencyAvailable);
        assertEq(assessor.values_uint("repaymentUpdate_currencyAmount"), repayAmount);
    }

    function testFailBalancePoolInactive() public {
        uint borrowAmount = 100 ether;
        bool requestWant = true;
        // fund reserve with enough currency
        fundReserve(200 ether);
        // borrow action: shelf requests currency
        shelf.setReturn("balanceRequest", requestWant, borrowAmount);
        // set max available currency
        reserve.file("currencyAvailable", 200 ether);
        // deactivate pool
        reserve.file("currencyAvailable", 0 ether);

        reserve.balance();
    }

    function testFailBalanceBorrowAmountTooHigh() public {
        uint borrowAmount = 100 ether;
        bool requestWant = true;
        // fund reserve with enough currency
        fundReserve(borrowAmount);
        // borrow action: shelf requests too much currency
        shelf.setReturn("balanceRequest", requestWant, safeMul(borrowAmount, 2));
        // set max available currency
        reserve.file("currencyAvailable", borrowAmount);
        reserve.balance();
    }

    function testFailBalanceReserveUnderfunded() public {
        uint borrowAmount = 100 ether;
        bool requestWant = true;
        // fund reserve with amount smaller than borrowAmount
        fundReserve(borrowAmount-1);
        // borrow action: shelf requests too much currency
        shelf.setReturn("balanceRequest", requestWant, safeMul(borrowAmount, 2));
        // set max available currency to borrowAmount
        reserve.file("currencyAvailable", borrowAmount);
        reserve.balance();
    }

    function testFailBalanceShelfNotEnoughFunds() public {
        uint repayAmount = 100 ether;
        bool requestWant = false;
        // fund shelf with currency amount smaller then repay amount
        currency.mint(shelf_, safeSub(repayAmount, 1));
        // borrow action: shelf requests currency
        shelf.setReturn("balanceRequest", requestWant, repayAmount);
        // shelf approve reserve to take currency
        shelf.doApprove(currency_, reserve_, repayAmount);
        reserve.balance();
    }

    function testDepositPayout() public {
        uint amount = 100 ether;
        currency.mint(self, amount);
        assertEq(reserve.totalBalance(), 0);
        currency.approve(reserve_, amount);
        reserve.deposit(amount);
        assertEq(reserve.totalBalance(), amount);
        assertEq(currency.balanceOf(reserve_), amount);

        amount = 60 ether;
        reserve.payout(amount);
        assertEq(reserve.totalBalance(), 40 ether);
        assertEq(currency.balanceOf(reserve_), 40 ether);
        assertEq(currency.balanceOf(self), 60 ether);
    }

    function testDrawFromZeroBalance() public {
        setUpLendingAdapter();
        uint remainingCredit = 100 ether;
        lending.setReturn("remainingCredit", remainingCredit);
        uint amount = 10 ether;
        reserve.payout(amount);
        assertEq(currency.balanceOf(self), amount);
    }

    function testAdditionalDraw() public {
        setUpLendingAdapter();
        uint amount = 100 ether;
        fundReserve(amount);
        uint remainingCredit = 100 ether;
        lending.setReturn("remainingCredit", remainingCredit);
        uint payoutAmount = 150 ether;
        reserve.payout(payoutAmount);
        assertEq(currency.balanceOf(self), payoutAmount);
    }

    function testAdditionalDrawMax() public {
        setUpLendingAdapter();
        uint amount = 100 ether;
        fundReserve(amount);

        uint remainingCredit = 100 ether;
        lending.setReturn("remainingCredit", remainingCredit);

        uint payoutAmount = 200 ether;
        reserve.payout(payoutAmount);
        assertEq(currency.balanceOf(self), payoutAmount);
    }
    function testFailDraw() public {
        setUpLendingAdapter();
        uint amount = 100 ether;
        fundReserve(amount);

        uint remainingCredit = 100 ether;
        lending.setReturn("remainingCredit", remainingCredit);

        uint payoutAmount = 201 ether;
        reserve.payout(payoutAmount);
        assertEq(currency.balanceOf(self), payoutAmount);
    }

    function testFailDrawFromZeroBalance() public {
        setUpLendingAdapter();

        uint remainingCredit = 100 ether;
        lending.setReturn("remainingCredit", remainingCredit);

        uint payoutAmount = 101 ether;
        reserve.payout(payoutAmount);
        assertEq(currency.balanceOf(self), payoutAmount);
    }

    function testWipe() public {
        setUpLendingAdapter();
        uint debt = 70 ether;
        lending.setReturn("debt", debt);

        uint amount = 100 ether;
        fundReserve(amount);
        assertEq(currency.balanceOf(reserve_), amount-debt);
    }

    function testWipeHighDebt() public {
        setUpLendingAdapter();
        uint debt = 700 ether;
        lending.setReturn("debt", debt);

        uint amount = 100 ether;
        fundReserve(amount);
        assertEq(currency.balanceOf(reserve_), 0);
        assertEq(currency.balanceOf(address(lending)), amount);
    }

    function testNoWipeZeroDebt() public {
        setUpLendingAdapter();
        uint debt = 0;
        lending.setReturn("debt", debt);
        uint amount = 100 ether;
        fundReserve(amount);
        assertEq(currency.balanceOf(reserve_), amount);
    }

    function testTotalReserveAvailable() public {
        uint amount = 100 ether;
        fundReserve(amount);

        assertEq(reserve.totalBalanceAvailable(), amount);

        setUpLendingAdapter();
        uint remainingCredit = 50 ether;
        lending.setReturn("remainingCredit", remainingCredit);
        assertEq(reserve.totalBalanceAvailable(), amount+remainingCredit);
    }

}
