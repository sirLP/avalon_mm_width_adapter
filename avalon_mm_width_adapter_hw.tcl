# =============================================================================
# avalon_mm_width_adapter_hw.tcl
# Platform Designer (Qsys) Component Descriptor
#
# Registers the Avalon-MM configurable width adapter as a reusable IP
# component that can be instantiated from the Platform Designer GUI or
# scripted with create_system / add_instance TCL flows.
#
# Author : GitHub Copilot
# Date   : 2026-04-03
# =============================================================================

package require -exact qsys 1.0

# -----------------------------------------------------------------------------
# Component identity
# -----------------------------------------------------------------------------
set_module_property NAME         avalon_mm_width_adapter
set_module_property VERSION      1.0
set_module_property GROUP        "Bridges and Adapters"
set_module_property DISPLAY_NAME "Avalon-MM Configurable Width Adapter"
set_module_property DESCRIPTION  \
    "Adapts between Avalon-MM master and slave ports operating at different \
     data widths.  Supports upsizing (narrow → wide) and downsizing \
     (wide → narrow) with a power-of-two ratio (1×, 2×, 4×, 8×)."
set_module_property AUTHOR       "GitHub Copilot"
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE     true
set_module_property ELABORATION_CALLBACK      elaboration_callback
set_module_property VALIDATION_CALLBACK       validation_callback

# -----------------------------------------------------------------------------
# Source files
# -----------------------------------------------------------------------------
add_fileset          QUARTUS_SYNTH QUARTUS_SYNTH
set_fileset_property QUARTUS_SYNTH TOP_LEVEL avalon_mm_width_adapter
add_fileset_file     avalon_mm_width_adapter.vhd \
                         VHDL PATH avalon_mm_width_adapter.vhd

add_fileset          SIM_VHDL SIM_VHDL
set_fileset_property SIM_VHDL TOP_LEVEL avalon_mm_width_adapter
add_fileset_file     avalon_mm_width_adapter.vhd \
                         VHDL PATH avalon_mm_width_adapter.vhd

# -----------------------------------------------------------------------------
# Parameters
# -----------------------------------------------------------------------------
add_parameter ADDR_WIDTH   NATURAL 32
set_parameter_property ADDR_WIDTH   DISPLAY_NAME "Address Width (bits)"
set_parameter_property ADDR_WIDTH   DESCRIPTION  \
    "Width of the byte address bus (same on both ports)."
set_parameter_property ADDR_WIDTH   ALLOWED_RANGES {8:64}
set_parameter_property ADDR_WIDTH   HDL_PARAMETER true

add_parameter S_DATA_WIDTH NATURAL 32
set_parameter_property S_DATA_WIDTH DISPLAY_NAME "Slave-Port Data Width (bits)"
set_parameter_property S_DATA_WIDTH DESCRIPTION  \
    "Data width of the slave (upstream) port."
set_parameter_property S_DATA_WIDTH ALLOWED_RANGES {8 16 32 64 128 256 512}
set_parameter_property S_DATA_WIDTH HDL_PARAMETER true

add_parameter M_DATA_WIDTH NATURAL 64
set_parameter_property M_DATA_WIDTH DISPLAY_NAME "Master-Port Data Width (bits)"
set_parameter_property M_DATA_WIDTH DESCRIPTION  \
    "Data width of the master (downstream) port."
set_parameter_property M_DATA_WIDTH ALLOWED_RANGES {8 16 32 64 128 256 512}
set_parameter_property M_DATA_WIDTH HDL_PARAMETER true

add_parameter SYMBOL_WIDTH NATURAL 8
set_parameter_property SYMBOL_WIDTH DISPLAY_NAME "Symbol Width (bits)"
set_parameter_property SYMBOL_WIDTH DESCRIPTION  \
    "Bits per addressable symbol (almost always 8 for byte-addressed systems)."
set_parameter_property SYMBOL_WIDTH ALLOWED_RANGES {8 16 32}
set_parameter_property SYMBOL_WIDTH HDL_PARAMETER true

# Derived / display-only parameters
add_parameter WIDTH_RATIO  NATURAL 1
set_parameter_property WIDTH_RATIO  DISPLAY_NAME "Width Ratio"
set_parameter_property WIDTH_RATIO  DESCRIPTION  \
    "Computed ratio between the larger and smaller data bus (read-only)."
set_parameter_property WIDTH_RATIO  HDL_PARAMETER false
set_parameter_property WIDTH_RATIO  DERIVED       true

