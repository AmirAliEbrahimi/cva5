#==============================================================================
# Baseline build: the stock CVA5 SoC (no accelerator), implemented end to end.
#
# Diagnostic. pynq_z2_sys.tcl builds the block design but stops there; this
# sources it and runs implementation with the same strategy and reporting as
# pynq_z2_nn_sys.tcl, so the only variable between the two bitstreams is the
# block design itself.
#
#   vivado -mode batch -source examples/xilinx/pynq_z2_baseline.tcl
#
# If hello world works from this bitstream but not the accelerator one, the
# fault is in pynq_z2_nn_sys.tcl. If it fails here too, the fault is upstream
# of the block design -- IP, mif, XDC, board files or programming.
#==============================================================================

set JOBS [expr {[llength $argv] > 0 ? [lindex $argv 0] : 4}]

source ./examples/xilinx/pynq_z2_sys.tcl

# pynq_z2_sys.tcl closes the project, so reopen it to implement.
open_project ./vivado/CVA5BD/CVA5BD.xpr

# Same IP configuration the accelerator design needs: the packaged defaults
# are not necessarily 16384 words, and LOCAL_MEM must be absolute or the
# block RAM preload silently does not resolve.
open_bd_design [get_files soc.bd]
set_property -dict [list \
    CONFIG.WORDS     {16384} \
    CONFIG.LOCAL_MEM [file normalize ./examples/sw/mem.mif] \
] [get_bd_cells cva5_top_0]
validate_bd_design
save_bd_design
close_bd_design [current_bd_design]
reset_run synth_1

set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs $JOBS
wait_on_run impl_1

open_run impl_1
report_utilization -file ./vivado/CVA5BD/utilization.rpt
puts [report_timing_summary -no_header -no_detailed_paths -return_string]
puts "\nbitstream: ./vivado/CVA5BD/CVA5BD.runs/impl_1/soc_wrapper.bit"

close_project
