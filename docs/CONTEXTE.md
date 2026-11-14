# Contexte projet : Accélération de WRF-RRTMG par PINN / émulateur neuronal

## 1. Objectif

Accélérer la simulation WRF en remplaçant les routines les plus coûteuses du schéma
radiatif RRTMG (`taumol_sw` / `taumol_lw`, calcul des épaisseurs optiques gazeuses)
par un réseau de neurones « physics-informed » (contraintes physiques douces), avec
intégration Fortran ↔ C++ ↔ PyTorch (TorchScript) dans WRF.

Source : étude préalable Perplexity (document de l'utilisateur, 4 sections :
coût des routines, interfaces `taumol_*`, architecture PINN, pipeline de données).

## 2. Faits vérifiés (contre code source et documentation officiels)

- WRF sélectionne RRTMG via `LW_PHYSICS = RRTMG_LWSCHEME` / `SW_PHYSICS = RRTMG_SWSCHEME`
  dans `phys/module_radiation_driver.F` ; les points d'entrée sont `rrtmg_lwrad` / `rrtmg_swrad`.
- **RRTMG_SW : 14 bandes spectrales (numérotées 16–29), 224 g-points AU TOTAL**
  (répartition inégale, 2–16 g-points par bande ; la version AER standalone est réduite à 112,
  mais WRF utilise 224 — `ngptsw = 224` confirmé dans `phys/module_ra_rrtmg_sw.F`).
- **RRTMG_LW : 16 bandes, 140 g-points au total** (`ngptlw = 140`).
- Signature réelle de `taumol_sw` (confirmée, ex. DALES/AER `rrtmg_sw_taumol.f90`) :
  entrées `nlayers, laytrop, jp, jt, jt1, colh2o, colco2, colch4, colo2, colo3, colmol,
  fac00, fac01, fac10, fac11, selffac, selffrac, indself, forfac, forfrac, indfor` ;
  sorties `sfluxzen` (224), `taug(nlayers,224)`, `taur(nlayers,224)`.
- `taumol_lw` : sorties `taug(nlayers,140)` et `fracs` (fractions de Planck, nécessaires
  à l'émission thermique). Le LW inclut N₂O (`coln2o`) ; le SW n'a pas de `for*` exactement
  comme décrit dans le document.
- Le coût élevé de `taumol_*` vient de l'interpolation dans les tables k-distribution
  (pression × température × espèce) pour chaque couche × g-point, avec branches
  basse/haute atmosphère (`laytrop`). Les portages GPU/MIC (Iacono et al., DOE 2014)
  rapportent des accélérations ~7–13× sur le couple LW/SW, ce qui confirme que ces
  boucles sont le goulot et qu'elles se parallélisent bien par colonne.
- La radiation est appelée tous les `radt` minutes (typ. 20–30 min en production),
  sur toutes les colonnes du domaine MPI-local → le batching naturel pour un NN
  est « toutes les colonnes × toutes les couches » d'un tile.

## 3. Erreurs et approximations du document à corriger

| Affirmation du document | Correction |
| :-- | :-- |
| « 16 bandes × 140 g-points → ≈ 2 240 profils » (LW) | 16 bandes totalisant **140** g-points ; pas de multiplication |
| « 14 bandes × 224 g-points → ≈ 3 136 profils » (SW) | 14 bandes totalisant **224** g-points (WRF) ; la confusion vient de RRTM-SW « pleine » (14×16) |
| « interpolation 4-D (T, P, espèce, η) » | En réalité interpolations **2-D (P,T) par espèce/bande** + termes de continuum (self/foreign) ; la structure est par bande, pas un tenseur 4-D unique |
| Speedups « 10–15× CPU, 50–120× GPU, 200–400× large batch » | **Spéculatifs** : empruntés à des portages GPU de RRTMG, pas à des émulateurs NN. Aucun benchmark d'émulateur `taumol` publié ne soutient ces chiffres |
| « Conservation d'énergie < 0,01 % garantie par PINN » | Un PINN à contraintes **douces** ne garantit rien ; seule une contrainte dure (ex. normalisation exacte des `fracs` par une couche Softmax) garantit Σfracs = 1 |
| Terme « PINN » | C'est en réalité un **émulateur supervisé avec pénalités physiques** (soft-constrained surrogate), pas un PINN au sens strict (pas de résidu d'EDP de transfert radiatif). Le terme « physics-constrained NN » est plus exact |

