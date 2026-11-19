// taumol_sw / taumol (RRTMG) par un TorchScript (pinn/train_v0.py --export).
// Appele depuis le shell Fortran (pinn_shell_sw.inc / pinn_shell_lw.inc) insere
// dans module_ra_rrtmg_sw.F / module_ra_rrtmg_lw.F par patch_wrf.sh.
// Layout des entrees/sorties = Fortran column-major : play[i + k*ncol] (i=colonne,
// k=couche 0..nlay-1), plev[i + l*ncol] (l=0..nlay), taug[i + k*ncol + ig*ncol*nlay].
// Features = train_v0.build_features (14 features/niveau), le modele fait la
// normalisation en interne (buffers feat_mean/feat_std).
//
// ROBUSTESSE : le shell Fortran peut passer une chaine non terminee par NUL
// (buffer rempli de blancs) -> lecture bornee (strnlen) + strip des blancs/NUL
// de fin. Toute exception est rattrapee : init -> g_on=false, precompute ->
// retourne 0, et le shell Fortran retombe sur taumol_sw_ref / taumol_ref
// (jamais d'abort du run).
#include <torch/script.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <vector>
#include <string>

static torch::jit::script::Module g_model;
static bool g_on = false;

static void build_X(int ncol, int nlay,
                    const float* play, const float* plev, const float* tlev, const float* tsfc,
                    const float* h2o, const float* o3, const float* co2, const float* ch4,
                    const float* n2o, const float* o2, torch::Tensor& X) {
  const int L = nlay + 1;
  X = torch::zeros({ncol, L, 14}, torch::kFloat32);
  auto xa = X.accessor<float, 3>();
  std::vector<double> dp(nlay), tlayc(nlay), h2oc(nlay), o3c(nlay);
  for (int i = 0; i < ncol; i++) {
    for (int k = 0; k < nlay; k++) {
      dp[k] = (double)plev[i + k * ncol] - (double)plev[i + (k + 1) * ncol];
      tlayc[k] = 0.5 * ((double)tlev[i + k * ncol] + (double)tlev[i + (k + 1) * ncol]);
      h2oc[k] = h2o[i + k * ncol];
      o3c[k] = o3[i + k * ncol];
    }
    std::vector<double> h2on(L), o3n(L), co2n(L), ch4n(L), n2on(L), o2n(L), tlayn(L), dpn(L), colh(L), colo(L);
    auto to_niv = [&](const float* c, std::vector<double>& v) {
      v[0] = c[i];
      v[L - 1] = c[i + (nlay - 1) * ncol];
      for (int k = 1; k < nlay; k++) v[k] = 0.5 * ((double)c[i + (k - 1) * ncol] + (double)c[i + k * ncol]);
    };
    to_niv(h2o, h2on); to_niv(o3, o3n); to_niv(co2, co2n); to_niv(ch4, ch4n); to_niv(n2o, n2on); to_niv(o2, o2n);
    for (int k = 0; k < nlay; k++) { tlayn[k] = tlayc[k]; dpn[k] = dp[k]; }
    tlayn[nlay] = tlayc[nlay - 1];
    dpn[nlay] = dp[nlay - 1];
    auto above = [&](const std::vector<double>& c, std::vector<double>& out) {
      double s = 0.0;
      for (int k = nlay - 1; k >= 0; k--) { s += c[k] * dp[k]; out[k] = s; }
      out[nlay] = 0.0;
    };
    above(h2oc, colh);
    above(o3c, colo);
    for (int l = 0; l < L; l++) {
      // clamp des arguments de log10 : au-dessus du sommet du modele, plev/dp
      // peuvent etre <= 0 (couches tampon) -> NaN -> taug NaN -> lookup de
      // table OOB dans rtrnmc/spcvmc (SIGSEGV). max(x, eps) rend tout fini.
      xa[i][l][0] = (float)log10(std::max((double)plev[i + l * ncol], 1e-6));
      xa[i][l][1] = tlev[i + l * ncol];
      xa[i][l][2] = (float)tlayn[l];
      xa[i][l][3] = (float)log10(std::max(h2on[l], 1e-12));
      xa[i][l][4] = (float)log10(std::max(o3n[l], 1e-12));
      xa[i][l][5] = co2n[l];
      xa[i][l][6] = ch4n[l];
      xa[i][l][7] = n2on[l];
      xa[i][l][8] = o2n[l];
      xa[i][l][9] = tsfc[i];
      xa[i][l][10] = (float)log10(std::max(colh[l], 1e-12));
      xa[i][l][11] = (float)log10(std::max(colo[l], 1e-12));
      xa[i][l][12] = (float)log10(std::max(dpn[l], 1e-12));
      xa[i][l][13] = (float)(dpn[l] * 100.0 / 9.80665);
    }
  }
}

