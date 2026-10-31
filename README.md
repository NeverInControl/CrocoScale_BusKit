# CrocoScale_BusKit — Bus Interconnect, Protection & CDC IP Library

---

## CDC Tapeout Guide: `wb/wbb4_cdc` (LibreLane / OpenROAD on `ihp-sg13cmos5l`)

> **What to include in your ASIC Synthesis / LibreLane flow:**
> * **RTL Sources:** Only the files inside [`wb/wbb4_cdc/rtl/`](wb/wbb4_cdc/rtl/) (listed in dependency order in [`wb/wbb4_cdc/wbb4_cdc_top.f`](wb/wbb4_cdc/wbb4_cdc_top.f)).
> * **Top-Level Module:** `wbb4_cdc_top` (in [`wb/wbb4_cdc/rtl/wbb4_cdc_top.sv`](wb/wbb4_cdc/rtl/wbb4_cdc_top.sv)).
> * **SDC Constraint File (MANDATORY):** [`wb/wbb4_cdc/constraints/wbb4_cdc.sdc`](wb/wbb4_cdc/constraints/wbb4_cdc.sdc).
> * **Do NOT include [`wb/wbb4_cdc/verification/`](wb/wbb4_cdc/verification/)** in synthesis — that folder contains simulation testbenches and formal verification harnesses only.

---

## CRITICAL: Mandatory SDC Constraint File & IHP 130nm (`ihp-sg13cmos5l`) Specificity

> **MANDATORY REQUIREMENT:**
> You **MUST** include [`wb/wbb4_cdc/constraints/wbb4_cdc.sdc`](wb/wbb4_cdc/constraints/wbb4_cdc.sdc) in your LibreLane / OpenROAD / OpenSTA synthesis and Place & Route flow (`PNR_SDC_FILE` and `SIGNOFF_SDC_FILE`). **Do not synthesize or route this block without `wbb4_cdc.sdc`.**

### Why [`wb/wbb4_cdc/constraints/wbb4_cdc.sdc`](wb/wbb4_cdc/constraints/wbb4_cdc.sdc) Is Essential
1. **Multi-Bit Gray Pointer Skew Bounding (`set_max_delay 2.0 -ignore_clock_latency`):**
   * An asynchronous FIFO relies on adjacent Gray-code transitions differing by at most 1 bit across the clock boundary.
   * Without the `2.0 ns` point-to-point `set_max_delay` constraint between `*u_launch_wptr*gray_q*/Q` $\to$ `*u_sync_wptr_to_rd*sync_meta_q*/D` (and `*u_launch_rptr*gray_q*/Q` $\to$ `*u_sync_rptr_to_wr*sync_meta_q*/D`), the router has no upper bound on wire detour skew between individual bits of the 4-bit Gray bus, which can corrupt FIFO pointers in silicon.
2. **Stage-0-Only Synchronizer False Paths:**
   * [`wbb4_cdc.sdc`](wb/wbb4_cdc/constraints/wbb4_cdc.sdc) constrains **only** the Stage-0 `/D` capture pin (`*sync_meta_q*/D`) and the asynchronous `/RESET_B` entry pins of the AASD reset bridges (`*u_rst_sync_*/RESET_B`, `*u_sync_dst_rst_to_src*/RESET_B`, `*u_sync_src_rst_to_dst*/RESET_B`).
   * All `22` internal **Stage-0 $\to$ Stage-1** synchronous shift paths (`*sync_meta_q*/Q -> *sync_pipe_q*/D` and `*rst_meta_n_q*/Q -> *rst_sync_n_q*/D`) and all downstream synchronous reset recovery/removal paths (`rst_sync_o -> */RESET_B`) are deliberately left **100% timed** so OpenROAD places synchronizer stages right next to each other and preserves maximum metastability resolution slack ($T_{\text{res}}$).

### Target Technology Specificity (`ihp-sg13cmos5l` 130nm ONLY)
* **This codebase and [`wbb4_cdc.sdc`](wb/wbb4_cdc/constraints/wbb4_cdc.sdc) are specifically engineered for the IHP 130nm CMOS5L (`ihp-sg13cmos5l`) standard-cell library (`sg13cmos5l_stdcell`).**
* **RTL Mapping to `sg13cmos5l_dfrbpq_1`:** Because `ihp-sg13cmos5l` provides active-low asynchronous clear flip-flops (`sg13cmos5l_dfrbpq_1` / `sg13cmos5l_dfrbp_1`) and no native async-preset flip-flops, all reset bridges (`rst_sync_aasd`), active-low reset handshakes (`src_req_n_q`, `dst_evt_n_q`), and seeded registers (`0xA`/`0x5` XOR masks in `wbb4_cdc_test_regfile`) are written to map 1-to-1 onto `sg13cmos5l_dfrbpq_1` without reset-inverter feedback loops.
* **Pin-Name Specificity in `wbb4_cdc.sdc`:** The SDC constraints explicitly reference `ihp-sg13cmos5l` standard-cell flip-flop pin names (`/Q`, `/D`, and `/RESET_B`) and a `2.0 ns` Gray skew leash calibrated to `sg13cmos5l_dfrbpq_1` ($T_{\text{cq}} \approx 0.26\text{–}0.39\text{ ns}$). **This constraint file is only valid for IHP 130nm (`ihp-sg13cmos5l`)** and must be adapted if retargeted to another foundry PDK.

