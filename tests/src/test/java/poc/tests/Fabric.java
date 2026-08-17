package poc.tests;

import io.grpc.Grpc;
import io.grpc.ManagedChannel;
import io.grpc.TlsChannelCredentials;
import org.hyperledger.fabric.client.Contract;
import org.hyperledger.fabric.client.Gateway;
import org.hyperledger.fabric.client.GatewayException;
import org.hyperledger.fabric.client.Network;
import org.hyperledger.fabric.client.identity.Identities;
import org.hyperledger.fabric.client.identity.Signers;
import org.hyperledger.fabric.client.identity.X509Identity;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.PrivateKey;
import java.security.cert.X509Certificate;
import java.util.concurrent.TimeUnit;
import java.util.stream.Stream;

/**
 * Connexion Gateway d'une organisation au reseau du PoC. Chaque instance =
 * une institution parlant a SON peer avec SON identite (User1) - la geometrie
 * institutionnelle du reseau est respectee jusque dans le harnais de test.
 * Les certificats sont ceux generes par cryptogen (montes sous CRYPTO_ROOT).
 */
final class Fabric implements AutoCloseable {

    private static final String CRYPTO = System.getenv().getOrDefault("CRYPTO_ROOT", "/crypto");
    private static final String CHANNEL = "dvp-channel";

    private final Gateway gateway;
    private final Network network;
    private final ManagedChannel channel;

    static Fabric connect(final String org, final String msp, final int port) throws Exception {
        final String domain = org + ".dvp.poc";
        final Path base = Paths.get(CRYPTO, "peerOrganizations", domain);
        final String user = "User1@" + domain;
        final Path certPath = base.resolve(Paths.get("users", user, "msp", "signcerts", user + "-cert.pem"));
        final Path keyDir = base.resolve(Paths.get("users", user, "msp", "keystore"));
        final Path tlsCa = base.resolve(Paths.get("peers", "peer0." + domain, "tls", "ca.crt"));

        final ManagedChannel grpcChannel = Grpc.newChannelBuilder(
                        "peer0." + domain + ":" + port,
                        TlsChannelCredentials.newBuilder().trustManager(tlsCa.toFile()).build())
                .build();

        final X509Certificate certificate;
        try (var reader = Files.newBufferedReader(certPath)) {
            certificate = Identities.readX509Certificate(reader);
        }
        final PrivateKey privateKey;
        try (Stream<Path> keys = Files.list(keyDir)) {
            final Path keyPath = keys.findFirst().orElseThrow(
                    () -> new IllegalStateException("no private key in " + keyDir));
            try (var reader = Files.newBufferedReader(keyPath)) {
                privateKey = Identities.readPrivateKey(reader);
            }
        }
        final Gateway gw = Gateway.newInstance()
                .identity(new X509Identity(msp, certificate))
                .signer(Signers.newPrivateKeySigner(privateKey))
                .connection(grpcChannel)
                .connect();
        return new Fabric(gw, grpcChannel);
    }

    private Fabric(final Gateway gateway, final ManagedChannel channel) {
        this.gateway = gateway;
        this.channel = channel;
        this.network = gateway.getNetwork(CHANNEL);
    }

    Contract contract(final String chaincode) {
        return network.getContract(chaincode);
    }

    Contract contract(final String chaincode, final String contractName) {
        return network.getContract(chaincode, contractName);
    }

    String evaluate(final Contract contract, final String fn, final String... args)
            throws GatewayException {
        return new String(contract.evaluateTransaction(fn, args), StandardCharsets.UTF_8);
    }

    String submit(final Contract contract, final String fn, final String... args) throws Exception {
        return new String(contract.submitTransaction(fn, args), StandardCharsets.UTF_8);
    }

    @Override
    public void close() {
        gateway.close();
        channel.shutdownNow();
        try {
            channel.awaitTermination(5, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
