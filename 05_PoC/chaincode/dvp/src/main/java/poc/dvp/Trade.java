package poc.dvp;

/**
 * Etat d'un trade dans la machine a etats du coordinateur DvP (section 5.2).
 * Serialise en JSON dans le world state sous la cle "trade:<tradeId>".
 * Les statuts terminaux sont ceux sur lesquels l'invariant DvP est verifie
 * (section 5.1) : l'ensemble est fini et ferme.
 */
public final class Trade {

    // Etats non terminaux
    public static final String PROPOSED = "PROPOSED";                     // I3 recu, 1re signature
    public static final String PENDING = "PENDING";                       // cosigne (R05)
    public static final String ESCROW_WAITING = "ESCROW_WAITING";         // provision insuffisante (R09)

    // Etats terminaux (invariant verifie sur chacun)
    public static final String SETTLED = "SETTLED";                       // les deux jambes ont bouge
    public static final String REJECTED_COMPLIANCE = "REJECTED_COMPLIANCE";   // R16
    public static final String REJECTED_INELIGIBLE = "REJECTED_INELIGIBLE";   // R03
    public static final String RELEASED_BUSINESS = "RELEASED_BUSINESS";   // timeout metier (R10)
    public static final String RELEASED_SAFETY = "RELEASED_SAFETY";       // filet de securite (R10)

    public String tradeId;
    public String buyerMsp;
    public String sellerMsp;
    public String proposerMsp;
    public String isin;
    public long bondAmount;
    public long cashAmount;
    public String currency;
    public String status;
    public long businessTimeoutTs;
    public long safetyTimeoutTs;
    public String reason;
}
