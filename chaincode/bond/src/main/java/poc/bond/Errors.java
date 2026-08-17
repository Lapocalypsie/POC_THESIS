package poc.bond;

/** Codes d'erreur metier du contrat titres, portes par les ChaincodeException. */
enum Errors {
    UNAUTHORIZED,
    NOT_FOUND,
    ALREADY_EXISTS,
    INVALID_AMOUNT,
    INVALID_STATE,
    INSUFFICIENT_AVAILABLE
}
