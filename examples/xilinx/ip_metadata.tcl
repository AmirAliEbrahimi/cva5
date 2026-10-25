#==============================================================================
# Metadata both packaging scripts apply to the IP currently open for editing.
#
#   source ./examples/xilinx/ip_metadata.tcl
#   cva5_ip_metadata "what this block is" 100000000
#
# Call it between ipx::edit_ip_in_project and ipx::update_checksums, which is
# the window where [ipx::current_core] exists and is writable.
#
# Two warnings the packager raises about every IP in this tree, and what it
# takes to answer them.
#==============================================================================

proc cva5_ip_metadata {description {freq_hz 0}} {
    set core [ipx::current_core]

    # WARNING: [IP_Flow 19-11888] Component Definition '...': IP description
    #          "cva5_top_v1_0" is not meaningful: same as name or display name
    #
    # ipx::package_project seeds the description from the module name, and the
    # check wants something a reader of the IP catalog can use. It has to differ
    # from both the name and the display name, so the display name is left as
    # the module name and this carries the sentence.
    set_property description $description $core

    # WARNING: [IP_Flow 19-11770] Clock interface 'clk' has no FREQ_HZ
    #          parameter.
    #
    # Every block here takes one clock and none of them derive anything from
    # its rate: the UART's baud divisor and the CLINT's prescaler are module
    # parameters, not functions of FREQ_HZ. So this is a declaration with a
    # default rather than something the RTL reads, and value_resolve_type user
    # lets the block design propagate the real frequency into it -- without
    # that, a clk_wiz set to anything other than the default would be a
    # propagation mismatch instead of a value.
    if {$freq_hz > 0} {
        set clk_if [ipx::get_bus_interfaces clk -of_objects $core]
        if {[llength $clk_if] == 0} {
            error "cva5_ip_metadata: no clock interface named clk on this core"
        }
        # Listed rather than queried by name: a name query that matches nothing
        # is itself a warning, and this runs on a freshly packaged core where
        # FREQ_HZ is the parameter that does not exist yet.
        set have_freq 0
        foreach p [ipx::get_bus_parameters -of_objects $clk_if] {
            if {[get_property name $p] eq "FREQ_HZ"} {
                set have_freq 1
            }
        }
        if {!$have_freq} {
            ipx::add_bus_parameter FREQ_HZ $clk_if
        }
        set freq [ipx::get_bus_parameters FREQ_HZ -of_objects $clk_if]
        set_property value $freq_hz $freq
        set_property value_resolve_type user $freq
    }
}

# Both warnings are raised a second time, earlier, by ipx::package_project
# itself -- before there is a component to set anything on, so that occurrence
# cannot be answered from here and is the one that remains in the log. What
# this removes is the pass raised by ipx::check_integrity, which is the pass
# that reports on the IP as it ships.
#
# Two the packager raises that nothing in this tree can answer:
#
#   WARNING: [IP_Flow 19-2187] The Product Guide file is missing.
#
#       It wants a vendor datasheet in a xilinx_productguide file group. There
#       is no such document and README.pynq_z2.md is not one.
#
#   WARNING: [IP_Flow 19-5101] Packaging a component with a SystemVerilog top
#            file is not fully supported.
#
#       Raised for each block whose top is SystemVerilog, which is all of them
#       but cva5_top. It is a general caution, and the 19-5107 lines that
#       follow it show inference worked anyway: every AXI interface, the reset,
#       the clock and the interrupts are found. That holds because these
#       wrappers keep flat port lists -- no structs, no interfaces at the
#       boundary -- which is the condition the warning is really about. The
#       alternative is a Verilog shim per block, and README.pynq_z2.md is
#       clear about the cost of maintaining the one shim this tree has.
