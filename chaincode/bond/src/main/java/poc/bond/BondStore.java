package poc.bond;

import com.owlike.genson.Genson;
import org.hyperledger.fabric.contract.Context;
import org.hyperledger.fabric.shim.ChaincodeException;
import org.hyperledger.fabric.shim.ChaincodeStub;
import org.hyperledger.fabric.shim.ledger.KeyValue;
import org.hyperledger.fabric.shim.ledger.QueryResultsIterator;

import java.nio.charset.StandardCharsets;

/**
 * Acces au world state du contrat titres : seule classe connaissant la
 * disposition des cles. Partagee par le cycle de vie du titre (BondContract)
 * et le service de reglement (BondSettlement), qui cohabitent dans le meme
 * chaincode donc le meme namespace.
 */
final class BondStore {

    static final String ISSUANCE_PREFIX = "bond:issuance:";
    static final String ACCOUNT_PREFIX = "bond:acct:";
    static final String EARMARK_TYPE = "bond:earmark";

    private BondStore() {
    }

    static String rawIssuance(final Context ctx, final String isin) {
        return ctx.getStub().getStringState(ISSUANCE_PREFIX + isin);
    }

    static Issuance requireIssuance(final Context ctx, final Genson genson, final String isin) {
        final String state = rawIssuance(ctx, isin);
        if (state.isEmpty()) {
            throw new ChaincodeException("no issuance registered for " + isin,
                    Errors.NOT_FOUND.toString());
        }
        return genson.deserialize(state, Issuance.class);
    }

    static void saveIssuance(final Context ctx, final Genson genson, final Issuance issuance) {
        ctx.getStub().putStringState(ISSUANCE_PREFIX + issuance.isin, genson.serialize(issuance));
    }

    static long readBalance(final Context ctx, final String isin, final String msp) {
        final String state = ctx.getStub().getStringState(ACCOUNT_PREFIX + isin + ":" + msp);
        return state.isEmpty() ? 0L : Long.parseLong(state);
    }

    static void writeBalance(final Context ctx, final String isin, final String msp, final long balance) {
        ctx.getStub().putStringState(ACCOUNT_PREFIX + isin + ":" + msp, Long.toString(balance));
    }

    static String earmarkKey(final Context ctx, final String isin, final String msp, final String tradeId) {
        return ctx.getStub().createCompositeKey(EARMARK_TYPE, isin, msp, tradeId).toString();
    }

    /** Somme des reservations de msp sur isin (requete par cle composite partielle). */
    static long earmarkedTotal(final Context ctx, final String isin, final String msp) {
        long total = 0L;
        try (QueryResultsIterator<KeyValue> results =
                ctx.getStub().getStateByPartialCompositeKey(EARMARK_TYPE, isin, msp)) {
            for (KeyValue kv : results) {
                total += Long.parseLong(kv.getStringValue());
            }
        } catch (Exception e) {
            throw new ChaincodeException("failed to read earmarks: " + e.getMessage(),
                    Errors.NOT_FOUND.toString());
        }
        return total;
    }

    /** Detention cessible = solde moins les reservations. */
    static long availableOf(final Context ctx, final String isin, final String msp) {
        return readBalance(ctx, isin, msp) - earmarkedTotal(ctx, isin, msp);
    }

    static void emitEvent(final Context ctx, final String name, final String subject, final long amount) {
        final ChaincodeStub stub = ctx.getStub();
        final String payload = String.format(
                "{\"subject\":\"%s\",\"amount\":%d,\"txId\":\"%s\"}", subject, amount, stub.getTxId());
        stub.setEvent(name, payload.getBytes(StandardCharsets.UTF_8));
    }
}