extern "C" int pinn_torch_init(const char* path) {
  try {
    // Le shell Fortran peut passer un buffer non NUL-termine (rempli de blancs,
    // voire de garbage apres) : lecture bornee (strnlen) puis coupure au
    // premier blanc/NUL (les chemins de modele n'ont pas d'espace).
    size_t n = strnlen(path, 4096);
    std::string p(path, n);
    size_t cut = p.find_first_of(" \t\r\n");
    if (cut != std::string::npos) p.resize(cut);
    if (p.empty()) throw std::runtime_error("chemin de modele vide");
    g_model = torch::jit::load(p);
    g_model.eval();
    g_on = true;
    fprintf(stderr, "[PINN] torch: modele charge: %s\n", p.c_str());
    return 1;
  } catch (const std::exception& e) {
    g_on = false;
    fprintf(stderr, "[PINN] ECHEC chargement modele (%s) -> fallback Fortran taumol\n", e.what());
    return 0;
  }
}

extern "C" int pinn_torch_is_on() { return g_on ? 1 : 0; }

extern "C" int pinn_torch_precompute_sw(int ncol, int nlay,
                                         const float* play, const float* plev, const float* tlay, const float* tlev, const float* tsfc,
                                         const float* h2o, const float* o3, const float* co2, const float* ch4,
                                         const float* n2o, const float* o2,
                                         float* taug, float* taur) {
  if (!g_on) return 0;
  try {
    torch::Tensor X;
    build_X(ncol, nlay, play, plev, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2, X);
    torch::NoGradGuard guard;
    auto out = g_model.forward({X}).toTuple()->elements();
    // sanitize: NaN/Inf -> bornes sures (un taug NaN/negatif rend l index de
    // lookup de table itgas negatif dans spcvmc_sw -> OOB -> SIGSEGV)
    auto t_sw = torch::nan_to_num(out[0].toTensor().contiguous(), 0.0, 1.0e6, 0.0).clamp(0.0, 1.0e6);
    auto r_sw = torch::nan_to_num(out[1].toTensor().contiguous(), 0.0, 0.3, 0.0).clamp(1.0e-12, 0.3);
    const int NGPT = 112;
    auto ta = t_sw.accessor<float, 3>();
    auto ra = r_sw.accessor<float, 3>();
    for (int i = 0; i < ncol; i++)
      for (int k = 0; k < nlay; k++)
        for (int ig = 0; ig < NGPT; ig++) {
          size_t idx = (size_t)i + (size_t)k * ncol + (size_t)ig * ncol * nlay;
          taug[idx] = ta[i][k][ig];
          taur[idx] = ra[i][k][ig];
        }
    return 1;
  } catch (const std::exception& e) {
    fprintf(stderr, "[PINN] precompute_sw ECHEC (%s) -> fallback Fortran\n", e.what());
    return 0;
  }
}

extern "C" int pinn_torch_precompute_lw(int ncol, int nlay,
                                         const float* play, const float* plev, const float* tlay, const float* tlev, const float* tsfc,
                                         const float* h2o, const float* o3, const float* co2, const float* ch4,
                                         const float* n2o, const float* o2,
                                         float* taug_lw, float* fracs_lw) {
  if (!g_on) return 0;
  try {
    torch::Tensor X;
    build_X(ncol, nlay, play, plev, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2, X);
    torch::NoGradGuard guard;
    auto out = g_model.forward({X}).toTuple()->elements();
    auto t_lw = torch::nan_to_num(out[2].toTensor().contiguous(), 0.0, 1.0e6, 0.0).clamp(0.0, 1.0e6);   // (ncol, nlay+1, 140)
    auto f_lw = torch::nan_to_num(out[3].toTensor().contiguous(), 0.5, 1.0, 0.0).clamp(0.0, 1.0);
    const int NGPT = 140;
    const int L = nlay + 1;
    auto ta = t_lw.accessor<float, 3>();
    auto fa = f_lw.accessor<float, 3>();
    for (int i = 0; i < ncol; i++)
      for (int l = 0; l < L; l++)
        for (int ig = 0; ig < NGPT; ig++) {
          size_t idx = (size_t)i + (size_t)l * ncol + (size_t)ig * ncol * L;
          taug_lw[idx] = ta[i][l][ig];
          fracs_lw[idx] = fa[i][l][ig];
        }
    return 1;
  } catch (const std::exception& e) {
    fprintf(stderr, "[PINN] precompute_lw ECHEC (%s) -> fallback Fortran\n", e.what());
    return 0;
  }
}
