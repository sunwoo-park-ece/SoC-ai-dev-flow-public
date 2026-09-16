# GTKWave Tcl script: auto-add major debug signals by profile.
# Inputs (optional env vars):
#   GTKW_PROFILE    : generic|fifo|apb|aes|soc
#   GTKW_REGEX_FILE : newline-delimited regex file (comments # allowed)

proc default_patterns {profile} {
    switch -- $profile {
        fifo {
            return {
                {clk} {rst|reset}
                {wr(_en)?|write} {rd(_en)?|read}
                {full|empty|almost_full|almost_empty}
                {count|level|used}
                {din|dout|data_in|data_out|wdata|rdata}
                {valid|ready}
            }
        }
        apb {
            return {
                {pclk|presetn}
                {psel|penable|pwrite|paddr|pwdata|prdata|pready|pslverr}
                {ctrl|control|status|busy|done|start|error|tag_ok}
                {key|iv|nonce|seq|len|payload|tag|ct|pt}
                {valid|ready}
            }
        }
        aes {
            return {
                {clk|rst|reset}
                {key|iv|nonce|aad}
                {payload|plain|pt|cipher|ct|tag}
                {start|busy|done|error|valid|ready}
                {state|fsm}
            }
        }
        soc {
            return {
                {clk|rst|reset}
                {haddr|hwrite|htrans|hsize|hburst|hready|hresp|hwdata|hrdata}
                {paddr|pwrite|psel|penable|pwdata|prdata|pready}
                {aw(valid|ready|addr|len|size|burst|id)|w(valid|ready|data|strb|last)|b(valid|ready|resp|id)|ar(valid|ready|addr|len|size|burst|id)|r(valid|ready|data|resp|last|id)}
                {dma|irq|intr|intc|timer}
                {start|busy|done|error}
            }
        }
        default {
            return {
                {clk|rst|reset}
                {valid|ready}
                {addr|data|wdata|rdata}
                {write|read|wr|rd}
                {req|ack|grant}
                {start|busy|done|error}
            }
        }
    }
}

proc file_patterns {path} {
    set plist [list]
    if {$path eq ""} { return $plist }
    if {![file exists $path]} { return $plist }

    set fd [open $path r]
    while {[gets $fd line] >= 0} {
        set s [string trim $line]
        if {$s eq ""} { continue }
        if {[string first "#" $s] == 0} { continue }
        lappend plist $s
    }
    close $fd
    return $plist
}

set profile "generic"
if {[info exists ::env(GTKW_PROFILE)] && $::env(GTKW_PROFILE) ne ""} {
    set profile $::env(GTKW_PROFILE)
}

set patterns [default_patterns $profile]
if {[info exists ::env(GTKW_REGEX_FILE)]} {
    set patterns [concat $patterns [file_patterns $::env(GTKW_REGEX_FILE)]]
}

set nfacs [gtkwave::getNumFacs]
set matched [list]

for {set i 0} {$i < $nfacs} {incr i} {
    set facname [gtkwave::getFacName $i]
    set hit 0
    foreach p $patterns {
        if {[regexp -nocase -- $p $facname]} {
            set hit 1
            break
        }
    }
    if {$hit} {
        lappend matched $facname
    }
}

set added 0
if {[llength $matched] > 0} {
    set added [gtkwave::addSignalsFromList $matched]
}

# Fallback: if no match, at least add clocks/resets if present.
if {$added == 0} {
    set fallback [list]
    for {set i 0} {$i < $nfacs} {incr i} {
        set facname [gtkwave::getFacName $i]
        if {[regexp -nocase -- {clk|rst|reset} $facname]} {
            lappend fallback $facname
        }
    }
    if {[llength $fallback] > 0} {
        set added [gtkwave::addSignalsFromList $fallback]
    }
}

puts "GTKWAVE_PROFILE=$profile"
puts "GTKWAVE_SIGNALS_ADDED=$added"

# Full hierarchy display and full zoom.
gtkwave::/Edit/Set_Trace_Max_Hier 0
gtkwave::/Time/Zoom/Zoom_Full