---

## What NOT To Do During Integration (Backend Rules)

To prevent breaking the CDC/RDC guarantees during synthesis and Place & Route in LibreLane / Yosys / OpenROAD, **strictly avoid the following**:

1. **DO NOT run `flatten -wb` or strip `keep_hierarchy` / `keep` / `dont_touch` attributes in Yosys:**
   * `cdc_gray_reg`, `cdc_sync_2ff`, and `rst_sync_aasd` are marked with `(* keep_hierarchy = "yes" *)` and `(* keep = "true", async_reg = "true", dont_touch = "true" *)`.
   * **Why:** Running `flatten -wb` (whitebox flatten ignoring `keep_hierarchy`) or `setattr -mod -unset keep_hierarchy *` *before* technology mapping allows Yosys `opt_merge` and `abc` to merge the Gray pointer MSB flip-flop (`wptr_gray_q[3]`) with the local binary counter MSB (`wptr_bin_q[3]`), attaching local combinational fanout to the CDC launch net and risking glitches/skew across the clock domain boundary.
   * If your post-mapping flow flattens the gate-level netlist for OpenROAD, always run Yosys `autoname` (standard in LibreLane) so hierarchical register names (`*u_launch_wptr*gray_q*`, `*u_sync_*sync_meta_q*`, `*u_rst_sync_*`) are preserved for [`wbb4_cdc.sdc`](wb/wbb4_cdc/constraints/wbb4_cdc.sdc).

2. **DO NOT apply a blanket `set_clock_groups -asynchronous` or clock-to-clock `set_false_path` between `clk_fab` and `clk_dll`:**
   * In OpenSTA / Synopsys SDC precedence, `set_clock_groups -asynchronous` and `set_false_path -from [get_clocks clk_fab] -to [get_clocks clk_dll]` **override and disable** `set_max_delay`!
   * If you put a blanket clock-group false path between `clk_fab` and `clk_dll` in the top-level chip SDC, OpenSTA will silently ignore the `2.0 ns` `set_max_delay` routing leash on the multi-bit Gray pointers in [`wbb4_cdc.sdc`](wb/wbb4_cdc/constraints/wbb4_cdc.sdc). Rely on the pin-level exceptions in `wbb4_cdc.sdc` instead.

3. **DO NOT false-path entire synchronizer modules (`set_false_path -to [get_cells *u_sync_*]`):**
   * Targeting `*u_sync_*` without restricting to Stage 0 (`*sync_meta_q*/D`) disables timing on the synchronous **Stage-0 $\to$ Stage-1** path (`sync_meta_q -> sync_pipe_q`), allowing the placer to separate the two synchronizer flip-flops across the macro and degrading MTBF. Always use [`wbb4_cdc.sdc`](wb/wbb4_cdc/constraints/wbb4_cdc.sdc) as provided.

4. **DO NOT wire an unsynchronized reset directly to `wb_b4_cdc` or `wbb4_cdc_test_regfile`:**
   * If instantiating `wbb4_cdc_top`, connect raw `rst_fab_i` and `rst_dll_pad_i` directly to `wbb4_cdc_top` (it instantiates `u_rst_sync_fab` and `u_rst_sync_dll` internally).
   * If instantiating `wb_b4_cdc` directly without `wbb4_cdc_top`, both `rst_wb_i` and `rst_slv_i` **must** be driven by `rst_sync_aasd` bridges so reset deassertion is synchronous to `clk_wb_i` and `clk_slv_i`, respectively.

---

## Top-Level Interface & Register Map (`wbb4_cdc_top`)

### Pinout (`18` Fabric Pins + `clk_dll_i` + `rst_dll_pad_i`)

* `clk_fab_i` to fabric clock
* `clk_dll_i` to internal DLL
* `rst_dll_pad_i` to external pad

Everything else directly into the fabric.


