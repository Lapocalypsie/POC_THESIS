package poc.wcbdc;

import org.hyperledger.fabric.contract.Context;
import org.hyperledger.fabric.contract.ContractInterface;
import org.hyperledger.fabric.contract.annotation.Contract;
import org.hyperledger.fabric.contract.annotation.Default;
import org.hyperledger.fabric.contract.annotation.Info;
import org.hyperledger.fabric.contract.annotation.Transaction;
import org.hyperledger.fabric.shim.ChaincodeException;
import org.hyperledger.fabric.shim.ChaincodeStub;

import java.nio.charset.StandardCharsets;

/**
 * Jambe cash de la variante B2 : wCBDC natif, monnaie de banque centrale sous
 * forme de token (Ch. 7.2). Realise les flux C2 (mint/burn, operation reservee
 * a la banque centrale, R14) et O2 (transfert cash au sein du swap atomique).
 *
 * Un compte par organisation (MSP), cle "wcbdc:acct:<MSPID>".
 * L'offre totale est suivie sous "wcbdc:supply" : sa variation ne peut resulter
 * que d'un mint ou d'un burn signes par la banque centrale (tracabilite R14).
 */
@Contract(
        name = "wcbdc",
        info = @Info(
                title = "wCBDC token contract",
                description = "Cash leg of variant B2 - native wholesale CBDC (flows C2, O2)"))
@Default
public final class WCBDCContract implements ContractInterface {

    private static final String CENTRAL_BANK_MSP = "CentralBankMSP";
    private static final String ACCOUNT_PREFIX = "wcbdc:acct:";
    private static final String SUPPLY_KEY = "wcbdc:supply";

    private enum Errors { UNAUTHORIZED, INVALID_AMOUNT, INSUFFICIENT_FUNDS }

    /**
     * C2 - emission de wCBDC contre soldes RTGS (on-ramp). Operation reservee :
     * seule une identite de la banque centrale peut l'invoquer (R14).
     */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public String mint(final Context ctx, final String toMsp, final String amount) {
        requireCentralBank(ctx, "mint");
        final long value = parseAmount(amount);

        final long newBalance = readBalance(ctx, toMsp) + value;
        writeBalance(ctx, toMsp, newBalance);
        writeSupply(ctx, readSupply(ctx) + value);

        emitEvent(ctx, "wCBDCMinted", toMsp, value);
        return Long.toString(newBalance);
    }

    /**
     * C2 - destruction de wCBDC lors de la reconversion en soldes RTGS
     * (off-ramp). Operation reservee a la banque centrale (R14).
     */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public String burn(final Context ctx, final String holderMsp, final String amount) {
        requireCentralBank(ctx, "burn");
        final long value = parseAmount(amount);

        final long balance = requireSufficientFunds(ctx, holderMsp, value, "burn");
        writeBalance(ctx, holderMsp, balance - value);
        writeSupply(ctx, readSupply(ctx) - value);

        emitEvent(ctx, "wCBDCBurned", holderMsp, value);
        return Long.toString(balance - value);
    }

    /**
     * O2 - transfert de la jambe cash. Le compte debite doit appartenir a
     * l'organisation qui soumet la transaction : nul ne depense l'argent
     * d'autrui. (Le chemin de reglement DvP, ou l'autorisation derive de
     * l'instruction cosignee I3, est porte par le contrat DvP.)
     */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public String transfer(final Context ctx, final String fromMsp, final String toMsp, final String amount) {
        final long value = parseAmount(amount);
        final String caller = ctx.getClientIdentity().getMSPID();
        if (!caller.equals(fromMsp)) {
            throw new ChaincodeException(
                    String.format("caller %s cannot debit account of %s", caller, fromMsp),
                    Errors.UNAUTHORIZED.toString());
        }
        if (fromMsp.equals(toMsp)) {
            throw new ChaincodeException("self-transfer is not allowed", Errors.INVALID_AMOUNT.toString());
        }

        final long fromBalance = requireSufficientFunds(ctx, fromMsp, value, "transfer");
        writeBalance(ctx, fromMsp, fromBalance - value);
        writeBalance(ctx, toMsp, readBalance(ctx, toMsp) + value);

        emitEvent(ctx, "wCBDCTransferred", fromMsp + ">" + toMsp, value);
        return Long.toString(fromBalance - value);
    }

