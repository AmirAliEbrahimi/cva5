#==============================================================================
# Methodology waiver: TIMING-9, "Unknown CDC Logic"
#
# Implementation only. Methodology checks run after place and route, and this
# documents a crossing inside cva5_top, which is a black box during top-level
# synthesis. pynq_z2_sys.tcl sets USED_IN accordingly.
#
# The check says:
#
#   One or more asynchronous Clock Domain Crossing has been detected between 2
#   clock domains through a set_false_path or a set_clock_groups or
#   set_max_delay -datapath_only constraint but no double-registers logic
#   synchronizer has been found on the side of the capture clock.
#
# It is pointing at the set_clock_groups between jtag_tck and the system clock
# in pynq_z2_cva5.xdc, and it is describing riscv-dbg's dmi_cdc correctly: the
# payload registers have no synchroniser. That is the design, not an omission.
# dmi_cdc is a two-phase handshake -- the request and acknowledge tokens cross
# through three stages of ASYNC_REG flops (common_cells `sync`, plus
# cdc_2phase_clearable's own req_synced_q1), and the payload is a holding
# register held stable for the whole handshake. Putting a synchroniser on the
# payload would break the protocol, not secure it: the point of a handshake is
# that the data is qualified by a signal that *is* synchronised.
#
# What the payload gets instead is a bound, which is the thing the module asks
# for in its header, and it is in pynq_z2_cva5.xdc as a set_bus_skew of two
# destination periods each way. Measured on the routed design: 1.857 ns against
# a 20 ns requirement, 41 endpoints, and report_cdc shows zero Unsafe and zero
# missing ASYNC_REG. Two periods is itself conservative -- the synchroniser
# budget is three.
#
# The XPM_CDC macros the message recommends do not apply. This is vendored
# third-party RTL implementing its own handshake; replacing it with XPM would
# mean forking riscv-dbg.
#
# WHAT THIS COSTS, since it is worth being honest about: TIMING-9 takes no
# object scoping -- create_waiver rejects -from/-to for anything but -type CDC
# (Vivado_Tcl 4-903) -- so this waiver is design-wide. It is the only automatic
# alarm the build has for an asynchronous crossing that genuinely forgot its
# synchroniser, and from here on it will not fire for a new one either. If
# another clock domain is ever added, check report_cdc by hand: Unsafe and
# "No ASYNC_REG" are the columns that matter, and both are zero today.
#
# Because it is unscoped, this line cannot silently match nothing the way a
# hierarchy-scoped waiver can. If TIMING-9 is the wrong ID, the warning simply
# stays in the report.
#==============================================================================

create_waiver -type METHODOLOGY -id {TIMING-9} -user "cva5" \
    -description "dmi_cdc is a two-phase handshake: req/ack cross through\
 three ASYNC_REG stages and the payload is a holding register stable for the\
 whole handshake, bounded by set_bus_skew in pynq_z2_cva5.xdc rather than\
 synchronised. A synchroniser on the payload would break the protocol.\
 report_cdc: 0 Unsafe, 0 missing ASYNC_REG; report_bus_skew: 1.857 ns against\
 20 ns."
