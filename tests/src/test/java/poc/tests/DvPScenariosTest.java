package poc.tests;

import org.hyperledger.fabric.client.Contract;
import org.hyperledger.fabric.client.GatewayException;
import org.hyperledger.fabric.protos.gateway.ErrorDetail;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestInstance;
import org.junit.jupiter.api.TestMethodOrder;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Suite T1-T9 du chapitre 5 (section 5.4) : un test par scenario fixe a la
 * section 3.6.3, execute bout-en-bout contre le reseau reel via le Gateway.
 * Chaque scenario verifie (i) l'etat terminal atteint et (ii) l'invariant DvP
 * (section 5.1) : les titres sont transferes si et seulement si le cash l'est,
 * observe sur les quatre soldes avant/apres. Aucun mock.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class DvPScenariosTest {

    private static final String ISIN = "FR0001";
    private static final Pattern STATUS = Pattern.compile("\"status\":\"([A-Z_]+)\"");

    private Fabric cb;
    private Fabric bankA;
    private Fabric bankB;
    private Contract dvpA;
    private Contract dvpB;
    private Contract admin;
    private Contract wcbdcCB;
    private Contract wcbdcA;
    private Contract bondA;
    private String run;
    private String settledTrade;

    @BeforeAll
    void setUp() throws Exception {
        cb = Fabric.connect("centralbank", "CentralBankMSP", 7051);
        bankA = Fabric.connect("banka", "BankAMSP", 9051);
        bankB = Fabric.connect("bankb", "BankBMSP", 10051);
        dvpA = bankA.contract("dvp");
        dvpB = bankB.contract("dvp");
        admin = cb.contract("dvp", "dvpAdmin");
        wcbdcCB = cb.contract("wcbdc");
        wcbdcA = bankA.contract("wcbdc");
        bondA = bankA.contract("bond");
        run = Long.toString(System.currentTimeMillis() % 100_000_000L);
        // Etat prealable requis (L2/R16): participants admis, plafond fixe,
        // reglement non suspendu. Idempotent.
        cb.submit(admin, "setEligibility", "BankAMSP", "true");
        cb.submit(admin, "setEligibility", "BankBMSP", "true");
        cb.submit(admin, "setComplianceCap", "10000000");
        cb.submit(admin, "unpause");
    }

    @AfterAll
    void tearDown() {
        for (Fabric f : new Fabric[] {cb, bankA, bankB}) {
            if (f != null) {
                f.close();
            }
        }
    }

    // ------------------------------------------------------------------
    // Scenarios
    // ------------------------------------------------------------------

    @Test
    @Order(1)
    @DisplayName("T1 - happy path: PROPOSED -> PENDING -> SETTLED, les deux jambes bougent (R05)")
    void t1_happyPath() throws Exception {
        final long[] before = snapshot();
        final String id = trade("T1");
        assertEquals("PROPOSED", propose(id, 1000, 950, 300, 600));
        assertEquals("PENDING", bankA.submit(dvpA, "confirmTrade", id));
        assertEquals("SETTLED", bankB.submit(dvpB, "executeSettlement", id));
        assertEquals("SETTLED", status(id));
        assertInvariantSettled(before, 1000, 950);
        settledTrade = id;
    }

    @Test
    @Order(2)
    @DisplayName("T2 - escrow jamais finance -> RELEASED_BUSINESS, aucune jambe ne bouge (R09/R10)")
    void t2_escrowBusinessTimeout() throws Exception {
        final long[] before = snapshot();
        final String id = trade("T2");
        assertEquals("PROPOSED", propose(id, 1000, 9_000_000L, 8, 300));
        assertEquals("PENDING", bankA.submit(dvpA, "confirmTrade", id));
        assertEquals("ESCROW_WAITING", bankB.submit(dvpB, "executeSettlement", id));
        Thread.sleep(10_000);
        assertEquals("RELEASED_BUSINESS", bankA.submit(dvpA, "releaseExpired", id));
        assertEquals("RELEASED_BUSINESS", status(id));
        assertInvariantUntouched(before);
    }

    @Test
    @Order(3)
    @DisplayName("T2bis - escrow puis on-ramp C2 -> SETTLED (R09)")
    void t2bis_escrowFundedSettles() throws Exception {
        final long[] before = snapshot();
        final long shortfall = 500_000L;
        final long mint = 600_000L;
        final long cashAmount = before[3] + shortfall;
        final String id = trade("T2B");
        assertEquals("PROPOSED", propose(id, 2000, cashAmount, 3600, 7200));
        assertEquals("PENDING", bankA.submit(dvpA, "confirmTrade", id));
        assertEquals("ESCROW_WAITING", bankB.submit(dvpB, "executeSettlement", id));
        cb.submit(wcbdcCB, "mint", "BankBMSP", Long.toString(mint));
        assertEquals("SETTLED", bankB.submit(dvpB, "executeSettlement", id));
        final long[] after = snapshot();
        assertEquals(before[0] - 2000, after[0], "titres vendeur");
        assertEquals(before[1] + 2000, after[1], "titres acheteur");
        assertEquals(before[2] + cashAmount, after[2], "cash vendeur");
        assertEquals(before[3] + mint - cashAmount, after[3], "cash acheteur (mint - prix)");
    }

    @Test
    @Order(4)
    @DisplayName("T3 - filet de securite -> RELEASED_SAFETY (R10)")
    void t3_safetyTimeout() throws Exception {
        final long[] before = snapshot();
        final String id = trade("T3");
        assertEquals("PROPOSED", propose(id, 1000, 9_000_000L, 2, 4));
        assertEquals("PENDING", bankA.submit(dvpA, "confirmTrade", id));
        assertEquals("ESCROW_WAITING", bankB.submit(dvpB, "executeSettlement", id));
        Thread.sleep(2_000);
        assertEquals("RELEASED_SAFETY", bankA.submit(dvpA, "releaseExpired", id));
        assertInvariantUntouched(before);
    }

    @Test
    @Order(5)
    @DisplayName("T4 - rejet compliance: plafond R16 depasse -> REJECTED_COMPLIANCE")
    void t4_complianceRejection() throws Exception {
        final long[] before = snapshot();
        final String id = trade("T4");
        assertEquals("REJECTED_COMPLIANCE", propose(id, 1000, 20_000_000L, 300, 600));
        assertEquals("REJECTED_COMPLIANCE", status(id));
        assertInvariantUntouched(before);
    }

    @Test
    @Order(6)
    @DisplayName("T5 - echec eligibilite: partie non admise -> REJECTED_INELIGIBLE (R03)")
    void t5_eligibilityFailure() throws Exception {
        final long[] before = snapshot();
        final String id = trade("T5");
        final String result = bankB.submit(dvpB, "proposeTrade", id, "BankBMSP", "CSDMSP",
                ISIN, "1000", "950", "EUR", "300", "600");
        assertEquals("REJECTED_INELIGIBLE", result);
        assertInvariantUntouched(before);
    }

    @Test
    @Order(7)
    @DisplayName("T6 - pause C1: reglement suspendu, reprise; pause reservee (R14)")
    void t6_pauseC1() throws Exception {
        cb.submit(admin, "pause", "test T6");
        try {
            final GatewayException blocked = assertThrows(GatewayException.class,
                    () -> propose(trade("T6"), 1000, 950, 300, 600));
            assertRefusalMentions(blocked, "paused");
            final Contract adminAsBank = bankA.contract("dvp", "dvpAdmin");
            assertThrows(GatewayException.class,
                    () -> bankA.submit(adminAsBank, "pause", "tentative illegitime"));
        } finally {
            cb.submit(admin, "unpause");
        }
        assertEquals("PROPOSED", propose(trade("T6R"), 1000, 950, 300, 600));
    }

    @Test
    @Order(8)
    @DisplayName("T7 - operations reservees: mint wCBDC hors banque centrale refuse (R14)")
    void t7_reservedOperations() throws Exception {
        final long supplyBefore = Long.parseLong(bankA.evaluate(wcbdcA, "totalSupply"));
        assertThrows(GatewayException.class,
                () -> bankA.submit(wcbdcA, "mint", "BankAMSP", "9999999"));
        assertEquals(supplyBefore, Long.parseLong(bankA.evaluate(wcbdcA, "totalSupply")),
                "l'offre totale n'a pas bouge apres le refus");
    }

    @Test
    @Order(9)
    @DisplayName("T8 - contournement: une jambe seule est inexecutable (ProposalGuard)")
    void t8_bypassAttempt() throws Exception {
        final long[] before = snapshot();
        final Contract bondSettlement = bankB.contract("bond", "bondSettlement");
        final GatewayException ex = assertThrows(GatewayException.class,
                () -> bankB.submit(bondSettlement, "transferForTrade",
                        settledTrade, "BankAMSP", "BankBMSP", ISIN, "1000"));
        assertRefusalMentions(ex, "dvp coordinator");
        assertInvariantUntouched(before);
    }

    @Test
    @Order(10)
    @DisplayName("T9 - pas de double reglement: rejouer un trade SETTLED est refuse")
    void t9_replayProtection() throws Exception {
        final long[] before = snapshot();
        assertThrows(GatewayException.class,
                () -> bankB.submit(dvpB, "executeSettlement", settledTrade));
        assertEquals("SETTLED", status(settledTrade));
        assertInvariantUntouched(before);
    }

    // ------------------------------------------------------------------
    // Helpers - l'invariant DvP observe sur les quatre soldes (section 5.1)
    // ------------------------------------------------------------------

    private String trade(final String name) {
        return "J" + name + "-" + run;
    }

    /**
     * Verifie le motif du refus. Le Gateway SDK range le message du chaincode
     * dans les details gRPC par endosseur (getDetails), pas dans getMessage.
     */
    private void assertRefusalMentions(final GatewayException ex, final String needle) {
        final StringBuilder all = new StringBuilder(String.valueOf(ex.getMessage()));
        for (ErrorDetail detail : ex.getDetails()) {
            all.append(" | ").append(detail.getMessage());
        }
        assertTrue(all.toString().contains(needle), all.toString());
    }

    private String propose(final String id, final long bondAmount, final long cashAmount,
            final long businessSec, final long safetySec) throws Exception {
        return bankB.submit(dvpB, "proposeTrade", id, "BankBMSP", "BankAMSP", ISIN,
                Long.toString(bondAmount), Long.toString(cashAmount), "EUR",
                Long.toString(businessSec), Long.toString(safetySec));
    }

    private String status(final String tradeId) throws Exception {
        final Matcher m = STATUS.matcher(bankA.evaluate(dvpA, "getTrade", tradeId));
        assertTrue(m.find(), "statut introuvable pour " + tradeId);
        return m.group(1);
    }

    /** {titres vendeur, titres acheteur, cash vendeur, cash acheteur}. */
    private long[] snapshot() throws Exception {
        return new long[] {
            Long.parseLong(bankA.evaluate(bondA, "balanceOf", ISIN, "BankAMSP")),
            Long.parseLong(bankA.evaluate(bondA, "balanceOf", ISIN, "BankBMSP")),
            Long.parseLong(bankA.evaluate(wcbdcA, "balanceOf", "BankAMSP")),
            Long.parseLong(bankA.evaluate(wcbdcA, "balanceOf", "BankBMSP")),
        };
    }

    /** Invariant, branche "les deux jambes ont bouge, des montants convenus". */
    private void assertInvariantSettled(final long[] before, final long bondAmount,
            final long cashAmount) throws Exception {
        final long[] after = snapshot();
        assertEquals(before[0] - bondAmount, after[0], "titres vendeur");
        assertEquals(before[1] + bondAmount, after[1], "titres acheteur");
        assertEquals(before[2] + cashAmount, after[2], "cash vendeur");
        assertEquals(before[3] - cashAmount, after[3], "cash acheteur");
    }

    /** Invariant, branche "aucune jambe n'a bouge". */
    private void assertInvariantUntouched(final long[] before) throws Exception {
        final long[] after = snapshot();
        for (int i = 0; i < before.length; i++) {
            assertEquals(before[i], after[i], "solde " + i + " a bouge sans reglement");
        }
    }
}