| Signal | Direction | Width | Clock Domain | Description |
| :--- | :---: | :---: | :--- | :--- |
| `clk_fab_i` | Input | `1` | `clk_fab_i` | eFPGA fabric Wishbone Master clock |
| `rst_fab_i` | Input | `1` | Async (`clk_fab_i`) | Active-high fabric reset (internally AASD-synchronized) |
| `wb_cyc_i` | Input | `1` | `clk_fab_i` | Wishbone B4 cycle valid (`0` aborts in-flight burst responses) |
| `wb_stb_i` | Input | `1` | `clk_fab_i` | Wishbone B4 request strobe |
| `wb_we_i` | Input | `1` | `clk_fab_i` | Wishbone B4 write enable (`1` = Write, `0` = Read) |
| `wb_adr_i` | Input | `2` | `clk_fab_i` | Word address (`0x0`..`0x3`) |
| `wb_dat_i` | Input | `4` | `clk_fab_i` | Write data payload |
| `wb_stall_o` | Output | `1` | `clk_fab_i` | Pipelined backpressure (`1` when request FIFO is full or RDC isolating) |
| `wb_ack_o` | Output | `1` | `clk_fab_i` | Normal completion acknowledge pulse |
| `wb_err_o` | Output | `1` | `clk_fab_i` | Error completion pulse (mid-burst DLL reset or watchdog timeout) |
| `wb_dat_o` | Output | `4` | `clk_fab_i` | Read data payload (valid when `wb_ack_o = 1`) |
| **DLL & Pad Signals** | | | | |
| `clk_dll_i` | Input | `1` | `clk_dll_i` | Internal clock from the DLL |
| `rst_dll_pad_i`| Input | `1` | Async (`clk_dll_i`) | Direct external chip reset pad for the DLL slave domain |

### Slave Test Register Map (`wbb4_cdc_test_regfile` in `clk_dll_i` Domain)

| Address (`wb_adr_i`) | Name | Reset Default | Access | Description |
| :---: | :--- | :---: | :---: | :--- |
| `2'h0` | `SCRATCH_0` | `4'hA` (`1010`) | R/W | 4-bit general-purpose R/W scratchpad register 0 |
| `2'h1` | `SCRATCH_1` | `4'h5` (`0101`) | R/W | 4-bit general-purpose R/W scratchpad register 1 |
| `2'h2` | `BURST_CHG_CNT` | `4'h0` (`0000`) | R/W | Increments by `+1` on writes to `2'h2` only when `wb_dat_i != prev_wdat_q` |
| `2'h3` | `CLK_OSC_CNT` | `4'h0` (`0000`) | R/W | Free-running `+1` per `clk_dll_i` cycle counter; writing `2'h3` clears `BURST_CHG_CNT` |

---

## 130nm Size (`ihp-sg13cmos5l` @ 50% Placement Density)

| `FIFO_DEPTH_LOG2` | FIFO Entries | Standard Cells | Flip-Flops | Cell Area | 50%-Density Macro Box | Area Saved |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **`3` (Default)** | `8` | `1,132` | `230` | `20,290 µm²` | **`201 µm × 201 µm`** (`40,580 µm²`) | Baseline |
| **`2`** | `4` | `830` | `167` | `14,551 µm²` | **`171 µm × 171 µm`** (`29,102 µm²`) | **`-28.3%`** |
| **`1`** | `2` | `668` | `126` | `10,904 µm²` | **`148 µm × 148 µm`** (`21,809 µm²`) | **`-46.3%`** |

In case `200 µm × 200 µm` is too big:
* Reduce `FIFO_DEPTH_LOG2` in [`wbb4_cdc_top.sv`](wb/wbb4_cdc/rtl/wbb4_cdc_top.sv) down to `2` (`4` entries, `-28.3%` area) or `1` (`2` entries, `-46.3%` area; minimum valid value is `1` — do not set to `0`). All three depths (`3`, `2`, and `1`) are verified automatically by `run_all_checks.sh`.

---

## Repository Layout

```text
CrocoScale_BusKit/
├── README.md
└── wb/
    └── wbb4_cdc/                                 # Wishbone B4 Pipelined CDC & RDC Subsystem
        ├── wbb4_cdc_top.f                        # Synthesis filelist: Full slot macro wrapper (8 RTL files)
        ├── wb_b4_cdc_core.f                      # Synthesis filelist: Standalone CDC bridge core (6 RTL files)
        ├── rtl/                                  # [SYNTHESIS] ONLY synthesizable SystemVerilog RTL (all 8 files in one folder)
        │   ├── cdc_gray_reg.sv
        │   ├── cdc_sync_2ff.sv
        │   ├── rst_sync_aasd.sv
        │   ├── cdc_reset_ctrlr.sv
        │   ├── cdc_fifo_gray_clearable.sv
        │   ├── wb_b4_cdc.sv
        │   ├── wbb4_cdc_test_regfile.sv
        │   └── wbb4_cdc_top.sv
        ├── constraints/                          # [SYNTHESIS / PnR] Mandatory SDC timing constraints
        │   └── wbb4_cdc.sdc                      # REQUIRED for IHP 130nm (ihp-sg13cmos5l) LibreLane / OpenSTA
        └── verification/                         # [SIMULATION / FORMAL ONLY] Non-synthesizable tests & scripts
            ├── tb/
            │   ├── tb_part1_bursts_and_skew.sv
            │   ├── tb_part2_resets_and_aborts.sv
            │   ├── tb_part3_watchdogs_and_stress.sv
            │   └── formal_wbb4_cdc.sv
            └── scripts/
                ├── run_all_checks.sh
                ├── run_synth_ihp130.sh
                ├── run_gls_ihp130.sh
                ├── run_sta_ihp130.sh
                └── run_formal.sh
```