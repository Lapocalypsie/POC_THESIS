package poc.dvp;

import com.owlike.genson.Genson;
import org.hyperledger.fabric.contract.Context;
import org.hyperledger.fabric.contract.ContractInterface;
import org.hyperledger.fabric.contract.annotation.Contract;
import org.hyperledger.fabric.contract.annotation.Default;
import org.hyperledger.fabric.contract.annotation.Info;
import org.hyperledger.fabric.contract.annotation.Transaction;
import org.hyperledger.fabric.shim.Chaincode;
import org.hyperledger.fabric.shim.ChaincodeException;


@Contract(
        name = "dvp",
        info = @Info(
                title = "DvP settlement coordinator",
                description = "State machine + atomic swap O1+O2 of variant B2 (flows I3, O1, O2)"))
@Default
public final class DvPContract implements ContractInterface {

    private static final String CENTRAL_BANK_MSP = "CentralBankMSP";
    private static final String BOND_CC = "bond";
    private static final String WCBDC_CC = "wcbdc";

    private final Genson genson = new Genson();

    /**
     * I3, premiere signature. Gardes dans l'ordre : pause (C1, refus sec),
     * eligibilite (R03 -> REJECTED_INELIGIBLE), plafond de conformite
     * (R16 -> REJECTED_COMPLIANCE). Les rejets sont des etats terminaux
     * ecrits au ledger : le superviseur les observe (R11).
     */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public String proposeTrade(final Context ctx, final String tradeId, final String buyerMsp,
            final String sellerMsp, final String isin, final String bondAmount,
            final String cashAmount, final String currency,
            final String businessTimeoutSec, final String safetyTimeoutSec) {
        requireNotPaused(ctx);
        final String caller = ctx.getClientIdentity().getMSPID();
        if (!caller.equals(buyerMsp) && !caller.equals(sellerMsp)) {
            throw new ChaincodeException("only a counterparty may propose the trade",
                    Errors.UNAUTHORIZED.toString());
        }
        if (buyerMsp.equals(sellerMsp)) {
            throw new ChaincodeException("buyer and seller must differ", Errors.INVALID_AMOUNT.toString());
        }
        if (!DvPStore.rawTrade(ctx, tradeId).isEmpty()) {
            throw new ChaincodeException("trade already exists: " + tradeId,
                    Errors.ALREADY_EXISTS.toString());
        }

        final Trade trade = new Trade();
        trade.tradeId = tradeId;
        trade.buyerMsp = buyerMsp;
        trade.sellerMsp = sellerMsp;
        trade.proposerMsp = caller;
        trade.isin = isin;
        trade.bondAmount = parsePositive(bondAmount);
        trade.cashAmount = parsePositive(cashAmount);
        trade.currency = currency;
        final long now = ctx.getStub().getTxTimestamp().getEpochSecond();
        trade.businessTimeoutTs = now + parsePositive(businessTimeoutSec);
        trade.safetyTimeoutTs = now + parsePositive(safetyTimeoutSec);
        if (trade.safetyTimeoutTs <= trade.businessTimeoutTs) {
            throw new ChaincodeException("safety timeout must exceed business timeout",
                    Errors.INVALID_AMOUNT.toString());
        }

        if (!DvPStore.isEligible(ctx, buyerMsp) || !DvPStore.isEligible(ctx, sellerMsp)) {
            trade.status = Trade.REJECTED_INELIGIBLE;
            trade.reason = "party not admitted (R03)";
            return DvPStore.save(ctx, genson, trade, "SettlementAborted");
        }
        final long cap = DvPStore.readCap(ctx);
        if (cap > 0 && trade.cashAmount > cap) {
            trade.status = Trade.REJECTED_COMPLIANCE;
            trade.reason = String.format("cash amount %d exceeds compliance cap %d (R16)",
                    trade.cashAmount, cap);
            return DvPStore.save(ctx, genson, trade, "SettlementAborted");
        }
        trade.status = Trade.PROPOSED;
        return DvPStore.save(ctx, genson, trade, "TradeProposed");
    }

