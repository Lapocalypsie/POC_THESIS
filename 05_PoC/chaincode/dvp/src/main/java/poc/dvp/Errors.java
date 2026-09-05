package poc.dvp;

/** Codes d'erreur metier du coordinateur, portes par les ChaincodeException. */
enum Errors {
    UNAUTHORIZED,
    NOT_FOUND,
    ALREADY_EXISTS,
    INVALID_AMOUNT,
    INVALID_STATE,
    SETTLEMENT_PAUSED,
    NOT_EXPIRED,
    CROSS_CHAINCODE_FAILURE
}
