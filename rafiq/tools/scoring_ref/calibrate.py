"""Calibration (spec §5.4/§7.3). Input: JSONL of labeled tokens from self-test / owner labels:
  {"class":"vowel_sub","gop":float,"is_error":bool}  (+ optional {"group":"vowel","logits":[...],"target":id} for temperatures)
Outputs scoring_calibration.json fields: temperature per group, tau[class]=[hard, soft], and a Markdown ROC/PR table.
tauHard = largest GOP threshold with false-alarm rate <= fa_hard on correct tokens (red);
tauSoft = largest GOP threshold with recall >= recall_target (amber). Nothing is written as 'calibrated'
unless every class has >= MIN_POS errors and >= MIN_NEG correct tokens; otherwise status stays UNCALIBRATED."""
import json, sys
import numpy as np
MIN_POS, MIN_NEG = 10, 30

def fit_temperature(logits: np.ndarray, targets: np.ndarray, grid=np.arange(0.5, 4.01, 0.05)) -> float:
    best, bt = np.inf, 1.0
    for t in grid:
        z = logits / t; z = z - z.max(1, keepdims=True)
        nll = -(z[np.arange(len(targets)), targets] - np.log(np.exp(z).sum(1))).mean()
        if nll < best: best, bt = nll, float(t)
    return round(bt, 2)

def roc_points(gop, is_err):
    gop, is_err = np.asarray(gop), np.asarray(is_err, bool)
    pts = []
    for th in np.unique(gop):
        flag = gop <= th
        tp, fp = (flag & is_err).sum(), (flag & ~is_err).sum()
        pts.append((float(th), tp / max(is_err.sum(), 1), fp / max((~is_err).sum(), 1)))
    return pts

def pick_tau(gop, is_err, fa_hard=0.01, recall_target=0.95):
    pts = roc_points(gop, is_err)
    # a token is flagged when gop <= tau. amber (soft) must reach the recall target; red (hard) must keep
    # false alarms <= fa_hard and can never be looser than amber.
    th_fa = max([th for th, r, fa in pts if fa <= fa_hard], default=-1e9)
    soft = min([th for th, r, fa in pts if r >= recall_target], default=1e9)
    return min(th_fa, soft), soft

def calibrate(rows, fa_hard=0.01, recall_target=0.95):
    tau, report, ok = {}, ["| class | n_err | n_ok | tauHard | tauSoft | recall@soft | FA@soft | FA@hard |", "|---|---|---|---|---|---|---|---|"], True
    for cls in sorted({r["class"] for r in rows}):
        g = [r["gop"] for r in rows if r["class"] == cls]; e = [r["is_error"] for r in rows if r["class"] == cls]
        npos, nneg = int(sum(e)), int(len(e) - sum(e))
        if npos < MIN_POS or nneg < MIN_NEG: ok = False
        h, s = pick_tau(g, e, fa_hard, recall_target)
        pts = {round(th, 6): (r, fa) for th, r, fa in roc_points(g, e)}
        rs, fs = pts.get(round(s, 6), (float("nan"),) * 2); fh = pts.get(round(h, 6), (float("nan"),) * 2)[1]
        tau[cls] = [round(h, 3), round(s, 3)]
        report.append(f"| {cls} | {npos} | {nneg} | {h:.2f} | {s:.2f} | {rs:.2f} | {fs:.2f} | {fh:.2f} |")
    return {"tau": tau, "calibration_status": "CALIBRATED" if ok else "UNCALIBRATED_INSUFFICIENT_DATA"}, "\n".join(report)

if __name__ == "__main__":
    rows = [json.loads(l) for l in open(sys.argv[1])]
    cal, md = calibrate(rows)
    json.dump(cal, open(sys.argv[2], "w"), indent=1); open(sys.argv[2] + ".md", "w").write(md + "\n"); print(md)
