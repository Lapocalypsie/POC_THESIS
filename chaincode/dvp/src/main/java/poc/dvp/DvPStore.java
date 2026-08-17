package poc.dvp;

import com.owlike.genson.Genson;
import org.hyperledger.fabric.contract.Context;
import org.hyperledger.fabric.shim.ChaincodeException;

import java.nio.charset.StandardCharsets;

/**
 * Acces au world state du coordinateur : seule classe connaissant la
 * disposition des cles. Partagee par le contrat de reglement (DvPContract)
 * et le plan de controle banque centrale (CentralBankOperations), qui
 * cohabitent dans le meme chaincode donc le meme namespace.
 */
final class DvPStore {

    static final String TRADE_PREFIX = "trade:";
    static final String PAUSE_KEY = "dvp:pause";
    static final String ELIGIBLE_PREFIX = "dvp:eligible:";
    static final String CAP_KEY = "dvp:config:cap";

    private DvPStore() {
    }

    static Trade load(final Context ctx, final Genson genson, final String tradeId) {
        final String state = ctx.getStub().getStringState(TRADE_PREFIX + tradeId);
        if (state.isEmpty()) {
            throw new ChaincodeException("no trade: " + tradeId, Errors.NOT_FOUND.toString());
        }
        return genson.deserialize(state, Trade.class);
    }

    static String rawTrade(final Context ctx, final String tradeId) {
        return ctx.getStub().getStringState(TRADE_PREFIX + tradeId);
    }

    /** Ecrit le trade, emet l'evenement, retourne le statut atteint. */
    static String save(final Context ctx, final Genson genson, final Trade trade,
            final String eventName) {
        ctx.getStub().putStringState(TRADE_PREFIX + trade.tradeId, genson.serialize(trade));
        emitEvent(ctx, eventName, trade.tradeId + ":" + trade.status);
        return trade.status;
    }

    static String readPause(final Context ctx) {
        return ctx.getStub().getStringState(PAUSE_KEY);
    }

    static boolean isEligible(final Context ctx, final String msp) {
        return !ctx.getStub().getStringState(ELIGIBLE_PREFIX + msp).isEmpty();
    }

    static long readCap(final Context ctx) {
        final String state = ctx.getStub().getStringState(CAP_KEY);
        return state.isEmpty() ? 0L : Long.parseLong(state);
    }

    static void emitEvent(final Context ctx, final String name, final String subject) {
        final String payload = String.format("{\"subject\":\"%s\",\"txId\":\"%s\"}",
                subject, ctx.getStub().getTxId());
        ctx.getStub().setEvent(name, payload.getBytes(StandardCharsets.UTF_8));
    }
}
