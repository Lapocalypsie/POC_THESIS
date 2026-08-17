package poc.dvp;

import org.hyperledger.fabric.contract.Context;
import org.hyperledger.fabric.contract.ContractInterface;
import org.hyperledger.fabric.contract.annotation.Contract;
import org.hyperledger.fabric.contract.annotation.Info;
import org.hyperledger.fabric.contract.annotation.Transaction;
import org.hyperledger.fabric.shim.ChaincodeException;

/**
 * Plan de controle banque centrale (flux C, R14) - contrat distinct du cycle
 * de reglement, dans le meme chaincode : la separation des responsabilites du
 * code reflete la separation institutionnelle des plans (reglement vs controle).
 * Invocation : "dvpAdmin:pause", "dvpAdmin:setEligibility", etc.
 */
@Contract(
        name = "dvpAdmin",
        info = @Info(
                title = "Central bank control plane",
                description = "Reserved operations C1 (pause), admission (R03), compliance cap (R16)"))
public final class CentralBankOperations implements ContractInterface {

    private static final String CENTRAL_BANK_MSP = "CentralBankMSP";

    /** C1 - suspension du reglement. Les trades deja commites ne sont pas defaits. */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public void pause(final Context ctx, final String reason) {
        requireCentralBank(ctx, "pause");
        ctx.getStub().putStringState(DvPStore.PAUSE_KEY,
                reason == null || reason.isEmpty() ? "paused" : reason);
        DvPStore.emitEvent(ctx, "SettlementPaused", reason);
    }

    /** C1 - reprise du reglement. */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public void unpause(final Context ctx) {
        requireCentralBank(ctx, "unpause");
        ctx.getStub().delState(DvPStore.PAUSE_KEY);
        DvPStore.emitEvent(ctx, "SettlementResumed", "");
    }

    /** Admission d'un participant au reglement (R03, couche L2). */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public void setEligibility(final Context ctx, final String msp, final String eligible) {
        requireCentralBank(ctx, "setEligibility");
        if (Boolean.parseBoolean(eligible)) {
            ctx.getStub().putStringState(DvPStore.ELIGIBLE_PREFIX + msp, "true");
        } else {
            ctx.getStub().delState(DvPStore.ELIGIBLE_PREFIX + msp);
        }
    }

    /** Plafond de conformite par trade (parametrage du controle R16). 0 = aucun. */
    @Transaction(intent = Transaction.TYPE.SUBMIT)
    public void setComplianceCap(final Context ctx, final String cap) {
        requireCentralBank(ctx, "setComplianceCap");
        ctx.getStub().putStringState(DvPStore.CAP_KEY, Long.toString(Long.parseLong(cap)));
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
}
