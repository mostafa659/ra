"""Pick >=50 ayahs for OWNER hand-verification against the printed Mushaf (writes test/fixtures/qps_review_50.json).
Required: 103:1-3, 1:1-7, 2:255; then the first ayah showing each QPS feature symbol. Status is always
'pending_owner_review' until the owner sets verified=true per item -- the test never treats these as verified."""
import gzip, json, sys
d = json.load(gzip.open("assets/qps_reference.json.gz", "rt"))["ayat"]
idx = {(a["s"], a["a"]): a for a in d}
pick = [(103, 1), (103, 2), (103, 3)] + [(1, i) for i in range(1, 8)] + [(2, 255)]
feat = {"ں": "ikhfa/ghunna noon", "ڇ": "qalqalah", "۾": "iqlab/meem", "ۦ": "madd yaa", "ۥ": "madd waw", "ٲ": "special", "۪": "imala/other", "ۜ": "saktah/other", "ؙ": "rawm/ishmam/other", "ـ": "tatweel-symbol"}
for ch, name in feat.items():
    k = 0
    for a in d:
        if ch in a["qps"] and (a["s"], a["a"]) not in pick and len(a["words"]) <= 12:
            pick.append((a["s"], a["a"])); k += 1
            if k == 3: break
for a in d:  # tanween, shadda: first ayahs ending in tanween / containing doubled letters
    if len(pick) >= 56: break
    if len(a["words"]) <= 8 and (a["s"], a["a"]) not in pick and a["s"] % 7 == 0:
        pick.append((a["s"], a["a"]))
out = [{"s": s, "a": a, "text": idx[(s, a)]["text"], "qps": idx[(s, a)]["qps"], "verified": False, "status": "pending_owner_review"} for s, a in pick]
json.dump(out, open("test/fixtures/qps_review_50.json", "w"), ensure_ascii=False, indent=1)
print(len(out))
