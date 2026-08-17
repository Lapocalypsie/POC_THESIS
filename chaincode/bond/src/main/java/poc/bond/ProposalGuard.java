package poc.bond;

import com.google.protobuf.InvalidProtocolBufferException;
import org.hyperledger.fabric.contract.Context;
import org.hyperledger.fabric.protos.common.ChannelHeader;
import org.hyperledger.fabric.protos.common.Header;
import org.hyperledger.fabric.protos.peer.ChaincodeHeaderExtension;
import org.hyperledger.fabric.protos.peer.Proposal;
import org.hyperledger.fabric.protos.peer.SignedProposal;
import org.hyperledger.fabric.shim.ChaincodeException;

/**
 * Garde d'invocation des fonctions de reglement (*ForTrade) : leur autorisation
 * derive du trade cosigne (R05), pas de l'identite de l'appelant - mais elles
 * ne doivent etre atteignables QUE via le coordinateur dvp, sinon un client
 * pourrait executer une jambe sans l'autre et briser l'invariant DvP.
 * La proposal signee par le client fixe le chaincode cible de la transaction :
 * on la lit pour verifier que la cible est bien "dvp".
 *
 * Les donnees du trade sont passees en ARGUMENTS par le coordinateur (qui les
 * tient du trade cosigne) : un rappel bond->dvp.getTrade est impossible,
 * Fabric interdisant l'invocation cyclique dans une meme transaction.
 */
final class ProposalGuard {

    private static final String DVP_CHAINCODE = "dvp";

    private ProposalGuard() {
    }

    static void requireInvokedViaDvp(final Context ctx, final String operation) {
        final String target;
        try {
            final SignedProposal signed = ctx.getStub().getSignedProposal();
            final Proposal proposal = Proposal.parseFrom(signed.getProposalBytes());
            final Header header = Header.parseFrom(proposal.getHeader());
            final ChannelHeader channelHeader = ChannelHeader.parseFrom(header.getChannelHeader());
            final ChaincodeHeaderExtension extension =
                    ChaincodeHeaderExtension.parseFrom(channelHeader.getExtension());
            target = extension.getChaincodeId().getName();
        } catch (InvalidProtocolBufferException e) {
            throw new ChaincodeException(
                    operation + ": cannot verify the invocation context: " + e.getMessage(),
                    "UNAUTHORIZED");
        }
        if (!DVP_CHAINCODE.equals(target)) {
            throw new ChaincodeException(String.format(
                    "%s is only invocable through the dvp coordinator; the signed proposal targets '%s'",
                    operation, target), "UNAUTHORIZED");
        }
    }
}
