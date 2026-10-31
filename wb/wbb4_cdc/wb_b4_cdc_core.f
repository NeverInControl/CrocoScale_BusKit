# ==============================================================================
# CrocoScale_BusKit — Synthesis Filelist: wb_b4_cdc (Standalone CDC Bridge Core)
# ==============================================================================
# Top-Level Module : wb_b4_cdc
# SDC Constraints  : constraints/wbb4_cdc.sdc (REQUIRED for ihp-sg13cmos5l)
# Note             : Excludes the wbb4_cdc_top wrapper and loopback register
#                    file. Paths are relative to wb/wbb4_cdc/
# ==============================================================================

rtl/cdc_gray_reg.sv
rtl/cdc_sync_2ff.sv
rtl/rst_sync_aasd.sv
rtl/cdc_reset_ctrlr.sv
rtl/cdc_fifo_gray_clearable.sv
rtl/wb_b4_cdc.sv