## 4. Évaluation de faisabilité

### Faisable et solide
- **Cibler `taumol_*`** est pertinent : c'est le cœur bouclé du coût radiatif, l'entrée/sortie
  est bien définie, et remplacer uniquement les épaisseurs optiques **conserve le solveur
  deux-flux et les propriétés nuageuses de RRTMG** → l'architecture reste physiquement
  contrainte en aval (meilleur choix qu'émuler les flux directement, au prix d'une sortie
  de haute dimension : 224+140 valeurs par couche).
- Le batching par colonnes est naturel et massivement parallèle ; TorchScript + interface
  C (ISO_C_BINDING) + C++ libtorch est une intégration standard et éprouvée.
- Les contraintes proposées (positivité via softplus, Σfracs=1, monotonie τ(H₂O) ≥ 0,
  bornes 0 ≤ τ ≤ 100) sont pertinentes et faciles à imposer.
- La littérature (émulateurs de radiation : Ukkonen et al. 2022/2023, Crane, PASC 2023,
  arXiv:2504.14542) montre que des émulateurs NN de schémas radiatifs atteignent des
  erreurs de type ~1 W m⁻² / ~0,1 K jour⁻¹ — les cibles du document sont donc
  ambitieuses mais réalistes **pour les flux/heating rates**, pas nécessairement
  pour τ g-point par g-point.

### Risques / points ouverts
1. **Dimension de sortie** : 364 valeurs par couche (taug SW+LW, taur, fracs). Prédire
   τ en échelle log est quasi obligatoire (τ couvre plusieurs ordres de grandeur).
   Alternative à évaluer : émuler directement flux/heating rates (moins de dimensions,
   plus de littérature, mais on perd la contrainte du solveur deux-flux).
2. **Généralisation hors distribution** : le document suppose que le NN généralise ;
   en pratique, des profils extrêmes non vus à l'entraînement peuvent produire des τ
   aberrants. Nécessite un fallback (repli sur le RRTMG fortran si entrée hors gamme)
   et une couverture d'entraînement très large (le pipeline de perturbations du
   document va dans le bon sens, mais T±50 K et P×[0,8,1,2] créent aussi des profils
   non physiques qu'il faut étiqueter comme tels, pas seulement « filtrer »).
3. **Overhead d'appel** : dans WRF, `taumol` est appelé colonne par colonne via
   `setcoef` ; passer par un wrapper Fortran→C→TorchScript **par colonne** annulerait
   le gain. Il faut restructurer l'appel au niveau du driver pour batcher toutes les
   colonnes du tile en une seule inférence (modification plus invasive de
   `module_ra_rrtmg_*` que le simple « remplacer le CALL » suggéré).
4. **Loi d'Amdahl** : la radiation représente une fraction variable du runtime WRF
   (souvent 10–30 % en production avec `radt` raisonnable). Même un émulateur 20×
   plus rapide sur `taumol` ne donnera qu'un speedup WRF global modeste. À quantifier
   par profilage (TAU/perf) sur le cas d'usage visé avant d'investir.
5. **McICA** : RRTMG échantillonne stochastiquement les nuages ; l'émulateur doit
   préserver ce comportement (ou être entraîné sur les états échantillonnés).
6. **Alternatives existantes** à benchmarker avant d'écrire du code : portage GPU de
   RRTMG (RRTMGP "GPU-ready", work DOE), réduction de g-points (déjà 224→112 possible),
   augmentation de `radt`, et RRTMGP (successeur, plus rapide et plus simple à
   accélérer). Le projet doit démontrer qu'il bat ces baselines.