# -----------------------------------------------------------------------------
# Validation callback – enforce power-of-two ratio constraint
# -----------------------------------------------------------------------------
proc validation_callback {} {
    set sw [get_parameter_value S_DATA_WIDTH]
    set mw [get_parameter_value M_DATA_WIDTH]

    if {$sw <= 0 || $mw <= 0} {
        send_message ERROR "Data widths must be positive integers."
        return
    }

    # Compute ratio
    set larger  [expr {$sw > $mw ? $sw : $mw}]
    set smaller [expr {$sw < $mw ? $sw : $mw}]
    set ratio   [expr {$larger / $smaller}]

    # Check exact divisibility
    if {[expr {$larger % $smaller}] != 0} {
        send_message ERROR \
            "Data widths must be exact multiples of each other \
             (S=$sw, M=$mw, ratio=${ratio}r[expr {$larger % $smaller}])."
        return
    }

    # Check power of two
    if {($ratio & ($ratio - 1)) != 0} {
        send_message ERROR \
            "Width ratio must be a power of two (got $ratio for S=${sw} → M=${mw})."
        return
    }

    if {$ratio > 8} {
        send_message WARNING \
            "Width ratio $ratio is supported but may result in high resource usage."
    }

    set_parameter_value WIDTH_RATIO $ratio

    set sym [get_parameter_value SYMBOL_WIDTH]
    if {[expr {$sw % $sym}] != 0 || [expr {$mw % $sym}] != 0} {
        send_message ERROR \
            "Both data widths must be multiples of SYMBOL_WIDTH ($sym)."
    }
}

# -----------------------------------------------------------------------------
# Elaboration callback – create interfaces with correct widths
# -----------------------------------------------------------------------------
proc elaboration_callback {} {
    set aw  [get_parameter_value ADDR_WIDTH  ]
    set sw  [get_parameter_value S_DATA_WIDTH]
    set mw  [get_parameter_value M_DATA_WIDTH]
    set sym [get_parameter_value SYMBOL_WIDTH]

    set s_be_w [expr {$sw / $sym}]
    set m_be_w [expr {$mw / $sym}]

    # -------------------------------------------------------------------
    # Clock interface
    # -------------------------------------------------------------------
    add_interface            clk clock end
    set_interface_property   clk ENABLED true
    add_interface_port       clk clk clk Input 1

    # -------------------------------------------------------------------
    # Reset interface
    # -------------------------------------------------------------------
    add_interface            reset reset end
    set_interface_property   reset associatedClock clk
    set_interface_property   reset synchronousEdges DEASSERT
    add_interface_port       reset reset reset Input 1

    # -------------------------------------------------------------------
    # Slave Avalon-MM interface  (upstream)
    # -------------------------------------------------------------------
    add_interface            s0 avalon end
    set_interface_property   s0 associatedClock   clk
    set_interface_property   s0 associatedReset   reset
    set_interface_property   s0 readLatency       0
    set_interface_property   s0 readWaitTime      1
    set_interface_property   s0 writeWaitTime     0
    set_interface_property   s0 maximumPendingReadTransactions 16

    add_interface_port s0 s_address       address     Input  $aw
    add_interface_port s0 s_read          read        Input  1
    add_interface_port s0 s_write         write       Input  1
    add_interface_port s0 s_writedata     writedata   Input  $sw
    add_interface_port s0 s_byteenable    byteenable  Input  $s_be_w
    add_interface_port s0 s_readdata      readdata    Output $sw
    add_interface_port s0 s_readdatavalid readdatavalid Output 1
    add_interface_port s0 s_waitrequest   waitrequest Output 1

    # -------------------------------------------------------------------
    # Master Avalon-MM interface  (downstream)
    # -------------------------------------------------------------------
    add_interface            m0 avalon start
    set_interface_property   m0 associatedClock   clk
    set_interface_property   m0 associatedReset   reset
    set_interface_property   m0 readLatency       0
    set_interface_property   m0 doStreamReads     false
    set_interface_property   m0 doStreamWrites    false
    set_interface_property   m0 maximumPendingReadTransactions 16

    add_interface_port m0 m_address       address       Output $aw
    add_interface_port m0 m_read          read          Output 1
    add_interface_port m0 m_write         write         Output 1
    add_interface_port m0 m_writedata     writedata     Output $mw
    add_interface_port m0 m_byteenable    byteenable    Output $m_be_w
    add_interface_port m0 m_readdata      readdata      Input  $mw
    add_interface_port m0 m_readdatavalid readdatavalid Input  1
    add_interface_port m0 m_waitrequest   waitrequest   Input  1
}
