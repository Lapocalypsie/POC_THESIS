package poc.bond;

/** Fiche d'emission - le golden record de l'emission (R06). */
public final class Issuance {

    public static final String PENDING_MINT = "pending_mint";
    public static final String ACTIVE = "active";

    public String isin;
    public String issuerMsp;
    public long totalAmount;
    public String currency;
    public String maturity;
    public String status;
}