    /** Seconde signature, par la contrepartie : la cosignature R05 est complete. */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public String confirmTrade(final Context ctx, final String tradeId) {
        requireNotPaused(ctx);
        final Trade trade = DvPStore.load(ctx, genson, tradeId);
        if (!Trade.PROPOSED.equals(trade.status)) {
            throw new ChaincodeException(
                    String.format("trade %s: expected status PROPOSED, found %s", tradeId, trade.status),
                    Errors.INVALID_STATE.toString());
        }
        final String caller = ctx.getClientIdentity().getMSPID();
        final String counterparty = trade.proposerMsp.equals(trade.buyerMsp)
                ? trade.sellerMsp : trade.buyerMsp;
        if (!caller.equals(counterparty)) {
            throw new ChaincodeException(
                    String.format("confirmation must come from %s; caller was %s", counterparty, caller),
                    Errors.UNAUTHORIZED.toString());
        }
        trade.status = Trade.PENDING;
        return DvPStore.save(ctx, genson, trade, "TradeConfirmed");
    }

    /**
     * Depuis PENDING : swap atomique si la provision suffit, sinon entree en
     * escrow (earmark des titres). Depuis ESCROW_WAITING : retry apres on-ramp
     * (consomme l'earmark), avec controle paresseux des timeouts.
     */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public String executeSettlement(final Context ctx, final String tradeId) {
        requireNotPaused(ctx);
        final Trade trade = DvPStore.load(ctx, genson, tradeId);
        requireParty(ctx, trade);
        if (!Trade.PENDING.equals(trade.status) && !Trade.ESCROW_WAITING.equals(trade.status)) {
            throw new ChaincodeException(
                    String.format("trade %s is not settleable (status: %s)", tradeId, trade.status),
                    Errors.INVALID_STATE.toString());
        }

        // Expiration paresseuse : le chaincode ne se reveille pas seul, les
        // timeouts sont evalues a l'invocation (accessoire dans B2 - le temps
        // ne porte pas la garantie, contrairement a B1/B3).
        if (Trade.ESCROW_WAITING.equals(trade.status)) {
            final String released = releaseIfExpired(ctx, trade);
            if (released != null) {
                return released;
            }
        }

        final long buyerCash = Long.parseLong(
                invokeCC(ctx, WCBDC_CC, "balanceOf", trade.buyerMsp));
        if (buyerCash >= trade.cashAmount) {
            // O1 + O2 : deux invocations, UNE transaction de plateforme.
            // Si l'une echoue, la transaction entiere est invalidee - aucun
            // etat intermediaire n'est constructible (invariant 5.1).
            invokeCC(ctx, BOND_CC, "bondSettlement:transferForTrade", tradeId,
                    trade.sellerMsp, trade.buyerMsp, trade.isin, Long.toString(trade.bondAmount));
            invokeCC(ctx, WCBDC_CC, "transferForTrade", tradeId,
                    trade.buyerMsp, trade.sellerMsp, Long.toString(trade.cashAmount));
            trade.status = Trade.SETTLED;
            return DvPStore.save(ctx, genson, trade, "AtomicSwapCommitted");
        }

        if (Trade.ESCROW_WAITING.equals(trade.status)) {
            throw new ChaincodeException(
                    String.format("buyer %s still holds %d, needs %d", trade.buyerMsp,
                            buyerCash, trade.cashAmount),
                    Errors.INVALID_STATE.toString());
        }
        // Entree en escrow : earmark des titres du vendeur (pas de transfert),
        // fenetre d'on-ramp pour l'acheteur (R09).
        invokeCC(ctx, BOND_CC, "bondSettlement:earmarkForTrade", tradeId,
                trade.sellerMsp, trade.isin, Long.toString(trade.bondAmount));
        trade.status = Trade.ESCROW_WAITING;
        return DvPStore.save(ctx, genson, trade, "SettlementEscrowed");
    }