    /**
     * O2 (v1.1) - jambe cash du swap atomique. Invocable uniquement via le
     * coordinateur dvp (ProposalGuard), qui detient le trade cosigne (R05) et
     * passe ses donnees en arguments. Si la provision manque, l'exception
     * invalide la transaction entiere - la jambe titres executee dans la meme
     * transaction est annulee avec elle.
     */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public String transferForTrade(final Context ctx, final String tradeId, final String buyerMsp,
            final String sellerMsp, final String amount) {
        ProposalGuard.requireInvokedViaDvp(ctx, "transferForTrade");
        final long value = parseAmount(amount);
        final long buyerBalance = requireSufficientFunds(ctx, buyerMsp, value, "settlement");
        writeBalance(ctx, buyerMsp, buyerBalance - value);
        writeBalance(ctx, sellerMsp, readBalance(ctx, sellerMsp) + value);

        emitEvent(ctx, "wCBDCTransferred", buyerMsp + ">" + sellerMsp + ":" + tradeId, value);
        return Long.toString(value);
    }

    /** Lecture seule - solde d'une organisation (surface d'observation S2, R11). */
    @Transaction(intent = Transaction.TYPE.EVALUATE)
    public String balanceOf(final Context ctx, final String msp) {
        return Long.toString(readBalance(ctx, msp));
    }

    /** Lecture seule - offre totale de wCBDC en circulation (R14, tracabilite). */
    @Transaction(intent = Transaction.TYPE.EVALUATE)
    public String totalSupply(final Context ctx) {
        return Long.toString(readSupply(ctx));
    }

    private void requireCentralBank(final Context ctx, final String operation) {
        final String caller = ctx.getClientIdentity().getMSPID();
        if (!CENTRAL_BANK_MSP.equals(caller)) {
            throw new ChaincodeException(
                    String.format("%s is a reserved central-bank operation (R14); caller was %s",
                            operation, caller),
                    Errors.UNAUTHORIZED.toString());
        }
    }

    /** Verifie que le solde de msp couvre value; retourne le solde courant. */
    private long requireSufficientFunds(final Context ctx, final String msp, final long value,
            final String action) {
        final long balance = readBalance(ctx, msp);
        if (balance < value) {
            throw new ChaincodeException(
                    String.format("%s of %d exceeds balance %d of %s", action, value, balance, msp),
                    Errors.INSUFFICIENT_FUNDS.toString());
        }
        return balance;
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

    private long readBalance(final Context ctx, final String msp) {
        final String state = ctx.getStub().getStringState(ACCOUNT_PREFIX + msp);
        return (state == null || state.isEmpty()) ? 0L : Long.parseLong(state);
    }

    private void writeBalance(final Context ctx, final String msp, final long balance) {
        ctx.getStub().putStringState(ACCOUNT_PREFIX + msp, Long.toString(balance));
    }

    private long readSupply(final Context ctx) {
        final String state = ctx.getStub().getStringState(SUPPLY_KEY);
        return (state == null || state.isEmpty()) ? 0L : Long.parseLong(state);
    }

    private void writeSupply(final Context ctx, final long supply) {
        ctx.getStub().putStringState(SUPPLY_KEY, Long.toString(supply));
    }

    private void emitEvent(final Context ctx, final String name, final String subject, final long amount) {
        final ChaincodeStub stub = ctx.getStub();
        final String payload = String.format(
                "{\"subject\":\"%s\",\"amount\":%d,\"txId\":\"%s\"}", subject, amount, stub.getTxId());
        stub.setEvent(name, payload.getBytes(StandardCharsets.UTF_8));
    }
}
