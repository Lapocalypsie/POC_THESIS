package poc.bond;

import org.hyperledger.fabric.contract.Context;
import org.hyperledger.fabric.contract.ContractInterface;
import org.hyperledger.fabric.contract.annotation.Contract;
import org.hyperledger.fabric.contract.annotation.Info;
import org.hyperledger.fabric.contract.annotation.Transaction;
import org.hyperledger.fabric.shim.ChaincodeException;

/**
 * Service de reglement de la jambe titres (v1.1) - contrat distinct du cycle
 * de vie du titre, dans le meme chaincode. Ses fonctions ne sont invocables
 * QUE via le coordinateur dvp (ProposalGuard) : c'est lui qui detient le trade
 * cosigne (R05) et passe ses donnees en arguments - un rappel vers dvp est
 * impossible, Fabric interdisant l'invocation cyclique dans une transaction.
 * Invocation : "bondSettlement:transferForTrade", etc.
 */
@Contract(
        name = "bondSettlement",
        info = @Info(
                title = "Bond settlement service",
                description = "Securities leg of the atomic swap (O1) - trade-authorised operations"))
public final class BondSettlement implements ContractInterface {

    /** O1 - jambe titres du swap atomique. Consomme l'earmark d'escrow s'il existe. */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public String transferForTrade(final Context ctx, final String tradeId, final String sellerMsp,
            final String buyerMsp, final String isin, final String amount) {
        ProposalGuard.requireInvokedViaDvp(ctx, "transferForTrade");
        final long value = Long.parseLong(amount);

        final String key = BondStore.earmarkKey(ctx, isin, sellerMsp, tradeId);
        final String earmarkState = ctx.getStub().getStringState(key);
        final long earmarked = earmarkState.isEmpty() ? 0L : Long.parseLong(earmarkState);

        final long sellerBalance = BondStore.readBalance(ctx, isin, sellerMsp);
        final long otherEarmarks = BondStore.earmarkedTotal(ctx, isin, sellerMsp) - earmarked;
        if (sellerBalance - otherEarmarks < value) {
            throw new ChaincodeException(String.format(
                    "settlement of %d exceeds transferable holdings %d of %s on %s",
                    value, sellerBalance - otherEarmarks, sellerMsp, isin),
                    Errors.INSUFFICIENT_AVAILABLE.toString());
        }
        if (earmarked > 0) {
            ctx.getStub().delState(key);
        }
        BondStore.writeBalance(ctx, isin, sellerMsp, sellerBalance - value);
        BondStore.writeBalance(ctx, isin, buyerMsp, BondStore.readBalance(ctx, isin, buyerMsp) + value);

        BondStore.emitEvent(ctx, "TokensTransferred",
                isin + ":" + sellerMsp + ">" + buyerMsp + ":" + tradeId, value);
        return Long.toString(value);
    }

    /** Entree en escrow (R09) : reserve les titres du vendeur pour le trade. */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public String earmarkForTrade(final Context ctx, final String tradeId, final String sellerMsp,
            final String isin, final String amount) {
        ProposalGuard.requireInvokedViaDvp(ctx, "earmarkForTrade");
        final long value = Long.parseLong(amount);

        final String key = BondStore.earmarkKey(ctx, isin, sellerMsp, tradeId);
        if (!ctx.getStub().getStringState(key).isEmpty()) {
            throw new ChaincodeException("earmark already exists for trade " + tradeId,
                    Errors.ALREADY_EXISTS.toString());
        }
        final long available = BondStore.availableOf(ctx, isin, sellerMsp);
        if (available < value) {
            throw new ChaincodeException(String.format(
                    "earmarkForTrade of %d exceeds available holdings %d of %s on %s",
                    value, available, sellerMsp, isin),
                    Errors.INSUFFICIENT_AVAILABLE.toString());
        }
        ctx.getStub().putStringState(key, Long.toString(value));

        BondStore.emitEvent(ctx, "TokensEarmarked", isin + ":" + sellerMsp + ":" + tradeId, value);
        return Long.toString(available - value);
    }

    /** Liberation d'escrow (R10) : leve la reservation, aucune jambe n'a bouge. */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public String releaseForTrade(final Context ctx, final String tradeId, final String sellerMsp,
            final String isin) {
        ProposalGuard.requireInvokedViaDvp(ctx, "releaseForTrade");
        final String key = BondStore.earmarkKey(ctx, isin, sellerMsp, tradeId);
        final String state = ctx.getStub().getStringState(key);
        if (state.isEmpty()) {
            throw new ChaincodeException("no earmark to release for trade " + tradeId,
                    Errors.NOT_FOUND.toString());
        }
        ctx.getStub().delState(key);

        BondStore.emitEvent(ctx, "EarmarkReleased",
                isin + ":" + sellerMsp + ":" + tradeId, Long.parseLong(state));
        return "released";
    }
}
