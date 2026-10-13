#==============================================================================
# The debug module's JTAG clock domain, and the waiver for the one check it
# provokes. Added with USED_IN {implementation} by pynq_z2_sys.tcl.
#
# IMPLEMENTATION ONLY, and not as tidiness: everything here names a cell inside
# cva5_top, which is a packaged IP synthesised out of context. During top-level
# synthesis that whole hierarchy is a black box, so the BSCANE2 and the CDC
# registers do not exist yet, every query returns nothing, and create_clock and
# set_clock_groups fail with "No valid object(s) found" -- while the
# implementation run, which reads the same file against the full netlist, works.
# The constraints did apply; the errors were the synthesis run complaining about
# objects it cannot see. Scoping the file is what stops that.
#
# No `if` in here either. XDC is a restricted Tcl subset: `set` is allowed,
# control flow is not, and a guard like `if {[llength $x] != 1}` is rejected
# with "Command 'if' is not supported in the xdc constraint file". There is no
# loss -- create_clock and set_bus_skew both fail loudly on an empty
# collection, which is the same thing the guard was there to say.
#==============================================================================

# ---- The TAP's clock ------------------------------------------------------
# The debug module's DTM hangs off the FPGA's JTAG chain through two BSCANE2
# primitives inside riscv-dbg's dmi_jtag_tap. TCK comes out of the USER3
# instance and clocks the whole DTM: the TAP shift registers, the DMI FSM, and
# the TCK half of the clock-domain crossing into the core's clock. Until this
# existed, 243 register pins were reached by no timing clock at all and
# report_methodology said so 243 times (TIMING-17). That is not cosmetic: a
# register with no clock has no requirement, so nothing stops the placer
# putting the two ends of the TAP's shift chain at opposite corners of the die.
#
# 100 ns is the 10 MHz that examples/xilinx/openocd/pynq-z2-jtag.cfg asks the
# adapter for. The DTM is a shift register and a small FSM, so the number only
# has to be honest about the cable, not tight.
#
# Found through the cell rather than by filtering every pin in the design on
# its hierarchical name, which is what XDCB #1 asks for. The instance is named
# rather than selected by REF_NAME == BSCANE2 because there are two of them and
# only this one has TCK connected.
set tck_pin [get_pins -filter {REF_PIN_NAME == TCK} \
                 -of_objects [get_cells -hierarchical i_tap_dtmcs]]
create_clock -period 100.000 -name jtag_tck -waveform {0.000 50.000} $tck_pin

# ---- Crossing into the core's clock ---------------------------------------
# Two constraints, because neither alone is right and they are not
# interchangeable:
#
#   set_clock_groups -asynchronous     stops the timer computing setup and hold
#                                      between two clocks whose phase relation
#                                      is unknowable. Without it the clocks are
#                                      "related with no common node", which
#                                      Vivado reports as a critical warning
#                                      saying the design could fail -- and it is
#                                      right, because those numbers are fiction.
#
#   set_bus_skew                       bounds the spread between the payload's
#                                      own bits, which is the requirement the
#                                      handshake actually has. It is NOT a
#                                      timing exception, so the clock group does
#                                      not override it; report_bus_skew checks it
#                                      independently and reports a slack.
#
# What does not work is set_max_delay -datapath_only, which was the previous
# attempt: a clock group outranks it in Vivado's exception precedence, so the two
# cannot be combined -- the group wins and the bound is silently discarded -- and
# used alone instead of the group it leaves the clocks related, which is the
# critical warning above.
#
# The value is the number of destination cycles the payload is held for. The
# destination sees the request only after a two-stage synchroniser, so the data
# has at least two destination clocks to settle, and the handshake holds it until
# the acknowledge returns. Two destination periods is therefore conservative in
# the safe direction: 2 x 10 ns for the request (TCK into the core's clock) and
# 2 x 100 ns for the response (the core's clock into TCK). Measured skew is
# 1.857 ns against the 20 ns requirement, so neither bound puts the router under
# any pressure -- they exist to keep it that way.
set dmi_cdc [get_cells -hierarchical i_dmi_cdc]
set_clock_groups -asynchronous -name jtag_tck_async -group [get_clocks jtag_tck]
set_bus_skew 20.000 \
    -from [get_cells $dmi_cdc/i_cdc_req/i_src/data_src_q_reg*] \
    -to   [get_cells $dmi_cdc/i_cdc_req/i_dst/data_dst_q_reg*]
set_bus_skew 200.000 \
    -from [get_cells $dmi_cdc/i_cdc_resp/i_src/data_src_q_reg*] \
    -to   [get_cells $dmi_cdc/i_cdc_resp/i_dst/data_dst_q_reg*]

# ---- Methodology waiver: TIMING-9, "Unknown CDC Logic" --------------------
# The check says:
#
#   One or more asynchronous Clock Domain Crossing has been detected between 2
#   clock domains through a set_false_path or a set_clock_groups or
#   set_max_delay -datapath_only constraint but no double-registers logic
#   synchronizer has been found on the side of the capture clock.
#
# It is pointing at the set_clock_groups above, and it is describing dmi_cdc
# correctly: the payload registers have no synchroniser. That is the design, not
# an omission. dmi_cdc is a two-phase handshake -- the request and acknowledge
# tokens cross through three stages of ASYNC_REG flops (common_cells `sync`,
# plus cdc_2phase_clearable's own req_synced_q1), and the payload is a holding
# register held stable for the whole handshake. Putting a synchroniser on the
# payload would break the protocol, not secure it: the point of a handshake is
# that the data is qualified by a signal that *is* synchronised. What the
# payload gets instead is the bound above, which is what the module asks for in
# its header. report_cdc shows zero Unsafe and zero missing ASYNC_REG.
#
# The XPM_CDC macros the message recommends do not apply. This is vendored
# third-party RTL implementing its own handshake; replacing it with XPM would
# mean forking riscv-dbg.
#
# The rule is TIMING-9. The implementation log prints "TIMING #1 Warning",
# which is the violation's ID within the rule and not a rule ID at all --
# report_property on the violation shows CHECK = TIMING-9, FULLNAME = "Unknown
# CDC Logic", ID = 1. TIMING-1 is "Invalid Clock Waveform on Clock Modifying
# Block" and waiving it does nothing. This cost a run to learn once already.
#
# WHAT THIS COSTS, since it is worth being honest about: the waiver is
# design-wide. It cannot be otherwise -- create_waiver rejects -from/-to for
# anything but -type CDC (Vivado_Tcl 4-903), and the violation carries no
# objects at all to scope to (OBJECT_TYPES is empty). TIMING-9 was the only
# automatic alarm this build had for an asynchronous crossing that genuinely
# forgot its synchroniser, and from here on it will not fire for a new one
# either. If another clock domain is ever added, read report_cdc by hand:
# Unsafe and "No ASYNC_REG" are the columns that matter, and both are zero
# today.
create_waiver -type METHODOLOGY -id {TIMING-9} -user "cva5" \
    -description "dmi_cdc is a two-phase handshake: req/ack cross through\
 three ASYNC_REG stages and the payload is a holding register stable for the\
 whole handshake, bounded by set_bus_skew above rather than synchronised. A\
 synchroniser on the payload would break the protocol. report_cdc: 0 Unsafe,\
 0 missing ASYNC_REG; report_bus_skew: 1.857 ns against 20 ns."
