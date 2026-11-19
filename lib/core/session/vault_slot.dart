/// Bóveda de la app (v2 fase 8, `docs/DISENO_SENUELO.md`).
///
/// * [primary]: la bóveda principal (la de siempre: onboarding, Drive,
///   código de recuperación, rotación). Sus rutas, claves y BD no cambian.
/// * [secondary]: la bóveda secundaria («señuelo», variante disimulo), con
///   otra DEK, otros archivos (`Documents/alt/`) y otra BD; sin nube.
///
/// Solo hay una bóveda desbloqueada a la vez.
enum VaultSlot { primary, secondary }
