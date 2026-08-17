package poc.bond;

import com.owlike.genson.Genson;
import org.hyperledger.fabric.contract.Context;
import org.hyperledger.fabric.contract.ContractInterface;
import org.hyperledger.fabric.contract.annotation.Contract;
import org.hyperledger.fabric.contract.annotation.Default;
import org.hyperledger.fabric.contract.annotation.Info;
import org.hyperledger.fabric.contract.annotation.Transaction;
import org.hyperledger.fabric.shim.ChaincodeException;

/**
 * Jambe titres de la variante B2 : cycle de vie de l'obligation tokenisee
 * (Ch. 7.2). Realise les flux I1 (enregistrement par l'emetteur) et I2
 * (creation des tokens, reservee au CSD - D2 CSD-as-DLT-node, R06), les
 * transferts entre detenteurs et l'earmark (reservation d'escrow, R09/R10).
 *
 * Le service de reglement (fonctions *ForTrade du swap atomique) est porte
 * par le contrat distinct BondSettlement, meme chaincode, meme namespace.
 */
@Contract(
        name = "bond",
        info = @Info(
                title = "Bond token contract",
                description = "Securities lifecycle of variant B2 - issuance and holdings (flows I1, I2)"))
@Default
public final class BondContract implements ContractInterface {

    private static final String CSD_MSP = "CSDMSP";
    private static final String CENTRAL_BANK_MSP = "CentralBankMSP";
    private static final String SUPERVISOR_MSP = "SupervisorMSP";

    private final Genson genson = new Genson();

    /**
     * I1 - enregistrement de l'emission par l'emetteur (une banque participante).
     * Le CSD, le superviseur et la banque centrale ne peuvent pas etre emetteurs
     * (separation des roles, R02).
     */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public String registerIssuance(final Context ctx, final String isin, final String amount,
            final String currency, final String maturity) {
        final String caller = ctx.getClientIdentity().getMSPID();
        if (caller.equals(CSD_MSP) || caller.equals(SUPERVISOR_MSP) || caller.equals(CENTRAL_BANK_MSP)) {
            throw new ChaincodeException(
                    String.format("%s cannot act as issuer (R02, role separation)", caller),
                    Errors.UNAUTHORIZED.toString());
        }
        if (!BondStore.rawIssuance(ctx, isin).isEmpty()) {
            throw new ChaincodeException("issuance already registered for " + isin,
                    Errors.ALREADY_EXISTS.toString());
        }
        final Issuance issuance = new Issuance();
        issuance.isin = isin;
        issuance.issuerMsp = caller;
        issuance.totalAmount = parseAmount(amount);
        issuance.currency = currency;
        issuance.maturity = maturity;
        issuance.status = Issuance.PENDING_MINT;
        BondStore.saveIssuance(ctx, genson, issuance);

        BondStore.emitEvent(ctx, "BondIssuanceRegistered", isin, issuance.totalAmount);
        return isin;
    }

    /**
     * I2 - creation des tokens vers l'emetteur, reservee au CSD : c'est son
     * endorsement qui fait de l'ecriture le golden record (D2, R06).
     */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public String mint(final Context ctx, final String isin) {
        final String caller = ctx.getClientIdentity().getMSPID();
        if (!CSD_MSP.equals(caller)) {
            throw new ChaincodeException(
                    String.format("mint is reserved to the CSD (I2, R06); caller was %s", caller),
                    Errors.UNAUTHORIZED.toString());
        }
        final Issuance issuance = BondStore.requireIssuance(ctx, genson, isin);
        if (!Issuance.PENDING_MINT.equals(issuance.status)) {
            throw new ChaincodeException(
                    String.format("issuance %s is not pending mint (status: %s)", isin, issuance.status),
                    Errors.INVALID_STATE.toString());
        }
        BondStore.writeBalance(ctx, isin, issuance.issuerMsp, issuance.totalAmount);
        issuance.status = Issuance.ACTIVE;
        BondStore.saveIssuance(ctx, genson, issuance);

        BondStore.emitEvent(ctx, "TokensMinted", isin + ">" + issuance.issuerMsp, issuance.totalAmount);
        return Long.toString(issuance.totalAmount);
    }

