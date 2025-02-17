// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IUniswapV2Router02 } from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import { IPresale } from "./interfaces/IPresale.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title Presale contract
 * @notice Create and manage a presale of an ERC20 token
 */
contract Presale is IPresale, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address payable;

    /// Для масштаба при пропорциональном вычислении.
    uint256 constant SCALE = 10**18;

    /** 
     * @notice Параметры пресейла
     * @param tokenDeposit Всего токенов, вносимых в контракт (и на продажу, и на ликвидность).
     * @param hardCap Максимальное количество BNB (wei), которое хотим собрать.
     * @param softCap Минимальное количество BNB для успеха.
     * @param max Максимальный взнос от одного адреса.
     * @param min Минимальный взнос от одного адреса.
     * @param start Timestamp начала пресейла.
     * @param end Timestamp конца пресейла.
     * @param liquidityBps Процент (в basis points) от собранных средств, который пойдёт в ликвидность (например, 50% = 5000).
    */ 
    struct PresaleOptions {
        uint256 tokenDeposit;
        uint256 hardCap;
        uint256 softCap;
        uint256 max;
        uint256 min;
        uint112 start;
        uint112 end;
        uint32 liquidityBps; 
    }

    /** 
     * @notice Структура хранения состояния пресейла
     * @param token Адрес токена (ERC20).
     * @param uniswapV2Router02 Адрес роутера (PancakeSwap / Uniswap V2).
     * @param tokenBalance Текущее количество токенов на контракте.
     * @param tokensClaimable Сколько токенов предназначено для участников пресейла.
     * @param tokensLiquidity Сколько токенов пойдёт в пул ликвидности.
     * @param weiRaised Сколько всего BNB собрано.
     * @param weth Адрес WETH / WBNB (обёрнутый BNB).
     * @param state Текущее состояние (1: Инициализирован, 2: Активен, 3: Отменён, 4: Завершён).
     * @param options Параметры пресейла PresaleOptions.
    */
    struct Pool {
        IERC20 token;
        IUniswapV2Router02 uniswapV2Router02;
        uint256 tokenBalance;
        uint256 tokensClaimable;
        uint256 tokensLiquidity;
        uint256 weiRaised;
        address weth;
        uint8 state;
        PresaleOptions options;
    }

    /// Учет вкладов (адрес -> внесённые BNB)
    mapping(address => uint256) public contributions;
    
    /// Храним все данные в одной структуре
    Pool public pool;

    /// 2. Механика whitelist (для снижения рисков фронтраннинга)
    bool public isWhitelistEnabled = false;
    mapping(address => bool) public whitelist;

    /// Модификатор, разрешающий рефанд при состоянии Canceled или при недостигнутом softCap после окончания
    modifier onlyRefundable() {
        bool canRefund = (
            pool.state == 3 ||
            (block.timestamp > pool.options.end && pool.weiRaised < pool.options.softCap)
        );
        if (!canRefund) revert NotRefundable();
        _;
    }

    /** 
     * @param _weth Адрес WBNB в сети BSC (или WETH, если это другая EVM-сеть).
     * @param _token Адрес токена, который продаём.
     * @param _uniswapV2Router02 Адрес роутера (PancakeSwap/Uniswap).
     * @param _options Параметры пресейла (PresaleOptions).
    */
    constructor(
        address _weth,
        address _token,
        address _uniswapV2Router02,
        PresaleOptions memory _options
    )
        Ownable(msg.sender)
    {
        _prevalidatePool(_options);

        pool.uniswapV2Router02 = IUniswapV2Router02(_uniswapV2Router02);
        pool.token = IERC20(_token);
        pool.state = 1; // Initialized
        pool.weth = _weth;
        pool.options = _options;
    }

    /// Функция для приёма BNB напрямую. Вызывает _purchase().
    receive() external payable {
        _purchase(msg.sender, msg.value);
    }

    // ========================================================
    //               ВНЕСЕНИЕ ТОКЕНОВ / СТАРТ ПРОДАЖИ
    // ========================================================

    /** 
     * @notice Владелец вносит нужное количество токенов для пресейла и ликвидности.
     *         До вызова этой функции пресейл недоступен участникам.
     * @return Количество внесённых токенов.
    */
    function deposit() external onlyOwner returns (uint256) {
        // Проверяем, что пресейл ещё в начальном состоянии
        if (pool.state != 1) revert InvalidState(pool.state);

        // Переводим в состояние "Active"
        pool.state = 2;
        
        // Рассчитываем, сколько токенов пойдёт на ликвидность и на пресейл
        pool.tokenBalance += pool.options.tokenDeposit;
        pool.tokensLiquidity = _tokensForLiquidity();
        pool.tokensClaimable = _tokensForPresale();

        // Безопасно переводим токены с адреса владельца на контракт
        pool.token.safeTransferFrom(msg.sender, address(this), pool.options.tokenDeposit);

        emit Deposit(msg.sender, pool.options.tokenDeposit, block.timestamp);
        return pool.options.tokenDeposit;
    }

    // ========================================================
    //               ПОКУПКА, РЕФАНД, КЛЕЙМ
    // ========================================================

    /** 
     * @dev Главная внутренняя функция покупки.
     * @param beneficiary Адрес покупателя.
     * @param amount Сколько BNB он отправил.
    */
    function _purchase(address beneficiary, uint256 amount) private nonReentrant {
        _prevalidatePurchase(beneficiary, amount);

        pool.weiRaised += amount;
        contributions[beneficiary] += amount;
        
        emit Purchase(beneficiary, amount);
    }

    /**
     * @notice Позволяет покупателям забрать свои токены после успешного завершения пресейла.
     */
    function claim() external nonReentrant returns (uint256) {
        // Проверяем состояние: только после finalize
        if (pool.state != 4) revert InvalidState(pool.state);
        // Проверяем, что есть вклад
        if (contributions[msg.sender] == 0) revert NotClaimable();

        uint256 amount = userTokens(msg.sender);
        contributions[msg.sender] = 0; // обнуляем вклад для исключения повторных вызовов
        pool.tokenBalance -= amount;
        
        pool.token.safeTransfer(msg.sender, amount);

        emit TokenClaim(msg.sender, amount, block.timestamp);
        return amount;
    }

    /**
     * @notice Возврат средств участникам, если пресейл отменён или не собрал softCap.
     */
    function refund() external onlyRefundable nonReentrant returns (uint256) {
        if (contributions[msg.sender] == 0) revert NotRefundable();

        uint256 amount = contributions[msg.sender];
        contributions[msg.sender] = 0;

        // Возвращаем BNB
        payable(msg.sender).sendValue(amount);

        emit Refund(msg.sender, amount, block.timestamp);
        return amount;
    }

    // ========================================================
    //               УПРАВЛЕНИЕ ПРЕСЕЙЛОМ
    // ========================================================

    /**
     * @notice Завершает пресейл, если он успешен (достигнут softCap).
     *         Добавляет ликвидность, переводит остатки владельцу, открывает клейм для участников.
     */
    function finalize() external onlyOwner nonReentrant returns (bool) {
        if (pool.state != 2) revert InvalidState(pool.state);

        // Если ещё не достигли softCap, но время не вышло, лучше подождать окончания
        if (pool.weiRaised < pool.options.softCap && block.timestamp < pool.options.end) {
            revert SoftCapNotReached();
        }

        // Переводим состояние в "Finalized"
        pool.state = 4;

        // Добавляем ликвидность: часть BNB + часть токенов
        uint256 liquidityWei = _weiForLiquidity();
        _liquify(liquidityWei, pool.tokensLiquidity);
        pool.tokenBalance -= pool.tokensLiquidity;

        // Остаток собранных средств отправляем владельцу
        uint256 withdrawable = pool.weiRaised - liquidityWei;
        if (withdrawable > 0) {
            payable(msg.sender).sendValue(withdrawable);
        }

        emit Finalized(msg.sender, pool.weiRaised, block.timestamp);
        return true;
    }

    /**
     * @notice Владелец может отменить пресейл (если он ещё не завершён).
     *         Тогда участники смогут вызвать refund() и вернуть BNB.
     */
    function cancel() external onlyOwner returns(bool) {
        if (pool.state > 3) revert InvalidState(pool.state);

        pool.state = 3; // Canceled

        // Возвращаем владельцу невостребованные токены
        if (pool.tokenBalance > 0) {
            uint256 amount = pool.tokenBalance;
            pool.tokenBalance = 0;
            pool.token.safeTransfer(msg.sender, amount);
        }

        emit Cancel(msg.sender, block.timestamp);
        return true;
    }

    // ========================================================
    //               WHITELIST (доп. проверка)
    // ========================================================

    /**
     * @notice Включает или отключает механизм whitelist.
     */
    function setWhitelistEnabled(bool _enabled) external onlyOwner {
        isWhitelistEnabled = _enabled;
    }

    /**
     * @notice Добавляет адреса в whitelist.
     */
    function addToWhitelist(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            whitelist[accounts[i]] = true;
        }
    }

    /**
     * @notice Удаляет адреса из whitelist.
     */
    function removeFromWhitelist(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            whitelist[accounts[i]] = false;
        }
    }

    // ========================================================
    //               ВНУТРЕННЯЯ ЛОГИКА И ПРОВЕРКИ
    // ========================================================

    /**
     * @dev Проверка валидности покупки.
     */
    function _prevalidatePurchase(address _beneficiary, uint256 _amount) internal view {
        if (pool.state != 2) revert InvalidState(pool.state);
        // Проверяем период
        if (block.timestamp < pool.options.start || block.timestamp > pool.options.end) {
            revert NotInPurchasePeriod();
        }
        // Проверяем hardCap
        if (pool.weiRaised + _amount > pool.options.hardCap) {
            revert HardCapExceed();
        }
        // Проверяем min
        if (_amount < pool.options.min) {
            revert PurchaseBelowMinimum();
        }
        // Проверяем max
        if (_amount + contributions[_beneficiary] > pool.options.max) {
            revert PurchaseLimitExceed();
        }
        // Если включен whitelist — проверяем
        if (isWhitelistEnabled && !whitelist[_beneficiary]) {
            revert("NotWhitelisted");
        }
    }

    /**
     * @dev Предварительная проверка параметров пресейла (можно доработать логику под нужды проекта).
     */
    function _prevalidatePool(PresaleOptions memory _options) internal pure {
        if (_options.softCap > _options.hardCap) revert InvalidCapValue();
        if (_options.min > _options.max) revert InvalidLimitValue();
        if (_options.start >= _options.end) revert InvalidTimestampValue();
    }


    /**
     * @dev Считаем, сколько токенов причитается конкретному участнику (пропорционально вкладу).
     */
    function userTokens(address contributor) public view returns (uint256) {
        // Пропорция: (вклад / общий сбор) * pool.tokensClaimable
        if (pool.weiRaised == 0) return 0;
        return ((contributions[contributor] * SCALE) / pool.weiRaised)
            * pool.tokensClaimable
            / SCALE;
    }

    /**
     * @dev Сколько токенов идёт на ликвидность
     */
    function _tokensForLiquidity() internal view returns (uint256) {
        return pool.options.tokenDeposit * pool.options.liquidityBps / 10000;
    }

    /**
     * @dev Сколько токенов идёт на пресейл (для участников)
     */
    function _tokensForPresale() internal view returns (uint256) {
        return pool.options.tokenDeposit - _tokensForLiquidity();
    }

    /**
     * @dev Сколько BNB пойдёт в пул ликвидности
     */
    function _weiForLiquidity() internal view returns (uint256) {
        return pool.weiRaised * pool.options.liquidityBps / 10000;
    }

    /**
     * @dev Добавление ликвидности через роутер (PancakeSwap / Uniswap V2).
     */
    function _liquify(uint256 _weiAmount, uint256 _tokenAmount) private {
        (uint amountToken, uint amountETH, ) =
            pool.uniswapV2Router02.addLiquidityETH{value : _weiAmount}(
                address(pool.token),
                _tokenAmount,
                _tokenAmount,   // минимум токенов (0% проскальзывания в примере)
                _weiAmount,     // минимум BNB
                owner(),
                block.timestamp + 600
            );
        
        if (amountToken != _tokenAmount && amountETH != _weiAmount) {
            revert LiquificationFailed();
        }
    }
}
