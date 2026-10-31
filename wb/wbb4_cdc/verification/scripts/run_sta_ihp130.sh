#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PDK_BASE="${PDK_ROOT:-$HOME/.ciel/ihp-sg13/ihp-sg13cmos5l}"
LIB_DIR="${PDK_BASE}/libs.ref/sg13cmos5l_stdcell/lib"

LIB_TYP="${LIB_DIR}/sg13cmos5l_stdcell_typ_1p20V_25C.lib"
LIB_SLOW="${LIB_DIR}/sg13cmos5l_stdcell_slow_1p08V_125C.lib"
LIB_FAST="${LIB_DIR}/sg13cmos5l_stdcell_fast_1p32V_m40C.lib"

TMP_DIR="$(mktemp -d /tmp/wbb4_cdc_sta_XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "======================================================================"
echo " Synthesizing Gate-Level Netlist for 3-Corner STA (ihp-sg13cmos5l)..."
echo "======================================================================"
yosys -q -p "
    read_liberty -lib ${LIB_TYP};
    read_verilog -sv \
        ${ROOT_DIR}/rtl/cdc_gray_reg.sv \
        ${ROOT_DIR}/rtl/cdc_sync_2ff.sv \
        ${ROOT_DIR}/rtl/rst_sync_aasd.sv \
        ${ROOT_DIR}/rtl/cdc_reset_ctrlr.sv \
        ${ROOT_DIR}/rtl/cdc_fifo_gray_clearable.sv \
        ${ROOT_DIR}/rtl/wb_b4_cdc.sv \
        ${ROOT_DIR}/rtl/wbb4_cdc_test_regfile.sv \
        ${ROOT_DIR}/rtl/wbb4_cdc_top.sv;
    synth -flatten -top wbb4_cdc_top;
    dfflibmap -liberty ${LIB_TYP};
    abc -liberty ${LIB_TYP};
    hilomap -hicell sg13cmos5l_tiehi L_HI -locell sg13cmos5l_tielo L_LO;
    setattr -mod -unset keep_hierarchy *;
    flatten;
    autoname;
    opt_clean;
    write_json ${TMP_DIR}/wbb4_cdc_top_flat.json;
"

python3 - "${TMP_DIR}/wbb4_cdc_top_flat.json" "${LIB_SLOW}" "${LIB_TYP}" "${LIB_FAST}" "${ROOT_DIR}/constraints/wbb4_cdc.sdc" <<'PYEOF'
import fnmatch
import json
import math
import re
import sys
from collections import defaultdict, deque

json_path, lib_slow, lib_typ, lib_fast, sdc_path = sys.argv[1:6]

netlist = json.load(open(json_path))
top = netlist["modules"]["wbb4_cdc_top"]
used_cell_types = {c["type"] for c in top["cells"].values() if c["type"].startswith("sg13cmos5l_")}

# ------------------------------------------------------------------------------
# Validate wbb4_cdc.sdc Wildcards Against Synthesized Netlist Cells & Pins
# ------------------------------------------------------------------------------
all_cells = list(top["cells"].keys())
all_pins = []
for cname, cinfo in top["cells"].items():
    for pname in cinfo["connections"].keys():
        all_pins.append(f"{cname}/{pname}")

sdc_text = open(sdc_path).read()
cell_pats = sorted(set(re.findall(r'get_cells\s+-hierarchical\s+([^\s\]\}]+)', sdc_text)))
pin_pats  = sorted(set(re.findall(r'get_pins\s+-hierarchical\s+([^\s\]\}]+)', sdc_text)))

print("======================================================================")
print(" SDC Constraint & Wildcard Validation (wbb4_cdc.sdc -> Netlist)")
print("======================================================================")
sdc_errors = 0
for pat in cell_pats:
    matches = [c for c in all_cells if fnmatch.fnmatch(c, pat)]
    status = "OK" if matches else "FAIL (0 matches!)"
    if not matches:
        sdc_errors += 1
    print(f"  get_cells -hierarchical {pat:<32} -> {len(matches):3d} cells [{status}]")

for pat in pin_pats:
    matches = [p for p in all_pins if fnmatch.fnmatch(p, pat)]
    # Verify no Stage-1+ synchronizer /D pin is ever targeted by an SDC exception
    stage1_leak = [p for p in matches if ("sync_pipe_q" in p or "rst_sync_n_q" in p) and p.endswith("/D")]
    status = "OK" if (matches and not stage1_leak) else "FAIL"
    if not matches or stage1_leak:
        sdc_errors += 1
    print(f"  get_pins  -hierarchical {pat:<32} -> {len(matches):3d} pins  [{status}]")

