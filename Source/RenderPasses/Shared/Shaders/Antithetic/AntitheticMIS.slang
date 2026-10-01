/** Balance-heuristic MIS for antithetic sampling.

    A primal direction w is sampled from the BSDF with density p, and a randomly chosen map T_i gives its
    antithetic partner w_a = T_i(w), with Jacobian J = |dw_a / dw|. The maps come in inverse pairs
    (T_j = T_i^-1) chosen with equal probability; a map may be its own inverse. Then:
    - the antithetic sample has density q_i(w_a) = p(w) / J,
    - the primal sample is weighted against the other map of the pair, whose density at w is
      q_j(w) = p(w_a) * J, so no second mapped point is needed.
    Each estimate on its own is biased; averaged over the choice of map it is unbiased. This needs the maps
    to be exact inverses and to fail together: T_i must fail at w exactly when w is outside the image of T_j.
*/

/** Estimate of the primal sample and its antithetic partner.
    @param[in] primalEstimate f(w) / p(w).
    @param[in] primalPdf p(w), the BSDF density of the primal direction.
    @param[in] antitheticValue f(w_a).
    @param[in] antitheticBsdfPdf p(w_a), the BSDF density of the antithetic direction.
    @param[in] jacobian |dw_a / dw|, greater than zero.
*/
float3 combineAntithetic(float3 primalEstimate, float primalPdf, float3 antitheticValue, float antitheticBsdfPdf,
    float jacobian)
{
    float mappedPdf = primalPdf / jacobian;         // q_i(w_a)
    float reversePdf = antitheticBsdfPdf * jacobian; // q_j(w)
    float primalWeight = primalPdf / (primalPdf + reversePdf);
    float antitheticWeight = mappedPdf / (mappedPdf + antitheticBsdfPdf);
    return primalWeight * primalEstimate + antitheticWeight * antitheticValue / mappedPdf;
}