    /**
     * Transfert de titres hors reglement. L'initiateur doit detenir le compte
     * debite, et seuls les titres non reserves (earmark) sont cessibles.
     */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public String transfer(final Context ctx, final String isin, final String fromMsp,
            final String toMsp, final String amount) {
        final long value = parseAmount(amount);
        final String caller = ctx.getClientIdentity().getMSPID();
        if (!caller.equals(fromMsp)) {
            throw new ChaincodeException(
                    String.format("caller %s cannot debit holdings of %s", caller, fromMsp),
                    Errors.UNAUTHORIZED.toString());
        }
        if (fromMsp.equals(toMsp)) {
            throw new ChaincodeException("self-transfer is not allowed", Errors.INVALID_AMOUNT.toString());
        }
        BondStore.requireIssuance(ctx, genson, isin);
        final long available = requireAvailable(ctx, isin, fromMsp, value, "transfer");
        BondStore.writeBalance(ctx, isin, fromMsp, BondStore.readBalance(ctx, isin, fromMsp) - value);
        BondStore.writeBalance(ctx, isin, toMsp, BondStore.readBalance(ctx, isin, toMsp) + value);

        BondStore.emitEvent(ctx, "TokensTransferred", isin + ":" + fromMsp + ">" + toMsp, value);
        return Long.toString(available - value);
    }

    /**
     * Earmark - reservation de titres par leur detenteur. La propriete ne
     * change pas; les titres reserves ne sont plus cessibles.
     */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public String earmark(final Context ctx, final String isin, final String tradeId, final String amount) {
        final long value = parseAmount(amount);
        final String caller = ctx.getClientIdentity().getMSPID();
        BondStore.requireIssuance(ctx, genson, isin);
        final String key = BondStore.earmarkKey(ctx, isin, caller, tradeId);
        if (!ctx.getStub().getStringState(key).isEmpty()) {
            throw new ChaincodeException(
                    String.format("earmark already exists for trade %s on %s", tradeId, isin),
                    Errors.ALREADY_EXISTS.toString());
        }
        final long available = requireAvailable(ctx, isin, caller, value, "earmark");
        ctx.getStub().putStringState(key, Long.toString(value));

        BondStore.emitEvent(ctx, "TokensEarmarked", isin + ":" + caller + ":" + tradeId, value);
        // Pas de relecture apres ecriture (Fabric lit l'etat committe, pas les
        // ecritures de la transaction en cours): on calcule le disponible resultant.
        return Long.toString(available - value);
    }

    /** Levee d'une reservation par son detenteur. */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public String releaseEarmark(final Context ctx, final String isin, final String tradeId) {
        final String caller = ctx.getClientIdentity().getMSPID();
        final String key = BondStore.earmarkKey(ctx, isin, caller, tradeId);
        final String state = ctx.getStub().getStringState(key);
        if (state.isEmpty()) {
            throw new ChaincodeException(
                    String.format("no earmark for trade %s on %s held by %s", tradeId, isin, caller),
                    Errors.NOT_FOUND.toString());
        }
        final long released = Long.parseLong(state);
        ctx.getStub().delState(key);

        BondStore.emitEvent(ctx, "EarmarkReleased", isin + ":" + caller + ":" + tradeId, released);
        // Disponible resultant calcule (pas de relecture apres suppression).
        return Long.toString(BondStore.availableOf(ctx, isin, caller) + released);
    }

    /** Lecture seule - detention totale (surface S1/S2, R11). */
    @Transaction(intent = Transaction.TYPE.EVALUATE)
    public String balanceOf(final Context ctx, final String isin, final String msp) {
        return Long.toString(BondStore.readBalance(ctx, isin, msp));
    }

    /** Lecture seule - detention cessible = solde moins les reservations. */
    @Transaction(intent = Transaction.TYPE.EVALUATE)
    public String availableOf(final Context ctx, final String isin, final String msp) {
        return Long.toString(BondStore.availableOf(ctx, isin, msp));
    }

    /** Lecture seule - la fiche d'emission (golden record, R06). */
    @Transaction(intent = Transaction.TYPE.EVALUATE)
    public String getIssuance(final Context ctx, final String isin) {
        final String state = BondStore.rawIssuance(ctx, isin);
        if (state.isEmpty()) {
            throw new ChaincodeException("no issuance registered for " + isin, Errors.NOT_FOUND.toString());
        }
        return state;
    }

    /** Verifie que la detention cessible de msp couvre value; retourne le disponible. */
    private long requireAvailable(final Context ctx, final String isin, final String msp,
            final long value, final String action) {
        final long available = BondStore.availableOf(ctx, isin, msp);
        if (available < value) {
            throw new ChaincodeException(
                    String.format("%s of %d exceeds available holdings %d of %s on %s "
                            + "(balance minus earmarks)", action, value, available, msp, isin),
                    Errors.INSUFFICIENT_AVAILABLE.toString());
        }
        return available;
    }

    private long parseAmount(final String amount) {
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
}