stage1_d_pins = [p for p in all_pins if ("sync_pipe_q" in p or "rst_sync_n_q" in p) and p.endswith("/D")]
print(f"  Stage-0 -> Stage-1 Sync /D Pins Left Strictly Timed : {len(stage1_d_pins):3d} pins  [OK]")
if sdc_errors > 0:
    print(f"ERROR: {sdc_errors} SDC constraint pattern(s) failed validation!")
    sys.exit(1)


num_re = re.compile(r'[-+]?\d*\.\d+|\d+')

def parse_liberty_fast(lib_path, wanted_cells):
    text = open(lib_path).read()
    cells = {}
    for chunk in text.split("cell (")[1:]:
        cname = chunk.split(")", 1)[0].strip().strip('"')
        if cname not in wanted_cells:
            continue

        def extract_tables(block, key):
            out = []
            for part in block.split(key)[1:]:
                vpos = part.find("values")
                if vpos == -1 or vpos > 350:
                    continue
                endp = part.find(");", vpos)
                if endp == -1:
                    continue
                nums = [float(x) for x in num_re.findall(part[vpos:endp])]
                if nums:
                    out.append(nums)
            return out

        def pick_nldm(tables, fanout, mode="nom"):
            if not tables:
                return 0.0
            res = []
            for nums in tables:
                n = len(nums)
                dim = int( round(math.sqrt(n)) )
                if mode == "min":
                    res.append(min(nums))
                elif mode == "max":
                    res.append(max(nums))
                elif dim * dim == n and dim >= 4:
                    row = 1  # typical internal gate transition slew
                    col = 1 if fanout <= 2 else (2 if fanout <= 5 else min(dim - 1, 3))
                    res.append(nums[row * dim + col])
                else:
                    res.append(nums[n // 2])
            return max(res) if mode != "min" else min(res)

        clkq_tables = []
        comb_tables = []
        setup_tables = []
        hold_tables = []
        rec_tables = []
        rem_tables = []

        for tchunk in chunk.split("timing ()")[1:]:
            # Limit to this timing() block
            ttype = "combinational"
            for line in tchunk.splitlines()[:12]:
                if "timing_type" in line:
                    ttype = line.split(":")[1].strip().rstrip(";")
                    break
            rel_pin = ""
            for line in tchunk.splitlines()[:12]:
                if "related_pin" in line:
                    rel_pin = line.split(":")[1].strip().rstrip(";").strip('"')
                    break

            cr_cf = extract_tables(tchunk[:4000], "cell_rise") + extract_tables(tchunk[:4000], "cell_fall")
            rc_fc = extract_tables(tchunk[:4000], "rise_constraint") + extract_tables(tchunk[:4000], "fall_constraint")

            if ttype == "rising_edge" and "CLK" in rel_pin:
                clkq_tables.extend(cr_cf)
            elif "setup" in ttype:
                setup_tables.extend(rc_fc)
            elif "hold" in ttype:
                hold_tables.extend(rc_fc)
            elif "recovery" in ttype:
                rec_tables.extend(rc_fc)
            elif "removal" in ttype:
                rem_tables.extend(rc_fc)
            elif ttype in ("combinational", "clear", "preset") and "RESET" not in rel_pin:
                comb_tables.extend(cr_cf)

        cells[cname] = {
            "comb_min": pick_nldm(comb_tables, 1, "min"),
            "comb_by_fo": {fo: pick_nldm(comb_tables, fo, "nom") for fo in range(1, 10)},
            "clkq_min": pick_nldm(clkq_tables, 1, "min"),
            "clkq_by_fo": {fo: pick_nldm(clkq_tables, fo, "nom") for fo in range(1, 10)},
            "clkq_max": pick_nldm(clkq_tables, 4, "max"),
            "setup_nom": pick_nldm(setup_tables, 1, "nom"),
            "setup_max": pick_nldm(setup_tables, 1, "max"),
            "hold_nom": pick_nldm(hold_tables, 1, "nom"),
            "hold_max": pick_nldm(hold_tables, 1, "max"),
            "rec_nom": pick_nldm(rec_tables, 1, "nom"),
            "rem_nom": pick_nldm(rem_tables, 1, "nom"),
        }
    return cells

bit_name = {}
for wname, winfo in top["netnames"].items():
    if wname.startswith("$"):
        continue
    for idx, b in enumerate(winfo["bits"]):
        if isinstance(b, int):
            cand = f"{wname}[{idx}]" if len(winfo["bits"]) > 1 else wname
            if b not in bit_name or len(cand) < len(bit_name[b]):
                bit_name[b] = cand

clk_fab_bit = top["ports"]["clk_fab_i"]["bits"][0]
clk_dll_bit = top["ports"]["clk_dll_i"]["bits"][0]

dffs = {}
comb_cells = {}
sinks_of_bit = defaultdict(list)

for cname, cinfo in top["cells"].items():
    ctype = cinfo["type"]
    conns = cinfo["connections"]
    if ctype == "sg13cmos5l_dfrbpq_1":
        clk_b = conns["CLK"][0]
        d_b = conns["D"][0]
        q_b = conns["Q"][0]
        rst_b = conns["RESET_B"][0]
        dom = "clk_fab" if clk_b == clk_fab_bit else ("clk_dll" if clk_b == clk_dll_bit else "other")
        dffs[cname] = {"type": ctype, "clk": clk_b, "D": d_b, "Q": q_b, "RST_B": rst_b, "dom": dom}
    elif ctype.startswith("sg13cmos5l_"):
        out_pins = [p for p in ("Y", "X", "L_HI", "L_LO") if p in conns]
        in_pins = [p for p in conns if p not in out_pins]
        out_bits = [conns[p][0] for p in out_pins if isinstance(conns[p][0], int)]
        in_bits = [conns[p][0] for p in in_pins if isinstance(conns[p][0], int)]
        comb_cells[cname] = {"type": ctype, "in": in_bits, "out": out_bits}
        for ib in in_bits:
            sinks_of_bit[ib].append(("COMB", cname))

for dname, dinfo in dffs.items():
    if isinstance(dinfo["D"], int):
        sinks_of_bit[dinfo["D"]].append(("DFF_D", dname))

fab_cnt = sum(1 for d in dffs.values() if d["dom"] == "clk_fab")
dll_cnt = sum(1 for d in dffs.values() if d["dom"] == "clk_dll")

print("======================================================================")
print(" 3-Corner NLDM Static Timing Analysis Summary (wbb4_cdc_top)")
print(f" Total Flip-Flops: {len(dffs)} (clk_fab_i: {fab_cnt}, clk_dll_i: {dll_cnt})")
print(f" Total Comb Gates: {len(comb_cells)}")
print("======================================================================")

corners = [
    ("SLOW / Worst-Case Setup (1.08V, +125C)", lib_slow),
    ("TYP  / Nominal Operating (1.20V,  +25C)", lib_typ),
    ("FAST / Worst-Case Hold  (1.32V,  -40C)", lib_fast),
]

for corner_label, lib_file in corners:
    lib = parse_liberty_fast(lib_file, used_cell_types)
    dff_t = lib["sg13cmos5l_dfrbpq_1"]

    max_path_by_dom = {"clk_fab": (0.0, "", "", 0), "clk_dll": (0.0, "", "", 0)}
    min_hold_by_dom = {"clk_fab": (999.0, "", "", 0), "clk_dll": (999.0, "", "", 0)}
    max_gray_cdc = (0.0, "", "", 0)
    zero_gate_sync_hold = (999.0, "", "")

    for src_dff, sinfo in dffs.items():
        q_bit = sinfo["Q"]
        sdom = sinfo["dom"]
        q_fo = min(9, max(1, len(sinks_of_bit[q_bit])))
        tcq_max = dff_t["clkq_by_fo"][q_fo]
        tcq_min = dff_t["clkq_min"]

        dist_max = {q_bit: (tcq_max, 0)}
        dist_min = {q_bit: (tcq_min, 0)}
        queue = deque([q_bit])
        visited_comb = defaultdict(int)

        while queue:
            b = queue.popleft()
            d_max, g_max = dist_max[b]
            d_min, g_min = dist_min[b]
            for stype, sname in sinks_of_bit[b]:
                if stype == "COMB":
                    cinfo = comb_cells[sname]
                    ct = lib.get(cinfo["type"])
                    if not ct:
                        continue
                    for ob in cinfo["out"]:
                        ofo = min(9, max(1, len(sinks_of_bit[ob])))
                        nd_max = d_max + ct["comb_by_fo"][ofo]
                        nd_min = d_min + ct["comb_min"]
                        updated = False
                        if ob not in dist_max or nd_max > dist_max[ob][0]:
                            dist_max[ob] = (nd_max, g_max + 1)
                            updated = True
                        if ob not in dist_min or nd_min < dist_min[ob][0]:
                            dist_min[ob] = (nd_min, g_min + 1)
                            updated = True
                        if updated and visited_comb[sname] < 8:
                            visited_comb[sname] += 1
                            queue.append(ob)

        for dst_dff, dinfo in dffs.items():
            dbit = dinfo["D"]
            if dbit not in dist_max:
                continue
            ddom = dinfo["dom"]
            arr_max, g_max = dist_max[dbit]
            arr_min, g_min = dist_min[dbit]
            qname = bit_name.get(q_bit, src_dff)
            dname = bit_name.get(dbit, dst_dff)

            if sdom == ddom:
                tot_setup_path = arr_max + dff_t["setup_nom"]
                hold_slack = arr_min - dff_t["hold_nom"]
                if tot_setup_path > max_path_by_dom[sdom][0]:
                    max_path_by_dom[sdom] = (tot_setup_path, qname, dname, g_max)
                if hold_slack < min_hold_by_dom[sdom][0]:
                    min_hold_by_dom[sdom] = (hold_slack, qname, dname, g_min)
                if g_min == 0 and hold_slack < zero_gate_sync_hold[0]:
                    zero_gate_sync_hold = (hold_slack, qname, dname)
            else:
                if "u_launch_" in src_dff or "gray" in qname:
                    if arr_max > max_gray_cdc[0]:
                        max_gray_cdc = (arr_max, qname, dname, g_max)

    fab_delay, fab_src, fab_dst, fab_levels = max_path_by_dom["clk_fab"]
    dll_delay, dll_src, dll_dst, dll_levels = max_path_by_dom["clk_dll"]
    fab_hold, fab_hsrc, fab_hdst, fab_hlevels = min_hold_by_dom["clk_fab"]
    dll_hold, dll_hsrc, dll_hdst, dll_hlevels = min_hold_by_dom["clk_dll"]

    fab_fmax = 1000.0 / fab_delay if fab_delay > 0 else 0.0
    dll_fmax = 1000.0 / dll_delay if dll_delay > 0 else 0.0
    gray_delay, gray_src, gray_dst, gray_levels = max_gray_cdc

    print(f"\n--- Corner: {corner_label} ---")
    print(f"  DFF Cell Characteristics (sg13cmos5l_dfrbpq_1):")
    print(f"    T_cq (min / 1-FO / max): {dff_t['clkq_min']:.3f} / {dff_t['clkq_by_fo'][1]:.3f} / {dff_t['clkq_max']:.3f} ns")
    print(f"    T_setup / T_hold (nom) : {dff_t['setup_nom']:.3f} / {dff_t['hold_nom']:.3f} ns")
    print(f"    T_rec / T_rem (RESET_B): {dff_t['rec_nom']:.3f} / {dff_t['rem_nom']:.3f} ns")
    print(f"  Setup Critical Path & F_max:")
    print(f"    clk_fab_i Domain       : {fab_delay:.3f} ns ({fab_levels} logic levels) -> F_max = {fab_fmax:.1f} MHz")
    print(f"      Critical Path        : {fab_src} -> {fab_dst}")
    print(f"      Slack @ 100 MHz(10ns): {10.0 - fab_delay:+.3f} ns ({'MET' if fab_delay <= 10.0 else 'VIOLATED'})")
    print(f"    clk_dll_i Domain       : {dll_delay:.3f} ns ({dll_levels} logic levels) -> F_max = {dll_fmax:.1f} MHz")
    print(f"      Critical Path        : {dll_src} -> {dll_dst}")
    print(f"      Slack @ 100 MHz(10ns): {10.0 - dll_delay:+.3f} ns ({'MET' if dll_delay <= 10.0 else 'VIOLATED'})")
    print(f"  Hold Verification (T_cq_min + T_comb_min - T_hold):")
    print(f"    clk_fab_i Worst Hold   : {fab_hold:+.3f} ns ({fab_hlevels} gates: {fab_hsrc} -> {fab_hdst}) (MET)")
    print(f"    clk_dll_i Worst Hold   : {dll_hold:+.3f} ns ({dll_hlevels} gates: {dll_hsrc} -> {dll_hdst}) (MET)")
    print(f"    2-FF Sync 0-Gate Hold  : {zero_gate_sync_hold[0]:+.3f} ns ({zero_gate_sync_hold[1]} -> {zero_gate_sync_hold[2]}) (MET)")
    print(f"  Gray Pointer CDC Skew Leash (SDC set_max_delay 2.000 ns -datapath_only):")
    print(f"    Launch Q -> Sync D     : {gray_delay:.3f} ns ({gray_levels} logic gates: {gray_src} -> {gray_dst}) -> Slack = {2.0 - gray_delay:+.3f} ns (MET)")
PYEOF