### Verdict
**Faisable techniquement**, avec un intérêt réel confirmé par la littérature sur les
émulateurs radiatifs, MAIS : (a) les chiffres de speedup du document sont non fondés,
(b) l'intégration WRF est plus invasive que décrite (batching au niveau du driver,
pas du CALL), (c) le gain global WRF dépend de la loi d'Amdahl et doit être mesuré
tôt, (d) il faut choisir explicitement entre émuler `taug/fracs` (physique conservée,
sortie haute dimension) et émuler les flux (plus simple, littérature plus fournie).

## 5. Plan recommandé (phase 1)

1. **Profilage** : instrumenter un cas WRF de référence (TAU or `-pg`) pour mesurer la
   part réelle de `rrtmg_lw/swrad` et de `taumol_*` — valide ou invalide la prémisse.
2. **Harness standalone** : extraire `taumol_sw/lw` de WRF (ou utiliser RRTMG AER)
   dans un binaire offline appelable depuis Python (f2py/ctypes) → génération de
   données (entrées `setcoef` + sorties `taug/taur/fracs/sfluxzen`).
3. **Dataset** : profils réels (RFMIP/CKDMIP, radiosondages IGRA, sorties WRF) +
   perturbations physiquement plausibles ; split par profil source (éviter fuite
   train/test comme le note le document) ; stockage HDF5.
4. **Modèle v0** : MLP résiduel, entrées log-colonnes + (T,P), sorties log(τ) ;
   contraintes dures (softplus, softmax pour fracs) ; pertes MSE + physique.
   Baseline obligatoire : régression linéaire / petit MLP par bande.
5. **Évaluation physique** : ne pas juger sur le MSE de τ, mais sur les **flux et
   heating rates** recalculés par le solveur deux-flux avec les τ prédits
   (métrique : W m⁻², K/jour) — c'est la métrique de la littérature.
6. **Intégration** : seulement ensuite, wrapper ISO_C_BINDING + libtorch, batch par
   tile, fallback RRTMG fortran si entrée hors distribution.

## 6. Glossaire

- **g-point** : quadrature de la distribution k corrélée ; RRTMG-LW 140, RRTMG-SW 224 (WRF).
- **k-distribution corrélée** : reformulation du spectre en fonction cumulative g,
  permettant de réduire le calcul spectral à ~140–224 quadratures.
- **fracs** : fractions de Planck (poids d'émission thermique par g-point, Σ = 1).
- **setcoef** : routine amont qui calcule les indices/facteurs d'interpolation
  (`jp, jt, fac00...`) — l'émulateur peut soit consommer ces indices, soit
  directement (T, P, gaz) et remplacer `setcoef` aussi.
- **McICA** : échantillonnage stochastique des nuages indépendant par colonne.
- **Two-stream solver** : solveur à deux flux (montant/descendant) en aval de taumol.

## 7. Sources clés vérifiées

- Code WRF : `phys/module_ra_rrtmg_sw.F`, `phys/module_ra_rrtmg_lw.F`,
  `phys/module_radiation_driver.F` (github.com/wrf-model/WRF, master).
- AER RRTMG_SW/LW : github.com/AER-RC/RRTMG_SW (112 g-points, standalone),
  github.com/AER-RC/RRTMG_LW.
- DTC/CCPP sci-doc : 14 bandes SW, 224 g-points, deux-flux — dtcenter.ucar.edu.
- Iacono et al. (DOE, 2014) : portages GPU/MIC de RRTMG dans WRF, 7–13×.
- Littérature émulateurs : Ukkonen et al. (GMD/JAMES 2022–2023),
  10.1029/2022MS003419 (10–25 % CPU pour < 1 W m⁻²), PASC 2023 pos133,
  arXiv:2504.14542 (2025).