    /** Liberation d'un escrow expire (timeout metier, ou filet de securite). */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public String releaseExpired(final Context ctx, final String tradeId) {
        final Trade trade = DvPStore.load(ctx, genson, tradeId);
        if (!Trade.ESCROW_WAITING.equals(trade.status)) {
            throw new ChaincodeException(
                    String.format("trade %s: expected status ESCROW_WAITING, found %s",
                            tradeId, trade.status),
                    Errors.INVALID_STATE.toString());
        }
        final String released = releaseIfExpired(ctx, trade);
        if (released == null) {
            throw new ChaincodeException(
                    String.format("trade %s: no timeout expired yet", tradeId),
                    Errors.NOT_EXPIRED.toString());
        }
        return released;
    }

    @Transaction(intent = Transaction.TYPE.EVALUATE)
    public String getTrade(final Context ctx, final String tradeId) {
        final String state = DvPStore.rawTrade(ctx, tradeId);
        if (state.isEmpty()) {
            throw new ChaincodeException("no trade: " + tradeId, Errors.NOT_FOUND.toString());
        }
        return state;
    }

    @Transaction(intent = Transaction.TYPE.EVALUATE)
    public String isPaused(final Context ctx) {
        final String state = DvPStore.readPause(ctx);
        return state.isEmpty() ? "false" : "true: " + state;
    }

    private String releaseIfExpired(final Context ctx, final Trade trade) {
        final long now = ctx.getStub().getTxTimestamp().getEpochSecond();
        if (now > trade.safetyTimeoutTs) {
            invokeCC(ctx, BOND_CC, "bondSettlement:releaseForTrade", trade.tradeId,
                    trade.sellerMsp, trade.isin);
            trade.status = Trade.RELEASED_SAFETY;
            trade.reason = "safety timeout backstop (R10)";
            return DvPStore.save(ctx, genson, trade, "SettlementAborted");
        }
        if (now > trade.businessTimeoutTs) {
            invokeCC(ctx, BOND_CC, "bondSettlement:releaseForTrade", trade.tradeId,
                    trade.sellerMsp, trade.isin);
            trade.status = Trade.RELEASED_BUSINESS;
            trade.reason = "business timeout expired unfunded (R10)";
            return DvPStore.save(ctx, genson, trade, "SettlementAborted");
        }
        return null;
    }

    private void requireNotPaused(final Context ctx) {
        final String state = DvPStore.readPause(ctx);
        if (!state.isEmpty()) {
            throw new ChaincodeException("settlement is paused (C1): " + state,
                    Errors.SETTLEMENT_PAUSED.toString());
        }
    }

    private void requireParty(final Context ctx, final Trade trade) {
        final String caller = ctx.getClientIdentity().getMSPID();
        if (!caller.equals(trade.buyerMsp) && !caller.equals(trade.sellerMsp)
                && !caller.equals(CENTRAL_BANK_MSP)) {
            throw new ChaincodeException("caller " + caller + " is not a party to " + trade.tradeId,
                    Errors.UNAUTHORIZED.toString());
        }
    }

    private long parsePositive(final String amount) {
        final long value;
        try {
            value = Long.parseLong(amount);
        } catch (NumberFormatException e) {
            throw new ChaincodeException("amount is not a number: " + amount,
                    Errors.INVALID_AMOUNT.toString());
        }
        if (value <= 0) {
            throw new ChaincodeException("amount must be strictly positive: " + amount,
                    Errors.INVALID_AMOUNT.toString());
        }
        return value;
    }

    /** Invocation cross-chaincode; un echec de l'appele invalide toute la transaction. */
    private String invokeCC(final Context ctx, final String chaincode, final String... args) {
        final Chaincode.Response response =
                ctx.getStub().invokeChaincodeWithStringArgs(chaincode, args);
        if (response.getStatus() != Chaincode.Response.Status.SUCCESS) {
            throw new ChaincodeException(
                    String.format("call to %s.%s failed: %s", chaincode, args[0], response.getMessage()),
                    Errors.CROSS_CHAINCODE_FAILURE.toString());
        }
        return response.getStringPayload();
    }
}
