# Basket Hook — hold the token, get paid in stocks (Robinhood Chain)

**Status:** draft · **Target:** Programmable Hookathon, submissions close 10 Sep 2026
**Chain:** Robinhood Chain (chainId 4663) · fallback Ethereum mainnet
**Prior art:** [$STACK](https://stackv4.tech) — Uniswap v4, Ethereum mainnet, live

---

## 0. Position on prior art

This is an adaptation of $STACK, stated openly. The judges will find it, and being
upfront is stronger than pretending. What is *not* copied: the contracts. Written from
scratch, own implementation.

The adaptation is not a chain swap. $STACK is the right idea on the wrong chain, and
§3 shows why with its own on-chain numbers.

---

## 1. What $STACK does (feature map)

| | |
|---|---|
| Chain / venue | Ethereum mainnet · Uniswap v4 hook |
| Buy fee | 2% |
| Sell fee | 3% |
| Team / presale | 0% — none |
| Launch | 100% of supply seeded into the pool |
| Anti-snipe | max buy 1.5% of supply per tx, first 30 minutes |
| Contract | ownership renounced · no mint · no setter |
| Basket | 5 Ondo tokenized assets, 20% each, constructor args, no setter |
| Reward split | 100% to holders |

**The loop**

```
1. Trade         every buy and sell pays a fee
2. Bank          the hook sends the fee to the token, in ETH
3. Assign        split across holders by balance, instantly
4. Claim         user calls claim() whenever they like
5. Buy basket    their ETH splits five ways and buys all five in the same tx
```

**Accrual rule.** Balance-weighted *at the moment each fee lands*. Hold more when a trade
happens, get more of it. No clock, no staking, no opt-in. A share is **frozen when it
accrues** — selling does not erase what you already earned.

This is the classic accumulator / magnified-dividend-per-share pattern, not a time
integral. Simpler than tenure weighting, and correct for this purpose.

**Positioning.** Against reflection tokens (which pay in the same token and inflate
supply), against staking dApps (lockups, a contract to trust), against a plain ETF
(no memecoin upside), against "trust me" treasuries (no team wallet, no keeper).

---

## 2. Verified on-chain before committing

The single question that could have killed this: **can Robinhood stock tokens be freely
transferred?** Two third-party sources claimed whitelist-gated, KYC-restricted transfers
that "cannot simply be tossed into Uniswap pools." Robinhood's own docs said standard
ERC-20.

Resolved directly against the chain, 31 Aug 2026:

```
RPC            https://rpc.mainnet.chain.robinhood.com
chainId        0x1237 → 4663                              ✓
NVDA proxy     0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC
beacon         0xe10b6f6b275de231345c20d14ab812db62151b00
implementation 0xb35490d6f9163de4f80d88dc75c3516eb64c5ae2  (11,614 bytes)
symbol         NVDA · decimals 18 · paused() false

selectors present   transfer ✓   paused ✓   hasRole ✓
selectors ABSENT    isWhitelisted · canTransfer · identityRegistry
                    compliance · blacklisted · frozen

DECISIVE  eth_call transfer(0x…dEaD, 1) from holder 0x8366a39C…0951
          → 0x…01   SUCCESS
```

A transfer to an address that has certainly never been KYC-onboarded simulates
successfully. **The tokens are freely transferable.** The third-party claims were
speculation — both hedged with "likely pattern".

The tokens are Pausable + AccessControl, so Robinhood can pause globally, but there is
no per-address gating. That residual risk is disclosed, not hidden.

---

## 3. Why Robinhood Chain, in $STACK's own numbers

**Gas.** A claim is five swaps in one transaction. On Ethereum mainnet that is expensive
enough that a small holder's share is worth less than the gas to collect it. $STACK's own
dashboard shows the symptom:

```
fees collected all-time   4.938 ETH
unclaimed, sitting        0.109 ETH   ≈ 2.2% stranded
market cap                $6.9K
```

The product is gas-broken at small scale. On Robinhood Chain — an Arbitrum Orbit L2 —
claiming costs cents, and micro-claims become viable. **This is the difference between
the mechanism working and not working**, not a cosmetic port.

**Native, not wrapped.** $STACK's basket is Ondo wrappers. Robinhood Chain's stock tokens
are first-party, issued natively, with Chainlink as the chain's official oracle.

**Depth.** A dozen stock tokens each clear $500K–$1M+ daily on Robinhood Chain. The basket
legs have real liquidity to buy into.

**Audience.** Robinhood's user base is retail index investors. "Hold this, get paid in
stocks" is native to that culture in a way it is not on Ethereum mainnet.

**Empty field.** Of 660 hooks in the Atrium incubator corpus, exactly one mentions stocks.
Robinhood Chain has 257 hook contracts of which ~89% are two meme-launch factories
(Doppler, Clanker) and only ~15–20 are independent development.

---

## 4. What we change

### 4.1 Claim on behalf of anyone — the headline fix

```solidity
function claim(address holder) external
```

Anyone may claim for anyone. The basket always lands in `holder`'s wallet; the caller
takes a small tip out of the ETH share to cover gas. An indexer settles every holder
automatically and **nobody's share is ever stranded**.

This directly fixes $STACK's most visible flaw, and it is only economical because L2 gas
makes settling a small share profitable. On mainnet it would not be.

### 4.2 ERC-8056 corporate-action multiplier — the correctness trap

Robinhood stock tokens implement the Scaled UI Amount Extension. `balanceOf()` returns a
**raw** balance; the shares-per-token ratio moves through an on-chain `uiMultiplier()`
when a split or dividend happens. Raw balances and total supply do not change.

Two rules a naive port would get wrong:

- Display and NAV must use `balanceOfUI()` / the multiplier, never raw `balanceOf()`
- Chainlink feeds **already include** the multiplier — do not apply it twice

Handling this correctly is a genuine, chain-specific contribution. A direct copy of
$STACK breaks silently on the first stock split.

### 4.3 Basket composition

Robinhood Chain live tokens (verified addresses):

```
NVDA   0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC
AAPL   0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9
TSLA   0x322F0929c4625eD5bAd873c95208D54E1c003b2d
AMZN   0x12f190a9F9d7D37a250758b26824B97CE941bF54
       also live: MSFT, GOOGL, META, MSTR, SPY, QCOM, PLTR, SPCX
```

`SPCX` (SpaceX) is worth considering — private-company exposure is not available in any
ETF, and it is the most distinctive thing this chain offers.

Fixed at deploy as constructor arguments, no setter, exactly as $STACK does.

---

## 5. Contracts

```
BasketToken.sol   ERC-20. Accumulator accounting in _update.
                  accruedOf(address), claim(address)
BasketHook.sol    beforeInitialize  lock config
                  beforeSwap        buy/sell fee split
                  afterSwap         route fee to the token as ETH
Basket.sol        immutable constituent set + weights + multiplier-aware valuation
```

Three targets, fitting Programmable's 3–16 requirement, well under the 49,152-byte
per-target init code cap.

**Fee split**

```
buy   2.0%      sell  3.0%
  → Programmable 0.10%   mandatory, LAUNCH.ETHEREUM_AND_TREASURY_10_BPS
  → holders      remainder
```

Note: the 10 bps Programmable obligation is specified for Ethereum mainnet. **Confirm in
Discord whether it applies on Robinhood Chain**, and whether Robinhood Chain launches are
open in the Custom Launch API yet — as of 30 Aug, discovery listed only chainId 1 as live.

---

## 6. Open questions — ask in Discord today

1. **Is Robinhood Chain live in the Programmable V3 launch API?** Discovery listed
   Ethereum mainnet only. The tweet says RH Chain support "will open in the coming days".
   **If it does not open before 10 Sep, this launches on Ethereum mainnet instead** — and
   then the gas argument in §3 works against us. This is the single biggest open risk
2. How much initial liquidity is required for a launch?
3. Does the 10 bps treasury obligation apply on Robinhood Chain?

---

## 7. Build plan

| When | What |
|---|---|
| **31 Aug** | Empty hook, permission bits mined into the CREATE2 address, `pack` → `validate --remote` **green**. Ask the three Discord questions |
| **1–3 Sep** | `BasketToken.sol` accumulator + `claim(address)`. Exhaustive tests on accrual arithmetic |
| **4–5 Sep** | `BasketHook.sol` fee routing. Basket buy path against live RH Chain pools |
| **5 Sep** | Multiplier handling + a forced-split test. This is where a naive port breaks |
| **6–7 Sep** | Auto-claim indexer. Website: live pot, your accrued share, basket prices, claim button |
| **8–9 Sep** | Launch. Two days of buffer for `action_required` loops |
| **9 Sep** | Submission form. Not the 10th |

---

## 8. Submission requirements

- [ ] Custom hook + official token launched through Programmable.market
- [ ] Working website
- [ ] Dedicated X account
- [ ] Public GitHub repository
- [ ] Telegram username
- [ ] Form submitted before 10 Sep

---

## 9. Honest risk register

| Risk | Severity | Note |
|---|---|---|
| Robinhood Chain not open in Programmable API by 10 Sep | **High** | Kills the core thesis. Ask today |
| Originality score | Medium | It is an adaptation. Mitigate by naming $STACK openly and leading with §3 and §4.2 |
| Robinhood can pause stock tokens globally | Low | AccessControl + Pausable confirmed on-chain. Disclose |
| Securities framing — distributing tokenized equities | Medium | $STACK carries a disclaimer; carry an equivalent one. Not legal advice |
| Basket leg liquidity thin at launch | Low | Legs clear $500K–$1M+ daily |
